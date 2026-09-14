import SwiftUI

struct VoiceAgentView: View {
    @EnvironmentObject var state: VoiceFlowState

    var body: some View {
        VStack(spacing: 18) {
            headerCard

            if state.permissionDenied || state.serviceError != nil {
                permissionWarning
            }

            transcriptCard
            controls

            Text("Live STT (SFSpeechRecognizer) + TTS (AVSpeechSynthesizer) • \(SpeechService.languages.count) languages • replies are mocked until apiUrl points at your LLM backend.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(18)
    }

    // MARK: Header card

    private var headerCard: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(LinearGradient(colors: [.purple.opacity(0.18), .blue.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 88)
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 46, height: 46)
                        Text("◉").foregroundStyle(.white).font(.system(size: 18, weight: .bold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VoiceFlow Agent").font(.system(size: 15, weight: .bold))
                        Text("Menu bar • always on • press V to talk").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(state.isListening ? Color.green : Color.gray.opacity(0.35)).frame(width: 8, height: 8)
                        .shadow(color: state.isListening ? .green.opacity(0.7) : .clear, radius: 6)
                    Text(state.isListening ? "Listening…" : "Idle").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(state.isListening ? .green : .secondary)
                }.padding(.horizontal, 16)
            }

            languagePicker

            // Wave
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(colors: [.purple, .blue], startPoint: .bottom, endPoint: .top))
                        .frame(width: 4, height: state.isListening ? [14,22,28,18,24][i] : [8,10,12,10,8][i])
                        .animation(state.isListening ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i)*0.08) : .default, value: state.isListening)
                }
            }.frame(height: 30)

            Text(state.status)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(state.isListening ? .green : .secondary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08)))
    }

    // MARK: Language picker (flag + name from the shared catalog)

    private var languagePicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker("Language", selection: state.languageSelection) {
                ForEach(SpeechService.languages) { language in
                    Text("\(language.flag)  \(language.name)").tag(language.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 210)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.purple.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    }

    // MARK: Permission / error warning

    private var permissionWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.serviceError ?? "Microphone and speech-recognition permission are required.")
                    .font(.system(size: 11, weight: .semibold))
                Text("System Settings › Privacy & Security › Microphone and Speech Recognition → allow VoiceFlow, then retry.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Retry") {
                state.serviceError = nil
                state.isListening = true
            }
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.isListening)
        }
        .padding(10)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.35)))
    }

    // MARK: Transcript card

    @ViewBuilder private var transcriptCard: some View {
        if !state.transcript.isEmpty || !state.agentReply.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !state.transcript.isEmpty {
                    Label(state.isListening ? "You (live)" : "You", systemImage: "person.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(.purple)
                    Text(state.transcript).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                }
                if !state.agentReply.isEmpty {
                    Divider().opacity(0.5)
                    Label("Agent", systemImage: "sparkles").font(.caption.weight(.bold)).foregroundStyle(.blue)
                    Text(state.agentReply).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "mic.slash").foregroundStyle(.secondary)
                Text("No transcript yet — pick a language, tap Start Talking and speak.").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("This window is the NATIVE agent zone; the Website tab is the WEB zone — same agent, two surfaces.").font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity).padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.35)) {
                    state.isListening.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: state.isListening ? "stop.circle.fill" : "mic.fill")
                    Text(state.isListening ? "Stop" : "Start Talking")
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing), in: Capsule())
                .foregroundStyle(.white)
            }.buttonStyle(.plain)

            Button {
                state.clearConversation()
            } label: {
                Text("Clear").font(.system(size: 13, weight: .semibold)).padding(.vertical, 11).padding(.horizontal, 18).background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
            }.buttonStyle(.plain)
        }
    }
}
