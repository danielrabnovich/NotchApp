import AppKit

/// Keeps NotchApp itself up to date from the GitHub repo's releases: checks the latest one (daily,
/// and from Settings → About), offers it in the notch, then downloads its zip, checks it's
/// NotchApp and properly signed, swaps it in and relaunches. The repo is public, so nothing signs in.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    static let repo = (Bundle.main.object(forInfoDictionaryKey: "NotchAppReleasesRepo") as? String) ?? "danielrabnovich/NotchApp"

    struct Release: Equatable {
        let version: String
        let notes: String
        let assetID: Int
        let assetName: String
        let page: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    private var timer: Timer?

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        Self.forgetSavedToken()
        // A while after launch, then daily; the notch says so only for a version not yet offered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.check(quietly: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { AppUpdater.shared.check(quietly: true) }
        }
    }

    /// Builds from when the repo was private kept a GitHub token in the Keychain; it isn't needed
    /// any more, so it doesn't stay behind.
    private static func forgetSavedToken() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.notchapp.NotchApp",
                                    kSecAttrAccount as String: "github-token"]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Checking

    func check(quietly: Bool = false) {
        guard state != .checking, !isInstalling else { return }
        if !quietly { state = .checking }
        Task {
            do {
                let release = try await Self.latest()
                lastChecked = Date()
                guard let release, Self.isNewer(release.version, than: Self.currentVersion) else {
                    if !quietly { state = .upToDate }
                    return
                }
                state = .available(release)
                let offered = UserDefaults.standard.string(forKey: "updateOffered")
                if !quietly || offered != release.version {
                    UserDefaults.standard.set(release.version, forKey: "updateOffered")
                    NotchPresenter.shared.offer(Prompt(icon: "arrow.down.app.fill", tint: .systemBlue,
                                                       title: "NotchApp \(release.version) is ready",
                                                       detail: release.notes.split(separator: "\n").first.map(String.init) ?? "Install it now; NotchApp restarts by itself.",
                                                       actions: [.init(title: "Install & Restart", primary: true) { AppUpdater.shared.install() },
                                                                 .init(title: "Later") {}]),
                                                peek: quietly)
                }
            } catch {
                if !quietly { state = .failed(error.localizedDescription) }
            }
        }
    }

    private var isInstalling: Bool { if case .installing = state { true } else { false } }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func request(_ url: URL, accept: String = "application/vnd.github+json") async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("NotchApp/\(await MainActor.run { currentVersion })", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The newest published release with a NotchApp zip, or nil when there's none yet.
    private static func latest() async throws -> Release? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, response) = try await URLSession.shared.data(for: try await request(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // No release published yet.
        if status == 404 { return nil }
        // Without signing in, GitHub allows 60 requests an hour from one address.
        if status == 403 || status == 429 { throw Failure(message: "GitHub is busy right now. Try again in a little while.") }
        guard status == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "GitHub didn't answer (\(status)).")
        }
        let tag = (obj["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let assets = obj["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String ?? "").hasSuffix(".zip") }),
              let id = zip["id"] as? Int else { return nil }
        return Release(version: tag, notes: obj["body"] as? String ?? "", assetID: id, assetName: zip["name"] as? String ?? "NotchApp.zip",
                       page: (obj["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// "1.10.0" is newer than "1.9.2".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    func install() {
        guard case .available(let release) = state else { return }
        state = .installing("Downloading \(release.version)…")
        Task {
            do {
                let app = try await Self.download(release)
                state = .installing("Checking it…")
                try await Self.verify(app)
                state = .installing("Restarting…")
                try Self.swap(in: app)
            } catch {
                state = .failed(error.localizedDescription)
                ActivityCenter.shared.show(.notice(title: "Update didn't install", detail: error.localizedDescription,
                                                   icon: "exclamationmark.triangle.fill", tone: .warning), for: 5)
            }
        }
    }

    /// The release's zip, unpacked; returns the NotchApp.app inside.
    private static func download(_ release: Release) async throws -> URL {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/assets/\(release.assetID)")!
        let (file, response) = try await URLSession.shared.download(for: try await request(url, accept: "application/octet-stream"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "The download didn't come through.") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("NotchAppUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent(release.assetName)
        try FileManager.default.moveItem(at: file, to: zip)
        let unzip = await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path], timeout: 120)
        guard unzip.ok, let app = (try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))
            .first(where: { $0.pathExtension == "app" }) else { throw Failure(message: "The download wasn't an app.") }
        return app
    }

    /// The same app (bundle ID), newer, and signed by the same developer as the running copy.
    private static func verify(_ app: URL) async throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw Failure(message: "The download isn't NotchApp.")
        }
        guard await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 60).ok else {
            throw Failure(message: "The download's signature doesn't check out.")
        }
        func team(_ path: String) async -> String? {
            let out = await Shell.run("/bin/sh", ["-c", "/usr/bin/codesign -dv \"\(path)\" 2>&1 | grep TeamIdentifier"], timeout: 30).out
            return out.split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let mine = await team(Bundle.main.bundlePath), theirs = await team(app.path)
        guard mine == theirs else { throw Failure(message: "The download is signed by someone else.") }
    }

    /// The old copy goes to the Trash, the new one takes its place, and it starts once this one has quit.
    private static func swap(in app: URL) throws {
        let current = Bundle.main.bundleURL
        var trashed: NSURL?
        try FileManager.default.trashItem(at: current, resultingItemURL: &trashed)
        do {
            try FileManager.default.moveItem(at: app, to: current)
        } catch {
            if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: current) }
            throw error
        }
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"\(current.path)\""]
        try relaunch.run()
        NSApp.terminate(nil)
    }
}
