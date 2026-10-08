import SwiftUI
import UniformTypeIdentifiers

enum ToolsPane: String {
    case network, vpn, cleaner, devices
    static let options: [(value: ToolsPane, title: String)] = [(.network, "Network"), (.vpn, "VPN"), (.cleaner, "Cleaner"), (.devices, "Devices")]
}

/// Tools tab: network (live traffic, connection details, speed test), a cleaner with an app
/// uninstaller, and Bluetooth battery levels.
struct ToolsView: View {
    @ObservedObject var viewModel: NotchViewModel
    @AppStorage("tools.pane") private var pane: ToolsPane = .network

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PaneSwitcher(selection: $pane, options: ToolsPane.options)
                Spacer()
                PaneAccessory(pane: pane)
            }
            Group {
                switch pane {
                case .network: NetworkPane()
                case .vpn: VPNPane()
                case .cleaner: CleanerPane()
                case .devices: DevicesPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The small actions at the right of the pane switcher.
private struct PaneAccessory: View {
    let pane: ToolsPane
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var cleaner: Cleaner
    @EnvironmentObject private var uninstaller: AppUninstaller
    @EnvironmentObject private var devices: DeviceBatteries
    @EnvironmentObject private var vpn: VPNMonitor

    var body: some View {
        switch pane {
        case .vpn:
            TextButton(vpn.loading ? "Checking…" : "Refresh") { vpn.refresh(exitInfo: true) }
        case .network:
            TextButton(network.pinging ? "Checking…" : "Refresh") { network.refreshDetails(force: true) }
                .disabled(network.pinging)
        case .cleaner:
            if uninstaller.target == nil {
                HStack(spacing: 12) {
                    if let scanned = cleaner.scanned, !cleaner.scanning {
                        Text("Scanned " + scanned.formatted(.relative(presentation: .named)))
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    }
                    TextButton(cleaner.scanning ? "Scanning…" : "Rescan") { cleaner.scan() }
                        .disabled(cleaner.scanning || cleaner.cleaning)
                }
            }
        case .devices:
            TextButton("Refresh") { devices.refresh() }
        }
    }
}

private struct TextButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
    }
}

enum ToolsPalette {
    static let down = Color(red: 0.32, green: 0.72, blue: 1)
    static let up = Color(red: 0.98, green: 0.55, blue: 0.3)
    static let good = Color(red: 0.4, green: 0.88, blue: 0.55)
}

// MARK: - Network

private struct NetworkPane: View {
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        HStack(spacing: 10) {
            SpeedTestCard()
                .frame(width: 210)
            TrafficCard()
                .frame(maxWidth: .infinity)
            ConnectionCard()
                .frame(width: 200)
        }
        .onAppear { network.viewerAppeared() }
        .onDisappear { network.viewerDisappeared() }
    }
}

private struct Card<Content: View>: View {
    var tint: Color = .white
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.1), .white.opacity(0.035)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }
}

private struct CardTitle: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(height: 16)
    }
}

private struct SpeedTestCard: View {
    @EnvironmentObject private var speed: SpeedTest
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        Card(tint: ToolsPalette.good) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    CardTitle(title: "Speed Test", icon: "speedometer", tint: ToolsPalette.good)
                    Spacer()
                    if speed.phase.isRunning {
                        Button("Stop") { speed.cancel() }
                            .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer(minLength: 4)
                content
                Spacer(minLength: 4)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch speed.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                if let last = speed.last {
                    ResultRow(result: last, compact: true)
                    Text("Last run " + last.date.formatted(.relative(presentation: .named)))
                        .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.35))
                } else {
                    Text("Download, upload and responsiveness, measured against Apple's servers.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Run Test") { speed.start() }
                    .buttonStyle(NotchPillButtonStyle(primary: true, height: 24))
            }
        case .connecting, .download, .upload:
            VStack(alignment: .leading, spacing: 4) {
                Text(speed.phase == .connecting ? "Connecting…" : speed.phase == .download ? "Download" : "Upload")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(speed.phase == .upload ? ToolsPalette.up : ToolsPalette.down)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(speed.phase == .connecting ? "–" : formatMbps(speed.liveSpeed))
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        .rollingNumber(formatMbps(speed.liveSpeed))
                    Text("Mbps").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.45))
                }
                PhaseBar(phase: speed.phase)
            }
        case .done(let result):
            VStack(alignment: .leading, spacing: 8) {
                ResultRow(result: result, compact: false)
                HStack(spacing: 8) {
                    Button("Again") { speed.start() }
                        .buttonStyle(NotchPillButtonStyle(height: 22))
                    Button("Done") { speed.reset() }
                        .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                Button("Try Again") { speed.start() }
                    .buttonStyle(NotchPillButtonStyle(height: 22))
            }
        }
    }

    private struct PhaseBar: View {
        let phase: SpeedTest.Phase

        var body: some View {
            HStack(spacing: 3) {
                segment(active: phase == .download, done: phase == .upload, color: ToolsPalette.down)
                segment(active: phase == .upload, done: false, color: ToolsPalette.up)
            }
            .frame(height: 4)
        }

        private func segment(active: Bool, done: Bool, color: Color) -> some View {
            Capsule()
                .fill(done ? color.opacity(0.9) : active ? color : .white.opacity(0.1))
                .phaseAnimator(active ? [0.55, 1] : [1]) { content, opacity in content.opacity(opacity) } animation: { _ in
                    .easeInOut(duration: 0.7)
                }
        }
    }
}

