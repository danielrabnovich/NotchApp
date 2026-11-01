import AppKit
import SwiftUI

/// A cloud provider's key (kept in the Keychain), address and model. Saving or checking the key
/// lists the models it can use, which is also the proof that it works; pick one from the list.
struct CloudProviderSettings: View {
    let provider: AIProvider
    @EnvironmentObject private var s: AppSettings
    @State private var key = ""
    @State private var hasKey = false
    /// Typing a new key over a saved one.
    @State private var replacing = false
    @State private var models: [CloudLLM.ModelInfo] = []
    @State private var checking = false
    @State private var result: (ok: Bool, message: String)?
    @State private var filter = ""
    /// A long model list, opened to pick from.
    @State private var browsing = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        Group {
            LabeledContent {
                if hasKey && !replacing { savedKey } else { keyField }
            } label: {
                RowLabel(title: "API key", subtitle: keySubtitle)
            }
            if provider.editableServer {
                TextField(text: Binding(get: { s.cloudBaseURL(for: provider) },
                                        set: { s.cloudBaseURLs[provider.rawValue] = $0 }),
                          prompt: Text(provider.defaultBaseURL)) {
                    RowLabel(title: "Server", subtitle: serverSubtitle)
                }
            }
            status
            if !models.isEmpty {
                modelPicker
            } else if result?.ok != true {
                TextField(text: modelBinding, prompt: Text(provider.suggestedModel.isEmpty ? "Model name" : provider.suggestedModel)) {
                    RowLabel(title: "Model", subtitle: "Or check the key to pick from the models it can use.")
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: provider) { _, _ in load() }
    }

    /// A saved key: that it's there (and which one, by its last characters), not an empty field.
    private var savedKey: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill").font(.system(size: 10.5))
                Text("Saved")
                    .fontWeight(.medium)
                if let tail = APIKeys.get(provider).map({ String($0.suffix(4)) }), !tail.isEmpty {
                    Text("••••\(tail)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(.green.opacity(0.13)))
            .help("Kept in your Mac's Keychain")
            Button("Replace…") {
                replacing = true
                keyFocused = true
            }
            Button(role: .destructive) {
                APIKeys.set(nil, for: provider)
                hasKey = false
                models = []
                result = nil
                AssistantStore.shared.refreshStatus()
            } label: { Image(systemName: "trash") }
            .help("Remove the key")
        }
    }

    private var keyField: some View {
        HStack {
            SecureField("", text: $key, prompt: Text(provider.keyPlaceholder))
                .textFieldStyle(.roundedBorder)
                .focused($keyFocused)
                .frame(minWidth: 180)
                .onSubmit(save)
            Button("Save", action: save)
                .disabled(checking || (key.isEmpty && provider.keyRequired))
            if replacing {
                Button("Cancel") { replacing = false; key = "" }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if checking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(provider.shortName)…").foregroundStyle(.secondary)
            }
            .font(.caption)
        } else if let result {
            HStack(spacing: 6) {
                Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.ok ? .green : .orange)
                Spacer()
                Button("Check again", action: check)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    /// The model: a menu when the list is short; when it's long (OpenRouter's hundreds), the chosen
    /// one with a filterable list to change it, laid out in the page rather than scrolling inside it.
    @ViewBuilder private var modelPicker: some View {
        let chosen = s.cloudModel(for: provider)
        if models.count <= 20 {
            Picker(selection: Binding(get: { chosen }, set: { s.cloudModels[provider.rawValue] = $0; AssistantStore.shared.refreshStatus() })) {
                if !models.contains(where: { $0.id == chosen }) { Text(chosen.isEmpty ? "Choose…" : chosen).tag(chosen) }
                ForEach(models) { model in Text(model.name ?? model.id).tag(model.id) }
            } label: {
                RowLabel(title: "Model", subtitle: models.first { $0.id == chosen }.flatMap { $0.name == nil ? nil : $0.id })
            }
        } else {
            LabeledContent {
                Button(browsing ? "Done" : "Change…") { browsing.toggle(); filter = "" }
            } label: {
                RowLabel(title: "Model", subtitle: models.first { $0.id == chosen }.map { ($0.name ?? $0.id) + ($0.name == nil ? "" : " · \($0.id)") } ?? chosen)
            }
            if browsing { modelBrowser(chosen: chosen) }
        }
    }

    private func modelBrowser(chosen: String) -> some View {
        let matches = filter.isEmpty ? models : models.filter {
            $0.id.localizedCaseInsensitiveContains(filter) || ($0.name?.localizedCaseInsensitiveContains(filter) ?? false)
        }
        let shown = matches.prefix(8)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("", text: $filter, prompt: Text("Filter \(models.count) models"))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            VStack(spacing: 1) {
                ForEach(shown) { model in
                    ModelChoiceRow(model: model, chosen: model.id == chosen) {
                        s.cloudModels[provider.rawValue] = model.id
                        AssistantStore.shared.refreshStatus()
                        browsing = false
                    }
                }
            }
            if matches.count > shown.count {
                Text("\(matches.count - shown.count) more · type to narrow it down").font(.caption).foregroundStyle(.secondary)
            } else if matches.isEmpty {
                Text("No models match “\(filter)”").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var keySubtitle: String? {
        guard let url = provider.keyURL else { return "Kept in your Mac's Keychain." }
        return "Get one at \(url.host() ?? url.absoluteString). Kept in your Mac's Keychain."
    }

    private var serverSubtitle: String? {
        switch provider {
        case .custom: "LM Studio, vLLM, Together, Mistral, xAI… anything that speaks the OpenAI chat API."
        case .customAnthropic: "Kimi, MiniMax, Qwen… anything that speaks Anthropic's Messages API."
        case .zai: "For the GLM Coding Plan, keep this address and use that plan's key."
        default: nil
        }
    }

    private var modelBinding: Binding<String> {
        Binding(get: { s.cloudModel(for: provider) }, set: { s.cloudModels[provider.rawValue] = $0; AssistantStore.shared.refreshStatus() })
    }

    private func load() {
        key = ""
        filter = ""
        replacing = false
        browsing = false
        hasKey = APIKeys.get(provider) != nil
        models = []
        result = nil
        if hasKey || !provider.keyRequired { check() }
    }

    private func save() {
        if !key.isEmpty {
            APIKeys.set(key, for: provider)
            key = ""
            hasKey = true
            replacing = false
        }
        check()
    }

    private func check() {
        guard let url = URL(string: s.cloudBaseURL(for: provider)) else { return }
        let config = CloudLLM.Config(provider: provider, key: APIKeys.get(provider), model: s.cloudModel(for: provider), baseURL: url)
        checking = true
        result = nil
        Task {
            do {
                let list = try await CloudLLM.models(config)
                models = list
                // Nothing chosen yet (or a name this key can't use): the first one listed.
                let chosen = s.cloudModel(for: provider)
                if chosen.isEmpty || !list.contains(where: { $0.id == chosen }), let first = list.first {
                    s.cloudModels[provider.rawValue] = provider.suggestedModel.isEmpty || !list.contains(where: { $0.id == provider.suggestedModel })
                        ? first.id : provider.suggestedModel
                }
                result = (true, "Connected to \(provider.shortName) · \(list.count) model\(list.count == 1 ? "" : "s") available")
            } catch {
                models = []
                result = (false, error.localizedDescription)
            }
            checking = false
            AssistantStore.shared.refreshStatus()
        }
    }
}

/// Claude Code or Codex, signed in with the person's own plan: whether the CLI is there and signed
/// in, a button to sign in (in Terminal, through the CLI's own login), and the model to use.
struct CLIProviderSettings: View {
    let tool: CLIAgent.Tool
    let provider: AIProvider
    @EnvironmentObject private var s: AppSettings
    @State private var availability: CLIAgent.Availability?
    @State private var path: String?
    @State private var checking = false

    var body: some View {
        Group {
            LabeledContent {
                HStack(spacing: 8) {
                    statusLabel
                    actionButton
                }
            } label: {
                RowLabel(title: tool.name, subtitle: path.map { "Found at \($0)" } ?? "Uses the \(tool.command) command you already have.")
            }
            if tool.suggestedModels.isEmpty {
                TextField(text: modelBinding, prompt: Text("Codex's default")) {
                    RowLabel(title: "Model", subtitle: "Any model your plan offers in Codex (its /model list). Leave empty for Codex's default.")
                }
            } else {
                Picker(selection: modelBinding) {
                    let chosen = s.cloudModel(for: provider)
                    if !tool.suggestedModels.contains(where: { $0.id == chosen }) { Text(chosen).tag(chosen) }
                    ForEach(tool.suggestedModels) { Text($0.title).tag($0.id) }
                } label: {
                    RowLabel(title: "Model", subtitle: "Bigger models use more of your plan's limits and answer more slowly.")
                }
            }
            TextField(text: Binding(get: { s.cliPaths[provider.rawValue] ?? "" },
                                    set: { s.cliPaths[provider.rawValue] = $0 }),
                      prompt: Text("Found automatically")) {
                RowLabel(title: "Location", subtitle: "Only if \(tool.command) is somewhere unusual. Press Return to check it.")
            }
            .onSubmit { check(rescan: true) }
        }
        .onAppear { check() }
        .onChange(of: provider) { _, _ in check() }
        // A sign-in or update finished in Terminal (NotchApp watches for it), or the person came
        // back to NotchApp from somewhere else: show where things stand without a button press.
        .onReceive(NotificationCenter.default.publisher(for: CLIAgent.availabilityChanged)) { note in
            guard note.userInfo?["tool"] as? String == tool.rawValue, !checking else { return }
            Task { availability = await CLIAgent.availability(tool) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
    }

    @ViewBuilder private var statusLabel: some View {
        if checking || availability == nil {
            ProgressView().controlSize(.small)
        } else {
            switch availability {
            case .ready?: Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .signedOut?: Label("Not signed in", systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
            case .outdated?: Label("Needs an update", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange)
            case .checkFailed?: Label("Couldn't check", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            default: Label("Not installed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch availability {
        case .signedOut?:
            Button("Sign in…") { CLIAgent.openSignIn(tool) }
                .help("Opens Terminal on \(tool.command)'s own sign-in. This updates by itself when it's done.")
            Button("Check again") { check(rescan: true) }
        case .notInstalled?:
            Link("Install…", destination: tool.installURL)
            Button("Check again") { check(rescan: true) }
        case .outdated?:
            Button("Update…") { CLIAgent.openUpdate(tool) }
                .help("This version of \(tool.command) is too old for NotchApp. "
                      + (tool.updateArguments == nil ? "Opens the page that explains updating it." : "Opens Terminal on \(tool.command)'s own update."))
            Button("Check again") { check(rescan: true) }
        case .checkFailed?:
            Button("Check again") { check(rescan: true) }
                .help("\(tool.command) didn't answer the status check. Questions still go to it, so any real problem shows up there.")
        case .ready?:
            Button("Check again") { check(rescan: true) }.buttonStyle(.borderless).foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private var modelBinding: Binding<String> {
        Binding(get: { s.cloudModel(for: provider) }, set: { s.cloudModels[provider.rawValue] = $0 })
    }

    /// `rescan` also looks for the CLI again and re-reads the Terminal setup: for the buttons,
    /// where someone may just have installed it or changed their shell profile.
    private func check(rescan: Bool = false) {
        checking = true
        Task {
            let result = await CLIAgent.availability(tool, refresh: true, rescan: rescan)
            path = await CLIAgent.executablePath(tool)
            availability = result
            checking = false
            AssistantStore.shared.refreshStatus()
        }
    }
}

/// One model in the long list: its name and id, ticked when chosen, lit on hover.
private struct ModelChoiceRow: View {
    let model: CloudLLM.ModelInfo
    let chosen: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name ?? model.id).font(.system(size: 12.5, weight: chosen ? .semibold : .regular))
                    if model.name != nil {
                        Text(model.id).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if chosen { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(chosen ? Color.accentColor.opacity(0.16) : hovering ? Color.primary.opacity(0.06) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
