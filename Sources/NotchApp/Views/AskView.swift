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
    /// The field has had the keyboard since this open. Until it does, a notch opened to type in
    /// already looks focused (the field takes focus once the opening spring settles, to keep it
    /// smooth), so the bar doesn't brighten and gain its caret a beat after appearing.
    @State private var focusLanded = false

    private var looksFocused: Bool {
        focused || (viewModel.isOpen && viewModel.wantsKeyboard && viewModel.tab == .ask && !focusLanded)
    }
    @ObservedObject private var suggestions = SearchSuggestions.shared
    @State private var copied: String?
    @ObservedObject private var commands = CommandCenter.shared
    @ObservedObject private var appActions = AppActions.shared
    @ObservedObject private var ramble = RambleStore.shared
    /// Proposed actions the user unticked before running the plan.
    @State private var excluded: Set<UUID> = []
    /// An AI action waiting for the user's instructions: the bar holds it, and ↩ runs it with them.
    @State private var pendingAction: Command?
    /// The result the arrow keys are on: previewed, and what ↩ / ⌘↩ / ⌘Y act on.
    @State private var resultIndex = 0

    var body: some View {
        if ramble.active {
            RambleView(ramble: ramble)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            search
        }
    }

    @ViewBuilder private var search: some View {
        // One layout with a single search field: swapping between separate layouts recreated
        // the field and took the cursor out of it as soon as suggestions appeared.
        // The bar moves up with the first key typed, not a beat later when the suggestions arrive
        // (it slid up through them then). Typing instructions for an action, or about a captured
        // window, keeps it where it is: there are no suggestions to make room for.
        let idle = assistant.current == nil && suggestions.items.isEmpty
            && (query.isEmpty || pendingAction != nil || assistant.context != nil)
        VStack(spacing: idle ? 12 : 6) {
            if idle { Spacer(minLength: 0) }
            searchBar(compact: !idle)
            if let job = assistant.current {
                ResultView(job: job, accent: accent, excluded: $excluded, selection: $resultIndex, applyPlan: applyPlan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else if !suggestions.items.isEmpty {
                SuggestionList(items: suggestions.items, placeholders: suggestions.placeholderRows,
                               selected: $suggestions.selected, copied: copied, perform: perform)
                    .padding(SuggestionList.inset)
                    .notchSurface(RoundedRectangle(cornerRadius: SuggestionList.radius, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // In once the bar has mostly made its move, so it doesn't pass over them.
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6))
                                                .animation(.easeOut(duration: 0.2).delay(0.12)),
                                            removal: .opacity.animation(.easeOut(duration: 0.1))))
            } else if !idle {
                // Typed, and the suggestions are on their way: room for them.
                Spacer(minLength: 0)
            } else {
                Group {
                    if let context = assistant.context {
                        ContextActions(state: context) { question in
                            query = question
                            assistant.run(question)
                        }
                    } else if let done = commands.confirmation {
                        ConfirmationLine(confirmation: done)
                    } else if let app = appActions.context, !appActions.items.isEmpty {
                        VStack(spacing: 10) {
                            AppActionsRow(context: app, items: appActions.items, perform: runAppAction, instruct: askInstructions)
                            // The hint gives way to the actions; a status that needs doing something stays.
                            if assistant.pullingModel != nil || ![.ready, .unknown].contains(assistant.status) { AIStatusLine() }
                        }
                    } else {
                        AIStatusLine()
                    }
                }
                .transition(.opacity)
                IndexingLine()
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The bar's move up and its change of size, as one motion.
        .animation(Motion.pane.animation, value: idle)
        .contentShape(Rectangle())
        .onTapGesture {
            guard idle else { return }
            viewModel.wantsKeyboard = true // after a hover-open, a click is the cue to start typing
            focused = true
        }
        .onAppear {
            assistant.refreshStatusIfStale()
            if viewModel.isOpen { AppActions.shared.prepare() }
            // ⌘1…⌘5 run the actions under the empty bar (the panel sees ⌘ keys before this view does).
            AppActions.shared.shortcut = { n, instructions in
                guard query.isEmpty, assistant.current == nil, assistant.context == nil, pendingAction == nil,
                      appActions.items.indices.contains(n - 1) else { return false }
                let command = appActions.items[n - 1]
                if instructions, command.takesInstructions { askInstructions(command) } else { runAppAction(command) }
                return true
            }
            // If Quick Look keeps the keyboard, its arrow keys still move the selection here.
            QuickLook.shared.onMove = { moveSelection($0) }
            // Hidden tabs aren't rendered, so restore the query when this page comes back. With no
            // result to come back to, the bar starts empty, and so does the list (it outlives this view).
            if let job = assistant.current { query = barText(job) } else if query.isEmpty { suggestions.clear() }
            focusIfShown()
        }
        .onDisappear { AppActions.shared.shortcut = nil }
        .onChange(of: viewModel.tab) { _, _ in focusIfShown() }
        .onChange(of: viewModel.isSettled) { _, _ in focusIfShown() }
        .onChange(of: viewModel.wantsKeyboard) { _, _ in focusIfShown() }
        .onChange(of: viewModel.typeAheadDelete) { _, n in
            guard n > 0 else { return }
            if !query.isEmpty { query.removeLast() }
            viewModel.typeAheadDelete = 0
        }
        // Keys typed while the notch opens show up as they're typed, not all at once on focus.
        .onChange(of: viewModel.typeAhead) { _, typed in
            guard !typed.isEmpty else { return }
            query += typed
            viewModel.typeAhead = ""
        }
        .onChange(of: assistant.current?.id) { _, _ in
            if let job = assistant.current { query = barText(job) }
            resultIndex = 0
            QuickLook.shared.close()
        }
        .onChange(of: viewModel.isOpen) { _, open in
            guard !open else { return }
            QuickLook.shared.close()
            // Drop focus so the next open focuses the field afresh (and its caret shows).
            focused = false
            focusLanded = false
        }

        .onChange(of: viewModel.tab) { _, _ in QuickLook.shared.close() }
        // A model came up: the AI actions can join the row.
        .onChange(of: assistant.status) { _, _ in AppActions.shared.refresh() }
        .onChange(of: commands.confirmation?.id) { _, new in
            // An action that ran straight from the bar: clear it for the next thing.
            if new != nil, assistant.current == nil { query = ""; suggestions.clear() }
        }
        .onChange(of: query) { _, q in
            // Typing something new replaces the last result with live suggestions — except while
            // asking about a captured window, where files and apps would only get in the way.
            // (An action's result sits under an empty bar: only typing something replaces it.)
            if let job = assistant.current, q != job.query, !(job.actionTitle != nil && q.isEmpty) { assistant.clear() }
            if assistant.current == nil {
                // Typing instructions for an action, or about a captured window: no suggestions.
                if assistant.context == nil, pendingAction == nil { suggestions.update(q) } else { suggestions.clear() }
            }
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
            AppIndex.shared.noteOpened(app.url)
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
            // A command that started a job (an AI Command, a question about the window) shows it:
            // emptying the bar would clear it.
            query = assistant.current.map(barText) ?? ""
            suggestions.clear()
        case .plan(let q):
            suggestions.clear()
            excluded = []
            assistant.run(q, route: .actions)
        case .doInApp(let q, _):
            suggestions.clear()
            assistant.run(q, route: .app)
        }
    }

    /// Holds an AI action in the bar for the user's instructions (right-click "Add Instructions…",
    /// ⌥-click or ⌥⌘1…5).
    private func askInstructions(_ command: Command) {
        withAnimation(Motion.small.animation) { pendingAction = command }
        query = ""
        suggestions.clear()
        viewModel.wantsKeyboard = true
        focused = true
    }

    /// ↩ with an action waiting: run it with what was typed (as it is, when nothing was).
    private func runPending() {
        guard let command = pendingAction else { return }
        let extra = query
        withAnimation(Motion.small.animation) { pendingAction = nil }
        query = ""
        runAppAction(command.withInstructions(extra))
    }

    /// A chip under the empty bar (or ⌘1…⌘5).
    private func runAppAction(_ command: Command) {
        if case .template(let prefix) = command.action {
            query = prefix
            return
        }
        CommandCenter.shared.run([command])
        if let job = assistant.current { query = barText(job) }
    }

    /// What the bar shows for a result: what was typed, so it can be changed and run again; nothing
    /// for one an action started (its title shows beside the bar's icon instead).
    private func barText(_ job: AssistantStore.Job) -> String {
        job.actionTitle == nil ? job.query : ""
    }

    /// Runs the ticked actions from an AI plan, then clears the bar for the next thing.
    private func applyPlan(_ plan: CommandPlanner.Plan) {
        if assistant.current?.actionTitle == "Ramble" { ramble.planApplied() }
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

    // MARK: - Keyboard over results

    /// What the arrow keys move through right now: a finished search's files or links, else the
    /// suggestion list's files and apps (nil entries for rows that aren't files).
    private var browsable: [URL] {
        guard let job = assistant.current else { return [] }
        let streaming = (job.route == .web || job.route == .screen || job.route == .help) && !(job.answer ?? "").isEmpty
        guard job.state == .done || streaming else { return [] }
        switch job.route {
        case .files?: return job.files.map(\.url)
        // Each moment's picture (for Quick Look); ↩ goes back to the page or app instead.
        case .recall?: return (job.recall?.hits ?? []).map { $0.thumbnail ?? URL(fileURLWithPath: "/") }
        case .weather?, .calendar?, .actions?, .help?: return []
        default: return (job.answer ?? "").isEmpty ? job.sources.map(\.url) : job.sources.prefix(5).map(\.url)
        }
    }

    private var showsFiles: Bool { assistant.current?.route == .files }
    private var showsRecall: Bool { assistant.current?.route == .recall }

    /// The local file under the selection, in results or suggestions.
    private var selectedFile: URL? {
        if assistant.current != nil {
            return showsFiles && browsable.indices.contains(resultIndex) ? browsable[resultIndex] : nil
        }
        return suggestions.current.flatMap { if case .file(let url) = $0 { url } else { nil } }
    }

    /// Files in the suggestion list, for Quick Look, with the selected one's position among them.
    private var suggestionFiles: (urls: [URL], index: Int?) {
        let urls = suggestions.items.compactMap { if case .file(let url) = $0 { url } else { nil } }
        return (urls, selectedFile.flatMap { urls.firstIndex(of: $0) })
    }

    private func moveSelection(_ delta: Int) {
        if let job = assistant.current {
            let count = job.route == .app ? job.appPicks.count : browsable.count
            guard count > 0 else { return }
            resultIndex = min(max(resultIndex + delta, 0), count - 1)
            if showsFiles || showsRecall { QuickLook.shared.follow(browsable, at: resultIndex) }
        } else {
            suggestions.move(delta)
            let files = suggestionFiles
            if let i = files.index { QuickLook.shared.follow(files.urls, at: i) } else { QuickLook.shared.close() }
        }
    }

    /// ↩ on a result opens it.
    private func openSelected() -> Bool {
        guard assistant.current != nil, browsable.indices.contains(resultIndex) else { return false }
        QuickLook.shared.close()
        if showsRecall, let hits = assistant.current?.recall?.hits, hits.indices.contains(resultIndex) {
            RecallSearch.open(hits[resultIndex])
            finish()
            return true
        }
        let url = browsable[resultIndex]
        if !HelpBrain.open(url) { NSWorkspace.shared.open(url) }
        if showsFiles { finish() }
        return true
    }

    /// ⌘↩ shows the selected file (or app) in Finder.
    private func revealSelected() -> KeyPress.Result {
        var url = selectedFile
        if url == nil, assistant.current == nil, case .app(let app)? = suggestions.current { url = app.url }
        guard let url else { return .ignored }
        QuickLook.shared.close()
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return .handled
    }

    /// ⌘↩ on a written answer carries it on in a chat window; a follow-up typed into the bar first
    /// is asked there straight away.
    private func continueInChat() -> KeyPress.Result {
        guard let job = assistant.current, ChatStore.canContinue(job) else { return .ignored }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        ChatWindow.shared.open(from: job)
        if !typed.isEmpty, typed != job.query { ChatStore.shared.send(typed) }
        query = ""
        return .handled
    }

    /// ⌘Y previews the selected file full size, or closes the preview.
    private func quickLookSelected() -> KeyPress.Result {
        if QuickLook.shared.isVisible { QuickLook.shared.close(); return .handled }
        if assistant.current != nil {
            guard showsFiles || showsRecall, browsable.indices.contains(resultIndex) else { return .ignored }
            QuickLook.shared.show(browsable, at: resultIndex)
        } else {
            let files = suggestionFiles
            guard let i = files.index else { return .ignored }
            QuickLook.shared.show(files.urls, at: i)
        }
        return .handled
    }

    /// Puts the cursor in the search bar whenever the notch shows this tab. Not until the notch has
    /// finished opening: the field taking focus mid-spring cost a dropped frame on every open. The
    /// window already has the keyboard by then, and keeps anything typed meanwhile (`typeAhead`).
    private func focusIfShown() {
        guard viewModel.isOpen, viewModel.isSettled, viewModel.wantsKeyboard, viewModel.tab == .ask, !focused else { return }
        FrameProbe.mark("focus")
        viewModel.takeKeyFocus()
        // The window has to be key before the field can take focus.
        DispatchQueue.main.async {
            focused = true
            // The field editor can become first responder before the panel is fully key; it then
            // takes typing but never starts blinking its caret. Restart the caret once focus has
            // landed, after adding what was typed while the notch opened.
            DispatchQueue.main.async {
                if !viewModel.typeAhead.isEmpty {
                    query += viewModel.typeAhead
                    viewModel.typeAhead = ""
                }
                guard let window = NSApp.keyWindow as? NotchPanel,
                      let editor = window.firstResponder as? NSTextView else { return }
                DispatchQueue.main.async {
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                    editor.updateInsertionPointStateAndRestartTimer(true)
                }
            }
        }
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
                    ThinkingRing(size: compact ? 20 : 24, speed: 0.9, disc: false)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    // One size, scaled down for the compact bar: a symbol that changes size redraws in
                    // place, where a scale moves along with the bar.
                    // In the colour of where the answer came from, once there's one.
                    Image(systemName: routeIcon)
                        .font(.system(size: 17, weight: .medium))
                        .scaleEffect(compact ? 14.0 / 17 : 1)
                        .foregroundStyle(assistant.current?.route.map { AnyShapeStyle($0.tint) }
                                         ?? AnyShapeStyle(.white.opacity(looksFocused ? 0.8 : 0.45)))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 20)

            if let context = assistant.context {
                ContextChip(state: context) { assistant.clearContext() }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else if let pending = pendingAction {
                ActionChip(title: pending.title, icon: pending.icon) {
                    withAnimation(Motion.small.animation) { pendingAction = nil }
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else if let job = assistant.current, let title = job.actionTitle, query.isEmpty {
                ActionChip(title: title, icon: job.actionIcon ?? "sparkles") { assistant.clear() }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }

            TextField("", text: $query, prompt: Text(placeholder)
                .foregroundStyle(.white.opacity(0.3)))
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 15 : 18, weight: .regular))
                .focused($focused)
                .overlay(alignment: .leading) {
                    // A caret where the real one will be, until the field has the keyboard.
                    if looksFocused, !focused, query.isEmpty {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color(nsColor: .textInsertionPointColor))
                            .frame(width: 2, height: compact ? 17 : 21)
                            .allowsHitTesting(false)
                    }
                }
                .onSubmit {
                    if pendingAction != nil {
                        runPending()
                    } else if assistant.context != nil, assistant.current == nil || assistant.current?.query != query {
                        assistant.run(query) // about the captured window
                    } else if assistant.current == nil, let pick = suggestions.current {
                        perform(pick)
                    } else if let job = assistant.current, job.route == .app, job.appPicks.indices.contains(resultIndex) {
                        assistant.runAppPick(job.appPicks[resultIndex])
                        query = ""
                    } else if let job = assistant.current, job.route == .actions, let plan = job.plan {
                        applyPlan(plan)
                    } else if !openSelected() {
                        assistant.run(query)
                    }
                }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    let revealed = revealSelected()
                    return revealed == .handled ? revealed : continueInChat()
                }
                .onKeyPress(keys: ["y"]) { press in
                    press.modifiers.contains(.command) ? quickLookSelected() : .ignored
                }
                .onExitCommand {
                    if pendingAction != nil {
                        withAnimation(Motion.small.animation) { pendingAction = nil }
                        query = ""
                    } else if QuickLook.shared.isVisible {
                        QuickLook.shared.close()
                    } else if assistant.current != nil || !query.isEmpty {
                        assistant.clear(); query = ""; suggestions.clear()
                    } else if assistant.context != nil {
                        assistant.clearContext() // then back to plain search
                    } else {
                        viewModel.backOut()
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
                // In where it lands, once the bar has moved there (a view coming in starts out in its
                // final place, which ahead of the bar was outside it).
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.8)).animation(.easeOut(duration: 0.16).delay(0.2)),
                                        removal: .opacity.animation(.easeOut(duration: 0.1))))
            } else if settings.hotKeysEnabled, let combo = HotKeys.combo(for: .search) {
                // The shortcut that brings the bar back, like Spotlight's ⌘Space: whatever it's set to
                // in Settings (a rebound key, or none when it's turned off).
                KeyCap(text: combo.display)
                    .transition(.opacity)
            }
        }
        .padding(.leading, compact ? 14 : 18)
        .padding(.trailing, compact ? 10 : 14)
        .frame(height: compact ? 38 : 48)
        .frame(maxWidth: compact ? .infinity : 500)
        .notchSurface(Capsule(), active: looksFocused)
        .overlay {
            // Above results the bar spans the page: keep the glow to the bar plus a 7pt bloom. One glow
            // either way, so the bar widening as you type doesn't bring a fresh one (and its flare).
            if settings.searchBarEffect != .none {
                RainbowGlow(style: settings.searchBarEffect, focused: looksFocused, running: running, compact: compact, typing: query.count,
                            pager: viewModel.pager, onScreen: viewModel.tab == .ask && viewModel.isSettled)
                    .mask { Capsule().padding(compact ? -7 : -RainbowGlow.spread) }
            }
        }
        // Room for the glow's bloom when the bar spans the page, so it isn't cut off at the edges.
        .padding(.horizontal, compact ? 8 : 0)
        .padding(.top, compact ? 7 : 0)
        .animation(.easeOut(duration: 0.18), value: looksFocused)
        .animation(.easeOut(duration: 0.15), value: query.isEmpty)
        // Only hold the notch open once something's typed, so an auto-focused empty bar
        // doesn't stop it closing when the pointer leaves.
        .onChange(of: focused) { _, f in
            viewModel.isEditing = f && !query.isEmpty
            if f { focusLanded = true }
        }
        .onChange(of: query) { _, q in viewModel.isEditing = focused && !q.isEmpty }
    }

    private var placeholder: String {
        switch assistant.context {
        case .ready(let c, _)?: c.hasSelection ? "Ask about the selection" : c.isArea ? "Ask about this area" : "Ask about \(c.appName ?? "this window")"
        case .capturing?: "Ask about what's on screen"
        default: pendingAction != nil ? "Add instructions, then ↩ (“focus on deadlines”, “in Spanish”…)"
            : assistant.current?.actionTitle != nil ? "Search something else" : "Search, or type a command"
        }
    }

    private var routeIcon: String {
        switch assistant.current?.route {
        case .files?: "doc.text.magnifyingglass"
        case .web?: "globe"
        case .weather?: "cloud.sun"
        case .actions?: "sparkles"
        case .calendar?: "calendar"
        case .notes?: "note.text"
        case .screen?: "macwindow"
        case .help?: "questionmark.circle"
        case .recall?: "clock.arrow.circlepath"
        case .write?: "character.bubble"
        case .app?: "wand.and.stars"
        case nil: "magnifyingglass"
        }
    }
}

