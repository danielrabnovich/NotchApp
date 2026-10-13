import AppKit
import SwiftUI

struct TaskItem: Identifiable, Codable, Equatable {
    enum LinkKind: String, Codable { case file, web, email }

    var id = UUID()
    var title: String
    var note: String?
    var link: URL?
    var linkKind: LinkKind?
    var createdAt = Date()
    var completedAt: Date?
    var due: Date?
    /// When a "due soon" nudge was last shown, so we don't repeat it.
    var nudgedAt: Date?

    var isDone: Bool { completedAt != nil }
    var isOverdue: Bool { !isDone && (due.map { $0 < Date() } ?? false) }

    var linkIcon: String? {
        switch linkKind {
        case .file: "doc.fill"
        case .web: "link"
        case .email: "envelope.fill"
        case nil: nil
        }
    }
}

/// What a drag would turn into, shown live on the "Add to Tasks" bin.
struct DragPreview: Equatable {
    var taskTitle: String?
    var hasFiles: Bool
    var icon: String
    /// A web link being dragged (for the video download bin).
    var webLink: URL?
    /// The files being dragged (for the one-drop conversions).
    var files: [URL] = []
}

/// Today's tasks. Persisted as JSON in Application Support.
@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    @Published private(set) var tasks: [TaskItem] = []
    /// The most recently added task, briefly highlighted in the list.
    @Published var justAddedID: UUID?

    /// Open tasks: dated ones first (soonest due on top), then the rest in the order added.
    var open: [TaskItem] {
        let open = tasks.filter { !$0.isDone }
        let dated = open.filter { $0.due != nil }.sorted { $0.due! < $1.due! }
        return dated + open.filter { $0.due == nil }
    }
    var doneToday: [TaskItem] {
        tasks.filter { $0.isDone }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    var openCount: Int { tasks.lazy.filter { !$0.isDone }.count }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }

    func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([TaskItem].self, from: data) {
            tasks = decoded
        }
        pruneOldCompleted()
        // Clear yesterday's finished tasks shortly after midnight.
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TaskStore.shared.pruneOldCompleted() }
        }
    }

    // MARK: - Mutations

    func add(_ task: TaskItem) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            tasks.insert(task, at: tasks.firstIndex(where: \.isDone) ?? tasks.endIndex)
            justAddedID = task.id
        }
        save()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            withAnimation(.easeOut(duration: 0.5)) {
                if self?.justAddedID == task.id { self?.justAddedID = nil }
            }
        }
    }

    func add(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let (clean, due) = DueDateParser.extract(from: trimmed)
        add(TaskItem(title: clean, due: due))
    }

    func setDue(_ id: UUID, _ due: Date?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            tasks[i].due = due
            tasks[i].nudgedAt = nil
        }
        save()
    }

    func markNudged(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].nudgedAt = Date()
        save()
    }

    func setDone(_ id: UUID, _ done: Bool) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].completedAt = done ? Date() : nil
        save()
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].title = trimmed
        save()
    }

    func delete(_ id: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            tasks.removeAll { $0.id == id }
        }
        save()
    }

    func clearCompleted() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            tasks.removeAll(where: \.isDone)
        }
        save()
    }

    func openLink(of task: TaskItem) {
        guard let link = task.link else { return }
        NSWorkspace.shared.open(link)
    }

    private func pruneOldCompleted() {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let before = tasks.count
        tasks.removeAll { ($0.completedAt ?? .distantFuture) < startOfDay }
        if tasks.count != before { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Turning drags into tasks

    /// Builds tasks from whatever is being dropped: text, links, emails or files.
    static func tasks(from pb: NSPasteboard) -> [TaskItem] {
        // Files → one task each, linked to the file.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map {
                TaskItem(title: $0.deletingPathExtension().lastPathComponent, link: $0, linkKind: .file)
            }
        }

        // Emails dragged from Mail → subject, linked back to the message.
        if let subject = mailSubject(in: pb) {
            let link = webURL(in: pb).flatMap { $0.scheme == "message" ? $0 : nil }
            return [TaskItem(title: subject, link: link, linkKind: link == nil ? nil : .email)]
        }

        // Links → page title when the browser provides one.
        if let url = webURL(in: pb) {
            let name = pb.string(forType: NSPasteboard.PasteboardType("public.url-name"))
            let text = pb.string(forType: .string)
            let title = [name, text].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0 != url.absoluteString }
                ?? url.host(percentEncoded: false) ?? url.absoluteString
            let kind: TaskItem.LinkKind = url.scheme == "message" ? .email : .web
            return [TaskItem(title: title, link: url, linkKind: kind)]
        }

        // Plain text → first line is the title, the rest becomes a note.
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            var title = lines.first { !$0.isEmpty } ?? text
            let (clean, due) = DueDateParser.extract(from: title)
            title = clean
            if title.count > 140 { title = String(title.prefix(137)) + "…" }
            return [TaskItem(title: title, note: lines.count > 1 ? text : nil, due: due)]
        }
        return []
    }

    static func preview(of pb: NSPasteboard) -> DragPreview {
        let hasFiles = pb.types?.contains(.fileURL) == true
        let first = tasks(from: pb).first
        let icon: String
        switch first?.linkKind {
        case .file: icon = "doc.fill"
        case .web: icon = "link"
        case .email: icon = "envelope.fill"
        case nil: icon = "text.alignleft"
        }
        let files = hasFiles ? pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [] : []
        return DragPreview(taskTitle: first?.title, hasFiles: hasFiles, icon: icon,
                           webLink: hasFiles ? nil : webURL(in: pb).flatMap { VideoDownloader.webURL($0.absoluteString) }, files: files)
    }

    static func webURL(in pb: NSPasteboard) -> URL? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first(where: { !$0.isFileURL }) {
            return url
        }
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.contains(" "), !s.contains("\n"),
           let url = URL(string: s), let scheme = url.scheme, ["http", "https", "message"].contains(scheme) {
            return url
        }
        return nil
    }

    /// Mail puts message metadata on the pasteboard as property lists; look for a subject.
    private static func mailSubject(in pb: NSPasteboard) -> String? {
        for type in pb.types ?? [] where type.rawValue.lowercased().contains("mail") {
            if let plist = pb.propertyList(forType: type), let subject = findSubject(in: plist) {
                return subject
            }
        }
        return nil
    }

    private static func findSubject(in object: Any) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict where key.lowercased() == "subject" {
                if let s = value as? String, !s.isEmpty { return s }
            }
            for value in dict.values { if let s = findSubject(in: value) { return s } }
        } else if let array = object as? [Any] {
            for value in array { if let s = findSubject(in: value) { return s } }
        }
        return nil
    }
}
