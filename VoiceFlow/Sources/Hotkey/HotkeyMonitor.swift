import Foundation
import Cocoa
import CoreGraphics
import IOKit.hidsystem

// MARK: - PhysicalKey

/// Represents a physical key on the keyboard using its keycode.
struct PhysicalKey: Hashable, Equatable {
    let keyCode: UInt16
    let displayName: String

    init(keyCode: UInt16) {
        self.keyCode = keyCode
        self.displayName = Self.keyName(for: keyCode)
    }

    // Common key shortcuts
    static let control = PhysicalKey(keyCode: 59) // Left Control
    static let v = PhysicalKey(keyCode: 9)        // V key
    static let space = PhysicalKey(keyCode: 49)   // Space
    static let escape = PhysicalKey(keyCode: 53)  // Escape
    static let enter = PhysicalKey(keyCode: 36)   // Enter/Return
    static let tab = PhysicalKey(keyCode: 48)     // Tab
    static let shift = PhysicalKey(keyCode: 56)   // Left Shift
    static let command = PhysicalKey(keyCode: 55) // Left Command
    static let option = PhysicalKey(keyCode: 58)  // Left Option

    var isModifierKey: Bool {
        modifierMaskRawValue != nil
    }

    private var modifierMaskRawValue: UInt64? {
        switch keyCode {
        case 54: UInt64(NX_DEVICERCMDKEYMASK | NX_COMMANDMASK)
        case 55: UInt64(NX_DEVICELCMDKEYMASK | NX_COMMANDMASK)
        case 56: UInt64(NX_DEVICELSHIFTKEYMASK | NX_SHIFTMASK)
        case 57: CGEventFlags.maskAlphaShift.rawValue
        case 58: UInt64(NX_DEVICELALTKEYMASK | NX_ALTERNATEMASK)
        case 59: UInt64(NX_DEVICELCTLKEYMASK | NX_CONTROLMASK)
        case 60: UInt64(NX_DEVICERSHIFTKEYMASK | NX_SHIFTMASK)
        case 61: UInt64(NX_DEVICERALTKEYMASK | NX_ALTERNATEMASK)
        case 62: UInt64(NX_DEVICERCTLKEYMASK | NX_CONTROLMASK)
        case 63: CGEventFlags.maskSecondaryFn.rawValue
        default: nil
        }
    }

    fileprivate var modifierMaskRawValueForCallback: UInt64? {
        return modifierMaskRawValue
    }

    private static func keyName(for keyCode: UInt16) -> String {
        // Try to get the localized key name
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true) else {
            return "Key\(keyCode)"
        }
        // Use keyboardGetUnicodeString to get the key name
        var buffer = [UniChar](repeating: 0, count: 4)
        var actualLength: CFIndex = 0
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &actualLength, unicodeString: &buffer)
        if actualLength > 0 {
            return String(utf16CodeUnits: buffer, count: Int(actualLength))
        }
        return "Key\(keyCode)"
    }
}

// MARK: - KeyChord

/// A chord is a combination of keys that must be pressed together.
struct KeyChord: Hashable {
    let keys: Set<PhysicalKey>

    var displayString: String {
        keys.map(\.displayName).sorted().joined(separator: " + ")
    }

    init(keys: [PhysicalKey]) {
        self.keys = Set(keys)
    }

    init(_ keys: PhysicalKey...) {
        self.keys = Set(keys)
    }
}

// MARK: - ChordAction

enum ChordAction: String, CaseIterable {
    case holdToTalk = "hold-to-talk"
    case toggleTalk = "toggle-to-talk"
}

// MARK: - EventSnapshot

private struct EventSnapshot {
    let type: CGEventType
    let key: PhysicalKey
    let flags: CGEventFlags
}

private extension EventSnapshot {
    init?(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged, .keyDown, .keyUp:
            self.init(
                type: type,
                key: PhysicalKey(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode))),
                flags: event.flags
            )
        default:
            return nil
        }
    }
}

// MARK: - C Callback

// Global callback function that can be passed as a C function pointer
@_cdecl("hotkeyCallback")
func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    // Re-enable tap if disabled by system
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        if let tap = monitor.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.handleEvent(type, event: event)
    return Unmanaged.passUnretained(event)
}

// MARK: - HotkeyMonitor