// MARK: - Results

struct CalendarResult: View {
    let answer: CalendarAnswer

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(answer.headline)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                if let detail = answer.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button("Open Calendar") { CalendarManager.shared.openCalendar() }
                        .buttonStyle(NotchPillButtonStyle())
                    if !answer.tasks.isEmpty {
                        Button("Open Tasks") { CommandCenter.shared.show(.tasks, pane: TasksPane.tasks.rawValue) }
                            .buttonStyle(NotchPillButtonStyle())
                    }
                }
            }
            .frame(width: 220, alignment: .leading)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(answer.events) { event in
                        HStack(spacing: 10) {
                            // The calendar's own colour, as Calendar shows it.
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(event.color.map { Color(red: $0[0], green: $0[1], blue: $0[2]) } ?? .white.opacity(0.35))
                                .frame(width: 3, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text(CommandParser.eventText(event.start, event.end, allDay: event.allDay)
                                     + (event.location.map { " · \($0)" } ?? ""))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                    if !answer.free.isEmpty {
                        let t = Date.FormatStyle(date: .omitted, time: .shortened)
                        ForEach(answer.free, id: \.start) { slot in
                            HStack(spacing: 10) {
                                Image(systemName: "circle.dashed").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                                Text("\(slot.start.formatted(.dateTime.weekday(.abbreviated))) \(slot.start.formatted(t)) – \(slot.end.formatted(t))")
                                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                                Text(BriefingService.duration(slot.duration))
                                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    if !answer.tasks.isEmpty {
                        if !answer.events.isEmpty || !answer.free.isEmpty {
                            Text("Tasks")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.35))
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                        }
                        ForEach(answer.tasks) { task in TaskCheckRow(task: task) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A task in an answer, ticked off right there.
private struct TaskCheckRow: View {
    let task: CalendarAnswer.TaskBrief
    @EnvironmentObject private var tasks: TaskStore

    var body: some View {
        let done = tasks.tasks.first { $0.id == task.id }?.isDone ?? false
        HStack(spacing: 10) {
            Button {
                withAnimation(Motion.small.animation) { tasks.setDone(task.id, !done) }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(done ? .green : .white.opacity(0.45))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(done ? "Mark as not done" : "Mark as done")
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .strikethrough(done, color: .white.opacity(0.5))
                    .foregroundStyle(.white.opacity(done ? 0.45 : 1))
                    .lineLimit(1)
                if let due = task.due {
                    Text(task.overdue ? "Overdue · \(due.formatted(date: .abbreviated, time: .shortened))"
                         : "Due \(due.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(task.overdue && !done ? Color.orange.opacity(0.85) : .white.opacity(0.45))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// An answer from the app's notes and tasks, with the lines it came from.
struct NotesResult: View {
    let answer: NotesAnswer
    @EnvironmentObject private var tasks: TaskStore

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                // Long answers get smaller rather than cut off, and can be copied.
                Text(answer.headline)
                    .font(.system(size: answer.headline.count > 140 ? 12.5 : answer.headline.count > 70 ? 14 : 17, weight: .semibold))
                    .lineLimit(7)
                    .minimumScaleFactor(0.85)
                    .textSelection(.enabled)
                if let detail = answer.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button("Open Notes") { CommandCenter.shared.show(.tasks, pane: TasksPane.notes.rawValue) }
                        .buttonStyle(NotchPillButtonStyle(primary: true))
                    if answer.lines.contains(where: { $0.task != nil }) {
                        Button("Tasks") { CommandCenter.shared.show(.tasks, pane: TasksPane.tasks.rawValue) }
                            .buttonStyle(NotchPillButtonStyle())
                    }
                }
            }
            .frame(width: 250, alignment: .leading)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(answer.lines) { line in
                        if let id = line.task {
                            TaskCheckRow(task: .init(id: id, title: line.text, due: line.due,
                                                     overdue: line.due.map { $0 < Date() } ?? false))
                        } else {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "text.alignleft")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.35))
                                    .frame(width: 14)
                                    .padding(.top, 2)
                                Text(line.text)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.white.opacity(0.88))
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct WeatherCard: View {
    let report: WeatherReport
    let accent: Color
    /// The days under the summary rather than beside it, for a narrow place (a chat).
    var stacked = false

    var body: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 22))
        let shown = Array(report.days.prefix(stacked ? 7 : 5))
        // The week's range, so each day's bar sits where its temperatures fall within it.
        let coldest = shown.map(\.low).min() ?? 0, warmest = shown.map(\.high).max() ?? 1
        layout {
            let focus = report.days.indices.contains(report.focusDay) ? report.days[report.focusDay] : nil
            HStack(spacing: 14) {
                Image(systemName: WeatherReport.symbol(report.focusDay == 0 ? report.currentCode : focus?.code ?? report.currentCode))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 46))
                    .shadow(color: glow(report.focusDay == 0 ? report.currentCode : focus?.code ?? report.currentCode).opacity(0.45), radius: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.place)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    if report.focusDay == 0 {
                        Text("\(Int(report.currentTemp.rounded()))°")
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .foregroundStyle(tint(report.currentTemp))
                        Text("\(WeatherReport.describe(report.currentCode)) · feels \(Int(report.feelsLike.rounded()))°")
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    } else if let focus {
                        Text(report.focusDay == 1 ? "Tomorrow" : focus.date.formatted(.dateTime.weekday(.wide)))
                            .font(.system(size: 13, weight: .medium))
                        (Text("\(Int(focus.high.rounded()))°").foregroundColor(tint(focus.high))
                         + Text(" / ").foregroundColor(.white.opacity(0.35))
                         + Text("\(Int(focus.low.rounded()))°").foregroundColor(tint(focus.low)))
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                        Text("\(WeatherReport.describe(focus.code)) · \(focus.rainChance)% rain")
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, day in
                    VStack(spacing: 6) {
                        Text(i == 0 ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(i == report.focusDay ? 0.95 : 0.5))
                        Image(systemName: WeatherReport.symbol(day.code))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 17))
                            .frame(height: 22)
                        Text("\(Int(day.high.rounded()))°")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(tint(day.high))
                        range(day, coldest: coldest, warmest: warmest)
                        Text("\(Int(day.low.rounded()))°")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(tint(day.low).opacity(0.75))
                        if day.rainChance >= 20 {
                            Text("\(day.rainChance)%")
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1))
                        } else {
                            Text(" ").font(.system(size: 9.5))
                        }
                    }
                    .frame(width: stacked ? nil : 46)
                    .frame(maxWidth: stacked ? .infinity : nil)
                    .padding(.vertical, 8)
                    .background {
                        if i == report.focusDay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(LinearGradient(colors: [glow(day.code).opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func tint(_ temp: Double) -> Color { report.tint(temp) }
    private func glow(_ code: Int) -> Color { WeatherReport.glow(code) }

    private func range(_ day: WeatherReport.Day, coldest: Double, warmest: Double) -> some View {
        TempRange(report: report, low: day.low, high: day.high, coldest: coldest, warmest: warmest)
    }
}

private struct ResultView: View {
    let job: AssistantStore.Job
    let accent: Color
    @Binding var excluded: Set<UUID>
    @Binding var selection: Int
    let applyPlan: (CommandPlanner.Plan) -> Void
    @EnvironmentObject private var assistant: AssistantStore

    var body: some View {
        switch job.state {
        case _ where job.meeting != nil:
            MeetingResults(job: job, id: job.meeting!, accent: accent)
        case .running where job.route == .web && !(job.answer ?? "").isEmpty:
            // The answer streams in as it's written.
            WebResults(job: job, accent: accent, selection: $selection)
        case .running where job.route == .screen && !(job.answer ?? "").isEmpty:
            ScreenResults(job: job, accent: accent, selection: $selection)
        case .running where job.route == .help && !(job.answer ?? "").isEmpty:
            HelpResults(job: job, accent: accent, selection: $selection)
        case .running(let stage):
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                ThinkingRing(size: 48)
                    .padding(.bottom, 2)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                ShimmerText(text: stage)
                Text(job.route == .web ? "Searching the web" : job.route == .files ? "Searching your Mac"
                     : job.route == .weather ? "Getting the weather" : job.route == .actions ? "Turning that into actions"
                     : job.route == .calendar ? "Reading your calendar"
                     : job.route == .notes ? "Looking in your notes"
                     : job.route == .screen ? ScreenQuestion.privacyLine
                     : job.route == .help ? "From NotchApp's guide, settings and changelog"
                     : job.route == .recall ? "Looking through what you've seen, on this Mac"
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
                HStack(spacing: 8) {
                    // Straight to the right list: "Screen Recording" is easy to confuse with Accessibility.
                    if job.route == .screen, !ScreenQuestion.hasPermission {
                        Button("Open Screen Recording settings") { ScreenQuestion.openPrivacySettings() }
                            .buttonStyle(NotchPillButtonStyle())
                    }
                    Button("Try again") { assistant.run(job.query, route: job.route) }
                        .buttonStyle(NotchPillButtonStyle(primary: true))
                }
            }
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done where job.route == .actions:
            if let plan = job.plan { PlanView(plan: plan, excluded: $excluded, apply: applyPlan) }
        case .done where job.route == .app:
            AppPicksView(job: job, selection: $selection)
        case .done:
            VStack(spacing: 10) {
                switch job.route {
                case .files?: FileResults(job: job, accent: accent, selection: $selection)
                case .weather?: if let report = job.weather { WeatherCard(report: report, accent: accent) }
                case .calendar?: if let answer = job.calendar { CalendarResult(answer: answer) }
                case .notes?: if let answer = job.notes { NotesResult(answer: answer) }
                case .screen?: ScreenResults(job: job, accent: accent, selection: $selection)
                case .help?: HelpResults(job: job, accent: accent, selection: $selection)
                case .recall?: if let answer = job.recall { RecallResults(answer: answer, selection: $selection) }
                default: WebResults(job: job, accent: accent, selection: $selection)
                }
                RouteFooter(job: job)
            }
        }
    }
}

/// A kept call's notes, and beside them its transcript: click a line to hear the call from there.
/// While the call is being transcribed again or written up, that shows here as it goes.
private struct MeetingResults: View {
    let job: AssistantStore.Job
    let id: UUID
    let accent: Color
    @ObservedObject private var meetings = MeetingAssistant.shared
    @ObservedObject private var player = MeetingPlayer.shared
    /// The voice being named by hand, and the name so far.
    @State private var renaming: Int?
    @State private var draft = ""
    @FocusState private var naming: Bool

    var body: some View {
        let stage = meetings.stage[id]
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                notes(stage)
                if job.state == .done { RouteFooter(job: job) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let meeting = meetings.meeting(id) {
                transcript(meeting, stage: stage).frame(width: 280)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private func notes(_ stage: MeetingAssistant.Stage?) -> some View {
        let text: String = {
            if let answer = job.answer, !answer.isEmpty { return answer }
            if case .writing(let soFar)? = stage { return soFar }
            return ""
        }()
        if case .failed(let message) = job.state {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 18))
                Text(message).font(.system(size: 12)).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if text.isEmpty {
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                ThinkingRing(size: 40)
                ShimmerText(text: label(stage))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                AnswerText(text: text, accent: accent).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func label(_ stage: MeetingAssistant.Stage?) -> String {
        switch stage {
        case .transcribing?: "Listening to the call again"
        case .downloadingVoices?: "Getting the voice model"
        case .voices?: "Telling voices apart"
        case .writing?: "Writing notes"
        case nil: if case .running(let s) = job.state { s } else { "Writing notes" }
        }
    }

    private func transcript(_ meeting: MeetingAssistant.Meeting, stage: MeetingAssistant.Stage?) -> some View {
        let audio = !meetings.tracks(id).isEmpty
        let here = player.meeting == id
        let current = here ? meeting.lines.last(where: { ($0.offset ?? .infinity) <= player.position + 0.3 })?.id : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if audio {
                    Button { player.toggle(id) } label: {
                        Image(systemName: here && player.playing ? "pause.fill" : "play.fill").font(.system(size: 10, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 22))
                    .help(here && player.playing ? "Pause" : "Play the call")
                }
                if let renaming {
                    renameField(renaming, in: meeting)
                } else {
                    Text(here ? clock(player.position) : "Transcript")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    if let (title, p) = progress(stage) {
                        Text("\(title) \(Int(p * 100))%")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.4))
                        ProgressView(value: p).progressViewStyle(.linear).frame(width: 46).tint(accent)
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(meeting.lines) { line in
                            row(line, in: meeting, current: line.id == current, playable: audio && line.offset != nil)
                                .id(line.id)
                        }
                    }
                }
                .onChange(of: current) { _, new in
                    guard let new, player.playing else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    /// What the transcript's header shows as the call's worked on after it ends.
    private func progress(_ stage: MeetingAssistant.Stage?) -> (String, Double)? {
        switch stage {
        case .transcribing(let p)?: ("Improving", p)
        case .downloadingVoices(let p)?: ("Voice model", p)
        case .voices(let p)?: ("Voices", p)
        default: nil
        }
    }

    private func row(_ line: LiveCaptions.Line, in meeting: MeetingAssistant.Meeting, current: Bool, playable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if meeting.inPerson != true {
                speaker(line, in: meeting)
                    // Room for names once voices are told apart.
                    .frame(width: meeting.voices?.isEmpty == false ? 52 : 30, alignment: .leading)
            }
            Text(line.text)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(current ? 0.95 : 0.72))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(current ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { if playable, let offset = line.offset { player.play(id, from: max(0, offset - 0.4)) } }
        .help(playable ? "Play from here" : "")
    }

    /// Who said it. Once voices are told apart, a voice's label is a menu to name it: the people
    /// invited, someone heard before, another name, or not sure. Its lines all follow.
    @ViewBuilder private func speaker(_ line: LiveCaptions.Line, in meeting: MeetingAssistant.Meeting) -> some View {
        let label = Text(meeting.label(line))
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(line.speaker == .you ? accent.opacity(0.9) : .white.opacity(0.4))
            .lineLimit(1)
        if let n = line.voice, let voice = meeting.voices?.first(where: { $0.number == n }) {
            Menu {
                let names = names(for: meeting)
                ForEach(names, id: \.self) { name in
                    MenuItem(name, name == voice.name ? "checkmark" : "person") { meetings.nameVoice(n, in: id, as: name) }
                }
                if !names.isEmpty { Divider() }
                MenuItem("Other Name…", "pencil") { beginRename(n, from: voice.name) }
                if voice.name != nil {
                    MenuItem("Not Sure", "questionmark.circle") { meetings.nameVoice(n, in: id, as: nil) }
                }
            } label: { label }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.white.opacity(0.4))
            .help("Who's this?")
        } else {
            label
        }
    }

    /// Who a voice could be: the people invited (by first name, as they're spoken to), then
    /// people named in earlier calls.
    private func names(for meeting: MeetingAssistant.Meeting) -> [String] {
        let you = NSFullUserName().split(separator: " ").first.map { $0.lowercased() }
        var seen = Set<String>()
        let invited = (meeting.attendees ?? []).compactMap { $0.split(separator: " ").first.map(String.init) }
        let known = VoicePrints.shared.people.map(\.name)
        return (invited + known).filter { $0.lowercased() != you && seen.insert($0.lowercased()).inserted }.prefix(12).map { $0 }
    }

    private func beginRename(_ number: Int, from name: String?) {
        draft = name ?? ""
        renaming = number
        NotchPresenter.shared.primary?.isEditing = true
        NotchPresenter.shared.primary?.takeKeyFocus()
        // The panel has to be key before the field can take focus.
        DispatchQueue.main.async { naming = true }
    }

    private func endRename(saving: Bool) {
        guard let number = renaming else { return }
        if saving { meetings.nameVoice(number, in: id, as: draft) }
        renaming = nil
        NotchPresenter.shared.primary?.isEditing = false
    }

    /// Naming a voice by hand, in the transcript's header.
    private func renameField(_ number: Int, in meeting: MeetingAssistant.Meeting) -> some View {
        HStack(spacing: 6) {
            Text("Speaker \(number):")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .focused($naming)
                .onSubmit { endRename(saving: true) }
                .onExitCommand { endRename(saving: false) }
                .onChange(of: naming) { _, focused in if !focused { endRename(saving: !draft.isEmpty) } }
            Button { endRename(saving: true) } label: {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(NotchIconButtonStyle(size: 20))
            .help("Name this voice")
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// "Do it in this app" when it wasn't sure, or the pick would delete or close something: the best
/// match and alternatives, to run with a click (or ↩ on the highlighted one).
private struct AppPicksView: View {
    let job: AssistantStore.Job
    @Binding var selection: Int
    @EnvironmentObject private var assistant: AssistantStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold))
                Text(AppDo.isRisky(job.appPicks.first!) ? "Check this one first, in \(job.appName ?? "the app")"
                     : "Did you mean, in \(job.appName ?? "the app")")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            VStack(spacing: 4) {
                ForEach(Array(job.appPicks.enumerated()), id: \.offset) { i, pick in
                    Button { assistant.runAppPick(pick) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pick.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 20)
                                .foregroundStyle(.white.opacity(0.8))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pick.title).font(.system(size: 13, weight: .semibold))
                                if let sub = pick.subtitle {
                                    Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                                }
                            }
                            Spacer()
                            if i == selection {
                                Text(AppDo.isRisky(pick) ? "Run anyway" : "Run")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AppDo.isRisky(pick) ? .orange : .white.opacity(0.8))
                                KeyCap(text: "↩")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(.white.opacity(i == selection ? 0.12 : 0.05)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { selection = i } }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct RouteFooter: View {
    let job: AssistantStore.Job
    @EnvironmentObject private var assistant: AssistantStore

    /// Where the answer came from.
    private var source: (icon: String, text: String) {
        switch job.route {
        case .files?: ("internaldrive", "Searched your Mac")
        case .weather?: ("cloud.sun", "Open-Meteo forecast")
        case .calendar?: ("calendar", job.calendar?.tasks.isEmpty == false ? "Your calendar and tasks" : "Your calendar")
        case .notes?: ("note.text", "Your notes and tasks")
        case .screen?: ("macwindow", job.screenIsArea ? (job.sources.isEmpty ? "Looked at the area" : "The area and the web")
                        : job.sources.isEmpty ? "Looked at your screen" : "Your screen and the web")
        case .help?: ("questionmark.circle", "NotchApp help")
        case .recall?: ("clock.arrow.circlepath", "Recall, on this Mac")
        case .write?: ("character.bubble", "Written by \(!AppSettings.shared.aiProvider.isCloud ? "the model on this Mac" : AppSettings.shared.aiProvider.shortName)")
        default: ("globe", "Searched the web")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: source.icon)
                .foregroundStyle(job.route?.tint ?? .white.opacity(0.5))
            Text(source.text)
            // With a list showing, its header says this instead.
            if job.findingMore, job.files.count < 2 {
                Text("·")
                ThinkingRing(size: 14, speed: 0.9, disc: false)
                Text("finding more")
                    .transition(.opacity)
            }
            // What an action wrote (a summary, a drafted reply) is for copying; searching the web for
            // its hidden instruction instead wouldn't mean anything.
            // What to do next, as buttons rather than faint links: the suggested next step in the
            // accent colour, the others plain, so they read over the glass and anything behind it.
            if let next = job.followUpTitle, job.state == .done {
                Button(next) { assistant.runFollowUp() }
                    .buttonStyle(NotchPillButtonStyle(primary: true, height: 20))
                    .padding(.leading, 4)
            }
            if ChatStore.canContinue(job) {
                Button("Follow up") { ChatWindow.shared.open(from: job) }
                    .buttonStyle(NotchPillButtonStyle(primary: job.followUpTitle == nil, height: 20))
                    .padding(.leading, job.followUpTitle == nil ? 4 : 0)
                    .help("Keep talking about this answer in a chat window (⌘↩). Type a follow-up first to ask it there.")
            }
            if job.route == .write || job.actionTitle != nil, let answer = job.answer, job.state == .done {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                    Haptics.tap()
                }
                .buttonStyle(NotchPillButtonStyle(height: 20))
            } else if job.route != .calendar, job.actionTitle == nil {
                Button(job.route == .web || job.route == .notes ? "Search my files instead" : "Search the web instead") {
                    assistant.switchRoute()
                }
                .buttonStyle(NotchPillButtonStyle(height: 20))
                .padding(.leading, (job.followUpTitle == nil || job.state != .done) && !ChatStore.canContinue(job) ? 4 : 0)
            }
            Spacer()
            if !assistant.aiAvailable && job.route != .weather && job.route != .recall && assistant.pullingModel == nil {
                Text(job.route == .web ? "AI writes answers from these ·" : "AI picks the best match ·")
                if case .modelMissing = assistant.status { DownloadModelMenu() }
            } else if job.route == .recall, !(job.recall?.hits.isEmpty ?? true) {
                KeyHints(hints: [("↑↓", nil), ("↩", "open"), ("⌘Y", "preview")])
            } else if job.route == .files, !job.files.isEmpty {
                KeyHints(hints: job.files.count > 1 ? [("↑↓", nil), ("↩", "open"), ("⌘Y", "preview")]
                                                    : [("↩", "open"), ("⌘Y", "preview")])
            } else if job.route != .weather && job.route != .calendar && !job.sources.isEmpty {
                KeyHints(hints: [("↑↓", nil), ("↩", "open")])
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
    }
}

/// Small keycaps with what each does, for the keyboard shortcuts over results.
private struct KeyHints: View {
    let hints: [(key: String, action: String?)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(hints, id: \.key) { hint in
                HStack(spacing: 3) {
                    KeyCap(text: hint.key)
                    if let action = hint.action { Text(action) }
                }
            }
        }
    }
}

private struct FileResults: View {
    @ObservedObject private var access = FolderAccess.shared
    @ObservedObject private var images = ImageIndex.shared
    let job: AssistantStore.Job
    let accent: Color
    @Binding var selection: Int

    var body: some View {
        if !job.files.isEmpty {
            let index = min(selection, job.files.count - 1)
            HStack(alignment: .top, spacing: 16) {
                // The selected match, previewed: ↑↓ (or a click in the list) changes it.
                BestFile(hit: job.files[index],
                         label: index == 0 ? (job.confident ? "Best match" : "Closest match") : "Match \(index + 1) of \(job.files.count)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                if job.files.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Text("\(job.files.count) matches")
                                .contentTransition(.numericText())
                            if job.findingMore {
                                Text("·")
                                ThinkingRing(size: 13, speed: 0.9, disc: false)
                                Text("finding more")
                            } else if images.isIndexing {
                                // Pictures not looked at yet can't match; say so.
                                Text("· \(images.remaining.formatted()) pictures still indexing")
                                    .help("Picture search finds the ones done so far")
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 8)
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 0) {
                                    ForEach(Array(job.files.enumerated()), id: \.element.id) { i, hit in
                                        FileRow(hit: hit, selected: i == index) {
                                            selection = i
                                            QuickLook.shared.follow(job.files.map(\.url), at: i)
                                        }
                                        .id(i)
                                    }
                                }
                            }
                            .onChange(of: index) { _, i in
                                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i) }
                            }
                        }
                    }
                    .frame(width: 230, alignment: .leading)
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
                        .buttonStyle(NotchPillButtonStyle(primary: true, height: 24))
                        .padding(.top, 4)
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
    let label: String
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Sized to the picture so a wide screenshot isn't a sliver in a tall box.
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: hit.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(thumbnail == nil ? 0 : 0.12), lineWidth: 1))
                .frame(maxWidth: 96, maxHeight: 108)
                .frame(width: 96, height: 108, alignment: .top)
                .id(hit.url)
                .transition(.opacity)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
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
                        .help("⌘↩")
                    ShelfButton(url: hit.url)
                }
                .padding(.top, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(hit.url) }
        .onDrag { NSItemProvider(object: hit.url as NSURL) }
        .task(id: hit.url) {
            thumbnail = nil
            thumbnail = await Thumbnail.load(hit.url, size: 300)
        }
    }

    private var location: String {
        hit.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func button(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(NotchPillButtonStyle(primary: primary, height: 24))
    }
}

/// "Add to Shelf" that turns into a checkmark once the file is on the shelf.
private struct ShelfButton: View {
    let url: URL
    @EnvironmentObject private var shelf: ShelfStore

    var body: some View {
        let added = shelf.items.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
        Button {
            guard !added else { return }
            withAnimation(Motion.small.animation) { ShelfStore.shared.add([url]) }
        } label: {
            HStack(spacing: 4) {
                if added {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).transition(.scale.combined(with: .opacity))
                }
                Text(added ? "On Shelf" : "Add to Shelf")
            }
            .contentTransition(.opacity)
        }
        // The same pill as Open and Show in Finder beside it.
        .buttonStyle(NotchPillButtonStyle(height: 24))
        .help(added ? "Already on your shelf" : "Keep it on the shelf")
    }
}

struct FileRow: View {
    let hit: FileHit
    var selected = false
    /// A click previews the file; a double-click opens it.
    var select: () -> Void = {}
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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.14 : hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(hit.url) }
        .onTapGesture(count: 1) { select() }
        .onDrag { NSItemProvider(object: hit.url as NSURL) }
        .help(hit.reason ?? hit.url.path)
        .contextMenu {
            MenuItem("Open", "arrow.up.forward.square") { NSWorkspace.shared.open(hit.url) }
            OpenWithMenu(urls: [hit.url])
            MenuItem("Quick Look", "eye") { QuickLookPreview.shared.show([hit.url]) }
            MenuItem("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
            Divider()
            MenuItem("Copy", "doc.on.doc") { ShelfStore.copy([hit.url]) }
            MenuItem("Copy Path", "point.topleft.down.to.point.bottomright.curvepath") { ShelfStore.copyPaths([hit.url]) }
            ShareLink(item: hit.url) { Label("Share…", systemImage: "square.and.arrow.up") }
            let onShelf = ShelfStore.shared.items.contains { $0.url == hit.url }
            MenuItem(onShelf ? "On Shelf" : "Add to Shelf", onShelf ? "checkmark" : "tray.and.arrow.down") { ShelfStore.shared.add([hit.url]) }
        }
    }
}

private struct WebResults: View {
    let job: AssistantStore.Job
    let accent: Color
    @Binding var selection: Int

    var body: some View {
        if job.state == .done && (job.answer ?? "").isEmpty {
            LinkResults(sources: job.sources, selection: selection)
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

            // A translation has no sources to list.
            if job.route != .write {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sources")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                    if job.state == .done {
                        ShelfIconButton(file: ShelfStore.answerFile(for: job.query), help: "Save the answer to the shelf") {
                            ShelfStore.shared.addAnswer(question: job.query, answer: job.answer ?? "", sources: job.sources)
                        }
                    }
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
                SourceList(sources: Array(job.sources.prefix(5)), selection: selection)
            }
            .frame(width: 200)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// An answer about what's on screen: the answer, and beside it the screen it looked at (plus any
/// web sources it needed).
private struct ScreenResults: View {
    let job: AssistantStore.Job
    let accent: Color
    @Binding var selection: Int

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ScrollView(.vertical, showsIndicators: false) {
                AnswerText(text: job.answer ?? "", accent: accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(job.screenIsArea ? "The area" : "Your screen")
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
                if let screen = job.screen {
                    Image(nsImage: screen)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.12)))
                        .frame(maxHeight: job.sources.isEmpty ? 120 : 64, alignment: .top)
                        .padding(.leading, 6)
                }
                if !job.sources.isEmpty {
                    SourceList(sources: Array(job.sources.prefix(3)), selection: selection)
                }
            }
            .frame(width: 200)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A help answer about NotchApp, with each "Settings → …" path a link to that page.
private struct HelpResults: View {
    let job: AssistantStore.Job
    let accent: Color
    @Binding var selection: Int

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            AnswerText(text: job.answer ?? "", accent: accent, settingsLinks: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 28)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.answer ?? "", forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(NotchIconButtonStyle(size: 20))
            .help("Copy answer")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.openURL, OpenURLAction { url in HelpBrain.open(url) ? .handled : .systemAction })
    }
}

/// Plain search results (no model to write an answer): title, site and snippet.
private struct LinkResults: View {
    let sources: [WebSource]
    let selection: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { i, source in
                        LinkRow(source: source, selected: i == selection).id(i)
                    }
                }
            }
            .onChange(of: selection) { _, i in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct LinkRow: View {
    let source: WebSource
    var selected = false
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
                    // The selected link shows more of its snippet, as a preview of the page.
                    Text(source.snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(selected ? 0.65 : 0.5))
                        .lineLimit(selected ? 3 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { LinkShelfButton(source: source, hovering: hovering || selected) }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.12 : hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(source.url.absoluteString)
    }
}

/// A small shelf button for a web link: shows on hover, and stays as a checkmark once it's on the shelf.
private struct LinkShelfButton: View {
    let source: WebSource
    let hovering: Bool

    var body: some View {
        ShelfIconButton(file: ShelfStore.linkFile(for: source.url, title: source.title), help: "Save the link to the shelf",
                        visible: hovering) {
            ShelfStore.shared.addLink(source.url, title: source.title)
        }
    }
}

/// Tray icon that saves something to the shelf and turns into a checkmark once it's there.
private struct ShelfIconButton: View {
    let file: URL
    let help: String
    var visible = true
    let add: () -> Void
    @EnvironmentObject private var shelf: ShelfStore

    var body: some View {
        let added = shelf.contains(file)
        if visible || added {
            Button {
                guard !added else { return }
                withAnimation(Motion.small.animation) { add() }
            } label: {
                Image(systemName: added ? "checkmark" : "tray.and.arrow.down")
                    .font(.system(size: 10, weight: added ? .bold : .regular))
                    .foregroundStyle(.white.opacity(added ? 0.9 : 0.6))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(NotchIconButtonStyle(size: 20))
            .help(added ? "On your shelf" : help)
            .transition(.opacity)
        }
    }
}

/// Answer text with citation markers like [2] drawn as small accent badges.
struct AnswerText: View {
    let text: String
    let accent: Color
    /// "Settings → Shelf → Quick drops" becomes a link to that page (help answers).
    var settingsLinks = false
    /// Every paragraph the same size (a chat reply), rather than the first one leading.
    var uniform = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .code(code, language):
                    CodeBlock(code: code, language: language)
                case let .prose(paras, first):
                    // One Text for every paragraph and bullet between code blocks: a selection
                    // can't cross from one Text into the next, so separate ones let you copy one
                    // bullet at a time.
                    prose(paras, startingAt: first)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private enum Block {
        case prose([(text: String, isBullet: Bool)], first: Int)
        case code(String, language: String?)
    }

    /// Runs of paragraphs and bullets, split by code blocks. `first` is the run's first paragraph's
    /// place in the whole answer (the very first one leads, bigger).
    private var blocks: [Block] {
        var out: [Block] = []
        var run: [(text: String, isBullet: Bool)] = []
        var runStart = 0
        for (i, para) in paragraphs.enumerated() {
            if para.isCode {
                if !run.isEmpty { out.append(.prose(run, first: runStart)); run = [] }
                out.append(.code(para.text, language: para.language))
            } else {
                if run.isEmpty { runStart = i }
                run.append((para.text, para.isBullet))
            }
        }
        if !run.isEmpty { out.append(.prose(run, first: runStart)) }
        return out
    }

    private func prose(_ paras: [(text: String, isBullet: Bool)], startingAt first: Int) -> Text {
        var result = Text("")
        for (k, para) in paras.enumerated() {
            let i = first + k
            let leads = !uniform && i == 0 && !para.isBullet
            if k > 0 {
                // A short blank line between paragraphs, as the old stack's spacing was.
                result = result + Text("\n") + Text("\n").font(.system(size: 4))
            }
            let font: Font = uniform ? .system(size: 13) : .system(size: leads ? 14.5 : 12.5, weight: leads ? .medium : .regular)
            let color = Color.white.opacity(uniform ? 0.9 : i == 0 ? 0.95 : 0.78)
            if para.isBullet { result = result + Text("•  ").font(font).foregroundColor(.white.opacity(0.5)) }
            result = result + styled(para.text).font(font).foregroundColor(color)
        }
        return result
    }

    /// Lines as paragraphs and bullets, and ``` fenced code as blocks (kept verbatim, indentation
    /// and all; a fence still open while the answer streams in is already a block).
    private var paragraphs: [(text: String, isBullet: Bool, isCode: Bool, language: String?)] {
        var out: [(String, Bool, Bool, String?)] = []
        var code: [String]?
        var language: String?
        // Models sometimes put "•" bullets inline; give each its own line.
        for raw in text.replacingOccurrences(of: " • ", with: "\n• ").components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    if !lines.isEmpty { out.append((lines.joined(separator: "\n"), false, true, language)) }
                    code = nil
                } else {
                    code = []
                    // "```python" names the language.
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            guard !trimmed.isEmpty else { continue }
            if let prefix = ["• ", "- ", "* "].first(where: trimmed.hasPrefix) {
                out.append((String(trimmed.dropFirst(prefix.count)), true, false, nil))
            } else if trimmed.hasPrefix("#") {
                // A heading reads as a bold line.
                out.append(("**" + trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) + "**", false, false, nil))
            } else {
                out.append((trimmed, false, false, nil))
            }
        }
        if let lines = code, !lines.isEmpty { out.append((lines.joined(separator: "\n"), false, true, language)) }
        return out
    }

    /// Citations ([1]) as small superscripts, `inline code` in monospace, and **bold** as bold.
    private func styled(_ s: String) -> Text {
        var result = Text("")
        for (i, part) in s.components(separatedBy: "`").enumerated() {
            if i % 2 == 1, !part.isEmpty {
                result = result + Text(part).font(.system(size: 12, design: .monospaced)).foregroundColor(.white.opacity(0.92))
            } else {
                for (j, run) in part.components(separatedBy: "**").enumerated() {
                    result = result + (j % 2 == 1 ? cited(run).bold().foregroundColor(.white.opacity(0.95)) : cited(run))
                }
            }
        }
        return result
    }

    private func cited(_ s: String) -> Text {
        var result = Text("")
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]"),
              Int(rest[rest.index(after: open)..<close]) != nil {
            result = result + linked(String(rest[..<open]))
            let n = String(rest[rest.index(after: open)..<close])
            result = result + Text(" \(n)").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.45)).baselineOffset(4)
            rest = rest[rest.index(after: close)...]
        }
        return result + linked(String(rest))
    }

    private func linked(_ s: String) -> Text {
        guard settingsLinks, s.contains("Settings") else { return Text(s) }
        var result = Text("")
        for part in HelpBrain.linkify(s) {
            if let url = part.link {
                var a = AttributedString(part.text)
                a.link = url
                a.foregroundColor = accent
                a.underlineStyle = .single
                result = result + Text(a)
            } else {
                result = result + Text(part.text)
            }
        }
        return result
    }
}

/// Code from an answer: syntax-coloured and monospaced on a soft panel, with a copy button.
private struct CodeBlock: View {
    let code: String
    var language: String?
    @State private var copied = false

    var body: some View {
        Text(SyntaxHighlighter.highlight(code, language: language))
            .font(.system(size: 11.5, design: .monospaced))
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .padding(.trailing, 18)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    ClipboardHistory.shared.ignoreCurrent()
                    copied = true
                    Haptics.tap()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(NotchIconButtonStyle(size: 20))
                .padding(3)
                .help("Copy code")
            }
    }
}

/// Numbered sources beside an answer; the one the arrow keys are on is scrolled into view.
private struct SourceList: View {
    let sources: [WebSource]
    let selection: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { i, source in
                        SourceRow(index: i + 1, source: source, selected: i == selection).id(i)
                    }
                }
            }
            .onChange(of: selection) { _, i in
                guard sources.indices.contains(i) else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i) }
            }
        }
    }
}

