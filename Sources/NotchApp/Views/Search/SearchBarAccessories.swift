import SwiftUI

/// Under the search bar: a hint when AI is on, otherwise how to turn it on. Search works either way.
/// While pictures are being indexed: a small running light, a thin bar and how far along it is.
struct IndexingLine: View {
    @ObservedObject private var images = ImageIndex.shared

    var body: some View {
        if images.isIndexing {
            HStack(spacing: 7) {
                SearchingCapsule(height: 9, speed: 0.4)
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
struct ContextChip: View {
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
struct RambleView: View {
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
struct ActionChip: View {
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
struct ContextActions: View {
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
struct AppActionsRow: View {
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

struct AIStatusLine: View {
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
