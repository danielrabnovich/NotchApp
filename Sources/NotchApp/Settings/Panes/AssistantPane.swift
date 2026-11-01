import SwiftUI

/// The optional MobileCLIP download: describe a picture in your own words.
private struct VisualSearchRow: View {
    @ObservedObject private var visual = VisualSearch.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Understand descriptions")
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .downloading(let fraction) = visual.state {
                    ProgressView(value: fraction).controlSize(.small)
                }
            }
            Spacer()
            switch visual.state {
            case .notInstalled, .failed:
                Button("Download") { visual.install() }
            case .downloading:
                Button("Cancel") { visual.cancel() }
            case .preparing:
                ProgressView().controlSize(.small)
            case .ready:
                Button("Remove") { visual.remove() }
            }
        }
    }

    private var subtitle: String {
        switch visual.state {
        case .notInstalled:
            return "Describe a picture in your own words: “lighthouse at dusk”, “whiteboard with a diagram”. Downloads Apple's MobileCLIP (110 MB); it runs on this Mac."
        case .downloading(let fraction):
            return "Downloading MobileCLIP… \(Int(fraction * 100))%"
        case .preparing:
            return "Getting MobileCLIP ready…"
        case .ready:
            return "Pictures are matched against what you describe, on this Mac."
        case .failed(let message):
            return "Download failed: \(message)"
        }
    }
}