private struct SourceRow: View {
    let index: Int
    let source: WebSource
    var selected = false
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(source.url) } label: {
            HStack(alignment: .top, spacing: 8) {
                // The site's own icon; its number (what the answer cites) stays beside the address.
                Favicon(host: source.host) {
                    Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        .frame(width: 16, height: 16)
                }
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text("\(index) · \(source.host)")
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                LinkShelfButton(source: source, hovering: hovering || selected)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.12 : hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(source.url.absoluteString)
    }
}

/// AI-proposed actions to review: untick any you don't want, then run the rest.
struct PlanView: View {
    let plan: CommandPlanner.Plan
    @Binding var excluded: Set<UUID>
    let apply: (CommandPlanner.Plan) -> Void
    /// Cancel; by default it clears the Search tab's result.
    var cancel: (() -> Void)?
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
                Button("Cancel") { if let cancel { cancel() } else { assistant.clear() } }
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
                .foregroundStyle(confirmation.failed ? .orange : .green)
            Text(confirmation.text)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            if let undo = confirmation.undo {
                Text("·").foregroundStyle(.white.opacity(0.3))
                Button("Undo") { CommandCenter.shared.undo(undo) }
                    .buttonStyle(NotchLinkButtonStyle())
            }
            if let destination = confirmation.destination, case .show(let tab, let pane) = destination {
                Text("·").foregroundStyle(.white.opacity(0.3))
                Button("Show") { CommandCenter.shared.show(tab, pane: pane) }
                    .buttonStyle(NotchLinkButtonStyle())
            } else if let destination = confirmation.destination, case .settingsPane(let pane) = destination {
                Text("·").foregroundStyle(.white.opacity(0.3))
                Button("Settings") { CommandCenter.shared.run([Command(action: .settingsPane(pane), title: pane.title, icon: pane.icon)]) }
                    .buttonStyle(NotchLinkButtonStyle())
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .frame(height: 18)
    }
}

