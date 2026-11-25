import SwiftUI
import UniformTypeIdentifiers

// Tools › Cleaner: disk space, caches and leftovers, and the app uninstaller.

// MARK: - Cleaner

struct CleanerPane: View {
    @EnvironmentObject private var cleaner: Cleaner
    @EnvironmentObject private var uninstaller: AppUninstaller
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                DiskCard()
                UninstallDrop(targeted: dropTargeted)
            }
            .padding(.top, 4)
            .frame(width: 190)

            SectionDivider()

            Group {
                if uninstaller.target != nil {
                    UninstallView()
                        .transition(Motion.paneTransition(edge: .trailing))
                } else {
                    CategoryList()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in AppUninstaller.shared.inspect(url) }
            }
            return true
        }
        .onAppear {
            cleaner.refreshDisk()
            if cleaner.scanned.map({ Date().timeIntervalSince($0) > 600 }) ?? true { cleaner.scan() }
        }
    }
}

private struct DiskCard: View {
    @EnvironmentObject private var cleaner: Cleaner
    @State private var confirming = false

    var body: some View {
        Card(tint: .pink) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    CardTitle(title: "Disk", icon: "internaldrive.fill", tint: .pink)
                    Spacer(minLength: 2)
                    if let disk = cleaner.disk {
                        Text(formatBytes(disk.available))
                            .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("free").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                if let disk = cleaner.disk {
                    GeometryReader { geo in
                        let freed = max(3, geo.size.width * Double(cleaner.selectedSize) / Double(max(disk.total, 1)))
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.1))
                            Capsule().fill(disk.usedFraction > 0.92 ? Color.red.gradient : Color.pink.gradient)
                                .frame(width: geo.size.width * disk.usedFraction)
                            if cleaner.selectedSize > 0 {
                                // What a clean would give back, at the end of the used part.
                                Capsule().fill(.white.opacity(0.6))
                                    .frame(width: freed)
                                    .offset(x: max(0, geo.size.width * disk.usedFraction - freed))
                            }
                        }
                    }
                    .frame(height: 5)
                    .help("\(formatBytes(disk.used)) of \(formatBytes(disk.total)) used")
                }
                Spacer(minLength: 0)
                cleanButton
            }
        }
    }

    @ViewBuilder private var cleanButton: some View {
        if cleaner.cleaning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(.white)
                Text("Cleaning…").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            }
            .frame(height: 24)
        } else if let freed = cleaner.lastFreed, cleaner.selectedSize == 0 || cleaner.scanning {
            Label("\(formatBytes(freed)) cleaned", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(ToolsPalette.good)
                .frame(height: 24)
        } else {
            Button {
                if confirming {
                    confirming = false
                    cleaner.clean()
                } else {
                    confirming = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirming = false }
                }
            } label: {
                Text(confirming ? "Click to Confirm" : cleaner.selectedSize > 0 ? "Clean \(formatBytes(cleaner.selectedSize))" : "Nothing Selected")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NotchPillButtonStyle(primary: !confirming, height: 24))
            .disabled(cleaner.selectedSize == 0 || cleaner.scanning)
            .opacity(cleaner.selectedSize == 0 || cleaner.scanning ? 0.5 : 1)
            .help(cleaner.selected.contains(.trash) ? "Moves what's picked to the Trash, then empties it" : "Moves what's picked to the Trash")
        }
    }
}

private struct UninstallDrop: View {
    let targeted: Bool
    @EnvironmentObject private var uninstaller: AppUninstaller

