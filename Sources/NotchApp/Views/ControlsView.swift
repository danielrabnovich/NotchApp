import SwiftUI

/// Controls tab: volume and brightness sliders, and quick toggles and actions.
struct ControlsView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var controls: ControlsService
    @EnvironmentObject private var keepAwake: KeepAwake
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if updates.listOpen {
            UpdatesList(onBack: { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { updates.listOpen = false } })
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            controlsBody
                .transition(.opacity)
        }
    }

    private var controlsBody: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 10) {
                PillSlider(icon: volumeIcon, value: controls.volume) { controls.setVolume($0) }
                if Brightness.isAvailable {
                    PillSlider(icon: "sun.max.fill", value: controls.brightness) { controls.setBrightness($0) }
                }
                Spacer(minLength: 0)
                if settings.updateChecks {
                    UpdatesCard { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { updates.listOpen = true } }
                }
                if let error = controls.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .onTapGesture { controls.clearError() }
                }
            }
            .frame(width: 210)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ControlTile(icon: controls.wifiOn ? "wifi" : "wifi.slash", title: "Wi-Fi", on: controls.wifiOn) {
                    controls.toggleWiFi()
                }
                KeepAwakeTile()
                ControlTile(icon: "circle.lefthalf.filled", title: "Dark Mode", on: controls.darkMode) {
                    controls.toggleDarkMode()
                }
                ControlTile(icon: controls.micMuted ? "mic.slash.fill" : "mic.fill", title: controls.micMuted ? "Mic Off" : "Mic On",
                            on: controls.micMuted, onTint: .red) {
                    controls.toggleMic()
                }
                ControlTile(icon: "camera.viewfinder", title: "Screenshot", on: false) {
                    viewModel.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { controls.screenshot() }
                }
                ControlTile(icon: "eyedropper", title: "Color Picker", on: false) {
                    viewModel.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { controls.pickColor() }
                }
                ControlTile(icon: "lock.fill", title: "Lock Screen", on: false) {
                    viewModel.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { controls.lockScreen() }
                }
                ControlTile(icon: "trash.fill", title: controls.confirmingTrash ? "Click Again" : "Empty Trash",
                            on: controls.confirmingTrash, onTint: .red) {
                    controls.emptyTrash()
                }
            }
        }
        .onAppear { controls.refresh() }
    }

    private var volumeIcon: String {
        controls.volume <= 0.001 ? "speaker.slash.fill" : controls.volume < 0.34 ? "speaker.wave.1.fill"
            : controls.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// A wide Control Center-style slider: drag anywhere on it to set the level.
private struct PillSlider: View {
    let icon: String
    let value: Float
    let onChange: (Float) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: max(geo.size.height, geo.size.width * CGFloat(min(1, max(0, value)))))
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.7))
                    .frame(width: geo.size.height)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onChange(Float(min(1, max(0, g.location.x / max(geo.size.width, 1)))))
            })
        }
        .frame(height: 30)
    }
}

private struct ControlTile: View {
    let icon: String
    let title: String
    let on: Bool
    var onTint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ControlTileLabel(icon: icon, title: title, on: on, onTint: onTint)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

private struct ControlTileLabel: View {
    let icon: String
    let title: String
    let on: Bool
    let onTint: Color
    @State private var hovering = false

    var body: some View {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? (onTint == .white ? Color.black : .white) : .white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(on ? onTint : .white.opacity(hovering ? 0.16 : 0.1)))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Keep Awake: click to stop when on; otherwise pick how long (Amphetamine-style).
private struct KeepAwakeTile: View {
    @EnvironmentObject private var keepAwake: KeepAwake

