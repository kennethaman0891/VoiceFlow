import SwiftUI
import AppKit

// MARK: - FloatingHUDView

public struct FloatingHUDView: View {
    @ObservedObject var appState: AppState
    var onToggle: () -> Void
    var onCancel: () -> Void

    @State private var isStopHovered: Bool = false
    @State private var isCancelHovered: Bool = false
    @State private var isDragHovered: Bool = false
    @State private var isCaretVisible: Bool = true

    public init(
        appState: AppState,
        onToggle: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.appState = appState
        self.onToggle = onToggle
        self.onCancel = onCancel
    }

    private var isExpanded: Bool {
        appState.isRecording && !appState.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Main HUD capsule bar (always height 56)
            HStack(spacing: 10) {
                // 1. Elegant 6-dot drag handle
                ZStack {
                    WindowDragHandle()
                        .frame(width: 14, height: 26)

                    Image(systemName: "circle.grid.2x3.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isDragHovered ? Color.white.opacity(0.85) : Color.white.opacity(0.35))
                        .animation(.easeInOut(duration: 0.15), value: isDragHovered)
                }
                .frame(width: 14, height: 26)
                .onHover { isDragHovered = $0 }
                .help("Drag to reposition HUD")

                // 2. Status Indicator with Wispr Flow Circular Countdown Ring
                ZStack {
                    if appState.isSilenceCountingDown && appState.isHandsFree {
                        // Background track
                        Circle()
                            .stroke(Color.white.opacity(0.12), lineWidth: 2.5)
                            .frame(width: 32, height: 32)

                        // Countdown progress ring
                        Circle()
                            .trim(from: 0, to: CGFloat(appState.silenceProgress))
                            .stroke(
                                LinearGradient(
                                    colors: [Color.orange, Color.red],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                            )
                            .frame(width: 32, height: 32)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.1), value: appState.silenceProgress)
                    }

                    // Status icon badge
                    switch appState.phase {
                    case .recording:
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.cyan, Color.blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                            )
                            .shadow(color: Color.cyan.opacity(0.4), radius: 6, x: 0, y: 0)

                    case .handsFree:
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.cyan, Color.indigo],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: "waveform.badge.magnifyingglass")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            )
                            .shadow(color: Color.cyan.opacity(0.4), radius: 6, x: 0, y: 0)

