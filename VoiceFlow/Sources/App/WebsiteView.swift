//
//  WebsiteView.swift
//  VoiceFlow
//
//  Local preview of the bundled website plus the embed-snippet gallery.
//  The site URL resolves through WebsiteLocator (bundle first, source tree in
//  Debug); when it can't be found we degrade to a placeholder instead of
//  crashing or pointing at example.com.
//

import SwiftUI
import WebKit

struct WebsiteView: View {
    private var siteURL: URL? { WebsiteLocator.indexURL }

    var body: some View {
        if let url = siteURL {
            websitePreview(url)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("Website preview unavailable")
                    .font(.system(size: 14, weight: .semibold))
                Text("Website/index.html wasn't found in the app bundle or the project folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func websitePreview(_ url: URL) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Website Preview", systemImage: "globe").font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Text("Website/index.html").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Link("Open in Browser", destination: url).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Divider()

            WebView(url: url)
        }
    }
}

struct EmbedCodeView: View {
    @State private var copied = false
    private let snippet =
"""
<!-- VoiceFlow Embed — paste before </body> -->
<script>
  window.VOICEFLOW_CONFIG = {
    apiUrl: "https://your-agent-backend.com/voice",
    theme: "dark",
    position: "bottom-right",
    title: "Talk to VoiceFlow"
  };
</script>
<script src="https://yourdomain.com/embed/voiceflow-embed.js" defer></script>
"""

    private let localSnippet =
"""
<script>
  window.VOICEFLOW_CONFIG = {
    apiUrl: "", // empty = mock mode
    theme: "dark",
    position: "bottom-right"
  };
</script>
<script src="./embed/voiceflow-embed.js" defer></script>
"""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Embed your Voice Agent anywhere").font(.system(size: 20, weight: .bold))
                Text("Two surfaces, one agent — the native macOS app and the web widget share the same backend. Pick the snippet below.").font(.system(size: 12)).foregroundStyle(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Production (any site)", systemImage: "link").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button(copied ? "Copied ✓" : "Copy") {
                                copy(snippet)
                            }.font(.system(size: 11, weight: .semibold)).buttonStyle(.bordered).controlSize(.small)
                        }
                        Text(snippet).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                        Text("Host Website/embed/voiceflow-embed.js on your domain and point src there. Set apiUrl to your LLM backend POST endpoint that accepts {transcript} and returns {reply}.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Local dev (this project)", systemImage: "hammer.fill").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button("Copy local") { copy(localSnippet) }.font(.system(size: 11, weight: .semibold)).buttonStyle(.bordered).controlSize(.small)
                        }
                        Text(localSnippet).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        Text("This works directly from Website/index.html — no hosting needed. Open Website/index.html in a browser and the floating widget appears.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Inline container (for your own page layout)", systemImage: "rectangle.inset.filled").font(.system(size: 12, weight: .semibold))
                        Text("If you want the agent inline (like the demo hero card) instead of floating, use:").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("<div id=\"voiceflow-container\"></div>\n<script src=\"./js/voice-agent.js\"></script>").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        Text("Then call VoiceAgent.connect({apiUrl: \"...\"}) and VoiceAgent.sendText(\"hello\") from anywhere.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }.padding(18)
        }
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now()+1.5){ copied = false }
    }
}

// MARK: - WebKit wrapper

struct WebView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return wv
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
