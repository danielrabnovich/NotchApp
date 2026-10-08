import QuickLookThumbnailing
import SwiftUI

/// A single search and command bar: describe a file, ask a question, or tell it what to do
/// ("task …", "note …", "timer 10m", or in plain words with AI). Results replace the bar's empty space.
struct AskView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var media: MediaController

    @State private var query = ""
    @FocusState private var focused: Bool
    @ObservedObject private var suggestions = SearchSuggestions.shared
    @State private var copied: String?
    @ObservedObject private var commands = CommandCenter.shared
    /// Proposed actions the user unticked before running the plan.
    @State private var excluded: Set<UUID> = []

    var body: some View {
        // One layout with a single search field: swapping between separate layouts recreated
        // the field and took the cursor out of it as soon as suggestions appeared.
        let idle = assistant.current == nil && suggestions.items.isEmpty
        VStack(spacing: idle ? 12 : 6) {
            if idle { Spacer(minLength: 0) }
            searchBar(compact: !idle)
            if let job = assistant.current {
                ResultView(job: job, accent: accent, excluded: $excluded, applyPlan: applyPlan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else if !suggestions.items.isEmpty {
                SuggestionList(items: suggestions.items, selected: $suggestions.selected, copied: copied, perform: perform)
                    .padding(5)
                    .notchSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            } else {
                Group {
                    if let done = commands.confirmation {
                        ConfirmationLine(confirmation: done)
                    } else {
                        AIStatusLine()
                    }
                }
                .transition(.opacity)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { if idle { focused = true } }
        .onAppear {
            assistant.refreshStatus()
            focusIfShown()
        }
        .onChange(of: viewModel.tab) { _, _ in focusIfShown() }
        .onChange(of: viewModel.isOpen) { _, _ in focusIfShown() }
        .onChange(of: assistant.current?.id) { _, _ in
            if let q = assistant.current?.query { query = q }
        }
        .onChange(of: query) { _, q in
            // Typing something new replaces the last result with live suggestions.
            if let job = assistant.current, q != job.query { assistant.clear() }
            if assistant.current == nil { suggestions.update(q) }
        }
    }

    /// Acts on a suggestion: copy an answer, open an app or file, or run the full search.
    private func perform(_ item: Suggestion) {
        switch item {
        case .answer(let a):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(a.copyValue, forType: .string)
            copied = a.title
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == a.title { copied = nil } }
        case .app(let app):
            NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
            finish()
        case .file(let url):
            NSWorkspace.shared.open(url)
            finish()
        case .search(let q):
            suggestions.clear()
            assistant.run(q)
        case .command(let c):
            if case .template(let prefix) = c.action {
                query = prefix
                return
            }
            CommandCenter.shared.run([c])
            query = ""
            suggestions.clear()
        case .plan(let q):
            suggestions.clear()
            excluded = []
            assistant.run(q, route: .actions)
        }
    }

    /// Runs the ticked actions from an AI plan, then clears the bar for the next thing.
    private func applyPlan(_ plan: CommandPlanner.Plan) {
        CommandCenter.shared.run(plan.commands.filter { !excluded.contains($0.id) })
        excluded = []
        query = ""
        assistant.clear()
        suggestions.clear()
    }

    private func finish() {
        query = ""
        suggestions.clear()
        viewModel.close()
    }

    /// Puts the cursor in the search bar whenever the notch shows this tab.
    private func focusIfShown() {
        guard viewModel.isOpen, viewModel.tab == .ask else { return }
        viewModel.takeKeyFocus()
        // The window has to be key before the field can take focus.
        DispatchQueue.main.async { focused = true }
    }

    private var accent: Color {
        .white
    }

    // MARK: - Search bar

    private func searchBar(compact: Bool) -> some View {
        let running = assistant.current?.isRunning == true
        return HStack(spacing: compact ? 9 : 11) {
            Group {
                if running {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: routeIcon)
                        .font(.system(size: compact ? 14 : 17, weight: .medium))
                        .foregroundStyle(.white.opacity(focused ? 0.8 : 0.45))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 20)

            TextField("", text: $query, prompt: Text("Search, or type a command")
                .foregroundStyle(.white.opacity(0.3)))
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 15 : 18, weight: .regular))
                .focused($focused)
                .onSubmit {
                    if assistant.current == nil, let pick = suggestions.current {
                        perform(pick)
                    } else if let job = assistant.current, job.route == .actions, let plan = job.plan {
                        applyPlan(plan)
                    } else {
                        assistant.run(query)
                    }
                }
                .onKeyPress(.downArrow) { suggestions.move(1); return .handled }
                .onKeyPress(.upArrow) { suggestions.move(-1); return .handled }
                .onExitCommand {
                    if assistant.current != nil || !query.isEmpty {
                        assistant.clear(); query = ""; suggestions.clear()
                    } else {
                        focused = false
                    }
                }

            if !query.isEmpty || assistant.current != nil {
                Button {
                    query = ""
                    assistant.clear()
                    suggestions.clear()
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: compact ? 14 : 16))
                        .foregroundStyle(.white.opacity(0.35))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if settings.hotKeysEnabled {
                // The shortcut that brings the bar back, like Spotlight's ⌘Space.
                KeyCap(text: settings.hotKeyModifiers.symbol + HotKeys.Action.search.key)
                    .transition(.opacity)
            }
        }
        .padding(.leading, compact ? 14 : 18)
        .padding(.trailing, compact ? 10 : 14)
        .frame(height: compact ? 38 : 48)
        .frame(maxWidth: compact ? .infinity : 500)
        .notchSurface(Capsule(), active: focused)
        .overlay { if running { SweepingEdge() } }
        .shadow(color: .white.opacity(focused ? 0.06 : 0), radius: 16)
        .animation(.easeOut(duration: 0.18), value: focused)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: compact)
        .animation(.easeOut(duration: 0.15), value: query.isEmpty)
        // Only hold the notch open once something's typed, so an auto-focused empty bar
        // doesn't stop it closing when the pointer leaves.
        .onChange(of: focused) { _, f in viewModel.isEditing = f && !query.isEmpty }
        .onChange(of: query) { _, q in viewModel.isEditing = focused && !q.isEmpty }
    }

    private var routeIcon: String {
        switch assistant.current?.route {
        case .files?: "doc.text.magnifyingglass"
        case .web?: "globe"
        case .weather?: "cloud.sun"
        case .actions?: "sparkles"
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
                    .background {
                        if i == report.focusDay { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.09)) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct ResultView: View {
    let job: AssistantStore.Job
    let accent: Color
    @Binding var excluded: Set<UUID>
    let applyPlan: (CommandPlanner.Plan) -> Void
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
                     : job.route == .weather ? "Getting the weather" : job.route == .actions ? "Turning that into actions"
                     : "Working out where to look")
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
        case .done where job.route == .actions:
            if let plan = job.plan { PlanView(plan: plan, excluded: $excluded, apply: applyPlan) }
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
            if !assistant.aiAvailable && job.route != .weather && assistant.pullingModel == nil {
                Text(job.route == .web ? "AI writes answers from these ·" : "AI picks the best match ·")
                if case .modelMissing = assistant.status { DownloadModelMenu() }
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.32))
    }
}