private struct ResultRow: View {
    let result: SpeedTest.Result
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                value("arrow.down", formatMbps(result.download), ToolsPalette.down)
                value("arrow.up", formatMbps(result.upload), ToolsPalette.up)
            }
            if !compact {
                HStack(spacing: 10) {
                    if let label = result.responsivenessLabel, let rpm = result.responsiveness {
                        detail("Responsiveness", "\(label) · \(Int(rpm)) RPM")
                    }
                    if let latency = result.latency { detail("Latency", "\(Int(latency.rounded())) ms") }
                }
            }
        }
    }

    private func value(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            Text(text).font(.system(size: compact ? 18 : 22, weight: .semibold, design: .rounded).monospacedDigit())
            Text("Mbps").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
        }
    }
}

private struct TrafficCard: View {
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        Card(tint: ToolsPalette.down) {
            VStack(alignment: .leading, spacing: 4) {
                CardTitle(title: "Traffic", icon: "arrow.up.arrow.down", tint: ToolsPalette.down)
                HStack(spacing: 14) {
                    rate("arrow.down", network.downRate, ToolsPalette.down)
                    rate("arrow.up", network.upRate, ToolsPalette.up)
                }
                RateGraph(down: network.downHistory, up: network.upHistory)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func rate(_ icon: String, _ bytes: Double, _ color: Color) -> some View {
        let r = formatRate(bytes)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            Text(r.value).font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
            Text(r.unit).font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

/// Download as an area above the axis, upload mirrored below it, on a shared scale.
private struct RateGraph: View {
    let down: [Double]
    let up: [Double]

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height * 0.62
            let peak = max(64_000, (down + up).max() ?? 0) * 1.15
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: mid))
            axis.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(axis, with: .color(.white.opacity(0.1)), lineWidth: 1)
            draw(down, above: true, room: mid, peak: peak, color: ToolsPalette.down, ctx: &ctx, size: size, mid: mid)
            draw(up, above: false, room: size.height - mid, peak: peak, color: ToolsPalette.up, ctx: &ctx, size: size, mid: mid)
        }
    }

    private func draw(_ values: [Double], above: Bool, room: CGFloat, peak: Double, color: Color,
                      ctx: inout GraphicsContext, size: CGSize, mid: CGFloat) {
        // A couple of points just draw a tick at the edge; wait for a few seconds of history.
        guard values.count > 3 else { return }
        let step = size.width / CGFloat(NetworkMonitor.historyLength - 1)
        let points = values.enumerated().map { i, v in
            CGPoint(x: size.width - CGFloat(values.count - 1 - i) * step,
                    y: mid + (above ? -1 : 1) * room * CGFloat(min(1, v / peak)))
        }
        var line = Path()
        line.addLines(points)
        var area = line
        area.addLine(to: CGPoint(x: points.last!.x, y: mid))
        area.addLine(to: CGPoint(x: points.first!.x, y: mid))
        area.closeSubpath()
        ctx.fill(area, with: .color(color.opacity(0.28)))
        ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
    }
}

