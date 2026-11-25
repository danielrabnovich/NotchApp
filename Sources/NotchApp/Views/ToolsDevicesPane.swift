import SwiftUI
import UniformTypeIdentifiers

// Tools › Devices and VPN: batteries of nearby devices, the mic and camera, and VPN connections.

// MARK: - Devices

struct DevicesPane: View {
    @EnvironmentObject private var devices: DeviceBatteries
    @EnvironmentObject private var privacy: PrivacyMonitor
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 18) {
            if devices.devices.isEmpty {
                Card {
                    VStack(spacing: 6) {
                        Image(systemName: "airpods.pro").font(.system(size: 20))
                        Text("No Bluetooth devices with a battery are connected")
                            .font(.system(size: 11)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(devices.devices) { DeviceCard(device: $0).frame(width: 150) }
                    }
                }
                .scrollEdgeFade()
            }
            SectionDivider()
            PrivacyCard().frame(width: 180)
        }
        .padding(.top, 4)
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
                    Text(device.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
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

struct VPNPane: View {
    @EnvironmentObject private var vpn: VPNMonitor
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        // The VPN carrying all traffic also shows where sites see you; the rest only themselves.
        let carrier = vpn.connections.first { $0.isUp && $0.fullTunnel }?.id
        let columns = vpn.connections.count > 1 ? 2 : 1
        VStack(spacing: 6) {
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
            } else if vpn.connections.count <= 2 {
                // One or two VPNs: side by side at equal widths, filling the pane.
                HStack(spacing: 18) {
                    ForEach(vpn.connections) { c in
                        if c.id != vpn.connections.first?.id { SectionDivider() }
                        VPNRow(connection: c, showsExit: c.id == carrier, fills: true)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22, alignment: .top), count: columns), spacing: 14) {
                        ForEach(vpn.connections) { VPNRow(connection: $0, showsExit: $0.id == carrier) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if carrier == nil, let exit = vpn.exit {
                // Nothing tunnels all traffic: say so, with the address sites see.
                HStack(spacing: 5) {
                    if !exit.flag.isEmpty { Text(exit.flag).font(.system(size: 10)) }
                    Text("No VPN carries your traffic · sites see " + exit.ip + (exit.place.isEmpty ? "" : " in " + exit.place))
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.orange.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
            }
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
    /// This VPN carries all traffic: also show where sites see you through it.
    var showsExit = false
    var fills = false
    @EnvironmentObject private var vpn: VPNMonitor
    @EnvironmentObject private var network: NetworkMonitor
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
                    Text(c.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
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
                FlowDetails(items: details(c))
                if let warning = vpn.dnsWarning(for: c) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5)).foregroundStyle(.orange).lineLimit(1)
                }
            }
        }
        // Unboxed, as Tools' other sections are (Card).
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .contextMenu {
            if showsExit, let ip = vpn.exit?.ip {
                MenuItem("Copy Public IP", "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ip, forType: .string)
                }
            }
        }
    }

    /// The tunnel's details, then (for the VPN carrying all traffic) where sites see you through it.
    private func details(_ c: VPNMonitor.Connection) -> [(icon: String, text: String, help: String)] {
        let extra = vpn.extras[c.id]
        let exit = showsExit ? vpn.exit : nil
        var items: [(icon: String, text: String, help: String)?] = [
            c.server.map { ("server.rack", $0, "Server") },
            extra?.region.map { ("mappin.and.ellipse", $0, "Region") },
            c.tunnelAddresses.first.map { ("number", $0, "Tunnel address" + (c.interface.map { " on " + $0 } ?? "")) },
            c.protocolName.map { ("lock.fill", $0, "Protocol") },
            // Showing where sites see you already says everything goes through it.
            exit == nil ? ("arrow.triangle.branch", c.fullTunnel ? "All traffic" : "Split tunnel",
                           c.fullTunnel ? "Everything goes through the VPN" : "Only some networks go through the VPN") : nil,
            extra?.portForward.map { ("arrow.left.arrow.right", "Port " + $0, "Forwarded port") },
            c.dns.first.map { ("text.magnifyingglass", "DNS " + $0, "DNS: " + c.dns.joined(separator: ", ")) },
        ]
        if let exit {
            let place = exit.city ?? exit.country ?? "Unknown place"
            items += [
                ("location.fill", (exit.flag.isEmpty ? "" : exit.flag + " ") + place, "Sites see you in " + (exit.place.isEmpty ? place : exit.place)),
                ("globe", exit.ip, "Public IP address sites see · right-click to copy"),
                exit.org.map { ("building.2", $0, "Exit provider") },
                network.internetPing.map { ("bolt.horizontal", "\(Int($0.rounded())) ms", "Latency") },
            ]
        }
        return items.compactMap { $0 }
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
