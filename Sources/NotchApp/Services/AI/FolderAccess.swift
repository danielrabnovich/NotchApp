import AppKit

/// Spotlight silently leaves out Desktop, Documents, Downloads and iCloud Drive until the app
/// has been allowed into them, and searching alone never triggers the macOS prompt. Opening each
/// folder once does, so the first file search asks for access instead of quietly finding nothing.
@MainActor
final class FolderAccess: ObservableObject {
    static let shared = FolderAccess()

    struct Folder: Identifiable, Equatable {
        let name: String
        let path: String
        var id: String { path }
    }

    /// nil until checked; then whether each folder could be read.
    @Published private(set) var access: [String: Bool] = [:]
    private var checked = false

    let folders: [Folder] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var list = [Folder(name: "Desktop", path: "\(home)/Desktop"),
                    Folder(name: "Documents", path: "\(home)/Documents"),
                    Folder(name: "Downloads", path: "\(home)/Downloads")]
        let iCloud = "\(home)/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: iCloud) { list.append(Folder(name: "iCloud Drive", path: iCloud)) }
        // Nextcloud, Dropbox, Google Drive, OneDrive…: Spotlight also leaves these out of an app's
        // results until the app has opened them once.
        let cloud = "\(home)/Library/CloudStorage"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: cloud))?.sorted() ?? [] where !name.hasPrefix(".") {
            // "Nextcloud-nextcloud.example.com-Phil" → "Nextcloud"
            list.append(Folder(name: String(name.split(separator: "-").first ?? Substring(name)), path: "\(cloud)/\(name)"))
        }
        return list
    }()

    var missing: [Folder] { folders.filter { access[$0.path] == false } }

    /// macOS has asked about these folders before, so reading them won't put up a prompt.
    var decided: Bool { UserDefaults.standard.bool(forKey: "folderAccessAsked") }

    /// Asks once per launch (macOS only shows each prompt the first time).
    func ensure() async {
        guard !checked else { return }
        checked = true
        await recheck()
    }

    func recheck() async {
        let paths = folders.map(\.path)
        // Reading blocks while the prompt is up, so do it off the main thread.
        let result = await Task.detached(priority: .userInitiated) { () -> [String: Bool] in
            var out: [String: Bool] = [:]
            for p in paths { out[p] = (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil }
            return out
        }.value
        access = result
        UserDefaults.standard.set(true, forKey: "folderAccessAsked")
    }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }
}