private struct ConnectionCard: View {
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        let info = network.info
        Card {
            VStack(alignment: .leading, spacing: 3.5) {
                HStack(spacing: 4) {
                    CardTitle(title: title(info), icon: icon(info), tint: .white.opacity(0.8))
                    Spacer(minLength: 0)
                    if let q = info.signalQuality { SignalBars(quality: q) }
                }
                if info.kind == .offline {
                    Text("Not connected").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                } else {
                    if let rssi = info.rssi {
                        InfoRow(label: "Signal", value: "\(rssi) dBm" + (info.channel.map { " · " + $0.components(separatedBy: " · ")[0] } ?? ""),
                                help: [info.channel, info.txRateMbps.map { "Link \(Int($0)) Mbps" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    InfoRow(label: "Local IP", value: info.localIP ?? "–", copyable: info.localIP)
                    InfoRow(label: "Public IP", value: network.publicInfo?.ip ?? "–", copyable: network.publicInfo?.ip,
                            help: network.publicInfo?.location)
                    PingRow(router: network.routerPing, internet: network.internetPing, pinging: network.pinging)
                    if let vpn = info.vpn {
                        InfoRow(label: vpn, value: info.tailscaleIP ?? "On", copyable: info.tailscaleIP, tint: ToolsPalette.good)
                    }
                }
            }
        }
    }

    private func title(_ info: NetworkMonitor.Info) -> String {
        if info.kind == .wifi { return info.ssid ?? "Wi-Fi" }
        return info.kind == .offline ? "Offline" : info.interfaceName
    }

    private func icon(_ info: NetworkMonitor.Info) -> String {
        switch info.kind {
        case .wifi: "wifi"
        case .ethernet: "cable.connector.horizontal"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .vpn: "lock.shield.fill"
        case .other: "network"
        case .offline: "wifi.slash"
        }
    }

}

/// "Ping   2 ms · 18 ms": the router, then the internet (1.1.1.1), each colored by how quick it is.
private struct PingRow: View {
    let router: Double?
    let internet: Double?
    let pinging: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("Ping").foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 4)
            Text(ms(router)).foregroundStyle(color(router, ok: 10, slow: 40))
                .help("Your router")
            Text("·").foregroundStyle(.white.opacity(0.3))
            Text(ms(internet)).foregroundStyle(color(internet, ok: 40, slow: 120))
                .help("The internet (1.1.1.1)")
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .lineLimit(1)
    }

    private func ms(_ v: Double?) -> String {
        guard let v else { return pinging ? "…" : "–" }
        return v < 10 ? String(format: "%.1f ms", v) : "\(Int(v.rounded())) ms"
    }

    private func color(_ v: Double?, ok: Double, slow: Double) -> Color {
        guard let v else { return .white.opacity(0.6) }
        return v <= ok ? ToolsPalette.good : v <= slow ? Color(red: 1, green: 0.8, blue: 0.3) : Color(red: 1, green: 0.4, blue: 0.35)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var copyable: String?
    var help: String?
    var tint: Color = .white.opacity(0.85)
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 4)
            Text(copied ? "Copied" : value)
                .foregroundStyle(copied ? ToolsPalette.good : tint)
                .textSelection(.disabled)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let copyable else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyable, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
        .help(help ?? (copyable != nil ? "Click to copy" : ""))
    }
}

private struct SignalBars: View {
    let quality: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Double(i) < (quality * 4).rounded(.up) ? Color.white.opacity(0.85) : .white.opacity(0.18))
                    .frame(width: 3, height: 4 + CGFloat(i) * 2.5)
            }
        }
    }
}

// MARK: - Cleaner

