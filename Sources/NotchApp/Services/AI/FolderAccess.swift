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
        return list
    }()

    var missing: [Folder] { folders.filter { access[$0.path] == false } }

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
    }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }
}