    var body: some View {
        Button(action: pickApp) {
            HStack(spacing: 10) {
                IconBadge(symbol: "trash.fill", tint: .red, size: 26)
                    .scaleEffect(targeted ? 1.1 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Uninstall an app").font(.system(size: 12.5, weight: .semibold))
                    Text(uninstaller.message ?? (targeted ? "Release to look it over" : "Drop it here, or click"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(uninstaller.message != nil ? .orange : .white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(targeted ? 0.1 : 0))
                .padding(.horizontal, -7)
                .padding(.vertical, -4))
        }
        .buttonStyle(NotchRowButtonStyle())
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        panel.message = "Choose an app to uninstall"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { uninstaller.inspect(url) }
    }
}

private struct CategoryList: View {
    @EnvironmentObject private var cleaner: Cleaner
    @State private var expanded: Cleaner.CategoryID?

    var body: some View {
        if cleaner.categories.isEmpty {
            VStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Looking for space to free…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    if let error = cleaner.lastError {
                        Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                    }
                    ForEach(Cleaner.CategoryID.allCases) { id in
                        if let category = cleaner.categories[id], !category.items.isEmpty {
                            CategoryRow(category: category, expanded: expanded == id) {
                                withAnimation(Motion.small.animation) { expanded = expanded == id ? nil : id }
                            }
                            .verticalScrollEdgeFade()
                            if expanded == id, id != .trash {
                                ForEach(category.items.prefix(30)) { item in
                                    ItemRow(item: item, category: id)
                                        .verticalScrollEdgeFade()
                                }
                            }
                        }
                    }
                    if !cleaner.snapshots.isEmpty { SnapshotRow(count: cleaner.snapshots.count) }
                    if cleaner.categories.values.allSatisfy(\.items.isEmpty) && cleaner.snapshots.isEmpty {
                        Label("Nothing to clean", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(ToolsPalette.good)
                            .padding(.top, 30)
                    }
                }
            }
            .opacity(cleaner.scanning ? 0.5 : 1)
        }
    }
}

private struct CategoryRow: View {
    let category: Cleaner.Category
    let expanded: Bool
    let toggleExpanded: () -> Void
    @EnvironmentObject private var cleaner: Cleaner
    @State private var hovering = false

    var body: some View {
        let id = category.id
        let on = cleaner.selected.contains(id)
        HStack(spacing: 8) {
            Checkbox(on: on) {
                if on { cleaner.selected.remove(id) } else { cleaner.selected.insert(id) }
            }
            Image(systemName: id.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(id.tint.gradient))
            VStack(alignment: .leading, spacing: 0) {
                Text(id.title).font(.system(size: 11.5, weight: .medium))
                Text(id.detail).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(formatBytes(category.size))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(on ? 0.9 : 0.5))
            if id != .trash {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
            } else {
                Color.clear.frame(width: 12)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering || expanded ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if id != .trash { toggleExpanded() } }
    }
}

private struct ItemRow: View {
    let item: Cleaner.Item
    let category: Cleaner.CategoryID
    @EnvironmentObject private var cleaner: Cleaner
    @State private var hovering = false

    var body: some View {
        let included = !cleaner.excluded.contains(item.url)
        HStack(spacing: 8) {
            Color.clear.frame(width: 14)
            Checkbox(on: included && cleaner.selected.contains(category), small: true) {
                if included { cleaner.excluded.insert(item.url) } else { cleaner.excluded.remove(item.url) }
                if !included { cleaner.selected.insert(category) }
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().frame(width: 14, height: 14)
            Text(item.name)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(included ? 0.8 : 0.4))
                .lineLimit(1).truncationMode(.middle)
            if let date = item.date {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.3)).lineLimit(1)
            }
            Spacer(minLength: 6)
            if hovering {
                Button { cleaner.reveal(item) } label: { Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(NotchIconButtonStyle(size: 18))
                    .help("Show in Finder")
            }
            Text(formatBytes(item.size))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            Color.clear.frame(width: 12)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct SnapshotRow: View {
    let count: Int
    @EnvironmentObject private var cleaner: Cleaner

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 14)
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.green.gradient))
            VStack(alignment: .leading, spacing: 0) {
                Text("Time Machine snapshots").font(.system(size: 11.5, weight: .medium))
                Text("\(count) local snapshot\(count == 1 ? "" : "s") holding deleted files' space").font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
            Spacer()
            Button("Delete") { cleaner.deleteSnapshots() }
                .buttonStyle(NotchPillButtonStyle(height: 20))
                .help("Asks for your password")
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
    }
}

private struct Checkbox: View {
    let on: Bool
    var small = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: small ? 11 : 14))
                .foregroundStyle(on ? Color.white : .white.opacity(0.3))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}

private struct UninstallView: View {
    @EnvironmentObject private var uninstaller: AppUninstaller
    @State private var confirming = false

    var body: some View {
        if let target = uninstaller.target {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: target.appURL.path)).resizable().frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Uninstall \(target.name)").font(.system(size: 12.5, weight: .semibold))
                        Text(uninstaller.searching ? "Looking for its files…"
                             : "\(formatBytes(target.total)) · app and \(target.leftovers.count) support item\(target.leftovers.count == 1 ? "" : "s")")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Button("Cancel") { uninstaller.cancel() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    if uninstaller.removing {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Button(confirming ? "Click to Confirm" : uninstaller.isRunning ? "Quit & Uninstall" : "Move to Trash") {
                            if confirming { confirming = false; uninstaller.uninstall() } else {
                                confirming = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirming = false }
                            }
                        }
                        .buttonStyle(NotchPillButtonStyle(primary: !confirming, height: 24))
                        .disabled(uninstaller.searching)
                    }
                }
                if let message = uninstaller.message {
                    Text(message).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 1) {
                        row(url: target.appURL, size: target.appSize, removable: false)
                        ForEach(target.leftovers) { item in row(url: item.url, size: item.size, removable: true) }
                    }
                }
            }
        }
    }

    private func row(url: URL, size: Int64, removable: Bool) -> some View {
        let included = !uninstaller.excluded.contains(url)
        return HStack(spacing: 8) {
            if removable {
                Checkbox(on: included, small: true) {
                    if included { uninstaller.excluded.insert(url) } else { uninstaller.excluded.remove(url) }
                }
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 14, height: 14)
            Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(included ? 0.8 : 0.4))
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 6)
            Text(size > 0 ? formatBytes(size) : "–").font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
    }
}
