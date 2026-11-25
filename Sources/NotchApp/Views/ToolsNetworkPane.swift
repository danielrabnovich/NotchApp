import SwiftUI
import UniformTypeIdentifiers

// Tools › Network: the speed test, traffic and the connection.

// MARK: - Network

struct NetworkPane: View {
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        HStack(spacing: 18) {
            SpeedTestCard()
                .frame(width: 200)
            SectionDivider()
            TrafficCard()
                .frame(maxWidth: .infinity)
            SectionDivider()
            ConnectionCard()
                .frame(width: 200)
        }
        .padding(.top, 4)
        .onAppear { network.viewerAppeared() }
        .onDisappear { network.viewerDisappeared() }
    }
}

/// One of a pane's sections. No box: sections sit straight on the notch, as Home's do, with a
/// rule between them where they stand side by side (`SectionDivider`).
struct Card<Content: View>: View {
    var tint: Color = .white
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CardTitle: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        NotchSectionLabel(title: title, symbol: icon, tint: tint)
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
                    // The numbers lead; running it again is a link beside when it last ran.
                    ResultRow(result: last, compact: true)
                    HStack(spacing: 4) {
                        Text("Last run " + last.date.formatted(.relative(presentation: .named)) + " ·")
                            .foregroundStyle(.white.opacity(0.4))
                        Button("Run Again") { speed.start() }
                            .buttonStyle(NotchLinkButtonStyle())
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                } else {
                    Text("Download, upload and responsiveness, measured against Apple's servers.")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Run Test") { speed.start() }
                        .buttonStyle(NotchPillButtonStyle(primary: true, height: 24))
                }
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
            Text(text).font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
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
            Text(r.value).font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
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
            VStack(alignment: .leading, spacing: 4) {
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

/// "Ping   ⌂ 2 ms  🌐 18 ms": the router, then the internet (1.1.1.1), each with its glyph and colored
/// by how quick it is.
private struct PingRow: View {
    let router: Double?
    let internet: Double?
    let pinging: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("Ping").foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 4)
            // A glyph before each, so it's plain which is which without hovering.
            reading("wifi.router", ms(router), color(router, ok: 10, slow: 40))
                .help("To your router")
            reading("globe", ms(internet), color(internet, ok: 40, slow: 120))
                .padding(.leading, 6)
                .help("To the internet (1.1.1.1)")
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .lineLimit(1)
    }

    private func reading(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            // As tall as the digits beside it and nearly as bright, so it reads as their label.
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(text).foregroundStyle(color)
        }
    }

    private func ms(_ v: Double?) -> String {
        guard let v else { return pinging ? "…" : "–" }
        return "\(formatSmall(v)) ms"
    }

    private func color(_ v: Double?, ok: Double, slow: Double) -> Color {
        guard let v else { return .white.opacity(0.6) }
        return v <= ok ? ToolsPalette.good : v <= slow ? Color(red: 1, green: 0.8, blue: 0.3) : Color(red: 1, green: 0.4, blue: 0.35)
    }
}

struct InfoRow: View {
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
        .font(.system(size: 11, weight: .medium).monospacedDigit())
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
