import SwiftUI

/// Live captions under the closed notch: the last line said, faint, over what's being said now.
/// In a transcribed call, each line says whose it is. Hover for a button to stop.
struct CaptionStripView: View {
    @ObservedObject private var captions = LiveCaptions.shared
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            VStack(alignment: .leading, spacing: 2) {
                if let problem = captions.problem {
                    Text(problem).foregroundStyle(.orange.opacity(0.9))
                } else if captions.preparing, captions.lines.isEmpty, captions.partial.isEmpty {
                    Text("Getting captions ready…").foregroundStyle(.white.opacity(0.5))
                } else {
                    if let last = previous {
                        line(last.speaker, last.text).foregroundStyle(.white.opacity(0.45))
                    }
                    if let now = current {
                        line(now.speaker, now.text).foregroundStyle(.white.opacity(0.95))
                    } else if previous == nil {
                        Text("Listening…").foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.head) // the newest words are at the end
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.15), value: captions.lines.count)
            if hovering {
                Button { captions.stopCaptions() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Stop captions")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu {
            Button("Copy Transcript") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(captions.transcript, forType: .string)
            }
            Button("Stop Captions") { captions.stopCaptions() }
        }
    }

    /// What's being said now: their words first (captions are mostly for them).
    private var current: (speaker: LiveCaptions.Speaker, text: String)? {
        if let t = captions.partial[.them], !t.isEmpty { return (.them, t) }
        if let t = captions.partial[.you], !t.isEmpty { return (.you, t) }
        return captions.lines.last.map { ($0.speaker, $0.text) }
    }

    /// The line before it.
    private var previous: LiveCaptions.Line? {
        let speaking = !(captions.partial[.them] ?? "").isEmpty || !(captions.partial[.you] ?? "").isEmpty
        let lines = captions.lines
        return speaking ? lines.last : (lines.count >= 2 ? lines[lines.count - 2] : nil)
    }

    @ViewBuilder private func line(_ speaker: LiveCaptions.Speaker, _ text: String) -> some View {
        if captions.recording {
            (Text(speaker == .you ? "You  " : "Them  ").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.4)) + Text(text))
        } else {
            Text(text)
        }
    }
}
