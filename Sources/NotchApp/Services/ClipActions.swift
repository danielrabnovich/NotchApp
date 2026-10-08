import AppKit

/// Things to do with a copied item beyond pasting it, picked from what it is: a date becomes an
/// event, a list becomes tasks, an address opens in Maps, an image's text can be copied, and so on.
/// Most relevant first; the clipboard card offers the first one on hover and the rest on right-click.
struct ClipAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    /// Does it, and says what happened (shown on the card), or nil to say nothing.
    let run: @MainActor () -> String?
}

@MainActor
enum ClipActions {
    static func suggestions(for clip: ClipboardHistory.Clip) -> [ClipAction] {
        switch clip.kind {
        case .text: text((clip.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        case .link: link(clip.text ?? "")
        case .image: image(clip)
        case .files: files(clip.filePaths ?? [])
        }
    }

    // MARK: Text

    private static func text(_ t: String) -> [ClipAction] {
        guard !t.isEmpty else { return [] }
        let s = AppSettings.shared
        var out: [ClipAction] = []
        let lines = listItems(t)
        let singleLine = !t.contains("\n")

        // A date in a short line: probably something to put on the calendar.
        if s.calendarEnabled, singleLine, t.count <= 160, let draft = DueDateParser.event(from: t) {
            out.append(ClipAction(id: "event", title: "Add to Calendar: \(draft.title), \(eventWhen(draft))", icon: "calendar.badge.plus") {
                CommandCenter.shared.run([CommandParser.createEvent(draft)])
                return "Added to Calendar"
            })
        }
        if s.tasksEnabled {
            if lines.count >= 2 {
                out.append(ClipAction(id: "tasks", title: "Add \(lines.count) Tasks", icon: "checklist") {
                    lines.forEach { TaskStore.shared.add(title: $0) }
                    return "Added \(lines.count) tasks"
                })
            }
        }
        // Then things found in the text, which are more specific than "add to tasks".
        let found = detected(in: t)
        if let email = firstEmail(in: t) {
            out.append(ClipAction(id: "mail", title: "Write to \(email)", icon: "envelope") {
                open("mailto:\(email)")
                return nil
            })
        }
        if let phone = found.phone {
            out.append(ClipAction(id: "call", title: "Call \(phone)", icon: "phone") {
                open("tel:\(phone.filter { $0.isNumber || $0 == "+" })")
                return nil
            })
        }
        if let address = found.address {
            out.append(ClipAction(id: "maps", title: "Show in Maps", icon: "map") {
                open("maps://?q=\(address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
                return nil
            })
        }
        if let url = found.link {
            out.append(ClipAction(id: "openlink", title: "Open \(url.host() ?? "Link")", icon: "safari") {
                NSWorkspace.shared.open(url)
                return nil
            })
        }
        if let rgb = rgbString(fromHex: t) {
            out.append(ClipAction(id: "rgb", title: "Copy as \(rgb)", icon: "paintpalette") {
                copy(rgb)
                return "Copied \(rgb)"
            })
        }
        // Then the general ones.
        var generic: [ClipAction] = []
        if s.tasksEnabled {
            generic.append(ClipAction(id: "task", title: "Add to Tasks", icon: "checkmark.circle") {
                if singleLine, t.count <= 200 {
                    TaskStore.shared.add(title: t) // picks up "tomorrow 3pm" as a due date
                } else {
                    let first = t.split(separator: "\n").first.map(String.init) ?? t
                    TaskStore.shared.add(TaskItem(title: String(first.prefix(120)), note: t))
                }
                return "Added to Tasks"
            })
        }
        if s.notesEnabled {
            generic.append(ClipAction(id: "note", title: "Add to Notes", icon: "note.text.badge.plus") {
                appendToNotes(t)
                return "Added to Notes"
            })
        }

        out += generic
        if singleLine, t.count <= 120 {
            out.append(ClipAction(id: "search", title: "Search for “\(t.prefix(40))\(t.count > 40 ? "…" : "")”", icon: "magnifyingglass") {
                NotchPresenter.shared.open(tab: .ask)
                AssistantStore.shared.run(t)
                return nil
            })
        }
        return out
    }

    // MARK: Links, images, files

    private static func link(_ raw: String) -> [ClipAction] {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return [] }
        let s = AppSettings.shared
        let name = url.host().map { $0.replacingOccurrences(of: "www.", with: "") } ?? raw
        var out: [ClipAction] = []
        if s.tasksEnabled {
            out.append(ClipAction(id: "task", title: "Add to Tasks", icon: "checkmark.circle") {
                TaskStore.shared.add(TaskItem(title: "Read \(name)", link: url, linkKind: .web))
                return "Added to Tasks"
            })
        }
        out.append(ClipAction(id: "shelf", title: "Save to Shelf", icon: "tray.and.arrow.down") {
            ShelfStore.shared.addLink(url, title: name)
            return "Saved to Shelf"
        })
        if s.notesEnabled {
            out.append(ClipAction(id: "note", title: "Add to Notes", icon: "note.text.badge.plus") {
                appendToNotes(raw)
                return "Added to Notes"
            })
        }
        out.append(ClipAction(id: "open", title: "Open in Browser", icon: "safari") {
            NSWorkspace.shared.open(url)
            return nil
        })
        return out
    }

    private static func image(_ clip: ClipboardHistory.Clip) -> [ClipAction] {
        guard let url = ClipboardHistory.shared.imageURL(for: clip) else { return [] }
        return [
            ClipAction(id: "ocr", title: "Copy Text in Image", icon: "text.viewfinder") {
                Task {
                    guard let text = await SystemTweaks.recognizeText(in: url) else {
                        ActivityCenter.shared.show(.notice(title: "No text found", detail: "Clipboard", icon: "text.viewfinder", tone: .warning), for: 2.5)
                        return
                    }
                    copy(text)
                    ActivityCenter.shared.show(.notice(title: "Copied \(text.split(whereSeparator: \.isWhitespace).count) words",
                                                       detail: String(text.prefix(48)), icon: "text.viewfinder", tone: .success), for: 2.5)
                }
                return "Reading text…"
            },
            ClipAction(id: "shelf", title: "Save to Shelf", icon: "tray.and.arrow.down") {
                ShelfStore.shared.add([url])
                return "Saved to Shelf"
            },
        ]
    }

    private static func files(_ paths: [String]) -> [ClipAction] {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard let first = urls.first else { return [] }
        var out = [
            ClipAction(id: "shelf", title: urls.count == 1 ? "Add to Shelf" : "Add \(urls.count) to Shelf", icon: "tray.and.arrow.down") {
                ShelfStore.shared.add(urls)
                return "Added to Shelf"
            },
        ]
        if AppSettings.shared.tasksEnabled, urls.count == 1 {
            out.append(ClipAction(id: "task", title: "Add to Tasks", icon: "checkmark.circle") {
                TaskStore.shared.add(TaskItem(title: first.deletingPathExtension().lastPathComponent, link: first, linkKind: .file))
                return "Added to Tasks"
            })
        }
        out.append(ClipAction(id: "reveal", title: "Show in Finder", icon: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return nil
        })
        return out
    }

    // MARK: Helpers

    /// Lines that read as a list (2–20 short lines, bullets or numbers stripped), else none.
    static func listItems(_ t: String) -> [String] {
        let lines = t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (2...20).contains(lines.count), lines.allSatisfy({ $0.count <= 140 }) else { return [] }
        return lines.map { line in
            line.replacingOccurrences(of: #"^(\[[ xX]?\]\s*|[-*•·–]\s+|\d{1,2}[.)]\s+)"#, with: "", options: .regularExpression)
        }
    }

    private static func appendToNotes(_ text: String) {
        let store = ScratchpadStore.shared
        store.text += (store.text.isEmpty || store.text.hasSuffix("\n") ? "" : "\n") + text
    }

    private static func eventWhen(_ draft: EventDraft) -> String {
        draft.allDay ? draft.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                     : draft.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
        | NSTextCheckingResult.CheckingType.address.rawValue | NSTextCheckingResult.CheckingType.link.rawValue)

    private static func detected(in t: String) -> (phone: String?, address: String?, link: URL?) {
        var phone: String?, address: String?, link: URL?
        detector?.enumerateMatches(in: t, range: NSRange(t.startIndex..., in: t)) { match, _, _ in
            guard let match else { return }
            switch match.resultType {
            case .phoneNumber: phone = phone ?? match.phoneNumber
            case .address: address = address ?? Range(match.range, in: t).map { String(t[$0]) }
            case .link: if let url = match.url, url.scheme?.hasPrefix("http") == true { link = link ?? url }
            default: break
            }
        }
        return (phone, address, link)
    }

    private static func firstEmail(in t: String) -> String? {
        t.range(of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.regularExpression, .caseInsensitive]).map { String(t[$0]) }
    }

    /// "#ff8800" or "ff8800" → "rgb(255, 136, 0)".
    static func rgbString(fromHex t: String) -> String? {
        let hex = t.hasPrefix("#") ? String(t.dropFirst()) : t
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return "rgb(\(v >> 16 & 0xFF), \(v >> 8 & 0xFF), \(v & 0xFF))"
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
