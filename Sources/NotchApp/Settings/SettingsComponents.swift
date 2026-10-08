import SwiftUI

/// A settings page: a header with the pane's icon, title and summary, then grouped sections.
/// An accessory, if given, stays put under the header while the sections scroll.
struct SettingsPage<Content: View, Accessory: View>: View {
    let pane: SettingsPane
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(pane: SettingsPane, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.pane = pane
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                PaneHeader(pane: pane)
                if Accessory.self != EmptyView.self {
                    accessory
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                }
            }
        }
    }
}

extension SettingsPage where Accessory == EmptyView {
    init(pane: SettingsPane, @ViewBuilder content: () -> Content) {
        self.init(pane: pane, accessory: { EmptyView() }, content: content)
    }
}

/// The page's title bar: a large icon, the title and what the page is for. Sits in the window's
/// (hidden) title bar area.
struct PaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(pane: pane, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(.system(size: 20, weight: .bold))
                Text(pane.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            PaneShortcuts(pane: pane)
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.97))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 1)
        }
    }
}

// MARK: - Sidebar

/// Raycast-style navigation: a search field that finds settings by what they do, the pages in
/// groups with on/off dots for features, and keyboard control (↑ ↓ ↩, ⌘F to search).
struct SettingsSidebar: View {
    @ObservedObject private var router = SettingsRouter.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var query = ""
    @FocusState private var searching: Bool
    @State private var highlighted: SettingsPane?

    private var results: [SettingsPane] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return SettingsPane.allCases.filter { $0.matches(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 40)
                .padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        if query.isEmpty {
                            ForEach(SettingsPane.Group.allCases, id: \.self) { group in
                                if !group.rawValue.isEmpty {
                                    Text(group.rawValue.uppercased())
                                        .font(.system(size: 10, weight: .semibold))
                                        .tracking(0.6)
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 12)
                                        .padding(.bottom, 4)
                                }
                                ForEach(SettingsPane.allCases.filter { $0.group == group }) { row($0) }
                            }
                        } else if results.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(.tertiary)
                                Text("No settings match “\(query)”").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                        } else {
                            ForEach(results) { row($0, hint: $0.matchHint(query)) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                // Only scrolls if the row is out of sight (picked by keyboard or search), and only as far as needed.
                .onChange(of: router.pane) { _, p in proxy.scrollTo(p) }
            }
            footer
        }
        .background(VisualEffect(material: .sidebar))
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            if let highlighted { router.pane = highlighted }
            searching = false
            return .handled
        }
        .background {
            // ⌘F jumps to search.
            Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).opacity(0)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searching)
                .onChange(of: query) { _, _ in highlighted = results.first }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            } else {
                Text("⌘F")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(searching ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: searching ? 1.5 : 1))
    }

    private func row(_ pane: SettingsPane, hint: String? = nil) -> some View {
        let selected = router.pane == pane
        let lit = selected || (!query.isEmpty && highlighted == pane)
        return Button {
            router.pane = pane
        } label: {
            HStack(spacing: 9) {
                SettingsIcon(pane: pane, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(pane.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let hint {
                        Text(hint).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let on = pane.enabled(settings)?.wrappedValue {
                    Circle()
                        .fill(on ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                        .help(on ? "On" : "Off")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: hint == nil ? 30 : 38)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.22) : lit ? Color.primary.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(pane)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text("NotchApp").font(.system(size: 11.5, weight: .semibold))
                Text("Version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Quit NotchApp")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 1) }
    }

    private func move(_ delta: Int) {
        let list = query.isEmpty ? SettingsPane.allCases : results
        guard !list.isEmpty else { return }
        let current = query.isEmpty ? router.pane : (highlighted ?? list[0])
        let i = list.firstIndex(of: current) ?? 0
        let next = list[(i + delta + list.count) % list.count]
        if query.isEmpty { router.pane = next } else { highlighted = next }
    }
}

/// An NSVisualEffectView, for the translucent sidebar.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

extension SettingsPane {
    /// Words people might search for that aren't in the title or summary.
    var keywords: [String] {
        switch self {
        case .general: ["open", "hover", "click", "display", "monitor", "menu bar", "fake notch", "login", "startup"]
        case .addOns: ["features", "tabs", "enable", "disable", "music", "calendar", "timer", "mixer", "stats", "tools", "agents", "clipboard"]
        case .appearance: ["accent", "color", "colour", "animation", "bouncy", "shadow", "theme"]
        case .live: ["live activities", "pin", "beside the notch", "menu bar", "cpu", "battery", "vpn", "network", "agents", "disk", "keep awake", "layout"]
        case .assistant: ["search", "ollama", "ai", "model", "web", "weather", "files", "pictures", "screenshots", "ocr", "notifications"]
        case .media: ["music", "spotify", "now playing", "visualizer", "volume", "mixer", "sound", "per-app"]
        case .hud: ["volume", "brightness", "overlay", "osd", "hud"]
        case .battery: ["charging", "plug", "power"]
        case .shelf: ["files", "drag", "drop", "airdrop", "taildrop", "tailscale", "screenshots", "downloads", "clipboard", "history", "yt-dlp", "youtube", "video", "convert", "ffmpeg", "gif", "quality"]
        case .tasks: ["todo", "reminders", "notes", "scratchpad", "due", "nudges", "brief"]
        case .timer: ["pomodoro", "stopwatch", "countdown", "focus", "sounds"]
        case .stats: ["cpu", "gpu", "memory", "ram", "temperature", "fahrenheit", "celsius", "fans", "power"]
        case .tools: ["network", "wifi", "speed test", "vpn", "proton", "pia", "mullvad", "ip", "ping", "cleaner", "disk", "uninstall", "bluetooth", "airpods", "battery", "microphone", "camera", "dev server", "ports", "alerts", "offline"]
        case .agents: ["claude", "claude code", "codex", "opencode", "zcode", "tokens", "usage", "keep awake", "ai agents"]
        case .calendar: ["events", "meetings", "zoom", "meet", "teams", "join", "alerts"]
        case .controls: ["quick actions", "tiles", "wifi", "dark mode", "ports", "copy text", "ocr", "night shift", "hidden files", "flush dns", "keep awake", "camera", "mirror"]
        case .mouse: ["scroll", "reverse", "middle click", "trackpad", "three finger"]
        case .updates: ["homebrew", "brew", "sparkle", "upgrade"]
        case .shortcuts: ["hotkeys", "keyboard", "keys", "⌃⌥", "hyper"]
        case .about: ["version", "credits"]
        }
    }

    func matches(_ q: String) -> Bool {
        title.lowercased().contains(q) || summary.lowercased().contains(q) || rawValue.lowercased().contains(q)
            || keywords.contains { $0.contains(q) }
    }

    /// Why a search matched, when it wasn't the title ("vpn, proton").
    func matchHint(_ query: String) -> String? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !title.lowercased().contains(q) else { return nil }
        let hits = keywords.filter { $0.contains(q) }.prefix(3)
        return hits.isEmpty ? nil : hits.joined(separator: ", ")
    }

    /// The feature's master switch, for pages that have one.
    @MainActor func enabled(_ s: AppSettings) -> Binding<Bool>? {
        func bind(_ path: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
            Binding(get: { s[keyPath: path] }, set: { s[keyPath: path] = $0 })
        }
        switch self {
        case .assistant: return bind(\.assistantEnabled)
        case .shelf: return bind(\.shelfEnabled)
        case .tasks: return bind(\.tasksEnabled)
        case .timer: return bind(\.timerEnabled)
        case .stats: return bind(\.statsEnabled)
        case .tools: return bind(\.toolsEnabled)
        case .agents: return bind(\.agentsEnabled)
        case .calendar: return bind(\.calendarEnabled)
        case .controls: return bind(\.controlsEnabled)
        case .updates: return bind(\.updateChecks)
        case .shortcuts: return bind(\.hotKeysEnabled)
        case .media: return Binding(get: { s.musicEnabled }, set: { s.musicEnabled = $0; s.musicLiveActivity = $0 })
        case .battery: return bind(\.chargingAnimation)
        default: return nil
        }
    }
}

/// The rounded, tinted icon tile used in the sidebar and page headers.
struct SettingsIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: pane.icon)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [pane.tint.opacity(0.95), pane.tint.opacity(0.75)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: pane.tint.opacity(0.25), radius: size * 0.08, y: size * 0.04)
    }
}