protocol HotkeyMonitoring: AnyObject {
    var onRecordingStart: (@Sendable () -> Void)? { get set }
    var onRecordingStop: (@Sendable () -> Void)? { get set }
    var onRecordingRestart: (@Sendable () -> Void)? { get set }

    func start() -> Bool
    func stop()
    func updateBindings(_ bindings: [ChordAction: KeyChord])
}

/// Monitors configured key chords for hold-to-talk using a CGEvent tap.
/// Requires Accessibility permission to create the event tap.
final class HotkeyMonitor: NSObject, HotkeyMonitoring, @unchecked Sendable {

    // MARK: - Callbacks

    var onRecordingStart: (@Sendable () -> Void)?
    var onRecordingStop: (@Sendable () -> Void)?
    var onRecordingRestart: (@Sendable () -> Void)?

    // MARK: - State

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventThread: Thread?
    private var bindings: [ChordAction: KeyChord]
    private var monitoredKeys: Set<PhysicalKey>
    private var isSuspended = false
    private let stateLock = NSLock()

    // MARK: - Init

    init(bindings: [ChordAction: KeyChord] = [:]) {
        self.bindings = bindings
        self.monitoredKeys = bindings.values.reduce(into: Set<PhysicalKey>()) { keys, chord in
            keys.formUnion(chord.keys)
        }
        super.init()
    }

    // MARK: - Public API

    /// Starts monitoring for key chord events.
    /// - Returns: `false` if Accessibility permission is denied.
    func start() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard eventTap == nil else { return true }

        let thread = Thread { @Sendable [weak self] in
            guard let self else { return }
            self.runEventLoop()
        }
        thread.name = "VoiceFlow Hotkey Monitor"
        thread.start()
        eventThread = thread

        // Give the thread time to initialize
        usleep(100000) // 100ms

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            stop()
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source

        return true
    }

    /// Stops monitoring and cleans up the event tap.
    func stop() {
        stateLock.lock()
        let tap = eventTap
        let source = runLoopSource
        eventTap = nil
        runLoopSource = nil
        stateLock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        eventThread = nil
    }

    func updateBindings(_ bindings: [ChordAction: KeyChord]) {
        stateLock.lock()
        self.bindings = bindings
        monitoredKeys = bindings.values.reduce(into: Set<PhysicalKey>()) { keys, chord in
            keys.formUnion(chord.keys)
        }
        stateLock.unlock()
    }

    // MARK: - Private

    private func runEventLoop() {
        RunLoop.current.run()
    }

    internal func handleEvent(_ type: CGEventType, event: CGEvent) {
        guard let snapshot = EventSnapshot(type: type, event: event) else { return }

        stateLock.lock()
        let suspended = isSuspended
        stateLock.unlock()

        guard !suspended else { return }

        let pressedKeys = currentPressedKeys()

        switch type {
        case .flagsChanged, .keyDown, .keyUp:
            processKeyEvent(snapshot.key, pressedKeys: pressedKeys, type: type)
        default:
            break
        }
    }

    private func processKeyEvent(_ key: PhysicalKey, pressedKeys: Set<PhysicalKey>, type: CGEventType) {
        // Check if this key is part of any binding
        for (_, chord) in bindings {
            let isPartOfChord = chord.keys.contains(key)
            let allKeysPressed = chord.keys.isSubset(of: pressedKeys)

            switch type {
            case .keyDown:
                if isPartOfChord && allKeysPressed {
                    let callback = onRecordingStart
                    if let callback {
                        DispatchQueue.main.async {
                            callback()
                        }
                    }
                }
            case .keyUp:
                if isPartOfChord && !allKeysPressed {
                    let callback = onRecordingStop
                    if let callback {
                        DispatchQueue.main.async {
                            callback()
                        }
                    }
                }
            default:
                break
            }
        }
    }

    private func currentPressedKeys() -> Set<PhysicalKey> {
        var keys = Set<PhysicalKey>()

        // Check modifier keys
        let flags = CGEventSource.flagsState(.combinedSessionState)
        for monitoredKey in monitoredKeys where monitoredKey.isModifierKey {
            if let mask = monitoredKey.modifierMaskRawValueForCallback,
               flags.rawValue & mask == mask {
                keys.insert(monitoredKey)
            }
        }

        // Check non-modifier keys
        for monitoredKey in monitoredKeys where !monitoredKey.isModifierKey {
            if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(monitoredKey.keyCode)) {
                keys.insert(monitoredKey)
            }
        }

        return keys
    }
}