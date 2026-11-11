import Foundation
import Cocoa
import CoreGraphics
import IOKit.hidsystem

// MARK: - PhysicalKey

/// Represents a physical key on the keyboard using its keycode.
public struct PhysicalKey: Hashable, Equatable, Sendable {
    public let keyCode: UInt16
    public let displayName: String

    public init(keyCode: UInt16) {
        self.keyCode = keyCode
        self.displayName = Self.keyName(for: keyCode)
    }

    // Common key shortcuts
    public static let control = PhysicalKey(keyCode: 59) // Left Control
    public static let v = PhysicalKey(keyCode: 9)        // V key
    public static let space = PhysicalKey(keyCode: 49)   // Space
    public static let escape = PhysicalKey(keyCode: 53)  // Escape
    public static let enter = PhysicalKey(keyCode: 36)   // Enter/Return
    public static let tab = PhysicalKey(keyCode: 48)     // Tab
    public static let shift = PhysicalKey(keyCode: 56)   // Left Shift
    public static let command = PhysicalKey(keyCode: 55) // Left Command
    public static let rightCommand = PhysicalKey(keyCode: 54) // Right Command
    public static let option = PhysicalKey(keyCode: 58)  // Left Option
    public static let rightOption = PhysicalKey(keyCode: 61) // Right Option

    public var isModifierKey: Bool {
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
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true) else {
            return "Key\(keyCode)"
        }
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

public struct KeyChord: Hashable, Sendable {
    public let keys: Set<PhysicalKey>

    public var displayString: String {
        keys.map(\.displayName).sorted().joined(separator: " + ")
    }

    public init(keys: [PhysicalKey]) {
        self.keys = Set(keys)
    }

    public init(_ keys: PhysicalKey...) {
        self.keys = Set(keys)
    }

    public static let optionSpace = KeyChord(.option, .space)
    public static let controlHold = KeyChord(.control)
    public static let controlV = KeyChord(.control, .v)
}

// MARK: - ChordAction

public enum ChordAction: String, CaseIterable, Sendable {
    case holdToTalk = "hold-to-talk"
    case toggleTalk = "toggle-to-talk"
    case handsFree = "hands-free"
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

@_cdecl("hotkeyCallback")
func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

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

public protocol HotkeyMonitoring: AnyObject {
    var onRecordingStart: (@Sendable () -> Void)? { get set }
    var onRecordingStop: (@Sendable () -> Void)? { get set }
    var onHandsFreeToggle: (@Sendable () -> Void)? { get set }
    var onRecordingCancel: (@Sendable () -> Void)? { get set }

    func start() -> Bool
    func stop()
    func updateBindings(_ bindings: [ChordAction: KeyChord])
}

public final class HotkeyMonitor: NSObject, HotkeyMonitoring, @unchecked Sendable {

    // MARK: - Callbacks

    public var onRecordingStart: (@Sendable () -> Void)?
    public var onRecordingStop: (@Sendable () -> Void)?
    public var onHandsFreeToggle: (@Sendable () -> Void)?
    public var onRecordingCancel: (@Sendable () -> Void)?

    // MARK: - State

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventThread: Thread?
    private var bindings: [ChordAction: KeyChord]
    private var monitoredKeys: Set<PhysicalKey>
    private var isSuspended = false
    private let stateLock = NSLock()
    private var holdMachine = HotkeyStateMachine()

    public init(bindings: [ChordAction: KeyChord] = [:]) {
        var merged = bindings
        if merged.isEmpty {
            merged[.holdToTalk] = .controlHold
        }
        self.bindings = merged
        var keys = merged.values.reduce(into: Set<PhysicalKey>()) { k, chord in
            k.formUnion(chord.keys)
        }
        // Always monitor Escape key for quick cancellation
        keys.insert(PhysicalKey.escape)
        self.monitoredKeys = keys
        super.init()
    }

    public func start() -> Bool {
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

    public func stop() {
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

    public func updateBindings(_ bindings: [ChordAction: KeyChord]) {
        stateLock.lock()
        self.bindings = bindings
        var keys = bindings.values.reduce(into: Set<PhysicalKey>()) { k, chord in
            k.formUnion(chord.keys)
        }
        keys.insert(PhysicalKey.escape)
        monitoredKeys = keys
        stateLock.unlock()
    }

    public func setHandsFreeState(_ active: Bool) {
        stateLock.lock()
        holdMachine.handsFreeActive = active
        stateLock.unlock()
    }

    private func runEventLoop() {
        RunLoop.current.run()
    }

    internal func handleEvent(_ type: CGEventType, event: CGEvent) {
        guard let snapshot = EventSnapshot(type: type, event: event) else { return }

        stateLock.lock()
        let suspended = isSuspended
        stateLock.unlock()

        guard !suspended else { return }

        if snapshot.key.keyCode == PhysicalKey.escape.keyCode && type == .keyDown {
            stateLock.lock()
            _ = holdMachine.escapePressed()
            stateLock.unlock()
            dispatch(.cancel)
            return
        }

        let pressedKeys = currentPressedKeys()
        processKeyEvent(snapshot.key, pressedKeys: pressedKeys)
    }

    private func processKeyEvent(_ key: PhysicalKey, pressedKeys: Set<PhysicalKey>) {
        guard let chord = bindings[.holdToTalk], chord.keys.contains(key) else { return }
        let allKeysPressed = chord.keys.isSubset(of: pressedKeys)

        stateLock.lock()
        let effect: HotkeyStateMachine.Effect
        if allKeysPressed {
            effect = holdMachine.chordBecamePressed(at: Date())
        } else {
            effect = holdMachine.chordBecameReleased(at: Date())
        }
        stateLock.unlock()
        dispatch(effect)
    }

    private func dispatch(_ effect: HotkeyStateMachine.Effect) {
        let callback: (@Sendable () -> Void)?
        switch effect {
        case .startHold:
            callback = onRecordingStart
        case .stopHold:
            callback = onRecordingStop
        case .toggleHandsFree:
            callback = onHandsFreeToggle
        case .cancel:
            callback = onRecordingCancel
        case .none:
            callback = nil
        }
        guard let callback else { return }
        DispatchQueue.main.async { callback() }
    }

    private func currentPressedKeys() -> Set<PhysicalKey> {
        var keys = Set<PhysicalKey>()

        let flags = CGEventSource.flagsState(.combinedSessionState)
        for monitoredKey in monitoredKeys where monitoredKey.isModifierKey {
            if let mask = monitoredKey.modifierMaskRawValueForCallback,
               flags.rawValue & mask == mask {
                keys.insert(monitoredKey)
            }
        }

        // Either Control key satisfies a Control-only hold chord. Device-dependent
        // bits are not always set on flagsState, so the generic Control bit counts.
        if monitoredKeys.contains(.control),
           flags.rawValue & CGEventFlags.maskControl.rawValue == CGEventFlags.maskControl.rawValue {
            keys.insert(.control)
        }

        for monitoredKey in monitoredKeys where !monitoredKey.isModifierKey {
            if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(monitoredKey.keyCode)) {
                keys.insert(monitoredKey)
            }
        }

        return keys
    }
}