/// An Apple Intelligence–style glow around the search bar: layered strokes of a conic gradient in
/// Apple Intelligence's palette (a crisp core, a soft bloom and a faint wash that tints the bar's
/// inside), each turning at its own pace so the colours flow into one another. It eases in as it comes
/// on, flares as a search starts, pulses with each key typed, runs faster while a search does, and
/// drifts slowly when the bar isn't focused. It's never frozen while it can be seen, except for Reduce Motion. As a shimmer,
/// the same layers carry a white light round the edge instead, with no colour.
private struct RainbowGlow: View {
    var style: AppSettings.SearchBarEffect = .glow
    let focused: Bool
    let running: Bool
    /// The bar spans the page above results: keep the glow tight to the bar (edge, inner tint and a
    /// small bloom) so it isn't clipped by the page or spill onto the list below.
    var compact = false
    /// Changes with each key typed, for a pulse of light.
    var typing = 0
    /// Paused while pages slide, another tab is showing or the notch is still springing open.
    @ObservedObject var pager: PagerState
    var onScreen = true

    /// How far the glow spreads past the bar on each side.
    static let spread: CGFloat = 56

    var body: some View {
        let still = pager.isSwiping || pager.isSettling || !onScreen
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // How fast it flows: drifting when the bar isn't focused, faster while a search runs; held
        // where it is while paused (it carries on from the same angle).
        let speed: Float = still || reduceMotion ? 0 : running ? 2.2 : focused ? 1 : 0.35
        let level: Float = running ? 0.8 : focused ? 0.62 : 0.3
        GlowLayers(style: style, speed: speed, level: level, compact: compact, typing: typing)
            .padding(-Self.spread)
            .allowsHitTesting(false)
    }
}

