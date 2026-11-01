import SwiftUI

struct WebResults: View {
    let job: AssistantStore.Job
    let accent: Color
    @Binding var selection: Int

    var body: some View {
        if job.state == .done && (job.answer ?? "").isEmpty {
            LinkResults(sources: job.sources, selection: selection)
        } else {
            answerWithSources
        }
    }

    private var answerWithSources: some View {
        HStack(alignment: .top, spacing: 18) {
            ScrollView(.vertical, showsIndicators: false) {
                AnswerText(text: job.answer ?? "", accent: accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)

            // A translation has no sources to list.
            if job.route != .write {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sources")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                    if job.state == .done {
                        ShelfIconButton(file: ShelfStore.answerFile(for: job.query), help: "Save the answer to the shelf") {
                            ShelfStore.shared.addAnswer(question: job.query, answer: job.answer ?? "", sources: job.sources)
                        }
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(job.answer ?? "", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 20))
                    .help("Copy answer")
                }
                .padding(.leading, 6)
                SourceList(sources: Array(job.sources.prefix(5)), selection: selection)
            }
            .frame(width: 200)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// An answer about what's on screen: the answer, and beside it the screen it looked at (plus any
/// web sources it needed).
struct ScreenResults: View {
    let job: AssistantStore.Job
    let accent: Color
    @Binding var selection: Int

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ScrollView(.vertical, showsIndicators: false) {
                AnswerText(text: job.answer ?? "", accent: accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(job.screenIsArea ? "The area" : "Your screen")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(job.answer ?? "", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 20))
                    .help("Copy answer")
                }
                .padding(.leading, 6)
                if let screen = job.screen {
                    Image(nsImage: screen)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.12)))
                        .frame(maxHeight: job.sources.isEmpty ? 120 : 64, alignment: .top)
                        .padding(.leading, 6)
                }
                if !job.sources.isEmpty {
                    SourceList(sources: Array(job.sources.prefix(3)), selection: selection)
                }
            }
            .frame(width: 200)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A help answer about NotchApp, with each "Settings → …" path a link to that page.
struct HelpResults: View {
    let job: AssistantStore.Job
    let accent: Color
    @Binding var selection: Int

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            AnswerText(text: job.answer ?? "", accent: accent, settingsLinks: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 28)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.answer ?? "", forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(NotchIconButtonStyle(size: 20))
            .help("Copy answer")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.openURL, OpenURLAction { url in HelpBrain.open(url) ? .handled : .systemAction })
    }
}

/// Plain search results (no model to write an answer): title, site and snippet.
private struct LinkResults: View {
    let sources: [WebSource]
    let selection: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { i, source in
                        LinkRow(source: source, selected: i == selection).id(i)
                    }
                }
            }
            .onChange(of: selection) { _, i in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct LinkRow: View {
    let source: WebSource
    var selected = false
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(source.url) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text(source.host)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
                if !source.snippet.isEmpty {
                    // The selected link shows more of its snippet, as a preview of the page.
                    Text(source.snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(selected ? 0.65 : 0.5))
                        .lineLimit(selected ? 3 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { LinkShelfButton(source: source, hovering: hovering || selected) }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.12 : hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(source.url.absoluteString)
    }
}

/// A small shelf button for a web link: shows on hover, and stays as a checkmark once it's on the shelf.
private struct LinkShelfButton: View {
    let source: WebSource
    let hovering: Bool

    var body: some View {
        ShelfIconButton(file: ShelfStore.linkFile(for: source.url, title: source.title), help: "Save the link to the shelf",
                        visible: hovering) {
            ShelfStore.shared.addLink(source.url, title: source.title)
        }
    }
}

/// Tray icon that saves something to the shelf and turns into a checkmark once it's there.
private struct ShelfIconButton: View {
    let file: URL
    let help: String
    var visible = true
    let add: () -> Void
    @EnvironmentObject private var shelf: ShelfStore

    var body: some View {
        let added = shelf.contains(file)
        if visible || added {
            Button {
                guard !added else { return }
                withAnimation(Motion.small.animation) { add() }
            } label: {
                Image(systemName: added ? "checkmark" : "tray.and.arrow.down")
                    .font(.system(size: 10, weight: added ? .bold : .regular))
                    .foregroundStyle(.white.opacity(added ? 0.9 : 0.6))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(NotchIconButtonStyle(size: 20))
            .help(added ? "On your shelf" : help)
            .transition(.opacity)
        }
    }
}

/// Numbered sources beside an answer; the one the arrow keys are on is scrolled into view.
private struct SourceList: View {
    let sources: [WebSource]
    let selection: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { i, source in
                        SourceRow(index: i + 1, source: source, selected: i == selection).id(i)
                    }
                }
            }
            .onChange(of: selection) { _, i in
                guard sources.indices.contains(i) else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i) }
            }
        }
    }
}

private struct SourceRow: View {
    let index: Int
    let source: WebSource
    var selected = false
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(source.url) } label: {
            HStack(alignment: .top, spacing: 8) {
                // The site's own icon; its number (what the answer cites) stays beside the address.
                Favicon(host: source.host) {
                    Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        .frame(width: 16, height: 16)
                }
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text("\(index) · \(source.host)")
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                LinkShelfButton(source: source, hovering: hovering || selected)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.12 : hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(source.url.absoluteString)
    }
}