                    case .transcribing:
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 26, height: 26)

                    case .success:
                        Circle()
                            .fill(Color.green)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            )
                            .shadow(color: Color.green.opacity(0.4), radius: 6, x: 0, y: 0)

                    default:
                        Circle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.4))
                            )
                    }
                }
                .frame(width: 32, height: 32)

                // 3. Middle Section: Mode & Audio Waveform
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(statusTitle)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)

                        if appState.isHandsFree {
                            Text("HANDS-FREE")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.2))
                                .foregroundColor(.cyan)
                                .cornerRadius(4)
                        }

                        if appState.isSilenceCountingDown && appState.isHandsFree {
                            Text(String(format: "Auto-stopping in %.1fs", appState.silenceRemainingSeconds))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundColor(.orange)
                                .transition(.opacity)
                        }
                    }

                    // Live symmetrical audio bars
                    if appState.isRecording {
                        HStack(spacing: 2.5) {
                            ForEach(0..<14, id: \.self) { i in
                                let sample = audioLevel(for: i)
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.cyan, Color.blue.opacity(0.9), Color.indigo.opacity(0.8)],
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(width: 2.5, height: max(3.5, CGFloat(sample * 18)))
                                    .animation(.easeOut(duration: 0.08), value: sample)
                            }
                        }
                        .frame(height: 18)
                    } else if appState.phase == .transcribing {
                        Text("Whisper transcription in progress...")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                    } else if appState.phase == .success {
                        Text("Inserted at cursor")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.green.opacity(0.9))
                    }
                }

                Spacer(minLength: 4)

                // 4. Actions: Stop & Cancel Buttons
                if appState.isRecording {
                    HStack(spacing: 8) {
                        Button(action: onToggle) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 24, height: 24)
                                .background(
                                    Circle()
                                        .fill(isStopHovered ? Color.red : Color.red.opacity(0.85))
                                )
                                .shadow(color: isStopHovered ? Color.red.opacity(0.5) : Color.clear, radius: 4, x: 0, y: 0)
                                .scaleEffect(isStopHovered ? 1.06 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .onHover { isStopHovered = $0 }
                        .help("Stop dictation")

                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(isCancelHovered ? .white : .white.opacity(0.8))
                                .frame(width: 24, height: 24)
                                .background(
                                    Circle()
                                        .fill(isCancelHovered ? Color.white.opacity(0.22) : Color.white.opacity(0.10))
                                )
                                .scaleEffect(isCancelHovered ? 1.06 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .onHover { isCancelHovered = $0 }
                        .help("Cancel (Esc)")
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 56)

            // 5. Expanded Handy Live Transcript HUD
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                        .background(Color.white.opacity(0.12))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)

                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 3) {
                                Text(appState.liveTranscript)
                                    .font(.system(size: 13, weight: .regular, design: .rounded))
                                    .foregroundColor(.white.opacity(0.95))
                                    .lineSpacing(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                // Blinking typing caret
                                Rectangle()
                                    .fill(Color.cyan)
                                    .frame(width: 2, height: 14)
                                    .opacity(isCaretVisible ? 1.0 : 0.15)
                                    .animation(
                                        .easeInOut(duration: 0.55).repeatForever(autoreverses: true),
                                        value: isCaretVisible
                                    )
                                    .padding(.top, 2)
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 6)
                            .id("transcriptBottom")
                        }
                        .frame(height: 52)
                        .onChange(of: appState.liveTranscript) { _, _ in
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo("transcriptBottom", anchor: .bottom)
                            }
                        }
                    }
                }
                .onAppear {
                    isCaretVisible = false
                }
            }
        }
        .frame(width: isExpanded ? 460 : 340, height: isExpanded ? 124 : 56, alignment: .top)
        .background(
            ZStack {
                // Native window drag background for non-interactive areas
                WindowDragBackground()

                // Obsidian glass base material
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)

                // Obsidian deep tint
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.08, blue: 0.11).opacity(0.82))

                // Rim glow & hairline border
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: appState.isRecording ? [
                                Color.cyan.opacity(0.60),
                                Color.indigo.opacity(0.40),
                                Color.white.opacity(0.12)
                            ] : [
                                Color.white.opacity(0.20),
                                Color.indigo.opacity(0.15),
                                Color.white.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: appState.isRecording ? Color.cyan.opacity(0.22) : Color.black.opacity(0.40),
                radius: appState.isRecording ? 18 : 14,
                x: 0,
                y: 8
            )
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isExpanded)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: appState.phase)
    }

    private var statusTitle: String {
        switch appState.phase {
        case .recording:
            return "Listening..."
        case .handsFree:
            return "Dictating..."
        case .transcribing:
            return "Transcribing..."
        case .success:
            return "Pasted!"
        default:
            return "VoiceFlow"
        }
    }

    private func audioLevel(for index: Int) -> Float {
        let levels = appState.audioLevels
        guard !levels.isEmpty else { return 0.05 }
        let count = levels.count
        let sampleIdx = max(0, count - 14 + index)
        let raw = levels[min(sampleIdx, count - 1)]

        // Subtle bell-curve shaping so the bars form an organic soundwave shape
        let centerDist = abs(Float(index) - 6.5) / 6.5
        let shapeFactor = max(0.45, 1.0 - (centerDist * 0.45))
        return min(1.0, max(0.05, raw * shapeFactor))
    }
}

// MARK: - Window Drag Helpers

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleNSView {
        DragHandleNSView()
    }
    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}
}

final class DragHandleNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
}

struct WindowDragBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> DragBackgroundNSView {
        DragBackgroundNSView()
    }
    func updateNSView(_ nsView: DragBackgroundNSView, context: Context) {}
}

final class DragBackgroundNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