/// The glow as Core Animation layers, seen through the bar's outline in three blurred strata. Every
/// motion is a Core Animation animation that runs in the window server: nothing is drawn per frame by
/// the app. Each speed change restarts the turns from where they are (there's no shared clock to
/// re-base, which could leave a reused glow stuck).
/// Lets the app build the search bar's glow ahead of the first open.
enum SearchGlow {
    @MainActor static func prewarm() { GlowLayers.prewarm() }
}

private struct GlowLayers: NSViewRepresentable {
    let style: AppSettings.SearchBarEffect
    let speed: Float
    let level: Float
    let compact: Bool
    let typing: Int

    /// Finished glows, kept for the next open: building the layers and their blur filters cost a
    /// dropped frame at the start of every open. (One per notch screen at most, so it stays tiny.)
    @MainActor private static var pool: [GlowView] = []

    func makeNSView(context: Context) -> GlowView {
        let view = Self.pool.popLast() ?? GlowView()
        view.typing = typing
        return view
    }

    func updateNSView(_ view: GlowView, context: Context) {
        view.apply(style)
        view.set(speed: speed, level: level, compact: compact)
        if typing != view.typing {
            if typing > view.typing { view.pulse() }
            view.typing = typing
        }
    }

    static func dismantleNSView(_ view: GlowView, coordinator: ()) {
        view.reset()
        if pool.count < 2 { pool.append(view) }
    }

