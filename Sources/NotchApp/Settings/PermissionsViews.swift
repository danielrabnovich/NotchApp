import SwiftUI

/// One permission as a row: its icon, what it unlocks, and its state (Allowed, or the button
/// that grants it). Statuses stay live while it's on screen.
struct PermissionCard: View {
    let kind: Permissions.Kind
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        let info = Permissions.info(kind)
        let status = permissions.status[kind] ?? .notAsked
        HStack(spacing: 12) {
            Image(systemName: info.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: info.tint).gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.system(size: 13, weight: .semibold))
                Text(info.unlocks)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch status {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.green.opacity(0.14)))
            case .denied:
                Button("Open Settings…") { permissions.openSettings(kind) }
                    .help("Turned off in System Settings: switch NotchApp on there")
            case .notAsked:
                Button("Allow…") { permissions.request(kind) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Settings → Permissions: every permission, by how much it matters.
struct PermissionsPane: View {
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        SettingsPage(pane: .permissions) {
            ForEach([Permissions.Level.essential, .recommended, .optional], id: \.self) { level in
                Section {
                    ForEach(Permissions.Kind.allCases.filter { Permissions.info($0).level == level }) { PermissionCard(kind: $0) }
                } header: {
                    Text(level.rawValue)
                } footer: {
                    if level == .optional {
                        FooterText("NotchApp only asks when you press Allow. Nothing it sees leaves your Mac unless you've chosen a cloud model in Search, and then only what you ask about.")
                    }
                }
            }
            Section {
                Button("Show the Welcome Window") { Onboarding.show() }
            }
        }
        .onAppear { permissions.watch(true) }
        .onDisappear { permissions.watch(false) }
    }
}

/// The first launch: what NotchApp is, the permissions worth granting now, and how to open it.
@MainActor
enum Onboarding {
    private static var window: NSWindow?

    /// Once ever: closing it counts as seen (Settings → Permissions has the same list, and reopens it).
    static func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "onboarded") else { return }
        UserDefaults.standard.set(true, forKey: "onboarded")
        show()
    }

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView { finish() }
                .environmentObject(AppSettings.shared))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 560, height: 680))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private static func finish() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        window?.close()
        // Show what it looks like, right where it lives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotchPresenter.shared.primary?.open(tab: .ask, takeKeyboard: true, reason: .keyboard)
        }
    }
}

private struct OnboardingView: View {
    let done: () -> Void
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                Text("Welcome to NotchApp")
                    .font(.system(size: 24, weight: .bold))
                Text("Your notch becomes a search bar, a shelf, your day at a glance, and actions for whatever app you're in.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .padding(.top, 40)
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group(.essential, note: "Needed for most of what makes NotchApp useful.")
                    group(.recommended, note: "Grant these now or when you first need them.")
                    group(.optional, note: "Each one asks on its own the first time you use its feature.")
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }

            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text("Hover over the notch, or press")
                    Text(HotKeys.combo(for: .search)?.display ?? "⌘Space")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
                    Text("to search.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Button(action: done) {
                    Text(permissions.essentialsGranted ? "Start Using NotchApp" : "Continue Without Accessibility")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .background(.bar)
        }
        .frame(width: 560, height: 680)
        .onAppear { permissions.watch(true) }
        .onDisappear { permissions.watch(false) }
    }

    private func group(_ level: Permissions.Level, note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(level.rawValue).font(.system(size: 13, weight: .bold))
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                let kinds = Permissions.Kind.allCases.filter { Permissions.info($0).level == level }
                ForEach(Array(kinds.enumerated()), id: \.element) { i, kind in
                    PermissionCard(kind: kind)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    if i < kinds.count - 1 { Divider().padding(.leading, 54) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}
