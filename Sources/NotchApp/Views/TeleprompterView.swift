import AppKit
import SwiftUI

/// The Prompter pane in the Tasks tab: write or import the script, pick the pace, start.
struct PrompterSetupView: View {
    @ObservedObject var viewModel: NotchViewModel
    @Binding var pane: TasksPane
    @ObservedObject private var prompter = Teleprompter.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PaneSwitcher(selection: $pane, options: TasksPane.options)
                Text(summary)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button { prompter.importScript() } label: {
                    Image(systemName: "doc.badge.plus").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(NotchIconButtonStyle(size: 24))
                .help("Use a text, Word, RTF or PDF file")
                if Teleprompter.canFollowVoice {
                    Button { prompter.followsVoice.toggle() } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(prompter.followsVoice ? Color.accentColor : .white.opacity(0.6))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 24))
                    .help(prompter.followsVoice ? "Following your voice: it moves as you speak" : "Steady pace: follow your voice instead")
                }
                if !prompter.followsVoice { PaceStepper() }
                Button { focused = false; prompter.start() } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(NotchPillButtonStyle(primary: true))
                .disabled(prompter.words.isEmpty)
            }
            .notchHeaderRow()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompter.script)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focused)
                    .onKeyPress(.escape) { focused = false; return .handled }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                if prompter.script.isEmpty {
                    Text("Write or paste your script, or use a file. It rolls under the camera so your eyes stay on the lens.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .notchSurface(RoundedRectangle(cornerRadius: 14, style: .continuous), active: focused)
            .animation(.easeOut(duration: 0.15), value: focused)
            .onChange(of: focused) { _, f in viewModel.isEditing = f }
        }
    }

    private var summary: String {
        let n = prompter.words.count
        guard n > 0 else { return "No script" }
        let minutes = Int((prompter.duration / 60).rounded(.up))
        return "\(n) words · " + (prompter.followsVoice ? "at your pace" : "about \(minutes) min")
    }
}

/// "140 wpm" with − and +.
private struct PaceStepper: View {
    @ObservedObject private var prompter = Teleprompter.shared

    var body: some View {
        HStack(spacing: 2) {
            Button { prompter.slower() } label: { Image(systemName: "minus").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(NotchIconButtonStyle(size: 20))
            Text("\(Int(prompter.wordsPerMinute)) wpm")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 54)
                .contentTransition(.numericText())
                .animation(.snappy, value: prompter.wordsPerMinute)
            Button { prompter.faster() } label: { Image(systemName: "plus").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(NotchIconButtonStyle(size: 20))
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
        .notchSurface(Capsule())
        .help("Words a minute")
    }
}

/// The script rolling in the open notch, the line being read right under the camera.
struct TeleprompterView: View {
    @ObservedObject private var prompter = Teleprompter.shared
    @State private var hovering = false
    @State private var layout = LineLayout()

    var body: some View {
        GeometryReader { geo in
            let size = CGFloat(prompter.textSize)
            let lineHeight = (size * 1.32).rounded()
            let lines = layout.lines(for: prompter.words, size: size, width: geo.size.width - 24)
            let (line, fraction) = locate(lines)
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { i in
                        lineText(lines[i], size: size, isCurrent: i == line)
                            .frame(height: lineHeight, alignment: .leading)
                            .opacity(i < line ? 0.35 : 1)
                    }
                }
                .padding(.horizontal, 12)
                .frame(width: geo.size.width, alignment: .leading)
                // The line being read sits second from the top: the one just read stays above it.
                .offset(y: -(CGFloat(line) + fraction - 1) * lineHeight)
                .animation(.linear(duration: 1.0 / 30), value: prompter.position)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black.opacity(0.5), location: 0), .init(color: .black, location: 0.25),
                                         .init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottom) { controls.opacity(hovering || prompter.paused ? 1 : 0) }
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hovering = h } }
            .onTapGesture { prompter.togglePause() }
        }
    }

    /// The line holding the current word, and how far through that line it is.
    private func locate(_ lines: [Range<Int>]) -> (Int, CGFloat) {
        let p = prompter.position
        guard let i = lines.firstIndex(where: { Double($0.upperBound) > p }) else { return (max(0, lines.count - 1), 1) }
        let r = lines[i]
        // Holds still while the line is read, sliding up over its last few words.
        let through = (p - Double(r.lowerBound)) / Double(max(1, r.count))
        return (i, CGFloat(max(0, through - 0.7) / 0.3))
    }

    private func lineText(_ range: Range<Int>, size: CGFloat, isCurrent: Bool) -> some View {
        let current = Int(prompter.position)
        var text = AttributedString()
        for i in range {
            var word = AttributedString(prompter.words[i] + " ")
            word.foregroundColor = i < current ? .white.opacity(0.4) : i == current && isCurrent ? .white : .white.opacity(0.88)
            text += word
        }
        return Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .fixedSize()
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button { prompter.restart() } label: { Image(systemName: "backward.end.fill").font(.system(size: 10)) }
                .buttonStyle(NotchIconButtonStyle(size: 26)).help("From the top")
            Button { prompter.togglePause() } label: {
                Image(systemName: prompter.paused ? "play.fill" : "pause.fill").font(.system(size: 12))
            }
            .buttonStyle(NotchIconButtonStyle(size: 30)).help(prompter.paused ? "Go on" : "Pause")
            if !prompter.followsVoice { PaceStepper() }
            if Teleprompter.canFollowVoice {
                Button { prompter.followsVoice.toggle() } label: {
                    Image(systemName: "waveform").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(prompter.followsVoice ? Color.accentColor : .white.opacity(0.85))
                        .symbolEffect(.variableColor.iterative, isActive: prompter.listening)
                }
                .buttonStyle(NotchIconButtonStyle(size: 26)).help("Follow my voice")
            }
            Button { prompter.smaller() } label: { Image(systemName: "textformat.size.smaller").font(.system(size: 11)) }
                .buttonStyle(NotchIconButtonStyle(size: 26)).help("Smaller text")
            Button { prompter.larger() } label: { Image(systemName: "textformat.size.larger").font(.system(size: 11)) }
                .buttonStyle(NotchIconButtonStyle(size: 26)).help("Larger text")
            ProgressView(value: prompter.progress)
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 90)
                .padding(.horizontal, 4)
            Button { prompter.stop() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(NotchIconButtonStyle(size: 26)).help("Stop")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .notchSurface(Capsule())
        .background(Capsule().fill(.black.opacity(0.55)))
    }
}

/// Words laid into lines as wide as the notch, measured with the font they're shown in. Kept
/// until the words, size or width change.
private final class LineLayout {
    private var key: (count: Int, first: String, size: CGFloat, width: CGFloat)?
    private var cached: [Range<Int>] = []

    func lines(for words: [String], size: CGFloat, width: CGFloat) -> [Range<Int>] {
        if let key, key.count == words.count, key.first == (words.first ?? ""), key.size == size, key.width == width { return cached }
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
        let attrs: [NSAttributedString.Key: Any] = [.font: rounded]
        let space = (" " as NSString).size(withAttributes: attrs).width
        var out: [Range<Int>] = []
        var start = 0, used: CGFloat = 0
        for (i, word) in words.enumerated() {
            let w = (word as NSString).size(withAttributes: attrs).width
            if used > 0, used + w > width {
                out.append(start..<i)
                start = i
                used = 0
            }
            used += w + space
        }
        if start < words.count { out.append(start..<words.count) }
        key = (words.count, words.first ?? "", size, width)
        cached = out
        return out
    }
}