private struct CleanerPane: View {
    @EnvironmentObject private var cleaner: Cleaner
    @EnvironmentObject private var uninstaller: AppUninstaller
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 6) {
                DiskCard()
                UninstallDrop(targeted: dropTargeted)
            }
            .frame(width: 180)

            Group {
                if uninstaller.target != nil {
                    UninstallView()
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    CardTitle(title: "Disk", icon: "internaldrive.fill", tint: .pink)
                    Spacer(minLength: 2)
                    if let disk = cleaner.disk {
                        Text(formatBytes(disk.available))
                            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("free").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
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
        HStack(spacing: 8) {
            Image(systemName: "xmark.app.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(targeted ? 0.95 : 0.6))
            VStack(alignment: .leading, spacing: 1) {
                Text("Uninstall an app").font(.system(size: 11, weight: .semibold))
                Text(uninstaller.message ?? "Drop it here, or click").font(.system(size: 9.5))
                    .foregroundStyle(uninstaller.message != nil ? .orange : .white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(targeted ? 0.6 : 0.18), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(targeted ? 0.1 : 0.03)))
        .contentShape(Rectangle())
        .onTapGesture { pickApp() }
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
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded = expanded == id ? nil : id }
                            }
                            if expanded == id, id != .trash {
                                ForEach(category.items.prefix(30)) { item in
                                    ItemRow(item: item, category: id)
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

// MARK: - Devices

private struct DevicesPane: View {
    @EnvironmentObject private var devices: DeviceBatteries
    @EnvironmentObject private var privacy: PrivacyMonitor
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            if devices.devices.isEmpty {
                Card {
                    VStack(spacing: 6) {
                        Image(systemName: "airpods").font(.system(size: 20))
                        Text("No Bluetooth devices with a battery are connected")
                            .font(.system(size: 11)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(devices.devices) { DeviceCard(device: $0).frame(width: 150) }
                    }
                }
            }
            PrivacyCard().frame(width: 170)
        }
        .onAppear { devices.refresh() }
    }
}

private struct DeviceCard: View {
    let device: DeviceBatteries.Device

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: device.icon).font(.system(size: 15)).foregroundStyle(.white.opacity(0.85))
                    Text(device.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if device.left != nil || device.right != nil {
                    level("L", device.left)
                    level("R", device.right)
                    if let c = device.caseLevel { level("Case", c) }
                } else {
                    level(nil, device.main)
                }
            }
        }
    }

    private func level(_ label: String?, _ value: Int?) -> some View {
        HStack(spacing: 6) {
            if let label {
                Text(label).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).frame(width: 26, alignment: .leading)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(color(value).gradient).frame(width: geo.size.width * Double(value ?? 0) / 100)
                }
            }
            .frame(height: 5)
            Text(value.map { "\($0)%" } ?? "–")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func color(_ v: Int?) -> Color {
        guard let v else { return .gray }
        return v <= 20 ? .red : v <= 40 ? .orange : ToolsPalette.good
    }
}

private struct PrivacyCard: View {
    @EnvironmentObject private var privacy: PrivacyMonitor
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Card(tint: privacy.isActive ? .orange : .white) {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle(title: "Mic & Camera", icon: "eye.fill", tint: privacy.isActive ? .orange : .white.opacity(0.6))
                if !settings.privacyAlerts && !LiveActivities.shared.wantsPrivacy {
                    Text("Turn on mic and camera alerts to see which apps are listening.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Turn On") { settings.privacyAlerts = true; PrivacyMonitor.shared.update() }
                        .buttonStyle(NotchPillButtonStyle(height: 22))
                } else {
                    status("mic.fill", "Microphone", privacy.micInUse)
                    ForEach(privacy.micApps) { app in
                        HStack(spacing: 5) {
                            AppIcon(bundlePath: app.bundlePath, size: 13)
                            Text(app.name).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                        .padding(.leading, 18)
                    }
                    status("video.fill", "Camera", privacy.cameraInUse)
                }
            }
        }
    }

    private func status(_ icon: String, _ label: String, _ on: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(on ? .orange : .white.opacity(0.4)).frame(width: 12)
            Text(label).font(.system(size: 11, weight: .medium))
            Spacer()
            Text(on ? "In use" : "Off").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? .orange : .white.opacity(0.35))
        }
    }
}

// MARK: - VPN