    /// Builds one ahead of time, so even the first open finds one ready.
    @MainActor static func prewarm() {
        if pool.isEmpty { pool.append(GlowView()) }
    }

    final class GlowView: NSView {
        private struct Stratum {
            let wrapper: CALayer
            let mask: CAShapeLayer
            let gradient: CAGradientLayer
            let line: CGFloat
            let opacity: Float
            /// Seconds per turn at speed 1, and which way.
            var period: Double
            var direction: Double
        }

        /// All the strata; its opacity is how bright the glow is.
        private let glow = CALayer()
        private var strata: [Stratum] = []
        private var speed: Float = 0
        private var level: Float = 0
        private var compact = false
        private var style: AppSettings.SearchBarEffect = .glow
        var typing = 0

        /// One white light with a tail, once round: the shimmer.
        private static let shimmer: [CGColor] = [0, 0, 0.5, 0.95, 0].map { CGColor(gray: 1, alpha: $0) }

        /// Apple Intelligence's palette: lilac/violet, periwinkle, sky, pink, coral and peach.
        private static let colors: [CGColor] = {
            let hex: [Int] = [0xBC82F3, 0x8D9FFF, 0x79C4FB, 0xF5B9EA, 0xFF6778, 0xFFBA71, 0xFFA1F3, 0xBC82F3]
            return hex.map { (v: Int) -> CGColor in
                let r = CGFloat((v >> 16) & 0xFF) / 255
                let g = CGFloat((v >> 8) & 0xFF) / 255
                let b = CGFloat(v & 0xFF) / 255
                return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
            }
        }()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerUsesCoreImageFilters = true
            glow.opacity = 0
            layer?.addSublayer(glow)
            // (line width, blur, opacity, seconds per turn, direction), widest first. The wash turns
            // the other way, so the colours inside and along the edge drift through each other.
            let specs: [(CGFloat, Double, Float, Double, Double)] = [(16, 18, 0.2, 15, 1), (5, 6, 0.55, 9, -1), (1.5, 0, 0.95, 6.5, -1)]
            for (i, (line, blur, opacity, period, direction)) in specs.enumerated() {
                let wrapper = CALayer()
                wrapper.opacity = opacity
                if blur > 0, let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]) {
                    wrapper.filters = [filter]
                }
                let masked = CALayer()
                let mask = CAShapeLayer()
                mask.fillColor = nil
                mask.strokeColor = CGColor.white
                mask.lineWidth = line
                masked.mask = mask
                let gradient = CAGradientLayer()
                gradient.type = .conic
                gradient.colors = Self.colors
                gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
                gradient.endPoint = CGPoint(x: 0.5, y: 0)
                // Each starts a third of a turn on from the last, so they never line up.
                gradient.setValue(Double(i) * 2 * .pi / 3, forKeyPath: "transform.rotation.z")
                masked.addSublayer(gradient)
                wrapper.addSublayer(masked)
                glow.addSublayer(wrapper)
                strata.append(Stratum(wrapper: wrapper, mask: mask, gradient: gradient, line: line, opacity: opacity, period: period, direction: direction))
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Colour or shimmer. The shimmer's layers turn together, so the soft light stays with the
        /// bright one, and there's no wash: only the edge lights up.
        func apply(_ style: AppSettings.SearchBarEffect) {
            guard style != self.style else { return }
            self.style = style
            let shimmer = style == .shimmer
            let glow: [(period: Double, direction: Double)] = [(15, 1), (9, -1), (6.5, -1)]
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for i in strata.indices {
                strata[i].gradient.colors = shimmer ? Self.shimmer : Self.colors
                strata[i].wrapper.opacity = shimmer ? [0, 0.4, 1][i] : strata[i].opacity
                strata[i].period = shimmer ? 4 : glow[i].period
                strata[i].direction = shimmer ? 1 : glow[i].direction
                strata[i].gradient.setValue(shimmer ? 0 : Double(i) * 2 * .pi / 3, forKeyPath: "transform.rotation.z")
            }
            CATransaction.commit()
            if speed > 0 { turn() }
            if shimmer { strata[0].wrapper.removeAnimation(forKey: "breathe") } else { breathe(speed > 0) }
        }

        func set(speed: Float, level: Float, compact: Bool) {
            if compact != self.compact {
                self.compact = compact
                needsLayout = true
            }
            let (wasSpeed, wasLevel) = (self.speed, self.level)
            self.speed = speed
            self.level = level
            if level != wasLevel { fade(to: level) }
            if speed != wasSpeed {
                turn()
                breathe(speed > 0)
            }
            // A search starting while it's already flowing: it flares, and settles. (Not as it comes
            // on: that waits for the notch to settle, so a flare there came late, as a jump.)
            if speed > 0, wasSpeed > 0, wasLevel >= 0.5, level > wasLevel + 0.1 {
                ignite()
            }
        }

