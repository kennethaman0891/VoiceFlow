import Cocoa
import SwiftUI
import Combine

// MARK: - FloatingHUDPanel

public final class FloatingHUDPanel: NSPanel {

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

// MARK: - FloatingHUDController

@MainActor
public final class FloatingHUDController: ObservableObject {
    public static let shared = FloatingHUDController()

    public static let positionXKey = "voiceflow.floating_hud.x"
    public static let positionYKey = "voiceflow.floating_hud.y"

    public static let compactWidth: CGFloat = 340
    public static let compactHeight: CGFloat = 56
    public static let expandedWidth: CGFloat = 460
    public static let expandedHeight: CGFloat = 124

    private var panel: FloatingHUDPanel?
    private var cancellables = Set<AnyCancellable>()
    private var appState: AppState?
    private var isExpanded: Bool = false
    private var isProgrammaticResize: Bool = false

    public init() {}

    public func configure(
        appState: AppState,
        onToggle: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.appState = appState
        cancellables.removeAll()

        let initialRect = Self.calculateInitialFrame()
        let hudPanel = FloatingHUDPanel(contentRect: initialRect)

        let hudView = FloatingHUDView(
            appState: appState,
            onToggle: onToggle,
            onCancel: onCancel
        )

        let hostingView = NSHostingView(rootView: hudView)
        hudPanel.contentView = hostingView
        self.panel = hudPanel

        // Save position on move
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: hudPanel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak hudPanel] _ in
                guard let self, let panel = hudPanel, !self.isProgrammaticResize else { return }

                // When expanded, convert origin back to compact baseline so it persists consistently
                let originX = self.isExpanded
                    ? panel.frame.minX + (Self.expandedWidth - Self.compactWidth) / 2
                    : panel.frame.minX
                let originY = self.isExpanded
                    ? panel.frame.minY + (Self.expandedHeight - Self.compactHeight)
                    : panel.frame.minY

                UserDefaults.standard.set(Double(originX), forKey: Self.positionXKey)
                UserDefaults.standard.set(Double(originY), forKey: Self.positionYKey)
            }
            .store(in: &cancellables)

        // Bind to phase and live transcript changes
        Publishers.CombineLatest(appState.$phase, appState.$liveTranscript)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase, transcript in
                guard let self else { return }
                self.handlePhaseChange(phase)
                let isRecording = (phase == .recording || phase == .handsFree)
                let hasTranscript = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                self.updateFrame(expanded: isRecording && hasTranscript)
            }
            .store(in: &cancellables)
    }

    public func updateFrame(expanded: Bool) {
        guard let panel else { return }
        guard expanded != isExpanded else { return }
        isExpanded = expanded

        let newWidth = expanded ? Self.expandedWidth : Self.compactWidth
        let newHeight = expanded ? Self.expandedHeight : Self.compactHeight

        let currentWidth = panel.frame.width
        let currentHeight = panel.frame.height

        let deltaY = newHeight - currentHeight
        let newOrigin = NSPoint(
            x: panel.frame.minX - (newWidth - currentWidth) / 2,
            y: panel.frame.minY - deltaY
        )

        let targetRect = NSRect(origin: newOrigin, size: CGSize(width: newWidth, height: newHeight))

        isProgrammaticResize = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetRect, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isProgrammaticResize = false
            }
        })
    }

    public func show() {
        guard let panel else { return }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1.0
            }
        }
    }

    public func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak panel] in
            MainActor.assumeIsolated {
                panel?.orderOut(nil)
            }
        })
    }

    private func handlePhaseChange(_ phase: DictationPhase) {
        switch phase {
        case .recording, .handsFree, .transcribing, .success:
            show()
        case .idle:
            // Delay hide slightly so success flash or transition completes cleanly
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                if self.appState?.phase == .idle {
                    self.hide()
                }
            }
        }
    }

    private static func calculateInitialFrame() -> NSRect {
        let width = Self.compactWidth
        let height = Self.compactHeight

        let defaults = UserDefaults.standard
        let hasSavedX = defaults.object(forKey: positionXKey) != nil
        let hasSavedY = defaults.object(forKey: positionYKey) != nil

        let primaryScreen = NSScreen.main ?? NSScreen.screens.first
        let primaryVisible = primaryScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultOrigin = NSPoint(
            x: primaryVisible.midX - width / 2,
            y: primaryVisible.minY + 70
        )

        guard hasSavedX && hasSavedY else {
            return NSRect(origin: defaultOrigin, size: CGSize(width: width, height: height))
        }

        let savedX = defaults.double(forKey: positionXKey)
        let savedY = defaults.double(forKey: positionYKey)
        let candidateRect = NSRect(x: savedX, y: savedY, width: width, height: height)

        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.visibleFrame.intersects(candidateRect) }) else {
            // Off-screen (e.g. external monitor unplugged) -> reset to primary screen default
            return NSRect(origin: defaultOrigin, size: CGSize(width: width, height: height))
        }

        // Clamp inside screen visibleFrame with safe padding
        let visible = screen.visibleFrame
        var clampedX = candidateRect.minX
        var clampedY = candidateRect.minY

        if clampedX < visible.minX {
            clampedX = visible.minX + 16
        } else if clampedX + width > visible.maxX {
            clampedX = visible.maxX - width - 16
        }

        if clampedY < visible.minY {
            clampedY = visible.minY + 16
        } else if clampedY + height > visible.maxY {
            clampedY = visible.maxY - height - 16
        }

        return NSRect(x: clampedX, y: clampedY, width: width, height: height)
    }
}