struct AssistantPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var assistant = AssistantStore.shared
    @ObservedObject private var folders = FolderAccess.shared
    @ObservedObject private var images = ImageIndex.shared
    @ObservedObject private var recall = Recall.shared
    @State private var customModel = ""

    private var folderState: PermissionRow.State {
        if folders.access.isEmpty { return .unknown }
        return folders.missing.isEmpty ? .granted : .denied
    }

    private var folderSubtitle: String {
        if folders.missing.isEmpty {
            return folders.access.isEmpty ? "So file search can see the files you keep there." : "File search can see these folders."
        }
        return "Can't see \(folders.missing.map(\.name).joined(separator: ", ")). Turn it on under Files & Folders."
    }

    /// What Recall does, and (once on) how much it holds.
    private var recallSubtitle: String {
        let what = "Search for things you saw (“that error in Terminal yesterday”). Windows are read into text on this Mac and never leave it. Skips password managers, private windows and a locked or shared screen."
        guard s.recall else { return what }
        let held = recall.count > 0 ? "\(recall.count.formatted()) moments, \(ByteCountFormatter.string(fromByteCount: recall.bytes, countStyle: .file))." : "Nothing saved yet."
        return recall.paused ? "Paused from Search (“resume recall” turns it back on). \(held)" : "\(what) \(held)"
    }

    /// What the picture index is up to, under its toggle.
    private var imageSubtitle: String {
        let what = "Find photos and screenshots by what's in them, or the text they contain. Your Mac's built-in Vision looks at each one, on this Mac."
        guard s.imageIndexing else { return what }
        if images.isIndexing { return "Looking at your pictures in the background. Search finds the ones done so far." }
        return images.indexed > 0 ? "\(what) \(images.indexed.formatted()) pictures so far." : what
    }

    var body: some View {
        SettingsPage(pane: .assistant) {
            Section {
                ToggleRow("Notify when a search finishes", subtitle: "A macOS notification if the notch is closed.",
                          isOn: $s.systemNotifications)
            } footer: {
                FooterText(intelligenceFooter)
            }
            Section {
                Picker(selection: $s.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                } label: {
                    RowLabel(title: "Model", subtitle: "On this Mac stays private and free; Claude Code or Codex uses the plan you already pay for; a cloud model with your own key is smarter and faster.")
                }
                if s.aiProvider == .apple {
                    LabeledContent("Status") { statusLabel }
                } else if let tool = s.aiProvider.cliTool {
                    CLIProviderSettings(tool: tool, provider: s.aiProvider)
                } else if s.aiProvider.isCloud {
                    CloudProviderSettings(provider: s.aiProvider)
                }
            } header: {
                Text("Intelligence")
            }
            AICommandsEditor()
            Section("Files & folders") {
                PermissionRow(title: "Desktop, Documents, Downloads & cloud folders",
                              subtitle: folderSubtitle,
                              state: folderState,
                              request: { Task { await folders.recheck() } },
                              openSettings: { FolderAccess.openPrivacySettings() })
                ToggleRow("Search inside pictures", subtitle: imageSubtitle, isOn: $s.imageIndexing)
                ToggleRow("Search the text in screenshots", subtitle: "Screenshots are read on this Mac (newest first) so Search finds them by what they say.",
                          isOn: $s.screenshotSearch)
                if s.imageIndexing, images.isIndexing {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: images.fraction)
                        Text("\(images.passDone.formatted()) of \(images.passTotal.formatted()) pictures\(images.timeLeft.map { " · \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if s.imageIndexing { VisualSearchRow() }
            }
            if s.aiProvider == .local, assistant.pullingModel != nil || assistant.pullError != nil || assistant.justPulled != nil {
                Section { DownloadActivity() }
            }
            if s.aiProvider == .local {
            Section("Ollama") {
                LabeledContent("Status") {
                    if let pulling = assistant.pullingModel {
                        Label("Downloading \(OllamaModelCatalog.displayName(pulling))…", systemImage: "arrow.down.circle")
                            .foregroundStyle(.blue)
                    } else {
                        statusLabel
                    }
                }
                Picker("Model", selection: Binding(get: { s.ollamaModel }, set: { assistant.use($0) })) {
                    ForEach(pickerModels, id: \.self) { name in
                        Text(assistant.isInstalled(name) ? OllamaModelCatalog.displayName(name)
                                                         : "\(OllamaModelCatalog.displayName(name)) (not downloaded)").tag(name)
                    }
                }
                TextField("Server", text: $s.ollamaURL)
            }
            Section {
                ForEach(OllamaModelCatalog.recommended) { entry in
                    ModelRow(name: entry.name, title: entry.title, detail: entry.blurb, size: entry.size)
                }
                ForEach(otherInstalled) { model in
                    ModelRow(name: model.name, title: model.name, detail: "Installed",
                             size: ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Other model", text: $customModel, prompt: Text("Any name from ollama.com/library, e.g. deepseek-r1:8b"))
                            .onSubmit(downloadCustom)
                        Button("Download", action: downloadCustom)
                            .disabled(!customIsValid || assistant.pullingModel != nil)
                    }
                    if !cleanedCustom.isEmpty && !customIsValid {
                        Text("Model names look like qwen3.5:9b (letters, numbers, . - _ and one :tag).")
                            .font(.caption).foregroundStyle(.orange)
                    } else if assistant.isInstalled(cleanedCustom) && !cleanedCustom.isEmpty {
                        Text("\(cleanedCustom) is already downloaded.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Download a model")
            } footer: {
                HStack {
                    Text(diskUsage)
                    Spacer()
                    Link("Browse the Ollama library", destination: URL(string: "https://ollama.com/library")!)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            }
            Section {
                ToggleRow("Answer questions about your screen",
                          subtitle: "“What’s the answer to this question” (or Ask about this) looks at the window in front. It’s never saved.",
                          isOn: $s.screenQuestions)
                if s.screenQuestions, s.aiProvider.isCloud {
                    ToggleRow("Use \(s.aiProvider.shortName) for screen questions",
                              subtitle: s.cloudScreenQuestions
                                ? "The window you ask about (a picture and its text) is sent to \(s.aiProvider.shortName) with the question."
                                : "Screen questions stay on this Mac and use the local Ollama model.",
                              isOn: $s.cloudScreenQuestions)
                }
                if s.screenQuestions && !ScreenQuestion.hasPermission {
                    LabeledContent {
                        Button("Open Settings") { ScreenQuestion.openPrivacySettings() }
                    } label: {
                        RowLabel(title: "Screen Recording is off", subtitle: "Needed to see your screen.")
                    }
                }
                ToggleRow("Recall what you've seen", subtitle: recallSubtitle, isOn: $s.recall)
                if s.recall {
                    Picker(selection: $s.recallKeep) {
                        ForEach(Recall.Keep.allCases) { Text($0.label).tag($0) }
                    } label: {
                        RowLabel(title: "Keep for", subtitle: "Older moments are deleted. Recall never uses more than about 2 GB.")
                    }
                    .pickerStyle(.segmented)
                    if !ScreenQuestion.hasPermission {
                        LabeledContent {
                            Button("Open Settings") { ScreenQuestion.openPrivacySettings() }
                        } label: {
                            RowLabel(title: "Screen Recording is off", subtitle: "Recall keeps windows' text without it, but no pictures, and can't read apps that only draw their text.")
                        }
                    }
                }
            } header: {
                Text("Your screen")
            }
            Section("Weather") {
                TextField(text: $s.homeCity, prompt: Text("e.g. Chapel Hill, NC")) {
                    RowLabel(title: "Home city", subtitle: "Used when you don't name a place.")
                }
            }
        }
        .task { assistant.refreshStatus() }
        .onChange(of: s.ollamaURL) { _, _ in assistant.refreshStatus() }
        .onChange(of: s.aiProvider) { _, _ in assistant.refreshStatus() }
        .onChange(of: assistant.justPulled) { _, done in
            // Keep what was typed until it downloads, so a typo can be fixed and retried.
            if let done, done == cleanedCustom { customModel = "" }
        }
    }

    /// What the chosen model means for privacy and cost, under the Intelligence section.
    private var intelligenceFooter: String {
        if s.aiProvider == .apple {
            return "Apple's own model, built into macOS: search understands what you mean, picks the right file and writes answers, with nothing to install. Everything stays on your Mac except web searches. It reads text only, so screen questions read the window's text."
        }
        if s.aiProvider == .local {
            return "With a local model through Ollama, search understands what you mean, picks the right file and writes answers. Everything stays on your Mac except web searches."
        }
        if let tool = s.aiProvider.cliTool {
            return "Search, briefs, nudges and screen questions go through \(tool.name) on this Mac, signed in with your own \(tool.plan) plan, and count toward its usage limits. NotchApp never sees your login. What you search for (and, if allowed below, the window you ask about) is sent to \(tool.company)."
        }
        return "Search, briefs, nudges and screen questions use \(s.aiProvider.title) with your key. What you search for (and, if allowed below, the window you ask about) is sent to \(s.aiProvider.shortName)."
    }

    @ViewBuilder private var statusLabel: some View {
        switch assistant.status {
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notRunning: Button("Start Ollama") { assistant.startServer() }
        case .modelMissing:
            Text(assistant.installed.isEmpty ? "No model downloaded" : "Selected model isn't downloaded")
                .foregroundStyle(.orange)
        case .unknown: ProgressView().controlSize(.small)
        case .needsKey: Text("Add an API key above").foregroundStyle(.orange)
        case .appleUnavailable(let why): Text(why).foregroundStyle(.orange)
        case .cliUnavailable(let tool, let availability):
            Text(availability == .signedOut ? "Sign in to \(tool.name)"
                 : availability == .outdated ? "Update \(tool.name)" : "\(tool.name) isn't installed").foregroundStyle(.orange)
        }
    }

    private var cleanedCustom: String { OllamaClient.cleanModelName(customModel) }
    private var customIsValid: Bool { OllamaClient.isPlausibleModelName(cleanedCustom) }

    /// Installed models plus the selected one, so the picker always shows the current choice.
    private var pickerModels: [String] {
        var names = assistant.installed.map(\.name)
        if !names.contains(where: { OllamaClient.matches(installed: $0, wanted: s.ollamaModel) }) { names.append(s.ollamaModel) }
        return names.sorted()
    }

    private var otherInstalled: [OllamaClient.InstalledModel] {
        assistant.installed.filter { model in
            !OllamaModelCatalog.recommended.contains { OllamaClient.matches(installed: model.name, wanted: $0.name) }
        }
    }

    private var diskUsage: String {
        let total = assistant.installed.reduce(0) { $0 + $1.size }
        return total == 0 ? "No models downloaded" : "Models use \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }

    private func downloadCustom() {
        guard customIsValid, assistant.pullingModel == nil else { return }
        assistant.pullModel(cleanedCustom)
    }
}

/// The current download (or its result), shown at the top of the pane so it's never off-screen.
private struct DownloadActivity: View {
    @ObservedObject private var assistant = AssistantStore.shared

    var body: some View {
        if let name = assistant.pullingModel, let p = assistant.pull {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("\(p.phase == .lookingUp ? "Finding" : "Downloading") \(OllamaModelCatalog.displayName(name))").fontWeight(.medium)
                    Spacer()
                    Button("Cancel") { assistant.cancelPull() }
                }
                if p.phase == .lookingUp {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    // Full once the bytes are in, while Ollama verifies and writes the model.
                    ProgressView(value: p.phase == .downloading ? (p.fraction ?? 0) : 1)
                }
                Text(detail(name, p))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } else if let error = assistant.pullError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(assistant.failedPull.map { "Couldn't download \($0)" } ?? "Download failed").fontWeight(.medium)
                    Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let failed = assistant.failedPull {
                    Button("Try Again") { assistant.pullModel(failed) }
                }
                Button("Dismiss") { assistant.dismissPullError() }
            }
        } else if let done = assistant.justPulled {
            Label("\(OllamaModelCatalog.displayName(done)) downloaded and ready to use", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func detail(_ name: String, _ p: OllamaClient.PullProgress) -> String {
        switch p.phase {
        case .lookingUp: return "Looking up \(name) in the Ollama library…"
        case .verifying: return "Verifying the download…"
        case .finishing: return "Finishing up…"
        case .downloading:
            let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
            var parts = ["\(size(p.completed)) of \(size(p.total))", "\(Int(((p.fraction ?? 0) * 100).rounded()))%"]
            if assistant.pullSpeed > 1 {
                parts.append("\(size(Int64(assistant.pullSpeed)))/s")
                let remaining = Double(p.total - p.completed) / assistant.pullSpeed
                let f = DateComponentsFormatter()
                f.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute, .second]
                f.unitsStyle = .abbreviated
                f.maximumUnitCount = 2
                if let eta = f.string(from: remaining) { parts.append("\(eta) left") }
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// One downloadable model: download with progress, switch to it, or delete it.
private struct ModelRow: View {
    let name: String
    let title: String
    let detail: String
    let size: String
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var assistant = AssistantStore.shared
    @State private var confirmDelete = false

    var body: some View {
        let installed = assistant.isInstalled(name)
        let selected = OllamaClient.matches(installed: name, wanted: s.ollamaModel) || name == s.ollamaModel
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if name == OllamaModelCatalog.defaultModel {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.blue.opacity(0.18)))
                            .foregroundStyle(.blue)
                    }
                }
                Text("\(detail) · \(size)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if assistant.pullingModel == name {
                ProgressView(value: assistant.pullProgress ?? 0).frame(width: 90)
                Text("\(Int((assistant.pullProgress ?? 0) * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Button { assistant.cancelPull() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Cancel download")
            } else if installed {
                if selected {
                    Label("In use", systemImage: "checkmark").foregroundStyle(.green).font(.callout)
                } else {
                    Button("Use") { assistant.use(name) }
                }
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete \(title)")
            } else {
                Button("Download") { assistant.pullModel(name) }
                    .disabled(assistant.pullingModel != nil)
            }
        }
        .confirmationDialog("Delete \(title)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { assistant.deleteModel(name) }
        } message: {
            Text("This frees \(size) of disk space. You can download it again later.")
        }
    }
}