        /// Ready to be shown again from nothing: dark, still, and with nothing left running.
        func reset() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.removeAllAnimations()
            glow.opacity = 0
            for s in strata {
                hold(s.gradient)
                s.gradient.removeAnimation(forKey: "ignite")
                s.mask.removeAllAnimations()
                s.wrapper.removeAllAnimations()
            }
            CATransaction.commit()
            speed = 0
            level = 0
        }

        /// A key typed: a quick swell of light along the edge.
        func pulse() {
            guard speed > 0 else { return }
            for s in strata.dropFirst() {
                let swell = CABasicAnimation(keyPath: "opacity")
                swell.isAdditive = true
                swell.fromValue = 0.12
                swell.toValue = 0
                swell.duration = 0.35
                swell.timingFunction = CAMediaTimingFunction(name: .easeOut)
                s.wrapper.add(swell, forKey: "pulse")
                let widen = CABasicAnimation(keyPath: "lineWidth")
                widen.isAdditive = true
                widen.fromValue = s.line * 0.3
                widen.toValue = 0
                widen.duration = 0.35
                widen.timingFunction = CAMediaTimingFunction(name: .easeOut)
                s.mask.add(widen, forKey: "pulse")
            }
        }

        /// Brightness eases to the new level from wherever it is now.
        private func fade(to level: Float) {
            let from = glow.presentation()?.opacity ?? glow.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.opacity = level
            CATransaction.commit()
            let ease = CABasicAnimation(keyPath: "opacity")
            ease.fromValue = from
            ease.toValue = level
            ease.duration = 0.35
            ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glow.add(ease, forKey: "level")
        }

        /// Turns every stratum at the current speed, from the angle it's at now.
        private func turn() {
            for s in strata {
                let angle = hold(s.gradient)
                guard speed > 0 else { continue }
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                turn.fromValue = angle
                turn.toValue = angle + s.direction * 2 * .pi
                turn.duration = s.period / Double(speed)
                turn.repeatCount = .infinity
                s.gradient.add(turn, forKey: "turn")
            }
        }

        /// Stops a gradient's turn where it is on screen, and returns that angle.
        @discardableResult private func hold(_ gradient: CAGradientLayer) -> Double {
            let angle = (gradient.presentation() ?? gradient).value(forKeyPath: "transform.rotation.z") as? Double ?? 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.removeAnimation(forKey: "turn")
            gradient.setValue(angle, forKeyPath: "transform.rotation.z")
            CATransaction.commit()
            return angle
        }

        /// The bloom and wash breathe slowly, out of step with each other.
        private func breathe(_ on: Bool) {
            for (i, s) in strata.dropLast().enumerated() {
                // (The shimmer has no wash to breathe: it would show as a faint ring.)
                guard on, !(style == .shimmer && i == 0) else { s.wrapper.removeAnimation(forKey: "breathe"); continue }
                guard s.wrapper.animation(forKey: "breathe") == nil else { continue }
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.isAdditive = true
                breathe.fromValue = -0.04
                breathe.toValue = 0.05
                breathe.duration = 2.4 + Double(i) * 0.9
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                s.wrapper.add(breathe, forKey: "breathe")
            }
        }

        /// A search starting: a soft flare, a little brighter and wider for a moment, the colours
        /// sweeping round a little faster, then easing into the steady flow.
        private func ignite() {
            let duration = 0.7
            let flare = CAKeyframeAnimation(keyPath: "opacity")
            flare.values = [glow.presentation()?.opacity ?? 0, min(1, level + 0.08), level]
            flare.keyTimes = [0, 0.3, 1]
            flare.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            flare.duration = duration
            glow.add(flare, forKey: "level")
            for s in strata {
                let sweep = CABasicAnimation(keyPath: "transform.rotation.z")
                sweep.isAdditive = true
                sweep.fromValue = -s.direction * 0.25 * .pi
                sweep.toValue = 0
                sweep.duration = duration
                sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                s.gradient.add(sweep, forKey: "ignite")
                let bloom = CABasicAnimation(keyPath: "lineWidth")
                bloom.isAdditive = true
                bloom.fromValue = s.line * 0.25
                bloom.toValue = 0
                bloom.duration = duration
                bloom.timingFunction = CAMediaTimingFunction(name: .easeOut)
                s.mask.add(bloom, forKey: "ignite")
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.frame = bounds
            let bar = bounds.insetBy(dx: RainbowGlow.spread, dy: RainbowGlow.spread)
            let path = CGPath(roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil)
            // Large enough that the turning gradient always covers the bar.
            let side = hypot(bar.width, bar.height) + 40
            for s in strata {
                s.wrapper.frame = bounds
                s.wrapper.sublayers?.first?.frame = bounds
                s.mask.frame = bounds
                s.mask.path = path
                s.gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                s.gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            CATransaction.commit()
        }
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

/// Status text that gently pulses while work is happening. The pulse comes from a timeline rather
/// than a repeating animation: one started on appear also caught the layout settling around it
/// and kept replaying that, drawing the text twice.
struct ShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.575 + 0.225 * sin(t * .pi / 0.9)))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: text)
        }
    }
}

/// Results as you type: an instant answer, apps, files, and the full search. Arrow keys move,
/// Return acts on the highlighted row.
private struct SuggestionList: View {
    let items: [Suggestion]
    /// Rows held for file matches still loading.
    var placeholders = 0
    @Binding var selected: Int
    let copied: String?
    let perform: (Suggestion) -> Void
    @EnvironmentObject private var assistant: AssistantStore

    private let rowHeight: CGFloat = 30
    /// The list's surface corner and the padding inside it. The highlight sits concentric
    /// within: its radius is the outer radius minus the inset.
    static let radius: CGFloat = 16
    static let inset: CGFloat = 5
    private static let highlightRadius = radius - inset

    var body: some View {
        // Rows are keyed by position and the highlight is one layer behind them: the list changes
        // on every keystroke ("Search for …" is a new item each time), and per-item identity made
        // the highlight fade out and back in as you typed.
        // The full "/" command list is taller than the notch: show six rows and scroll the rest,
        // instead of pushing the search bar up out of view.
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        row(item, highlighted: i == selected)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = i; perform(item) }
                            .onHover { if $0 { selected = i } }
                            .id(i)
                    }
                    ForEach(0..<placeholders, id: \.self) { i in
                        PlaceholderRow(index: i).frame(height: rowHeight)
                    }
                }
                .background(alignment: .top) {
                    if items.indices.contains(selected) {
                        RoundedRectangle(cornerRadius: Self.highlightRadius, style: .continuous)
                            .fill(Color.accentColor.gradient)
                            .frame(height: rowHeight)
                            .offset(y: CGFloat(selected) * rowHeight)
                    }
                }
            }
            .scrollDisabled(items.count <= Self.maxRows)
            // Up to its rows' height, and no taller than the room under the bar: the notch grows to
            // fit new rows with a spring, and a list already at full height overflowed the page until
            // it caught up, which pushed the bar up and back (rows coming in on the third key or so).
            .frame(minHeight: 0, maxHeight: CGFloat(min(items.count + placeholders, Self.maxRows)) * rowHeight, alignment: .top)
            .clipped()
            .onChange(of: selected) { _, i in proxy.scrollTo(i) }
        }
        .transaction { $0.animation = nil }
    }

    private static let maxRows = SearchSuggestions.maxRows

    /// One line per result, like Spotlight: icon, name, a dimmer detail, and the action on the selected row.
    @ViewBuilder private func row(_ item: Suggestion, highlighted: Bool) -> some View {
        HStack(spacing: 9) {
            icon(item, highlighted: highlighted)
                .frame(width: 20, height: 20)
            // A long query truncates the title; the detail drops out rather than shrinking to a letter.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    titleText(item)
                    if let sub = subtitle(item) {
                        Text(sub)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(highlighted ? 0.7 : 0.38))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // Ideal width small, so a long detail (a definition) truncates into
                            // the room there is instead of the whole detail being dropped.
                            .frame(minWidth: 90, idealWidth: 90, maxWidth: .infinity, alignment: .leading)
                    }
                }
                titleText(item)
            }
            Spacer(minLength: 8)
            if highlighted {
                HStack(spacing: 5) {
                    if case .file = item {
                        KeyCap(text: "⌘Y", onAccent: true)
                        Text("Preview").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                            .padding(.trailing, 4)
                    }
                    Text(hint(item))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    if !(item.isAnswer && copied == title(item)) { KeyCap(text: "↩", onAccent: true) }
                }
                // The action keeps its size however long the query gets.
                .fixedSize()
                .layoutPriority(2)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: rowHeight)
    }

    private func titleText(_ item: Suggestion) -> some View {
        Text(title(item))
            .font(.system(size: item.isAnswer ? 15 : 13, weight: item.isAnswer ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(.white.opacity(0.95))
            .lineLimit(1)
            .truncationMode(.tail)
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
                // In what it does' colour; white on the highlight, which is the accent colour.
                Image(systemName: c.icon).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(highlighted ? AnyShapeStyle(.white) : c.tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.white.opacity(0.75)))
            }
        case .plan:
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(highlighted ? 1 : 0.75))
        case .doInApp:
            if let icon = AppActions.shared.context.flatMap({ NSRunningApplication(processIdentifier: $0.pid)?.icon }) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(highlighted ? 1 : 0.75))
            }
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
        case .doInApp(let q, let app): "Do “\(q)” in \(app)"
        }
    }

    private func subtitle(_ item: Suggestion) -> String? {
        switch item {
        case .answer(let a): a.subtitle
        case .app: "Application"
        case .file(let url):
            ScreenshotText.shared.snippet(for: url, query: SearchSuggestions.shared.currentQuery).map { "Screenshot · “\($0)”" }
                ?? url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .search: assistant.aiAvailable ? "Files, web and weather, with AI" : "Files, web and weather"
        case .command(let c): c.subtitle
        case .plan: "AI drafts them, you review first"
        case .doInApp(_, let app): "Picks from \(app)'s menus and actions"
        }
    }

    private func hint(_ item: Suggestion) -> String {
        switch item {
        case .answer(let a): copied == a.title ? "Copied" : "Copy"
        case .app, .file: "Open"
        case .search: "Search"
        case .command(let c): c.verb
        case .plan: "Plan"
        case .doInApp: "Do it"
        }
    }
}

/// A skeleton row held for a file match that's still loading: an icon and a name-length bar,
/// gently pulsing. Driven by the clock rather than an animation, since the list turns animations off.
private struct PlaceholderRow: View {
    let index: Int

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * 2.6 - Double(index) * 0.7)
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 5, style: .continuous).frame(width: 20, height: 20)
                Capsule().frame(width: [150, 110, 170][index % 3], height: 9)
                Capsule().frame(width: [90, 120, 70][index % 3], height: 7).opacity(0.6)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.06 + 0.05 * pulse))
            .padding(.horizontal, 9)
        }
        .transition(.opacity)
    }
}

private extension Suggestion {
    var isAnswer: Bool { if case .answer = self { true } else { false } }
}

/// Under the search bar: a hint when AI is on, otherwise how to turn it on. Search works either way.
/// While pictures are being indexed: a small ring, a thin bar and how far along it is.
private struct IndexingLine: View {
    @ObservedObject private var images = ImageIndex.shared

    var body: some View {
        if images.isIndexing {
            HStack(spacing: 7) {
                ThinkingRing(size: 13, speed: 0.7, disc: false)
                Text("Indexing pictures")
                Capsule()
                    .fill(.white.opacity(0.1))
                    .frame(width: 90, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.5)).frame(width: 90 * images.fraction, height: 3)
                    }
                    .animation(.easeOut(duration: 0.4), value: images.fraction)
                Text("\(images.passDone.formatted()) of \(images.passTotal.formatted())")
                    .monospacedDigit()
                if let left = images.timeLeft { Text("· \(left)") }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.32))
            .transition(.opacity)
        }
    }
}

/// The window "Ask about this" captured, in the search bar: a thumbnail and the app, or the
/// selection. ✕ (or Esc on an empty bar) goes back to plain search.
private struct ContextChip: View {
    let state: AssistantStore.ContextState
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .capturing:
                ProgressView().controlSize(.mini).tint(.white)
                Text("Looking…")
            case let .ready(context, thumbnail):
                if context.hasSelection {
                    Image(systemName: "text.cursor").font(.system(size: 10, weight: .semibold))
                } else if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 26, height: 17)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                }
                Text(context.hasSelection ? "Selection" : context.isArea ? "Area" : context.appName ?? "Screen")
                    .frame(maxWidth: 120)
            case .failed:
                Image(systemName: "eye.slash").foregroundStyle(.orange)
                Text("Can't see it")
            }
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
            }
            .buttonStyle(NotchIconButtonStyle(size: 16))
            .help("Ask about something else")
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .padding(.leading, 7)
        .padding(.trailing, 2)
        .frame(height: 24)
        .fixedSize()
        .background(Capsule().fill(.white.opacity(0.12)))
        .help(helpText)
    }

    private var helpText: String {
        guard case let .ready(c, _) = state else { return "" }
        let source = c.textSource == .accessibility ? "its text as the app reports it" : "its text read from the picture"
        return "\(c.label)\nAsking about \(c.isArea ? "the area you picked" : "this window") and \(source). \(ScreenQuestion.privacyLine)."
    }
}

