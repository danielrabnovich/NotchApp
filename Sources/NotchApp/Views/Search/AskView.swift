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
    @ObservedObject private var actionPanel = ActionPanel.shared
    @ObservedObject private var emoji = EmojiPicker.shared

    /// ":" then a name is the emoji picker: what's typed after the ":".
    private var emojiQuery: String? {
        query.hasPrefix(":") && assistant.current == nil && assistant.context == nil && pendingAction == nil ? String(query.dropFirst()) : nil
    }
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
            if emojiQuery != nil {
                EmojiPickerView(picker: emoji)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            } else if let job = assistant.current {
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
        .overlay(alignment: .bottomTrailing) {
            if actionPanel.isOpen {
                ZStack(alignment: .bottomTrailing) {
                    // A click anywhere else closes the list (and doesn't reach the rows under it).
                    Color.black.opacity(0.001)
                        .onTapGesture { actionPanel.close() }
                    ActionPanelView(panel: actionPanel)
                        .padding(.trailing, 4)
                        .padding(.bottom, 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                }
                .padding(.top, 52) // below the bar, which stays usable
            }
        }
        .animation(.easeOut(duration: 0.14), value: actionPanel.isOpen)
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
            // ⌘K and the highlighted result's shortcuts, while suggestions are showing.
            actionPanel.attach(current: {
                guard assistant.current == nil, assistant.context == nil, pendingAction == nil, !query.isEmpty else { return nil }
                return suggestions.current
            }, primary: { perform($0) }, finish: { finish() })
            // ⌘K on a GitHub, Vercel or Linear result.
            actionPanel.attachResults {
                guard let job = assistant.current, query == barText(job) else { return nil }
                return DevActions.forJob(job, index: resultIndex)
            }
            // If Quick Look keeps the keyboard, its arrow keys still move the selection here.
            QuickLook.shared.onMove = { moveSelection($0) }
            // Hidden tabs aren't rendered, so restore the query when this page comes back. With no
            // result to come back to, the bar starts empty, and so does the list (it outlives this view).
            if let job = assistant.current { query = barText(job) } else if query.isEmpty { suggestions.clear() }
            openEmojiIfRequested()
            focusIfShown()
        }
        .onDisappear {
            AppActions.shared.shortcut = nil
            actionPanel.detach()
        }
        // The list closed: typing goes back to the bar.
        .onChange(of: actionPanel.isOpen) { _, open in if !open, viewModel.isOpen { focused = true } }
        // It's for one result: another result, or another search, closes it.
        .onChange(of: suggestions.selected) { _, _ in actionPanel.close() }
        .onChange(of: resultIndex) { _, _ in actionPanel.close() }
        .onChange(of: emoji.requested) { _, _ in openEmojiIfRequested() }
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
            actionPanel.close()
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
            actionPanel.close()
            if let typed = emojiQuery {
                suggestions.clear()
                emoji.update(typed)
                if !assistant.pickingEmoji { assistant.pickingEmoji = true }
                return
            }
            if assistant.pickingEmoji { assistant.pickingEmoji = false }
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

    /// The emoji hotkey: the bar starts over with ":", the picker's prefix.
    private func openEmojiIfRequested() {
        guard emoji.requested else { return }
        emoji.requested = false
        assistant.clear()
        pendingAction = nil
        query = ":"
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
            AppIndex.shared.noteOpened(app.url, query: AppIndex.stripLaunchPrefix(suggestions.currentQuery).name)
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
        case .github?, .deploys?, .linear?: return DevResultsInfo.links(job) ?? []
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
        if emojiQuery != nil {
            emoji.move(delta * emoji.columns)
        } else if let job = assistant.current {
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
        // The same number in several repos: show the one picked, here.
        if let answer = assistant.current?.github, answer.choices, answer.items.indices.contains(resultIndex) {
            let item = answer.items[resultIndex]
            assistant.run("\(item.repo)#\(item.number)", route: .github)
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
                    ScanningLens()
                        .scaleEffect(compact ? 14.0 / 17 : 1)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else if emojiQuery != nil {
                    // The highlighted emoji itself, popping in as the highlight moves.
                    let shown = emoji.current.map { $0.toned(emoji.tone) } ?? "🙂"
                    Text(shown)
                        .font(.system(size: 19))
                        .scaleEffect(compact ? 14.0 / 17 : 1)
                        .id(shown)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
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
            .animation(Motion.small.animation, value: emojiQuery == nil ? nil : emoji.current.map { $0.toned(emoji.tone) })

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
                    if emojiQuery != nil {
                        if let e = emoji.current { emoji.insert(e); query = "" }
                    } else if pendingAction != nil {
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
                // In the emoji grid, sideways too, and ⇥ for the skin tone.
                .onKeyPress(.leftArrow) { guard emojiQuery != nil else { return .ignored }; emoji.move(-1); return .handled }
                .onKeyPress(.rightArrow) { guard emojiQuery != nil else { return .ignored }; emoji.move(1); return .handled }
                .onKeyPress(.tab) { guard emojiQuery != nil else { return .ignored }; emoji.cycleTone(); return .handled }
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
        assistant.current?.route?.icon ?? "magnifyingglass"
    }
}