/// A toggle with a one-line explanation under its title.
struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            RowLabel(title: title, subtitle: subtitle)
        }
    }
}

struct RowLabel: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A macOS permission with its state: an "Allowed" pill, or a button to grant it.
struct PermissionRow: View {
    enum State { case granted, denied, unknown }

    let title: String
    var subtitle: String? = nil
    let state: State
    let request: () -> Void
    var openSettings: (() -> Void)? = nil

    var body: some View {
        LabeledContent {
            switch state {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.green.opacity(0.14)))
            case .denied:
                Button("Open System Settings…") { (openSettings ?? request)() }
            case .unknown:
                Button("Allow…", action: request)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: state == .granted ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(state == .granted ? Color.secondary : Color.orange)
                    .frame(width: 16)
                RowLabel(title: title, subtitle: subtitle)
            }
        }
    }
}

/// A section footer: small secondary text, aligned with the card's leading edge like System Settings.
struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The keyboard shortcuts that open a pane's feature, as keycaps in its header. Clicking one goes
/// to Keyboard Shortcuts to change it.
private struct PaneShortcuts: View {
    let pane: SettingsPane
    @ObservedObject private var settings = AppSettings.shared

    private var actions: [HotKeys.Action] {
        switch pane {
        case .assistant: [.search]
        case .media: [.home, .mixer]
        case .shelf: [.shelf, .downloads, .clipboard]
        case .tasks: [.tasks, .notes]
        case .timer: [.timer]
        case .stats: [.stats]
        case .tools: [.tools, .copyText]
        case .agents: [.agents]
        case .controls: [.controls, .camera]
        default: []
        }
    }

    var body: some View {
        if settings.hotKeysEnabled {
            HStack(spacing: 6) {
                ForEach(actions) { action in
                    if let combo = HotKeys.combo(for: action) {
                        Button { SettingsRouter.shared.pane = .shortcuts } label: {
                            Text(combo.display)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.06)))
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("\(action.title): \(combo.display). Click to change.")
                    }
                }
            }
        }
    }
}