/// Ramble: a big box to talk (Dictate, on this Mac) or type everything into, then turn it into
/// tasks, events and a note, or keep it as a note as it is.
private struct RambleView: View {
    @ObservedObject var ramble: RambleStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                Text("Ramble").font(.system(size: 14, weight: .semibold))
                Text(RambleStore.canDictate ? "Dictate and talk, or just type" : "Type or paste it all out, or use any dictation app")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                if RambleStore.canDictate {
                    Button { ramble.toggleDictation(); focused = true } label: {
                        Label(ramble.dictating ? "Stop" : "Dictate", systemImage: ramble.dictating ? "stop.fill" : "mic.fill")
                    }
                    .buttonStyle(NotchPillButtonStyle(height: 24))
                    .help("Turned into text on this Mac as you talk")
                }
                Button { ramble.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(NotchIconButtonStyle(size: 24))
                .help("Back to search (the draft is kept)")
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $ramble.text)
                    .font(.system(size: 14.5))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focused)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                if ramble.text.isEmpty {
                    Text("Everything on your mind: errands, deadlines, “call the dentist Tuesday”, ideas for the launch… It becomes tasks, events and a note.")
                        .font(.system(size: 14.5))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(ramble.dictating ? Color.orange.opacity(0.6) : .white.opacity(0.08), lineWidth: 1))
            HStack(spacing: 8) {
                if ramble.dictating {
                    // What's being heard, before it lands in the box.
                    HStack(spacing: 5) {
                        Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
                        Text(ramble.hearing.isEmpty ? "Listening…" : ramble.hearing).lineLimit(1).truncationMode(.head)
                    }
                    .font(.system(size: 11)).foregroundStyle(.orange.opacity(0.8))
                } else {
                    Text(ramble.wordCount == 0 ? "" : "\(ramble.wordCount) words")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.35))
                }
                Spacer()
                Button("Save as Note") { ramble.saveAsNote() }
                    .buttonStyle(NotchPillButtonStyle(height: 26))
                    .disabled(ramble.wordCount == 0)
                Button { ramble.turnIntoTasks() } label: {
                    HStack(spacing: 6) { Text("Turn into Tasks"); Text("⌘↩").opacity(0.5) }
                }
                .buttonStyle(NotchPillButtonStyle(primary: true, height: 26))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(ramble.wordCount == 0 || !AssistantStore.shared.aiAvailable)
                .help(AssistantStore.shared.aiAvailable ? "AI drafts them; you review before anything's added" : "Needs an AI model (Settings → Search)")
            }
        }
        .padding(.horizontal, 4)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand { ramble.close() }
    }
}

/// What an action's result came from, in the bar where typed text would be: its icon and name.
/// ✕ clears it.
private struct ActionChip: View {
    let title: String
    let icon: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(title).frame(maxWidth: 180)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
            }
            .buttonStyle(NotchIconButtonStyle(size: 16))
            .help("Clear")
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 24)
        .fixedSize()
        .background(Capsule().fill(.white.opacity(0.12)))
    }
}

/// One-click questions for the captured window: what you'd most likely ask about a selection, an
/// error, a page or a question on screen.
private struct ContextActions: View {
    let state: AssistantStore.ContextState
    let ask: (String) -> Void

    var body: some View {
        switch state {
        case .capturing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(.white)
                Text("Looking at what's in front…")
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
        case .failed(let message):
            VStack(spacing: 6) {
                Text(message).multilineTextAlignment(.center)
                if !ScreenQuestion.hasPermission {
                    Button("Open Screen Recording Settings") { ScreenQuestion.openPrivacySettings() }
                        .buttonStyle(NotchPillButtonStyle())
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 30)
        case .ready(let context, _):
            HStack(spacing: 6) {
                if context.hasSelection {
                    // Selected text: your AI Commands (the ones that replace put the result back).
                    ForEach(AICommandStore.shared.commands.prefix(4)) { command in
                        Button { AICommandRunner.run(command) } label: {
                            Label(command.name, systemImage: command.icon)
                        }
                        .buttonStyle(NotchPillButtonStyle())
                        .help(command.output == .replace ? "Replaces the selection in \(context.appName ?? "the app")" : command.prompt)
                    }
                } else {
                    ForEach(Self.suggestions(for: context), id: \.self) { question in
                        Button(question) { ask(context.isArea ? Self.areaPrompt(question) : question) }
                            .buttonStyle(NotchPillButtonStyle())
                    }
                    if context.isArea, !context.text.isEmpty {
                        Button { Self.copyText(context.text) } label: { Label("Copy text", systemImage: "doc.on.doc") }
                            .buttonStyle(NotchPillButtonStyle())
                    }
                }
            }
        }
    }

    /// A short button, said in full: small local models took a bare "Bullet points" for a quiz.
    static func areaPrompt(_ label: String) -> String {
        switch label {
        case "Bullet points": "Turn everything in this area into a bulleted list. Keep each point's wording."
        case "Summarize this": "Summarize what this area says."
        case "Explain this": "Explain what this area shows."
        case "Translate to English": "Translate the text in this area to English."
        default: label
        }
    }

    /// The area's text, read off the picture, onto the clipboard (what Copy Text does, after the fact).
    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Haptics.tap()
        ActivityCenter.shared.show(.notice(title: "Copied \(text.split(whereSeparator: \.isWhitespace).count) words",
                                           detail: "From the area", icon: "doc.on.doc", tone: .info), for: 2)
    }

    /// A date or time in the text ("Friday", "Oct 14", "3:30 pm"), so "Add to my calendar" makes sense.
    static func mentionsDate(_ text: String) -> Bool {
        let t = String(text.prefix(4000))
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return false }
        return detector.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    static func suggestions(for c: ScreenContext) -> [String] {
        if c.hasSelection {
            let selection = c.selection ?? ""
            return mentionsDate(selection) ? ["Explain this", "Summarize this", "Add to my calendar", "Add to my tasks"]
                : ["Explain this", "Summarize this", "Translate to English", "Fix spelling and grammar"]
        }
        if c.isArea {
            guard !c.text.isEmpty else { return ["What's this?", "Describe this"] }
            return [c.text.count > 600 ? "Summarize this" : "Explain this",
                    mentionsDate(c.text) ? "Add to my calendar" : "Bullet points", "Translate to English"]
        }
        let text = c.text.lowercased()
        var out: [String] = []
        if ["error", "exception", "failed", "traceback", "fatal", "warning:"].contains(where: text.contains) { out.append("Explain the error") }
        if text.contains("?") && ["a)", "b)", "a.", "b.", "question", "quiz", "select", "choose"].contains(where: text.contains) {
            out.append("What's the answer?")
        }
        if mentionsDate(c.hasSelection ? (c.selection ?? "") : c.text) { out.append("Add to my calendar") }
        if ["action item", "to do", "todo", "to-do", "- [ ]", "next steps", "follow up", "follow-up"].contains(where: text.contains) {
            out.append("Add to my tasks")
        }
        out.append(c.text.count > 1500 ? "Summarize this" : "What's this?")
        out.append("Key points")
        if c.location?.hasPrefix("http") == true { out.append("What should I know about this site?") }
        return Array(out.prefix(4))
    }
}

/// Actions for the app in front, under the empty bar: its icon, then as many as fit. Right-click
/// one to keep it as a Glance beside the closed notch while this app is in front.
private struct AppActionsRow: View {
    let context: AppContext
    let items: [Command]
    let perform: (Command) -> Void
    /// An AI action held for the user's own instructions first.
    let instruct: (Command) -> Void
    @ObservedObject private var actions = AppActions.shared

    var body: some View {
        let shown = Array(items.prefix(5))
        ViewThatFits(in: .horizontal) {
            ForEach((1...max(1, shown.count)).reversed(), id: \.self) { n in
                row(Array(shown.prefix(n)))
            }
        }
        .padding(.horizontal, 24)
        .transition(.opacity.combined(with: .offset(y: 4)))
    }

    private func row(_ commands: [Command]) -> some View {
        HStack(spacing: 6) {
            AppIcon(bundlePath: context.bundlePath, size: 16)
                .padding(.trailing, 2)
                .help(context.selection == nil ? "For \(context.appName)" : "For the selection in \(context.appName)")
            ForEach(Array(commands.enumerated()), id: \.element.id) { i, command in
                let starred = actions.isStarred(command)
                Button {
                    // ⌥-click: add instructions first.
                    if NSEvent.modifierFlags.contains(.option), command.takesInstructions { instruct(command) } else { perform(command) }
                } label: {
                    HStack(spacing: 5) {
                        Label(command.title, systemImage: command.icon)
                        if starred {
                            Image(systemName: "star.fill").font(.system(size: 7)).foregroundStyle(.orange)
                        }
                    }
                }
                .buttonStyle(NotchPillButtonStyle())
                .help([command.subtitle, command.takesInstructions ? "⌘\(i + 1) · ⌥-click (⌥⌘\(i + 1)) to add instructions · right-click for more"
                                                                : "⌘\(i + 1) · right-click to keep it as a Glance"].compactMap { $0 }.joined(separator: "\n"))
                .contextMenu {
                    if command.takesInstructions {
                        MenuItem("Add Instructions…", "text.badge.plus") { instruct(command) }
                        Divider()
                    }
                    if starred {
                        MenuItem("Remove from Glance", "star.slash") { actions.toggleStar(command) }
                    } else if actions.canStar(command) {
                        MenuItem("Show as Glance in \(context.appName)", "star") { actions.toggleStar(command) }
                    } else if case .template = command.action {
                    } else {
                        Text("\(context.appName) has \(AppActions.starsPerApp) Glance actions already")
                    }
                }
            }
        }
    }
}

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
                                .buttonStyle(NotchLinkButtonStyle())
                        } else {
                            Link("Get Ollama for smarter results", destination: URL(string: "https://ollama.com/download")!)
                                .foregroundStyle(ActionColor.link)
                        }
                    }
                case .modelMissing:
                    HStack(spacing: 4) {
                        Text("Searching without AI ·")
                        DownloadModelMenu()
                    }
                case .needsKey(let provider):
                    HStack(spacing: 4) {
                        Text("Searching without AI ·")
                        Button("Add your \(provider) key") { SettingsWindowController.shared.show(pane: .assistant) }
                            .buttonStyle(NotchLinkButtonStyle())
                    }
                case .appleUnavailable(let why):
                    HStack(spacing: 4) {
                        Text("Searching without AI ·")
                        Button(why) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!) }
                            .buttonStyle(NotchLinkButtonStyle())
                    }
                case .cliUnavailable(let tool, let availability):
                    HStack(spacing: 4) {
                        Text("Searching without AI ·")
                        if availability == .signedOut {
                            Button("Sign in to \(tool.name)") { CLIAgent.openSignIn(tool) }
                                .buttonStyle(NotchLinkButtonStyle())
                        } else if availability == .outdated {
                            Button("Update \(tool.name)") { CLIAgent.openUpdate(tool) }
                                .buttonStyle(NotchLinkButtonStyle())
                        } else {
                            Link("Get \(tool.name)", destination: tool.installURL)
                                .foregroundStyle(ActionColor.link)
                        }
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
                MenuItem("\(option.title) · \(option.size) — \(option.blurb)", "arrow.down.circle") { assistant.pullModel(option.name) }
            }
            Divider()
            MenuItem("Choose Another Model…", "gearshape") { SettingsWindowController.shared.show(pane: .assistant) }
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

