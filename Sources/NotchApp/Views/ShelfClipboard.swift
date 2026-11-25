import Carbon.HIToolbox
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Clipboard

/// Recent copies as cards: click one to put it back on the clipboard (the notch closes so you can paste).
/// With the keyboard: ← → move a highlight, typing searches, and the Clipboard keys (↩ paste,
/// ⌘C copy, ⌃X remove, ⇧⌘P pin, ⌘1–⌘9 paste by position; see `ShelfKey`) act on it.
struct ClipboardStrip: View {
    @ObservedObject var viewModel: NotchViewModel
    @Binding var query: String
    @Binding var kind: ClipboardHistory.Clip.Kind?
    @EnvironmentObject private var clipboard: ClipboardHistory
    @EnvironmentObject private var settings: AppSettings
    /// The clip the keys act on. Opened with a shortcut it starts on the newest; otherwise the
    /// first arrow press puts it there, so the mouse alone never shows a highlight.
    @State private var highlight: UUID?
    /// Modifiers held right now: holding quick paste's shows the numbers on the cards.
    @State private var held: UInt32 = 0

    private var shown: [ClipboardHistory.Clip] { clipboard.shown(matching: query, kind: kind) }

    var body: some View {
        let shown = shown
        let numbered = ShelfKey.quickPaste.combo.map { $0.modifiers == held } ?? false
        Group {
            if !clipboard.clips.isEmpty, shown.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium))
                    Text("Nothing matches").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if clipboard.clips.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 20, weight: .medium))
                    Text("Things you copy show up here").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { outer in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                // Pinned first, then newest.
                                ForEach(Array(shown.enumerated()), id: \.element.id) { index, clip in
                                    ClipCard(clip: clip, marks: TileMarks(highlighted: highlight == clip.id,
                                                                         number: numbered && index < 9 ? index + 1 : nil)) {
                                        // ⌘ or ⇧: pick it (to act on several); a plain click puts it back to paste.
                                        let mods = NSEvent.modifierFlags
                                        if mods.contains(.command) || mods.contains(.shift) {
                                            withAnimation(.easeOut(duration: 0.12)) { clipboard.pick(clip, modifiers: mods, in: shown) }
                                        } else if !clipboard.selection.isEmpty {
                                            withAnimation(.easeOut(duration: 0.12)) { clipboard.selection = [] }
                                        } else {
                                            clipboard.copy(clip)
                                            viewModel.close()
                                        }
                                    }
                                    .id(clip.id)
                                    .scrollEdgeFade()
                                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                                }
                            }
                            .frame(height: outer.size.height)
                        }
                        .onChange(of: highlight) { _, id in
                            guard let id else { return }
                            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) }
                        }
                    }
                }
                .horizontalScrollRegion("clipboard", in: viewModel)
            }
        }
        .onAppear {
            if viewModel.openReason == .keyboard { highlight = shown.first?.id }
            if viewModel.isOpen, viewModel.tab == .shelf { Tips.shared.note(.clipboardOpened) }
        }
        .modifier(TabKeyboard(viewModel: viewModel, tab: .shelf, held: $held, handle: handle))
        // A new search highlights its first match, so ↩ pastes it.
        .onChange(of: query) { _, _ in highlight = self.shown.first?.id }
        .onChange(of: kind) { _, _ in if highlight != nil { highlight = self.shown.first?.id } }
    }

    // MARK: Keys

    private func handle(_ event: NSEvent) -> Bool {
        guard settings.clipboardHistory else { return false }
        let mods = ShelfKey.carbon(event.modifierFlags)
        let editor = event.window?.firstResponder as? NSTextView
        // ⌘C with words picked in the search field copies those words.
        if let editor, editor.selectedRange().length > 0, mods == UInt32(cmdKey), event.charactersIgnoringModifiers == "c" {
            return false
        }
        if let (key, digit) = ShelfKey.match(event) {
            run(key, digit: digit)
            return true
        }
        if let (step, extend) = ShelfKey.arrow(event) {
            move(step, extend: extend)
            return true
        }
        let plain = mods & UInt32(controlKey | optionKey | cmdKey) == 0
        if plain, event.keyCode == UInt16(kVK_Escape), !query.isEmpty {
            query = "" // the first Esc clears the search; the next one backs out as usual
            return true
        }
        // Typing with the search field not focused still searches.
        guard editor == nil, plain else { return false }
        if event.keyCode == UInt16(kVK_Delete) {
            guard !query.isEmpty else { return false }
            query.removeLast()
            return true
        }
        guard let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        query += chars
        return true
    }

    /// Moves the highlight; with ⇧, the picked clips run from where it was to where it lands.
    private func move(_ step: Int, extend: Bool) {
        let shown = shown
        guard !shown.isEmpty else { return }
        guard let next = ShelfKey.step(shown.map(\.id), from: highlight, by: step),
              let to = shown.first(where: { $0.id == next }) else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            if extend {
                if clipboard.selection.isEmpty, let from = shown.first(where: { $0.id == highlight }) ?? Optional(to) {
                    clipboard.pick(from, modifiers: [], in: shown)
                }
                clipboard.pick(to, modifiers: .shift, in: shown)
            }
            highlight = next
        }
    }

    /// What a key acts on: everything picked, else the highlighted clip.
    private var targets: [ClipboardHistory.Clip] {
        let shown = shown
        if !clipboard.selection.isEmpty { return shown.filter { clipboard.selection.contains($0.id) } }
        return shown.filter { $0.id == highlight }
    }

    private func run(_ key: ShelfKey, digit: Int?) {
        let shown = shown
        if key == .quickPaste {
            guard let digit, digit <= shown.count else { NSSound.beep(); return }
            clipboard.selection = []
            clipboard.paste(shown[digit - 1])
            return
        }
        let group = targets
        guard let first = group.first else {
            // Nothing highlighted yet: the first press shows where the keys will act.
            if !shown.isEmpty { withAnimation(.easeOut(duration: 0.12)) { highlight = shown[0].id } }
            return
        }
        switch key {
        case .paste:
            clipboard.selection = []
            group.count > 1 ? clipboard.pasteTogether(group) : clipboard.paste(first)
        case .copy:
            clipboard.selection = []
            if group.count > 1 { clipboard.copyTogether(group) } else { clipboard.copy(first) }
            viewModel.close()
        case .delete:
            // The highlight moves on to the clip after (or before) the ones removed.
            let ids = Set(group.map(\.id))
            let last = shown.lastIndex { ids.contains($0.id) } ?? 0
            let after = shown[(last + 1)...].first { !ids.contains($0.id) } ?? shown[..<last].last { !ids.contains($0.id) }
            group.count > 1 ? clipboard.remove(group) : clipboard.delete(first)
            highlight = after?.id
        case .pin:
            if group.count > 1 { clipboard.setPinned(group, !group.allSatisfy(\.pinned)) } else { clipboard.togglePin(first) }
        case .quickLook:
            // Pictures and files; text has nothing more to show than its card.
            let urls = group.flatMap { clip in (clip.filePaths ?? []).map(URL.init(fileURLWithPath:)) + [clipboard.imageURL(for: clip)].compactMap { $0 } }
            if urls.isEmpty { NSSound.beep() } else { QuickLookPreview.shared.show(urls) }
        case .quickPaste:
            break
        }
    }
}

