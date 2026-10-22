import AppKit
import ImageIO
import SwiftUI

/// Moments Recall found: the selected one large (its picture, app, time and the words that
/// matched), the rest in a list beside it, and a sentence answering the question when one was written.
struct RecallResults: View {
    let answer: RecallAnswer
    @Binding var selection: Int

    var body: some View {
        if answer.hits.isEmpty {
            VStack(spacing: 6) {
                Text("Nothing in Recall matches").font(.system(size: 13, weight: .medium))
                Text(emptyHint).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let index = min(selection, answer.hits.count - 1)
            VStack(alignment: .leading, spacing: 8) {
                if let sentence = answer.sentence, !sentence.isEmpty {
                    // Two lines at most, so the moments and the footer keep their room; all of it on hover.
                    Text(sentence)
                        .font(.system(size: sentence.count > 110 ? 13 : 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                        .help(sentence)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
                HStack(alignment: .top, spacing: 16) {
                    RecallMoment(hit: answer.hits[index], label: index == 0 ? "Best match" : "Match \(index + 1) of \(answer.hits.count)",
                                 hits: answer.hits, index: index)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if answer.hits.count > 1 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(header)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                                .lineLimit(1)
                                .padding(.leading, 8)
                            ScrollViewReader { proxy in
                                ScrollView(.vertical, showsIndicators: false) {
                                    VStack(spacing: 0) {
                                        ForEach(Array(answer.hits.enumerated()), id: \.element.id) { i, hit in
                                            RecallRow(hit: hit, selected: i == index) {
                                                selection = i
                                                if let thumbs = thumbnails { QuickLook.shared.follow(thumbs, at: i) }
                                            }
                                            .id(i)
                                        }
                                    }
                                }
                                .onChange(of: index) { _, i in
                                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i) }
                                }
                                // More below: the last row fades rather than being cut through.
                                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82),
                                                             .init(color: .black.opacity(0), location: 1)],
                                                     startPoint: .top, endPoint: .bottom))
                            }
                        }
                        .frame(width: 230, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
        }
    }

    private var thumbnails: [URL]? {
        let urls = answer.hits.compactMap(\.thumbnail)
        return urls.count == answer.hits.count ? urls : nil
    }

    /// "4 moments · yesterday · Terminal".
    private var header: String {
        let f = answer.filter
        return (["\(answer.hits.count) moments", f.when, f.apps.isEmpty ? nil : f.apps.joined(separator: ", ")].compactMap { $0 })
            .joined(separator: " · ")
    }

    private var emptyHint: String {
        let f = answer.filter
        var parts: [String] = []
        if !f.keywords.isEmpty { parts.append("“\(f.keywords.joined(separator: " "))”") }
        if let when = f.when { parts.append(when) }
        if !f.apps.isEmpty { parts.append("in \(f.apps.joined(separator: ", "))") }
        let looked = parts.isEmpty ? "" : "Looked for \(parts.joined(separator: " ")). "
        return looked + "Recall only knows what was on screen since it was turned on."
    }

    /// "Today 3:42 PM", "Yesterday 9:10 AM", "Tue 3:42 PM", "Oct 12, 3:42 PM".
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    static func appIcon(_ bundleID: String?) -> NSImage {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) ?? NSImage()
    }
}

/// The selected moment: its picture, where and when, the matching words, and the way back to it.
private struct RecallMoment: View {
    let hit: RecallSearch.Hit
    let label: String
    let hits: [RecallSearch.Hit]
    let index: Int
    @State private var picture: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let picture {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: RecallResults.appIcon(hit.bundleID)).resizable().aspectRatio(contentMode: .fit).padding(30)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(picture == nil ? 0 : 0.12), lineWidth: 1))
            .frame(maxWidth: 160, maxHeight: 96)
            .frame(width: 160, height: 96, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { quickLook() }
            .id(hit.id)
            .transition(.opacity)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                Text(hit.title?.isEmpty == false ? hit.title! : hit.appName ?? "Window")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(nsImage: RecallResults.appIcon(hit.bundleID)).resizable().frame(width: 13, height: 13)
                    Text([hit.appName, RecallResults.when(hit.time)].compactMap { $0 }.joined(separator: " · "))
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                if !hit.snippet.isEmpty {
                    Text(hit.snippet)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .padding(.top, 2)
                }
                HStack(spacing: 6) {
                    Button(openTitle) { RecallSearch.open(hit) }
                        .buttonStyle(NotchPillButtonStyle(primary: true, height: 24))
                    if hit.thumbnail != nil {
                        Button("Quick Look") { quickLook() }
                            .buttonStyle(NotchPillButtonStyle(height: 24))
                            .help("⌘Y")
                    }
                }
                .padding(.top, 4)
            }
        }
        .task(id: hit.id) {
            picture = nil
            guard let url = hit.thumbnail else { return }
            picture = await Task.detached(priority: .userInitiated) { Self.load(url) }.value
        }
    }

    /// "Open Page", "Open Document", else "Open Slack".
    private var openTitle: String {
        guard let location = hit.location, !location.isEmpty else { return "Open \(hit.appName ?? "App")" }
        return RecallSearch.webURL(location) != nil ? "Open Page" : "Open Document"
    }

    private func quickLook() {
        let urls = hits.compactMap(\.thumbnail)
        guard let url = hit.thumbnail, let i = urls.firstIndex(of: url) else { return }
        QuickLook.shared.show(urls, at: i)
    }

    private nonisolated static func load(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}

private struct RecallRow: View {
    let hit: RecallSearch.Hit
    var selected = false
    var select: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: RecallResults.appIcon(hit.bundleID))
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title?.isEmpty == false ? hit.title! : hit.appName ?? "Window")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text([hit.appName, RecallResults.when(hit.time)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.14 : hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { RecallSearch.open(hit) }
        .onTapGesture(count: 1) { select() }
        .help(hit.snippet.isEmpty ? (hit.location ?? "") : hit.snippet)
    }
}