private struct VPNPane: View {
    @EnvironmentObject private var vpn: VPNMonitor
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        HStack(spacing: 10) {
            if vpn.connections.isEmpty {
                Card {
                    VStack(spacing: 6) {
                        Image(systemName: "shield.slash").font(.system(size: 20))
                        Text(vpn.loading ? "Looking for VPNs…" : "No VPNs set up on this Mac")
                            .font(.system(size: 11.5, weight: .medium))
                        Text("Proton VPN, Tailscale, NordVPN, WireGuard and others show up once their app has added its VPN profile. PIA and Mullvad are read through their command-line tools.")
                            .font(.system(size: 10)).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.35))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if vpn.connections.count == 1, let only = vpn.connections.first {
                // One VPN: its card matches the height of the card beside it.
                VPNRow(connection: only, fills: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(vpn.connections) { VPNRow(connection: $0) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            ExitCard().frame(width: 200)
        }
        .onAppear {
            vpn.refresh(exitInfo: vpn.exit == nil)
            network.viewerAppeared()
        }
        .onDisappear { network.viewerDisappeared() }
    }
}

private struct VPNRow: View {
    let connection: VPNMonitor.Connection
    var fills = false
    @EnvironmentObject private var vpn: VPNMonitor
    @State private var expanded = false

    var body: some View {
        let c = connection
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ZStack {
                    if let app = c.appURL {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "lock.shield.fill").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 26, height: 26)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                Spacer(minLength: 6)
                if c.appURL != nil {
                    Button { vpn.open(c) } label: { Image(systemName: "arrow.up.forward.app").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(NotchIconButtonStyle(size: 22))
                        .help("Open \(c.name)")
                }
                if c.source != .tunnel {
                    Button(c.isUp || c.status == .connecting ? "Disconnect" : "Connect") { vpn.toggle(c) }
                        .buttonStyle(NotchPillButtonStyle(primary: !c.isUp, height: 22))
                }
            }
            if c.isUp {
                let extra = vpn.extras[c.id]
                FlowDetails(items: [
                    c.server.map { ("server.rack", $0, "Server") },
                    extra?.region.map { ("mappin.and.ellipse", $0, "Region") },
                    c.tunnelAddresses.first.map { ("number", $0, "Tunnel address") },
                    c.protocolName.map { ("lock.fill", $0, "Protocol") },
                    ("arrow.triangle.branch", c.fullTunnel ? "All traffic" : "Split tunnel",
                     c.fullTunnel ? "Everything goes through the VPN" : "Only some networks go through the VPN"),
                    extra?.portForward.map { ("arrow.left.arrow.right", "Port " + $0, "Forwarded port") },
                    c.dns.first.map { ("text.magnifyingglass", "DNS " + $0, "DNS: " + c.dns.joined(separator: ", ")) },
                ].compactMap { $0 })
                if let warning = vpn.dnsWarning(for: c) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5)).foregroundStyle(.orange).lineLimit(1)
                }
            }
        }
        // Same card as the others in Tools (Card): radius, padding and tinted fill.
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [(c.isUp ? statusColor : Color.white).opacity(0.1), .white.opacity(0.035)],
                                 startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(c.isUp ? statusColor.opacity(0.3) : .white.opacity(0.07), lineWidth: 1))
    }

    private var statusColor: Color {
        switch connection.status {
        case .connected: ToolsPalette.good
        case .connecting, .disconnecting: .orange
        default: .white.opacity(0.3)
        }
    }

    private var subtitle: String {
        var parts = [connection.status.label]
        if connection.isUp, let since = connection.since {
            parts.append("for " + Self.duration(Date().timeIntervalSince(since)))
        }
        if let iface = connection.interface, connection.isUp { parts.append(iface) }
        return parts.joined(separator: " · ")
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 60 { return "\(max(1, m))m" }
        let h = m / 60
        return h < 24 ? "\(h)h \(m % 60)m" : "\(h / 24)d \(h % 24)h"
    }
}

/// Small icon + value chips that wrap onto as many lines as they need.
private struct FlowDetails: View {
    let items: [(icon: String, text: String, help: String)]

    var body: some View {
        WrapLayout(spacing: 5) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 3) {
                    Image(systemName: items[i].icon).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                    Text(items[i].text).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(.white.opacity(0.07)))
                .help(items[i].help)
            }
        }
    }
}

private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// Where traffic leaves for the internet: the address sites see, its city and provider.
private struct ExitCard: View {
    @EnvironmentObject private var vpn: VPNMonitor
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        let protected = vpn.connections.contains { $0.isUp && $0.fullTunnel }
        Card(tint: protected ? ToolsPalette.good : .orange) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    CardTitle(title: "Seen as", icon: protected ? "lock.shield.fill" : "globe", tint: protected ? ToolsPalette.good : .orange)
                    Spacer()
                    Text(protected ? "Via VPN" : "Direct")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(protected ? ToolsPalette.good : .orange)
                }
                if let exit = vpn.exit {
                    HStack(spacing: 5) {
                        if !exit.flag.isEmpty { Text(exit.flag).font(.system(size: 16)) }
                        Text(exit.place.isEmpty ? "Unknown place" : exit.place)
                            .font(.system(size: 12.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    InfoRow(label: "IP", value: exit.ip, copyable: exit.ip)
                    if let org = exit.org { InfoRow(label: "Provider", value: org) }
                    InfoRow(label: "Latency", value: network.internetPing.map { "\(Int($0.rounded())) ms" } ?? "–")
                } else {
                    Text(vpn.loading ? "Checking…" : "Couldn't look up your address")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }
}