    var body: some View {
        if keepAwake.isActive {
            ControlTile(icon: "cup.and.saucer.fill", title: keepAwake.remainingText.map { "Awake · \($0)" } ?? "Awake", on: true) {
                keepAwake.stop()
            }
            .help("Click to let your Mac sleep again")
        } else {
            ControlTile(icon: "cup.and.saucer.fill", title: "Keep Awake", on: false) {
                PopUpMenu.show(KeepAwake.Length.presets.map { length in (length.label, { keepAwake.start(length) }) },
                               title: "Keep awake for")
            }
            .help("Keep your Mac awake for…")
        }
    }
}

/// "3 updates available" under the sliders; opens the list.
private struct UpdatesCard: View {
    let action: () -> Void
    @EnvironmentObject private var updates: UpdateChecker
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: updates.updates.isEmpty ? "checkmark.seal.fill" : "arrow.down.app.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(updates.updates.isEmpty ? Color.green : Color.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11.5, weight: .semibold))
                    Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 0)
                if updates.checking { ProgressView().controlSize(.mini).tint(.white) }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .notchSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), active: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var title: String {
        if updates.updates.isEmpty { return updates.lastChecked == nil ? "Software updates" : "Everything's up to date" }
        return updates.updates.count == 1 ? "1 update available" : "\(updates.updates.count) updates available"
    }

    private var subtitle: String {
        if updates.checking { return "Checking…" }
        guard let last = updates.lastChecked else { return "Homebrew and apps" }
        return "Checked " + last.formatted(.relative(presentation: .named))
    }
}

/// Every available update, with Update buttons.
private struct UpdatesList: View {
    let onBack: () -> Void
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(NotchIconButtonStyle(size: 22))
                Text("Updates").font(.system(size: 13, weight: .semibold))
                if updates.checking { ProgressView().controlSize(.mini).tint(.white) }
                Spacer()
                Button("Check Now") { updates.check() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .disabled(updates.checking)
                if updates.updates.contains(where: { $0.appURL == nil }) {
                    Button("Update All Homebrew") { updates.upgradeAllHomebrew() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
            if let error = updates.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
            }
            if updates.updates.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(.green)
                    Text(updates.checking ? "Checking for updates…" : "Everything's up to date").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(updates.updates) { UpdateRow(update: $0) }
                    }
                }
            }
        }
    }
}

private struct UpdateRow: View {
    let update: UpdateChecker.Update
    @EnvironmentObject private var updates: UpdateChecker
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(update.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(update.installed) → \(update.available) · \(sourceLabel)")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if updates.upgrading.contains(update.name) {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Button(update.appURL == nil ? "Update" : "Open") { updates.upgrade(update) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(Capsule().fill(.white.opacity(hovering ? 0.2 : 0.12)))
                    .help(update.appURL == nil ? "brew upgrade \(update.name)" : "Opens the app so it can install its update")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        if let url = update.appURL ?? appForCask {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "shippingbox.fill").font(.system(size: 14)).foregroundStyle(Color(red: 0.98, green: 0.73, blue: 0.25))
        }
    }

    /// Casks are usually apps in /Applications; show their real icon when we can find it.
    private var appForCask: URL? {
        guard update.source == .cask else { return nil }
        let guess = update.name.replacingOccurrences(of: "-", with: " ")
        return AppIndex.shared.search(guess, limit: 1).first.flatMap { $0.score >= 85 ? $0.app.url : nil }
    }

    private var sourceLabel: String {
        switch update.source {
        case .formula: "Homebrew"
        case .cask: "Homebrew cask"
        case .sparkle: "App"
        }
    }
}

/// A plain NSMenu at the pointer, for choices that don't fit a SwiftUI Menu's look.
@MainActor
enum PopUpMenu {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    static func show(_ items: [(String, () -> Void)], title: String? = nil) {
        let menu = NSMenu()
        if let title {
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }
        var targets: [Target] = []
        for (label, action) in items {
            let target = Target(action)
            targets.append(target)
            let item = NSMenuItem(title: label, action: #selector(Target.run), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        // popUp blocks until the menu closes, so the targets stay alive long enough.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(targets) {}
    }
}
