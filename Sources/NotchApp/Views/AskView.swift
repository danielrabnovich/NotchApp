import QuickLookThumbnailing
import SwiftUI

/// A single search bar: describe a file or ask a question. Results replace the bar's empty space.
struct AskView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var media: MediaController

    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            switch assistant.status {
            case .notRunning:
                SetupCard(icon: "bolt.horizontal.circle", title: "Ollama isn't running",
                          message: "Search runs on a local model through Ollama.",
                          button: "Start Ollama") { assistant.startServer() }
            case .modelMissing(let name):
                if let p = assistant.pullProgress {
                    VStack(spacing: 10) {
                        Text("Downloading \(name)").font(.system(size: 13, weight: .medium))
                        ProgressView(value: p).tint(.white).frame(width: 240)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SetupCard(icon: "arrow.down.circle", title: "One more step",
                              message: "Download \(name) to start searching.",
                              button: "Download") { assistant.pullModel() }
                }
            default:
                if let job = assistant.current {
                    VStack(spacing: 14) {
                        searchBar(compact: true)
                        ResultView(job: job, accent: accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                } else {
                    VStack(spacing: 10) {
                        Spacer(minLength: 0)
                        searchBar(compact: false)
                        Text("Find a file or ask anything")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.32))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true }
                }
            }
        }
        .onAppear { assistant.refreshStatus() }
        .onChange(of: assistant.current?.id) { _, _ in
            if let q = assistant.current?.query { query = q }
        }
    }

    private var accent: Color {
        .white
    }

    // MARK: - Search bar

    private func searchBar(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let job = assistant.current, job.isRunning {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: routeIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(focused ? 0.9 : 0.55))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 18)

            TextField("", text: $query, prompt: Text("Search files or the web").foregroundStyle(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 14 : 15, weight: .medium))
                .focused($focused)
                .onSubmit { assistant.run(query) }
                .onExitCommand {
                    if assistant.current != nil { assistant.clear(); query = "" } else { focused = false }
                }

            if !query.isEmpty || assistant.current != nil {
                Button {
                    query = ""
                    assistant.clear()
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: compact ? 38 : 46)
        .frame(maxWidth: compact ? .infinity : 440)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(focused ? 0.11 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(focused ? 0.2 : 0.06), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: focused)
        .onChange(of: focused) { _, f in viewModel.isEditing = f }
    }

    private var routeIcon: String {
        switch assistant.current?.route {
        case .files?: "doc.text.magnifyingglass"
        case .web?: "globe"
        case .weather?: "cloud.sun"
        case nil: "magnifyingglass"
        }
    }
}

// MARK: - Results

private struct WeatherCard: View {
    let report: WeatherReport
    let accent: Color

    var body: some View {
        HStack(spacing: 22) {
            let focus = report.days.indices.contains(report.focusDay) ? report.days[report.focusDay] : nil
            HStack(spacing: 14) {
                Image(systemName: WeatherReport.symbol(report.focusDay == 0 ? report.currentCode : focus?.code ?? report.currentCode))
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 46))
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.place)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    if report.focusDay == 0 {
                        Text("\(Int(report.currentTemp.rounded()))°")
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                        Text("\(WeatherReport.describe(report.currentCode)) · feels \(Int(report.feelsLike.rounded()))°")
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    } else if let focus {
                        Text(report.focusDay == 1 ? "Tomorrow" : focus.date.formatted(.dateTime.weekday(.wide)))
                            .font(.system(size: 13, weight: .medium))
                        Text("\(Int(focus.high.rounded()))° / \(Int(focus.low.rounded()))°")
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                        Text("\(WeatherReport.describe(focus.code)) · \(focus.rainChance)% rain")
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(Array(report.days.prefix(5).enumerated()), id: \.element.id) { i, day in
                    VStack(spacing: 6) {
                        Text(i == 0 ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(i == report.focusDay ? 0.95 : 0.5))
                        Image(systemName: WeatherReport.symbol(day.code))
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 17))
                            .frame(height: 22)
                        Text("\(Int(day.high.rounded()))°")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        Text("\(Int(day.low.rounded()))°")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.45))
                        if day.rainChance >= 20 {
                            Text("\(day.rainChance)%")
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.55))
                        } else {
                            Text(" ").font(.system(size: 9.5))
                        }
                    }
                    .frame(width: 46)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(i == report.focusDay ? 0.1 : 0)))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct ResultView: View {
    let job: AssistantStore.Job
    let accent: Color
    @EnvironmentObject private var assistant: AssistantStore

    var body: some View {
        switch job.state {
        case .running where job.route == .web && !(job.answer ?? "").isEmpty:
            // The answer streams in as it's written.
            WebResults(job: job, accent: accent)
        case .running(let stage):
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                ShimmerText(text: stage)
                Text(job.route == .web ? "Searching the web" : job.route == .files ? "Searching your Mac"
                     : job.route == .weather ? "Getting the weather" : "Working out where to look")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 20))
                Text(message).font(.system(size: 12)).multilineTextAlignment(.center)
                Button("Try again") { assistant.run(job.query, route: job.route) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            VStack(spacing: 10) {
                switch job.route {
                case .files?: FileResults(job: job, accent: accent)
                case .weather?: if let report = job.weather { WeatherCard(report: report, accent: accent) }
                default: WebResults(job: job, accent: accent)
                }
                RouteFooter(job: job)
            }
        }
    }
}

