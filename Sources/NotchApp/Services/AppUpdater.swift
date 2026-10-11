import AppKit

/// Keeps NotchApp itself up to date from the GitHub repo's releases: checks the latest one (daily,
/// and from Settings → About), offers it in the notch, then downloads its zip, checks it's
/// NotchApp and properly signed, swaps it in and relaunches. The repo is private, so requests use
/// the GitHub CLI's login when there is one, else a token saved in the Keychain.
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
        // A while after launch, then daily; the notch says so only for a version not yet offered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.check(quietly: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { AppUpdater.shared.check(quietly: true) }
        }
    }

    // MARK: - Token

    /// The GitHub CLI's login, else the saved token.
    nonisolated static func token() -> String? {
        if let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let out = Shell.runSync(gh, ["auth", "token"], timeout: 5)
            let t = out.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.ok, !t.isEmpty { return t }
        }
        return KeychainItem.get("github-token")
    }

    nonisolated static var hasGitHubCLI: Bool {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].contains { FileManager.default.isExecutableFile(atPath: $0) }
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
        if let token = await Task.detached(operation: { token() }).value {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// The newest published release with a NotchApp zip, or nil when there's none yet.
    private static func latest() async throws -> Release? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, response) = try await URLSession.shared.data(for: try await request(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            // A private repo answers 404 without access, the same as with no releases.
            if token() == nil { throw Failure(message: "The repo is private: sign in with the GitHub CLI (gh auth login), or add a token below.") }
            return nil
        }
        if status == 401 || status == 403 { throw Failure(message: "GitHub turned the token down (\(status)). Check it can read \(repo).") }
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
        let (file, response) = try await URLSession.shared.download(for: try await request(url, accept: "application/octet-stream"),
                                                                     delegate: DropAuthOnRedirect())
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

/// GitHub hands asset downloads to a storage host that rejects (and mustn't see) the GitHub token.
private final class DropAuthOnRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var next = request
        if request.url?.host != task.originalRequest?.url?.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        return next
    }
}

/// A generic password in the Keychain, for secrets that aren't model keys (a GitHub token).
enum KeychainItem {
    private static let service = "com.notchapp.NotchApp"

    nonisolated static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
