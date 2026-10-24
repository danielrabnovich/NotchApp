import AppKit
import ApplicationServices
import Combine

/// Everything rendering, exporting, copying or downloading, in one place for a Glance: NotchApp's
/// own downloads and conversions, files other apps are writing into Downloads, Desktop or Movies
/// (Safari downloads, Finder copies, AirDrop; macOS publishes their progress), and the progress
/// bars of exporting apps (Final Cut, Compressor, HandBrake, Premiere, Media Encoder, Resolve).
@MainActor
final class ProgressCenter: ObservableObject {
    static let shared = ProgressCenter()

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        /// 0…1, or nil while it can't say.
        let fraction: Double?
        /// The app doing it, for its icon.
        let bundlePath: String?
        /// Where a click goes: the file, or the app.
        let target: URL?
        /// What the Glance says in place of the percent ("3/12" for a batch).
        var label: String? = nil
        /// More for the card that drops on hover.
        var detail: String? = nil
        /// A process in a terminal (`notch run`'s shell, an agent): a click brings its pane forward.
        var focusPID: pid_t? = nil
    }

    @Published private(set) var items: [Item] = []

    /// The one the Glance shows: furthest along of those that say how far.
    var lead: Item? { items.max { ($0.fraction ?? -1) < ($1.fraction ?? -1) } }

    private var files: [String: Item] = [:]
    private var exporting: [Item] = []
    private var subscribers: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var scanTimer: Timer?

    /// Apps whose windows have the export progress bar worth showing.
    private static let exporters: [String: String] = [
        "com.apple.FinalCut": "Final Cut Pro", "com.apple.FinalCutTrial": "Final Cut Pro", "com.apple.Compressor": "Compressor",
        "fr.handbrake.HandBrake": "HandBrake", "com.apple.iMovieApp": "iMovie", "com.apple.logic10": "Logic Pro",
        "com.blackmagic-design.DaVinciResolve": "DaVinci Resolve", "com.blackmagic-design.DaVinciResolveLite": "DaVinci Resolve",
    ]

    func start() {
        VideoDownloader.shared.$jobs.sink { _ in DispatchQueue.main.async { ProgressCenter.shared.rebuild() } }.store(in: &cancellables)
        MediaConverter.shared.$jobs.sink { _ in DispatchQueue.main.async { ProgressCenter.shared.rebuild() } }.store(in: &cancellables)
        AppSettings.shared.$progressGlance.sink { on in DispatchQueue.main.async { ProgressCenter.shared.apply(on) } }.store(in: &cancellables)
    }

    private func apply(_ on: Bool) {
        subscribers.forEach { Progress.removeSubscriber($0) }
        subscribers = []
        scanTimer?.invalidate()
        scanTimer = nil
        files = [:]
        exporting = []
        guard on else { return rebuild() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in ["Downloads", "Desktop", "Movies"] {
            let url = home.appendingPathComponent(folder)
            subscribers.append(Progress.addSubscriber(forFileURL: url) { progress in
                Task { @MainActor in ProgressCenter.shared.watch(progress) }
                return { Task { @MainActor in ProgressCenter.shared.forget(progress) } }
            })
        }
        // Exporting apps say nothing outside their windows: look, every few seconds, while one runs.
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { ProgressCenter.shared.scanExporters() }
        }
        rebuild()
    }

    // MARK: - Files other apps are writing

    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    private func watch(_ progress: Progress) {
        let key = ObjectIdentifier(progress)
        observations[key] = progress.observe(\.fractionCompleted, options: [.initial]) { progress, _ in
            Task { @MainActor in ProgressCenter.shared.update(progress) }
        }
    }

    private func update(_ progress: Progress) {
        let url = progress.fileURL ?? (progress.userInfo[.fileURLKey] as? URL)
        let name = url?.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".download", with: "") ?? "File"
        let verb = progress.kind == .file && progress.fileOperationKind == .copying ? "Copying" : "Downloading"
        files["\(ObjectIdentifier(progress).hashValue)"] = Item(id: "file:\(ObjectIdentifier(progress).hashValue)", title: "\(verb) \(name)",
                                                               fraction: progress.isIndeterminate ? nil : progress.fractionCompleted,
                                                               bundlePath: nil, target: url)
        rebuild()
    }

    private func forget(_ progress: Progress) {
        observations[ObjectIdentifier(progress)] = nil
        files["\(ObjectIdentifier(progress).hashValue)"] = nil
        rebuild()
    }

    // MARK: - From the notch command and agents

    /// Rings asked for over the command bridge, with the process they're for: gone when it is, or
    /// when nothing has updated one for half an hour.
    private var external: [String: (item: Item, owner: pid_t?, updated: Date)] = [:]
    private var pruneTimer: Timer?

    func setExternal(_ item: Item, owner: pid_t?) {
        external[item.id] = (item, owner, Date())
        if pruneTimer == nil {
            pruneTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated { ProgressCenter.shared.pruneExternal() }
            }
        }
        rebuild()
    }

    func removeExternal(_ id: String) {
        guard external.removeValue(forKey: id) != nil else { return }
        rebuild()
    }

    private func pruneExternal() {
        external = external.filter { _, entry in
            let alive = entry.owner.map { kill($0, 0) == 0 || errno != ESRCH } ?? true
            return alive && Date().timeIntervalSince(entry.updated) < 30 * 60
        }
        if external.isEmpty { pruneTimer?.invalidate(); pruneTimer = nil }
        rebuild()
    }

    // MARK: - Exporting apps

    private func scanExporters() {
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String, String?)? in
            guard let id = app.bundleIdentifier, let name = Self.exporters[id] else { return nil }
            return (app.processIdentifier, name, app.bundleURL?.path)
        }
        guard !running.isEmpty, AXIsProcessTrusted() else {
            if !exporting.isEmpty { exporting = []; rebuild() }
            return
        }
        Task.detached(priority: .utility) {
            let found = running.compactMap { pid, name, path -> Item? in
                guard let fraction = Self.progressBar(pid: pid) else { return nil }
                return Item(id: "app:\(pid)", title: "\(name) exporting", fraction: fraction, bundlePath: path,
                            target: path.map { URL(fileURLWithPath: $0) })
            }
            await MainActor.run {
                let center = ProgressCenter.shared
                if center.exporting != found { center.exporting = found; center.rebuild() }
            }
        }
    }

    /// A determinate progress bar part-way along, in any of the app's windows (bounded walk).
    private nonisolated static func progressBar(pid: pid_t) -> Double? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let windows: [AXUIElement] = AXReader.value(app, kAXWindowsAttribute) else { return nil }
        let deadline = Date().addingTimeInterval(0.3)
        for window in windows {
            var queue = [(window, 0)], head = 0
            while head < queue.count, head < 600, Date() < deadline {
                let (element, depth) = queue[head]
                head += 1
                let role: String = AXReader.value(element, kAXRoleAttribute) ?? ""
                if role == "AXProgressIndicator",
                   let value: Double = (AXReader.value(element, kAXValueAttribute) as NSNumber?)?.doubleValue,
                   let max: Double = (AXReader.value(element, kAXMaxValueAttribute) as NSNumber?)?.doubleValue, max > 0 {
                    let min = (AXReader.value(element, kAXMinValueAttribute) as NSNumber?)?.doubleValue ?? 0
                    let f = (value - min) / (max - min)
                    if f > 0.001 && f < 0.999 { return f }
                }
                guard depth < 14, let children: [AXUIElement] = AXReader.value(element, kAXChildrenAttribute) else { continue }
                queue += children.map { ($0, depth + 1) }
            }
        }
        return nil
    }

    // MARK: -

    private func rebuild() {
        var all: [Item] = []
        if AppSettings.shared.progressGlance {
            for job in VideoDownloader.shared.jobs where job.isActive {
                all.append(Item(id: "video:\(job.id)", title: "Downloading \(job.displayTitle)", fraction: job.progress > 0 ? job.progress : nil,
                                bundlePath: nil, target: nil))
            }
            if let conversions = conversionItem() { all.append(conversions) }
            all += files.values.sorted { $0.id < $1.id }
            all += exporting
        }
        // Asked for by name, so shown whatever the setting (which is about watching other apps).
        all += external.values.map(\.item).sorted { $0.id < $1.id }
        if all != items { items = all }
    }

    /// Every conversion as one: a single file by name and percent, more as how many are done, the
    /// ring filling across all of them (the ones running count part-way).
    private func conversionItem() -> Item? {
        let batches = MediaConverter.shared.activeBatches
        guard !batches.isEmpty else { return nil }
        let jobs = batches.flatMap(\.jobs)
        let running = jobs.filter { $0.state == .running }
        let ops = Set(batches.map(\.operation))
        let verb = ops.count == 1 ? ops.first!.title : "Converting"
        if jobs.count == 1, let job = jobs.first {
            return Item(id: "convert", title: "\(verb): \(job.source.lastPathComponent)", fraction: job.progress, bundlePath: nil, target: job.source)
        }
        let done = jobs.filter { !$0.isActive }.count, waiting = jobs.filter { $0.state == .queued }.count
        let fraction = jobs.reduce(0.0) { $0 + ($1.isActive ? ($1.progress ?? 0) : 1) } / Double(jobs.count)
        let now = running.map { job in job.source.lastPathComponent + (job.progress.map { " \(Int(($0 * 100).rounded()))%" } ?? "") }
        let detail = ((now.isEmpty ? [] : ["Now " + now.joined(separator: ", ")]) + (waiting > 0 ? ["\(waiting) waiting"] : [])).joined(separator: " · ")
        return Item(id: "convert", title: "\(verb) · \(done) of \(jobs.count) done", fraction: fraction, bundlePath: nil,
                    target: running.first?.source ?? jobs.first?.source, label: jobs.count < 100 ? "\(done)/\(jobs.count)" : nil, detail: detail)
    }

    /// What the hover card says: the lead (with its percent, unless its label says more) and its
    /// detail, then whatever else is running.
    var peek: (title: String, detail: String) {
        guard let lead else { return ("Nothing in progress", "") }
        let percent = lead.fraction.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
        let others = items.filter { $0.id != lead.id }.map(\.title)
        let detail = [lead.detail, others.isEmpty ? nil : "Also " + others.joined(separator: ", ")].compactMap { $0?.nilIfEmpty }
        return (lead.title + percent, detail.joined(separator: " · "))
    }

    /// Clicking the Glance: the file or app it's for, else the Downloads list.
    func open() {
        if let pid = lead?.focusPID, AgentMonitor.shared.focus(pid: pid) { return }
        if let target = lead?.target {
            if target.pathExtension == "app" { NSWorkspace.shared.open(target) } else { NSWorkspace.shared.activateFileViewerSelecting([target]) }
        } else {
            UserDefaults.standard.set(ShelfPane.downloads.rawValue, forKey: "shelf.pane")
            NotchPresenter.shared.primary?.open(tab: .shelf, takeKeyboard: false, reason: .click)
        }
    }
}