private struct RouteFooter: View {
    let job: AssistantStore.Job
    @EnvironmentObject private var assistant: AssistantStore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: job.route == .files ? "internaldrive" : job.route == .weather ? "cloud.sun" : "globe")
            Text(job.route == .files ? "Searched your Mac" : job.route == .weather ? "Open-Meteo forecast" : "Searched the web")
            Text("·")
            Button(job.route == .web ? "Search my files instead" : "Search the web instead") { assistant.switchRoute() }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.32))
    }
}

private struct FileResults: View {
    let job: AssistantStore.Job
    let accent: Color

    var body: some View {
        if let best = job.files.first {
            HStack(alignment: .top, spacing: 20) {
                BestFile(hit: best, confident: job.confident)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if job.files.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Other matches")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.leading, 8)
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 0) {
                                ForEach(job.files.dropFirst()) { hit in FileRow(hit: hit) }
                            }
                        }
                    }
                    .frame(width: 250, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 6) {
                Text("No matching file").font(.system(size: 13, weight: .medium))
                Text("Try a word that might be in its name").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct BestFile: View {
    let hit: FileHit
    let confident: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: hit.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(thumbnail == nil ? 0 : 0.12), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(confident ? "Best match" : "Closest match")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                Text(hit.url.lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(location)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.head)
                if let reason = hit.reason {
                    Text(reason.prefix(1).uppercased() + reason.dropFirst())
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                HStack(spacing: 6) {
                    button("Open", primary: true) { NSWorkspace.shared.open(hit.url) }
                    button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
                    button("Add to Shelf") { ShelfStore.shared.add([hit.url]) }
                }
                .padding(.top, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(hit.url) }
        .onDrag { NSItemProvider(object: hit.url as NSURL) }
        .task(id: hit.url) { thumbnail = await Thumbnail.load(hit.url, size: 160) }
    }

    private var location: String {
        hit.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func button(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(primary ? .black : .white.opacity(0.85))
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(primary ? .white : .white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

private struct FileRow: View {
    let hit: FileHit
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hit.url.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.url.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(hit.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(hit.url) }
        .onDrag { NSItemProvider(object: hit.url as NSURL) }
        .help(hit.reason ?? hit.url.path)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(hit.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
            Button("Add to Shelf") { ShelfStore.shared.add([hit.url]) }
        }
    }
}

private struct WebResults: View {
    let job: AssistantStore.Job
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ScrollView(.vertical, showsIndicators: false) {
                AnswerText(text: job.answer ?? "", accent: accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sources")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(job.answer ?? "", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 20))
                    .help("Copy answer")
                }
                .padding(.leading, 6)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(job.sources.prefix(5).enumerated()), id: \.element.id) { i, source in
                            SourceRow(index: i + 1, source: source)
                        }
                    }
                }
            }
            .frame(width: 200)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Answer text with citation markers like [2] drawn as small accent badges.
private struct AnswerText: View {
    let text: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { i, para in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if para.isBullet {
                        Circle().fill(.white.opacity(0.5)).frame(width: 3.5, height: 3.5).offset(y: -3)
                    }
                    styled(para.text)
                        .font(.system(size: i == 0 && !para.isBullet ? 14.5 : 12.5, weight: i == 0 && !para.isBullet ? .medium : .regular))
                        .foregroundStyle(.white.opacity(i == 0 ? 0.95 : 0.78))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var paragraphs: [(text: String, isBullet: Bool)] {
        // Models sometimes put "•" bullets inline; give each its own line.
        text.replacingOccurrences(of: " • ", with: "\n• ")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                for prefix in ["• ", "- ", "* "] where line.hasPrefix(prefix) {
                    return (String(line.dropFirst(prefix.count)), true)
                }
                return (line, false)
            }
    }

    private func styled(_ s: String) -> Text {
        var result = Text("")
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]"),
              Int(rest[rest.index(after: open)..<close]) != nil {
            result = result + Text(String(rest[..<open]))
            let n = String(rest[rest.index(after: open)..<close])
            result = result + Text(" \(n)").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.45)).baselineOffset(4)
            rest = rest[rest.index(after: close)...]
        }
        return result + Text(String(rest))
    }
}

private struct SourceRow: View {
    let index: Int
    let source: WebSource
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(source.url) } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(.white.opacity(0.75)))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text(source.host)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(source.url.absoluteString)
    }
}

/// Status text that gently pulses while work is happening.
private struct ShimmerText: View {
    let text: String
    @State private var dim = false

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(dim ? 0.35 : 0.8))
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: text)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

private struct SetupCard: View {
    let icon: String
    let title: String
    let message: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum Thumbnail {
    static func load(_ url: URL, size: CGFloat) async -> NSImage? {
        await withCheckedContinuation { cont in
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                       scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
    }
}

