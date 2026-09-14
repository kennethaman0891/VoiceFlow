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

    private static func keyName(for keyCode: UInt16) -> String {
        guard let cfString = CGKeyCodeToAppleKeymapKeyCodeString(keyCode) else { return "Key\(keyCode)" }
        return cfString as String
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

// MARK: - HotkeyMonitor

protocol HotkeyMonitoring: AnyObject {
    var onRecordingStart: (() -> Void)? { get set }
    var onRecordingStop: (() -> Void)? { get set }
    var onRecordingRestart: (() -> Void)? { get set }

    func start() -> Bool
    func stop()
    func updateBindings(_ bindings: [ChordAction: KeyChord])
}

/// Monitors configured key chords for hold-to-talk using a CGEvent tap.
/// Requires Accessibility permission to create the event tap.
final class HotkeyMonitor: NSObject, HotkeyMonitoring {

    // MARK: - Callbacks

    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?
    var onRecordingRestart: (() -> Void)?

    // MARK: - State

    private var eventTap: CFMachPort?
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

        let thread = Thread { [weak self] in
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

    private func handleEvent(_ type: CGEventType, event: CGEvent) {
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
        for (action, chord) in bindings {
            let isPartOfChord = chord.keys.contains(key)
            let allKeysPressed = chord.keys.isSubset(of: pressedKeys)

            switch type {
            case .keyDown:
                if isPartOfChord && allKeysPressed {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.onRecordingStart?()
                    }
                }
            case .keyUp:
                if isPartOfChord && !allKeysPressed {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.onRecordingStop?()
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
            if let mask = monitoredKey.modifierMaskRawValue,
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

    // MARK: - C Callback

    @private static func hotkeyCallback(
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
}

// MARK: - EventSnapshot

private extension HotkeyMonitor {
    struct EventSnapshot {
        let type: CGEventType
        let key: PhysicalKey
        let flags: CGEventFlags
    }
}

private extension HotkeyMonitor.EventSnapshot {
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

// MARK: - Key Code Helper

private func CGKeyCodeToAppleKeymapKeyCodeString(_ keyCode: UInt16) -> CFString? {
    let source = CGEventSource(stateID: .hidSystemState)
    guard let event = CGEvent(keyboardEventKeyboardType: 1, key: keyCode) else {
        return nil
    }
    return event.characters
}
