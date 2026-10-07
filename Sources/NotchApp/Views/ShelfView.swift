import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var shelf: ShelfStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if shelf.items.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Shelf")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                            Spacer()
                            Button("Clear") { withAnimation(.spring(response: 0.3)) { shelf.clear() } }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        GeometryReader { outer in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(shelf.items) { item in
                                        ShelfTile(item: item)
                                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                                    }
                                }
                                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: shelf.items.map(\.id))
                                .background(GeometryReader { inner in
                                    // Let two-finger swipes scroll the strip (not the tabs) when it overflows.
                                    let overflows = inner.size.width > outer.size.width + 1
                                    Color.clear
                                        .onAppear { report(overflows, outer.frame(in: .global)) }
                                        .onChange(of: overflows) { _, o in report(o, outer.frame(in: .global)) }
                                })
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if settings.airDropZone {
                AirDropZone()
                    .frame(width: 104)
            }
        }
    }

    private func report(_ overflows: Bool, _ frame: CGRect) {
        viewModel.horizontalScrollRegion = overflows ? frame : nil
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.03)))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 22, weight: .medium))
                    Text("Drop files here")
                        .font(.system(size: 12, weight: .medium))
                    if settings.screenshotCatcher {
                        Text("New screenshots land here too")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .foregroundStyle(.white.opacity(0.6))
            }
    }
}

private struct ShelfTile: View {
    @ObservedObject var item: ShelfItem
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: item.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 72, height: 26, alignment: .top)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { withAnimation(.spring(response: 0.3)) { ShelfStore.shared.remove(item) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.3))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("AirDrop") { ShelfStore.airDrop([item.url]) }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([item.url as NSURL])
            }
            Divider()
            Button("Remove from Shelf") { ShelfStore.shared.remove(item) }
        }
        .help(item.url.path)
    }
}

private struct AirDropZone: View {
    @EnvironmentObject private var shelf: ShelfStore
    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(targeted ? Color.blue.opacity(0.35) : .white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(targeted ? Color.blue : .white.opacity(0.12), lineWidth: 1)
            )
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 22, weight: .medium))
                        .symbolEffect(.variableColor.iterative, isActive: targeted)
                    Text("AirDrop")
                        .font(.system(size: 12, weight: .medium))
                    Text(shelf.items.isEmpty ? "Drop to send" : "Drop, or click\nto send shelf")
                        .font(.system(size: 9))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .scaleEffect(targeted ? 1.04 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { ShelfStore.airDrop(shelf.items.map(\.url)) }
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                ShelfStore.urls(from: providers) { ShelfStore.airDrop($0) }
                return true
            }
    }
}