private struct FileResults: View {
    @ObservedObject private var access = FolderAccess.shared
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
                if !access.missing.isEmpty {
                    Text("NotchApp can't see \(access.missing.map(\.name).joined(separator: ", ")) yet.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Button("Allow in System Settings") { FolderAccess.openPrivacySettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Text("Try a word that might be in its name").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
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
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(thumbnail == nil ? 0 : 0.12), lineWidth: 1))
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
        Button(title, action: action)
            .buttonStyle(NotchPillButtonStyle(primary: primary, height: 24))
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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.07 : 0)))
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
        if job.state == .done && (job.answer ?? "").isEmpty {
            LinkResults(sources: job.sources)
        } else {
            answerWithSources
        }
    }

    private var answerWithSources: some View {
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

/// Plain search results (no model to write an answer): title, site and snippet.
private struct LinkResults: View {
    let sources: [WebSource]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sources) { source in
                    LinkRow(source: source)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct LinkRow: View {
    let source: WebSource
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(source.url) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text(source.host)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
                if !source.snippet.isEmpty {
                    Text(source.snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(source.url.absoluteString)
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
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(.white.opacity(0.14)))
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
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(source.url.absoluteString)
    }
}

/// AI-proposed actions to review: untick any you don't want, then run the rest.
private struct PlanView: View {
    let plan: CommandPlanner.Plan
    @Binding var excluded: Set<UUID>
    let apply: (CommandPlanner.Plan) -> Void
    @EnvironmentObject private var assistant: AssistantStore

    private var included: [Command] { plan.commands.filter { !excluded.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(plan.summary)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            // Hugs a short plan; scrolls a long one.
            ViewThatFits(in: .vertical) {
                rows
                ScrollView(.vertical, showsIndicators: false) { rows }
            }
            .notchSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text("Untick anything you don't want")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.32))
                Spacer()
                Button("Cancel") { assistant.clear() }
                    .buttonStyle(NotchPillButtonStyle())
                Button { apply(plan) } label: {
                    HStack(spacing: 6) {
                        Text(applyTitle)
                        Text("↩").opacity(0.45)
                    }
                }
                .buttonStyle(NotchPillButtonStyle(primary: true))
                .disabled(included.isEmpty)
                .opacity(included.isEmpty ? 0.4 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(plan.commands) { command in row(command) }
        }
        .padding(4)
    }

    private var applyTitle: String {
        let tasks = included.reduce(0) { n, c in if case .addTasks(let items) = c.action { n + items.count } else { n } }
        if tasks == included.count { return tasks == 1 ? "Add task" : "Add \(tasks) tasks" }
        return included.count == 1 ? "Do it" : "Do all \(included.count)"
    }

    private func row(_ command: Command) -> some View {
        let on = !excluded.contains(command.id)
        let (title, detail) = display(command)
        return Button {
            if on { excluded.insert(command.id) } else { excluded.remove(command.id) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(on ? Color.accentColor : .white.opacity(0.3))
                    .contentTransition(.symbolEffect(.replace))
                Image(systemName: command.icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(on ? 0.92 : 0.4))
                    .strikethrough(!on, color: .white.opacity(0.3))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Tasks read as the task itself ("Call mom", "tomorrow 3 PM"), not "Add task “Call mom”".
    private func display(_ command: Command) -> (String, String?) {
        if case .addTasks(let items) = command.action, items.count == 1 {
            let (title, due) = DueDateParser.extract(from: items[0])
            return (title, due.map(CommandParser.dueText))
        }
        if case .appendNote(let text) = command.action { return (text, "note") }
        return (command.title, command.subtitle)
    }
}

/// What the last command did, with a way to go and see it.
private struct ConfirmationLine: View {
    let confirmation: CommandCenter.Confirmation

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: confirmation.icon)
                .foregroundStyle(.green)
            Text(confirmation.text)
                .foregroundStyle(.white.opacity(0.8))
            if let destination = confirmation.destination, case .show(let tab, let pane) = destination {
                Text("·").foregroundStyle(.white.opacity(0.3))
                Button("Show") { CommandCenter.shared.show(tab, pane: pane) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .frame(height: 18)
    }
}

/// A highlight that travels around the search bar's edge while a search runs.
private struct SweepingEdge: View {
    @State private var angle = 0.0

    var body: some View {
        Capsule()
            .strokeBorder(AngularGradient(colors: [.clear, .clear, .white.opacity(0.55), .white.opacity(0.9), .clear],
                                          center: .center, angle: .degrees(angle)), lineWidth: 1.2)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { angle = 360 }
            }
            .transition(.opacity)
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

/// Results as you type: an instant answer, apps, files, and the full search. Arrow keys move,
/// Return acts on the highlighted row.
private struct SuggestionList: View {
    let items: [Suggestion]
    @Binding var selected: Int
    let copied: String?
    let perform: (Suggestion) -> Void
    @EnvironmentObject private var assistant: AssistantStore

    private let rowHeight: CGFloat = 30

    var body: some View {
        // Rows are keyed by position and the highlight is one layer behind them: the list changes
        // on every keystroke ("Search for …" is a new item each time), and per-item identity made
        // the highlight fade out and back in as you typed.
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                row(item, highlighted: i == selected)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = i; perform(item) }
                    .onHover { if $0 { selected = i } }
            }
        }
        .background(alignment: .top) {
            if items.indices.contains(selected) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(height: rowHeight)
                    .offset(y: CGFloat(selected) * rowHeight)
            }
        }
        .transaction { $0.animation = nil }
    }

    /// One line per result, like Spotlight: icon, name, a dimmer detail, and the action on the selected row.
    @ViewBuilder private func row(_ item: Suggestion, highlighted: Bool) -> some View {
        HStack(spacing: 9) {
            icon(item, highlighted: highlighted)
                .frame(width: 20, height: 20)
            Text(title(item))
                .font(.system(size: item.isAnswer ? 15 : 13, weight: item.isAnswer ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .layoutPriority(1)
            if let sub = subtitle(item) {
                Text(sub)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(highlighted ? 0.7 : 0.38))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if highlighted {
                HStack(spacing: 5) {
                    Text(hint(item))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    if !(item.isAnswer && copied == title(item)) { KeyCap(text: "↩", onAccent: true) }
                }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: rowHeight)
    }

    @ViewBuilder private func icon(_ item: Suggestion, highlighted: Bool) -> some View {
        switch item {
        case .answer(let a):
            Image(systemName: a.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(highlighted ? 1 : 0.8))
        case .app(let app):
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable()
        case .file(let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        case .search:
            Image(systemName: assistant.aiAvailable ? "sparkle.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(highlighted ? 1 : 0.65))
        case .command(let c):
            if case .quitApp(let pid) = c.action, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: c.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(highlighted ? 1 : 0.75))
            }
        case .plan:
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(highlighted ? 1 : 0.75))
        }
    }

    private func title(_ item: Suggestion) -> String {
        switch item {
        case .answer(let a): a.title
        case .app(let app): app.name
        case .file(let url): url.lastPathComponent
        case .search(let q): "Search for “\(q)”"
        case .command(let c): c.title
        case .plan: "Turn into tasks & notes"
        }
    }

    private func subtitle(_ item: Suggestion) -> String? {
        switch item {
        case .answer(let a): a.subtitle
        case .app: "Application"
        case .file(let url): url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .search: assistant.aiAvailable ? "Files, web and weather, with AI" : "Files, web and weather"
        case .command(let c): c.subtitle
        case .plan: "AI drafts them, you review first"
        }
    }

    private func hint(_ item: Suggestion) -> String {
        switch item {
        case .answer(let a): copied == a.title ? "Copied" : "Copy"
        case .app, .file: "Open"
        case .search: "Search"
        case .command(let c): c.verb
        case .plan: "Plan"
        }
    }
}

private extension Suggestion {
    var isAnswer: Bool { if case .answer = self { true } else { false } }
}

/// Under the search bar: a hint when AI is on, otherwise how to turn it on. Search works either way.
private struct AIStatusLine: View {
    @EnvironmentObject private var assistant: AssistantStore

    var body: some View {
        Group {
            if let pulling = assistant.pullingModel {
                HStack(spacing: 8) {
                    if assistant.pull?.phase == .lookingUp {
                        Text("Looking up \(OllamaModelCatalog.displayName(pulling))…")
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Text("Downloading \(OllamaModelCatalog.displayName(pulling))")
                        ProgressView(value: assistant.pullProgress ?? 0).tint(.white).frame(width: 120)
                        Text("\(Int((assistant.pullProgress ?? 0) * 100))%").monospacedDigit()
                    }
                    Button { assistant.cancelPull() } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 18))
                    .help("Cancel download")
                }
            } else {
                switch assistant.status {
                case .ready, .unknown:
                    HStack(spacing: 5) {
                        Text("Find a file, ask anything, or type")
                        KeyCap(text: "/")
                        Text("for commands")
                    }
                case .notRunning:
                    HStack(spacing: 4) {
                        Text("Searching without AI ·")
                        if OllamaClient.isInstalled {
                            Button("Start Ollama for smarter results") { assistant.startServer() }
                                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                        } else {
                            Link("Get Ollama for smarter results", destination: URL(string: "https://ollama.com/download")!)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                case .modelMissing:
                    HStack(spacing: 4) {
                        Text("Searching without AI ·")
                        DownloadModelMenu()
                    }
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.32))
        .frame(height: 18)
        .overlay(alignment: .bottom) {
            if let error = assistant.pullError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1).offset(y: 16)
            }
        }
    }
}

/// "Download a model" with the suggested models, plus a way to pick any other.
struct DownloadModelMenu: View {
    @EnvironmentObject private var assistant: AssistantStore

    var body: some View {
        Menu {
            ForEach(OllamaModelCatalog.recommended) { option in
                Button("\(option.title) · \(option.size) — \(option.blurb)") { assistant.pullModel(option.name) }
            }
            Divider()
            Button("Choose another model…") { SettingsWindowController.shared.show(pane: .assistant) }
        } label: {
            Text("Download a model")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.white.opacity(0.7))
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