private struct ClipCard: View {
    let clip: ClipboardHistory.Clip
    /// Where the keyboard is, and the number quick paste gives it.
    var marks = TileMarks()
    let action: () -> Void
    @EnvironmentObject private var clipboard: ClipboardHistory
    @State private var hovering = false
    /// What can be done with this copy beyond pasting it (worked out once per clip).
    @State private var suggestions: [ClipAction] = []
    /// A short "Added to Tasks" over the card after an action.
    @State private var flash: String?

    private func run(_ suggestion: ClipAction) {
        guard let message = suggestion.run() else { return }
        withAnimation(Motion.small.animation) { flash = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.25)) { if flash == message { flash = nil } }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 4) {
                if let id = clip.sourceBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    AppIcon(bundlePath: url.path, size: 11)
                } else {
                    Image(systemName: clip.icon).font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Optional(clip.kind).tint ?? .white.opacity(0.4))
                }
                Text(Date().timeIntervalSince(clip.date) < 60 ? "now" : clip.date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                Spacer(minLength: 0)
                if clip.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.orange)
                }
            }
        }
        .padding(8)
        .frame(width: 132)
        .frame(maxHeight: .infinity)
        .notchSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), active: hovering || marks.highlighted)
        .tileMarks(TileMarks(highlighted: marks.highlighted && !clipboard.selection.contains(clip.id), number: marks.number))
        .overlay {
            if clipboard.selection.contains(clip.id) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5))
                    .allowsHitTesting(false)
            }
        }
        // Over the empty end of the bottom row (beside the time), not over what was copied.
        .overlay(alignment: .bottomTrailing) {
            if hovering, flash == nil {
                HStack(spacing: 2) {
                    // The most fitting action, one click away (the rest are on right-click).
                    if let first = suggestions.first {
                        Button { run(first) } label: {
                            Image(systemName: first.icon).font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(NotchIconButtonStyle(size: 20))
                        .help(first.title + (suggestions.count > 1 ? " · right-click for more" : ""))
                    }
                    Button { clipboard.paste(clip) } label: {
                        Image(systemName: "arrow.turn.down.left").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 20))
                    .help("Paste into \(FrontmostTracker.shared.userApp?.localizedName ?? "the app you're in")")
                    Button { clipboard.togglePin(clip) } label: {
                        Image(systemName: clip.pinned ? "pin.slash.fill" : "pin.fill").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 20))
                    .help(clip.pinned ? "Unpin" : "Pin: kept when you clear the history")
                    Button { clipboard.delete(clip) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 20))
                    .help("Remove")
                }
                .padding(3)
                .background(Capsule().fill(.black.opacity(0.6)))
                .padding(4)
            }
        }
        .overlay {
            if let flash {
                Label(flash, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(Color.green.opacity(0.85)))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture(perform: action)
        .onDrag {
            DragActivity.shared.active = true // shows AirDrop and Taildrop to drop it on
            return dragItem
        }
        .task(id: clip.id) { suggestions = ClipActions.suggestions(for: clip) }
        .contextMenu { ClipMenu(clip: clip, suggestions: suggestions, run: run) }
        .help("Click to copy · ⌘-click to select several")
    }

    @ViewBuilder private var content: some View {
        switch clip.kind {
        case .text:
            if let rgba = clip.hexColor {
                // The color itself, with its code on it in black or white, whichever reads.
                let light = 0.299 * rgba.r + 0.587 * rgba.g + 0.114 * rgba.b > 0.6 && rgba.a > 0.5
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .overlay(alignment: .bottomLeading) {
                        Text(clip.title.uppercased())
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(light ? Color.black.opacity(0.75) : Color.white.opacity(0.9))
                            .lineLimit(1)
                            .padding(6)
                    }
            } else {
                Text(clip.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(5)
            }
        case .link:
            VStack(alignment: .leading, spacing: 2) {
                // The site's own icon, like a browser tab's.
                Favicon(host: URL(string: clip.title)?.host() ?? "", size: 13) {
                    Image(systemName: "link").font(.system(size: 10, weight: .semibold)).foregroundStyle(.blue)
                }
                Text(URL(string: clip.title)?.host() ?? clip.title)
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(clip.title).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }
        case .image:
            if let image = clipboard.thumbnail(for: clip) {
                // Filled over a fixed-size base: a filled image on its own reports its overflowing
                // size, and the card grows past its neighbours to fit it.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        case .files:
            let paths = clip.filePaths ?? []
            if paths.count == 1 {
                // One file: its preview fills the card (a picture, a PDF's page, a document's icon).
                VStack(alignment: .leading, spacing: 4) {
                    FileThumbnail(path: paths[0], fill: clip.isPicture)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(clip.title).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.middle)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    FileFan(paths: paths, spread: hovering || marks.highlighted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(clip.isPicture ? "\(paths.count) pictures" : clip.title)
                        .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
        }
    }

    private var dragItem: NSItemProvider {
        switch clip.kind {
        case .files: NSItemProvider(object: URL(fileURLWithPath: clip.filePaths?.first ?? "") as NSURL)
        case .image: clipboard.image(for: clip).map { NSItemProvider(object: $0) } ?? NSItemProvider()
        default: NSItemProvider(object: (clip.text ?? "") as NSString)
        }
    }
}

/// Right-click on a copy: everything it can do, for every picked copy at once.
private struct ClipMenu: View {
    let clip: ClipboardHistory.Clip
    let suggestions: [ClipAction]
    let run: (ClipAction) -> Void
    @EnvironmentObject private var clipboard: ClipboardHistory

    private var app: String { FrontmostTracker.shared.userApp?.localizedName ?? "App" }

    var body: some View {
        let group = clipboard.targets(for: clip)
        if group.count > 1 {
            many(group)
        } else {
            one
        }
    }

    // MARK: Several

    @ViewBuilder private func many(_ group: [ClipboardHistory.Clip]) -> some View {
        Text("\(group.count) items")
        MenuItem("Paste Together into \(app)", "arrow.turn.down.left") { clipboard.pasteTogether(group) }
        MenuItem("Copy Together", "doc.on.doc") { clipboard.copyTogether(group) }
        MenuItem("Save All to Shelf", "tray.and.arrow.down") { group.forEach(clipboard.saveToShelf) }
        let files = group.flatMap { $0.filePaths ?? [] }.map { URL(fileURLWithPath: $0) }
        if !files.isEmpty {
            Divider()
            OpenWithMenu(urls: files)
            MenuItem("Quick Look", "eye") { QuickLookPreview.shared.show(files) }
            ShareLink(items: files) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
        Divider()
        let pin = !group.allSatisfy(\.pinned)
        MenuItem(pin ? "Pin All" : "Unpin All", pin ? "pin" : "pin.slash") { clipboard.setPinned(group, pin) }
        MenuItem("Deselect", "circle.dashed") { clipboard.selection = [] }
        Divider()
        MenuItem("Remove \(group.count) Items", "trash", role: .destructive) { clipboard.remove(group) }
    }

    // MARK: One

    @ViewBuilder private var one: some View {
        MenuItem("Paste into \(app)", "arrow.turn.down.left") { clipboard.paste(clip) }
        MenuItem("Copy", "doc.on.doc") { clipboard.copy(clip) }
        if !suggestions.isEmpty {
            Divider()
            ForEach(suggestions) { suggestion in MenuItem(suggestion.title, suggestion.icon) { run(suggestion) } }
        }
        Divider()
        switch clip.kind {
        case .link:
            if let url = clip.text.flatMap({ URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                MenuItem("Open Link", "safari") { NSWorkspace.shared.open(url) }
                if let host = url.host() { Text(host) }
                if let link = VideoDownloader.webURL(url.absoluteString), VideoDownloader.isAvailable {
                    MenuItem("Download Video…", "arrow.down.circle") { VideoDownloader.shared.chooseQuality(for: link) }
                    MenuItem("Download Audio", "music.note") { VideoDownloader.shared.download(link, format: .audio, height: nil) }
                }
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            }
        case .files:
            let urls = (clip.filePaths ?? []).map { URL(fileURLWithPath: $0) }
            MenuItem("Open", "arrow.up.forward.square") { urls.forEach { NSWorkspace.shared.open($0) } }
            OpenWithMenu(urls: urls)
            MenuItem("Quick Look", "eye") { QuickLookPreview.shared.show(urls) }
            MenuItem("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            MenuItem(urls.count > 1 ? "Copy Paths" : "Copy Path", "point.topleft.down.to.point.bottomright.curvepath") { ShelfStore.copyPaths(urls) }
            ShareLink(items: urls) { Label("Share…", systemImage: "square.and.arrow.up") }
        case .image:
            if let url = clipboard.imageURL(for: clip) {
                MenuItem("Quick Look", "eye") { QuickLookPreview.shared.show([url]) }
                MenuItem("Copy Text in Image", "text.viewfinder") { clipboard.copyText(in: clip) }
                MenuItem("Remove Background", "person.crop.rectangle") { Cutout.run([url]) }
                OpenWithMenu(urls: [url])
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            }
        case .text:
            if let text = clip.text {
                let words = text.split(whereSeparator: \.isWhitespace).count
                Text("\(words) \(words == 1 ? "word" : "words") · \(text.count) characters")
                MenuItem("Search the Web", "magnifyingglass") { clipboard.searchWeb(clip) }
                MenuItem("Ask About It", "sparkles") {
                    NotchPresenter.shared.open(tab: .ask)
                    AssistantStore.shared.run("Explain this briefly: \(text.prefix(2000))")
                }
                let transforms = TextTransform.applicable(to: text).filter { $0 != .plain }
                if !transforms.isEmpty {
                    Menu {
                        ForEach(transforms) { t in
                            MenuItem(t.title, t.symbol) {
                                clipboard.copy(clip, announce: false)
                                TextTransform.applyToClipboard(t)
                            }
                        }
                    } label: {
                        Label("Transform & Copy", systemImage: "textformat")
                    }
                }
                ShareLink(item: text) { Label("Share…", systemImage: "square.and.arrow.up") }
            }
        }
        MenuItem("Save to Shelf", "tray.and.arrow.down") { clipboard.saveToShelf(clip) }
        Divider()
        MenuItem(clip.pinned ? "Unpin" : "Pin", clip.pinned ? "pin.slash" : "pin") { clipboard.togglePin(clip) }
        MenuItem("Select", "checkmark.circle") { clipboard.pick(clip, modifiers: .command, in: clipboard.clips) }
        Divider()
        MenuItem("Remove", "trash", role: .destructive) { clipboard.delete(clip) }
    }
}
