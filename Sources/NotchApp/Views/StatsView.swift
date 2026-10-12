import SwiftUI

/// Live system stats: CPU, GPU, memory and power, each with a short history graph.
/// Values change every second and the notch rasterises on the CPU, so nothing here animates
/// between readings (tweens and numeric transitions cost ~20% CPU while open).
struct StatsView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var expanded: StatKind?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(StatKind.allCases) { kind in
                let mode = mode(for: kind)
                card(kind, mode: mode)
                    .frame(width: mode == .compact ? CardMode.compactWidth : nil)
                    .frame(maxWidth: mode == .compact ? CardMode.compactWidth : .infinity)
            }
        }
        .onAppear {
            monitor.viewerAppeared()
            // Opened from a Glance: show its card.
            if let kind = monitor.pendingCard, kind != expanded { toggle(kind) }
        }
        .onDisappear {
            monitor.viewerDisappeared()
            if expanded?.listsApps == true { monitor.detailDisappeared() }
        }
        .onChange(of: monitor.debugExpand) { _, command in
            let kind = StatKind(rawValue: String(command.prefix { $0 != "#" }))
            if kind != expanded { toggle(kind ?? expanded) }
        }
    }

    private func mode(for kind: StatKind) -> CardMode {
        guard let expanded else { return .normal }
        return expanded == kind ? .expanded : .compact
    }

    @ViewBuilder private func card(_ kind: StatKind, mode: CardMode) -> some View {
        let tap = { toggle(kind) }
        switch kind {
        case .cpu: CPUCard(mode: mode, onTap: tap)
        case .gpu: GPUCard(mode: mode, onTap: tap)
        case .memory: MemoryCard(mode: mode, onTap: tap)
        case .power: PowerCard(mode: mode, onTap: tap)
        }
    }

    /// Expands a card (or collapses it if it is already expanded). Per-app usage is only
    /// sampled while a card that lists apps is open.
    private func toggle(_ kind: StatKind?) {
        let next = kind == expanded ? nil : kind
        let wasListing = expanded?.listsApps == true
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { expanded = next }
        let isListing = next?.listsApps == true
        if isListing && !wasListing { monitor.detailAppeared() }
        if wasListing && !isListing { monitor.detailDisappeared() }
    }
}

enum StatKind: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, power
    var id: String { rawValue }
    var listsApps: Bool { self == .cpu || self == .memory }
}

private enum CardMode {
    case normal, expanded, compact
    static let compactWidth: CGFloat = 58
    /// Width of the summary column inside an expanded card.
    static let summaryWidth: CGFloat = 138
}

enum StatsPalette {
    static let cpu = Color(red: 0.30, green: 0.62, blue: 1.00)
    static let cpuSystem = Color(red: 1.00, green: 0.36, blue: 0.42)
    /// The fastest cluster ("Super" cores on M5, "Performance" before).
    static let cpuFast = Color(red: 1.00, green: 0.55, blue: 0.18)
    static let gpu = Color(red: 0.74, green: 0.47, blue: 1.00)
    static let memory = Color(red: 0.32, green: 0.86, blue: 0.56)
    static let memoryWired = Color(red: 1.00, green: 0.78, blue: 0.30)
    static let memoryCompressed = Color(red: 1.00, green: 0.45, blue: 0.62)
    static let power = Color(red: 1.00, green: 0.62, blue: 0.22)

    static func temperature(_ celsius: Double) -> Color {
        switch celsius {
        case ..<60: Color(red: 0.40, green: 0.88, blue: 0.55)
        case ..<80: Color(red: 1.00, green: 0.80, blue: 0.30)
        default: Color(red: 1.00, green: 0.38, blue: 0.35)
        }
    }
}

// MARK: - Cards

private struct CPUCard: View {
    let mode: CardMode
    let onTap: () -> Void
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        let s = monitor.snapshot
        StatCard(title: "CPU", icon: "cpu", tint: StatsPalette.cpu,
                 value: percent(s.cpuTotal), unit: "%", temperature: s.cpuTemp, mode: mode, onTap: onTap) {
            Sparkline(values: monitor.cpuHistory, under: monitor.cpuSystemHistory,
                      color: StatsPalette.cpu, underColor: StatsPalette.cpuSystem)
        } footer: {
            CoreBars(loads: s.cores, fast: monitor.performanceCores)
                .frame(height: 22)
        } detail: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    MiniStat(label: "User", value: percent(s.cpuUser) + "%", color: StatsPalette.cpu)
                    MiniStat(label: "System", value: percent(s.cpuSystem) + "%", color: StatsPalette.cpuSystem)
                    MiniStat(label: "Idle", value: percent(1 - s.cpuTotal) + "%", color: .white.opacity(0.6))
                    MiniStat(label: "Load", value: s.loadAverage.first.map { String(format: "%.1f", $0) } ?? "–", color: .white)
                }
                VStack(spacing: 3) {
                    MeterRow(label: monitor.clusterNames.fast, value: clusterLoad(s, fast: true), color: StatsPalette.cpuFast, labelWidth: 72)
                    MeterRow(label: monitor.clusterNames.other, value: clusterLoad(s, fast: false), color: StatsPalette.cpu, labelWidth: 72)
                }
                AppList(apps: s.topCPU, limit: 4, empty: "Measuring…") { app in
                    String(format: app.cpu < 0.1 ? "%.1f%%" : "%.0f%%", app.cpu * 100)
                }
            }
        }
    }

    private func clusterLoad(_ s: SystemSnapshot, fast: Bool) -> Double {
        let loads = s.cores.indices.filter { (monitor.performanceCores[safe: $0] ?? false) == fast }.map { s.cores[$0] }
        return loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count)
    }
}

private struct GPUCard: View {
    let mode: CardMode
    let onTap: () -> Void
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let s = monitor.snapshot
        let info = monitor.gpuInfo
        StatCard(title: "GPU", icon: "cube.transparent", tint: StatsPalette.gpu,
                 value: s.gpu.map(percent) ?? "–", unit: "%", temperature: s.gpuTemp, mode: mode, onTap: onTap) {
            Sparkline(values: monitor.gpuHistory, color: StatsPalette.gpu)
        } footer: {
            VStack(spacing: 3) {
                DetailRow(icon: "bolt.fill", label: "Power", value: s.gpuPower.map(watts) ?? "–")
                DetailRow(icon: "memorychip", label: "Memory", value: s.gpuMemory.map(gigabytes) ?? "–")
            }
        } detail: {
            VStack(alignment: .leading, spacing: 7) {
                Text([info.model, info.cores.map { "\($0)-core GPU" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                VStack(spacing: 5) {
                    MeterRow(label: "Device", value: s.gpu ?? 0, color: StatsPalette.gpu)
                    MeterRow(label: "Renderer", value: s.gpuRenderer ?? 0, color: StatsPalette.gpu)
                    MeterRow(label: "Tiler", value: s.gpuTiler ?? 0, color: StatsPalette.gpu)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    MiniStat(label: "Hottest", value: s.gpuTempMax.map(settings.formatTemperature) ?? "–",
                             color: s.gpuTempMax.map(StatsPalette.temperature) ?? .white)
                    MiniStat(label: "Average", value: s.gpuTemp.map(settings.formatTemperature) ?? "–",
                             color: s.gpuTemp.map(StatsPalette.temperature) ?? .white)
                    MiniStat(label: "Power", value: s.gpuPower.map(watts) ?? "–", color: .white)
                }
            }
        }
    }
}

private struct MemoryCard: View {
    let mode: CardMode
    let onTap: () -> Void
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        let m = monitor.snapshot.memory
        let total = Double(max(m.total, 1))
        StatCard(title: "Memory", icon: "memorychip", tint: StatsPalette.memory,
                 value: percent(Double(m.used) / total), unit: "%", mode: mode, onTap: onTap) {
            Sparkline(values: monitor.memoryHistory, color: StatsPalette.memory)
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                SegmentBar(segments: [
                    (Double(m.app) / total, StatsPalette.memory),
                    (Double(m.wired) / total, StatsPalette.memoryWired),
                    (Double(m.compressed) / total, StatsPalette.memoryCompressed),
                ])
                .frame(height: 5)
                HStack(spacing: 4) {
                    Text("\(gigabytes(m.used, digits: 1)) / \(gigabytes(m.total, digits: 0)) GB")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .rollingNumber("\(gigabytes(m.used, digits: 1))")
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    PressureDot(level: m.pressure)
                }
            }
        } compactNote: {
            // How much is in use, tinted by memory pressure (it was only a coloured dot).
            let color = PressureDot.color(m.pressure)
            Text("\(gigabytes(m.used, digits: 1)) GB")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .rollingNumber(gigabytes(m.used, digits: 1))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Capsule().fill(color.opacity(0.16)))
                .help("\(gigabytes(m.used, digits: 1)) of \(gigabytes(m.total, digits: 0)) GB in use")
        } detail: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 0) {
                    MiniStat(label: "App", value: gigabytes(m.app, digits: 1), color: StatsPalette.memory)
                    MiniStat(label: "Wired", value: gigabytes(m.wired, digits: 1), color: StatsPalette.memoryWired)
                    MiniStat(label: "Compressed", value: gigabytes(m.compressed, digits: 1), color: StatsPalette.memoryCompressed)
                    MiniStat(label: "Cached", value: gigabytes(m.cached, digits: 1), color: .white.opacity(0.6))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        SectionLabel("Top apps")
                        Spacer()
                        SectionLabel("Swap \(gigabytes(m.swapUsed))")
                    }
                    AppList(apps: monitor.snapshot.topMemory, limit: 4, empty: "Measuring…") { gigabytes($0.memory) }
                }
            }
        }
    }
}

private struct PowerCard: View {
    let mode: CardMode
    let onTap: () -> Void
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        let s = monitor.snapshot
        let peak = max(20, (monitor.powerHistory.max() ?? 0) * 1.2)
        StatCard(title: "Power", icon: "bolt.fill", tint: StatsPalette.power,
                 value: s.systemPower.map(formatSmall) ?? "–", unit: "W",
                 mode: mode, onTap: onTap) {
            Sparkline(values: monitor.powerHistory.map { $0 / peak }, color: StatsPalette.power)
        } footer: {
            VStack(spacing: 3) {
                if !s.fans.isEmpty {
                    DetailRow(icon: "fan.fill", label: "Fans", value: rpm(s.fans.reduce(0, +) / Double(s.fans.count)))
                }
                if let battery = s.batteryPower {
                    batteryRow(s, battery)
                } else if let cpu = s.cpuPower {
                    DetailRow(icon: "cpu", label: "CPU", value: watts(cpu))
                }
            }
        } detail: {
            // Two columns: where the power goes, then the battery and adapter. (The fans are in
            // the footer.)
            HStack(alignment: .top, spacing: 10) {
                breakdown(s)
                ColumnDivider()
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Battery")
                    if let battery = s.batteryPower {
                        DetailRow(icon: battery >= 0 ? "arrow.down.to.line" : "arrow.up.to.line",
                                  label: battery >= 0 ? "In" : "Out", value: watts(abs(battery)))
                    }
                    if let adapter = s.adapterWatts {
                        DetailRow(icon: "powerplug.fill", label: "Adapter", value: "\(adapter) W")
                    }
                    if let health = s.batteryHealth {
                        DetailRow(icon: "heart.fill", label: "Health", value: percent(health) + "%")
                    }
                    if let cycles = s.batteryCycles {
                        DetailRow(icon: "arrow.triangle.2.circlepath", label: "Cycles", value: "\(cycles)")
                    }
                    TemperatureRow(label: "Temp", celsius: s.batteryTemp)
                }
                .frame(width: 128)
            }
        }
    }

    /// Where the power goes: CPU, GPU, display, memory and everything else, as bars of the total.
    @ViewBuilder private func breakdown(_ s: SystemSnapshot) -> some View {
        let parts: [(label: String, icon: String, watts: Double?, color: Color, approx: Bool)] = [
            ("CPU", "cpu", s.cpuPower, StatsPalette.cpu, false),
            ("GPU", "cube.transparent", s.gpuPower, StatsPalette.gpu, false),
            ("Display", "sun.max.fill", s.displayPower, Color(red: 1, green: 0.85, blue: 0.4), false),
            ("Memory", "memorychip", s.memoryPower, StatsPalette.memory, true),
        ]
        let known = parts.compactMap(\.watts).reduce(0, +)
        let total = max(s.systemPower ?? known, known, 0.1)
        let other = s.systemPower.map { max(0, $0 - known) }
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Components")
            ForEach(parts.filter { $0.watts != nil }, id: \.label) { part in
                MeterRow(label: part.label, value: (part.watts ?? 0) / total, color: part.color,
                         text: watts(part.watts ?? 0))
                    .help(part.approx ? "Approximate: the memory controller's power, which follows memory traffic" : "")
            }
            if let other {
                MeterRow(label: "Other", value: other / total, color: .white.opacity(0.4), text: watts(other))
                    .help("Storage, Wi-Fi, fans, speakers, power conversion and the rest")
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func batteryRow(_ s: SystemSnapshot, _ battery: Double) -> some View {
        if battery > 0.5 {
            DetailRow(icon: "bolt.batteryblock.fill", label: "Charging", value: "+" + watts(battery))
        } else if let adapter = s.adapterWatts {
            DetailRow(icon: "powerplug.fill", label: "Adapter", value: "\(adapter) W")
        } else if let minutes = s.batteryMinutesRemaining {
            DetailRow(icon: "battery.75percent", label: "Battery", value: "\(minutes / 60)h \(minutes % 60)m")
        } else {
            DetailRow(icon: "battery.75percent", label: "Battery", value: watts(abs(battery)))
        }
    }
}

// MARK: - Building blocks

/// A stat card in one of three sizes: the normal summary; expanded to show details beside
/// the summary; or a slim live tile while another card is expanded. Clicking toggles.
private struct StatCard<Graph: View, Footer: View, Note: View, Detail: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let value: String
    let unit: String
    var temperature: Double?
    let mode: CardMode
    let onTap: () -> Void
    @ViewBuilder var graph: Graph
    @ViewBuilder var footer: Footer
    @ViewBuilder var compactNote: Note
    @ViewBuilder var detail: Detail

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if mode == .compact {
                compactFace
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            } else {
                HStack(alignment: .top, spacing: 10) {
                    summary
                        .frame(width: mode == .expanded ? CardMode.summaryWidth : nil)
                        .frame(maxWidth: mode == .expanded ? CardMode.summaryWidth : .infinity)
                    if mode == .expanded {
                        ColumnDivider()
                            .transition(.opacity)
                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(x: 12))
                                    .animation(.easeOut(duration: 0.25).delay(0.12)),
                                removal: .opacity.animation(.easeOut(duration: 0.08))))
                    }
                }
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
        }
        .padding(.horizontal, mode == .compact ? 7 : 10)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(mode == .expanded ? 0.15 : 0.10), .white.opacity(0.035)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(hovering ? 0.14 : 0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .help(mode == .expanded ? "Click to collapse" : "Click for details")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 2)
                if let temperature { TemperaturePill(celsius: temperature) }
            }
            .frame(height: 16)

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .rollingNumber(value)
                Text(unit)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 2)

            graph
                .frame(minHeight: 24, maxHeight: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 8)

            footer
        }
    }

    /// Icon, value and graph only, for the narrow tiles beside an expanded card.
    private var compactFace: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(height: 16)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .rollingNumber(value)
                Text(unit)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            graph
                .frame(maxHeight: .infinity)
            Group {
                if let temperature {
                    TemperaturePill(celsius: temperature, compact: true)
                } else {
                    compactNote
                }
            }
            .frame(height: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension StatCard where Note == EmptyView {
    init(title: String, icon: String, tint: Color, value: String, unit: String, temperature: Double? = nil,
         mode: CardMode, onTap: @escaping () -> Void,
         @ViewBuilder graph: () -> Graph, @ViewBuilder footer: () -> Footer, @ViewBuilder detail: () -> Detail) {
        self.init(title: title, icon: icon, tint: tint, value: value, unit: unit, temperature: temperature,
                  mode: mode, onTap: onTap, graph: graph, footer: footer, compactNote: { EmptyView() }, detail: detail)
    }
}

private struct ColumnDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.35))
    }
}

/// Area graph of recent values (0…1), newest at the right edge. An optional second
/// series is drawn underneath, e.g. system time inside total CPU.
private struct Sparkline: View {
    let values: [Double]
    var under: [Double]? = nil
    let color: Color
    var underColor: Color = .clear

    var body: some View {
        Canvas { ctx, size in
            for f in [0.5] {
                let y = size.height * (1 - f)
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(grid, with: .color(.white.opacity(0.07)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(base, with: .color(.white.opacity(0.1)), lineWidth: 1)

            draw(values, color: color, in: &ctx, size: size, line: true)
            if let under { draw(under, color: underColor, in: &ctx, size: size, line: false) }
        }
    }

    private func draw(_ values: [Double], color: Color, in ctx: inout GraphicsContext, size: CGSize, line: Bool) {
        guard values.count > 1 else { return }
        let step = size.width / CGFloat(SystemMonitor.historyLength - 1)
        let points = values.enumerated().map { i, v in
            CGPoint(x: size.width - CGFloat(values.count - 1 - i) * step,
                    y: size.height * (1 - CGFloat(min(1, max(0, v)))))
        }
        var stroke = Path()
        stroke.addLines(points)
        var area = stroke
        area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
        area.addLine(to: CGPoint(x: points.first!.x, y: size.height))
        area.closeSubpath()

        ctx.fill(area, with: .linearGradient(
            Gradient(colors: [color.opacity(line ? 0.45 : 0.7), color.opacity(line ? 0.02 : 0.25)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        if line {
            ctx.stroke(stroke, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            if let last = points.last {
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(color))
            }
        }
    }
}

/// One thin bar per logical core, fastest cluster in a brighter hue.
private struct CoreBars: View {
    let loads: [Double]
    let fast: [Bool]

    var body: some View {
        GeometryReader { geo in
            let n = max(loads.count, 1)
            let spacing: CGFloat = n > 16 ? 1.5 : 2
            let width = max(1.5, (geo.size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(loads.indices, id: \.self) { i in
                    let color = fast[safe: i] == true ? StatsPalette.cpuFast : StatsPalette.cpu
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: width / 2).fill(.white.opacity(0.08))
                        RoundedRectangle(cornerRadius: width / 2)
                            .fill(color.gradient)
                            .frame(height: max(width, geo.size.height * min(1, loads[i])))
                    }
                    .frame(width: width)
                }
            }
        }
    }
}

private struct SegmentBar: View {
    let segments: [(Double, Color)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle()
                        .fill(segments[i].1)
                        .frame(width: max(0, geo.size.width * min(1, segments[i].0)))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.1))
            .clipShape(Capsule())
        }
    }
}

private struct DetailRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 11)
                .foregroundStyle(.white.opacity(0.4))
            Text(label)
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 2)
            Text(value)
                .foregroundStyle(.white.opacity(0.85))
                .rollingNumber(value)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .lineLimit(1)
    }
}

private struct TemperaturePill: View {
    let celsius: Double
    var compact = false
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let color = StatsPalette.temperature(celsius)
        HStack(spacing: 2) {
            if !compact {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(settings.formatTemperature(celsius))
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .rollingNumber(settings.formatTemperature(celsius))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(Capsule().fill(color.opacity(0.16)))
    }
}

private struct PressureDot: View {
    let level: Int
    var showsLabel = true

    static func color(_ level: Int) -> Color {
        switch level {
        case 4: Color(red: 1, green: 0.38, blue: 0.35)
        case 2: Color(red: 1, green: 0.8, blue: 0.3)
        default: StatsPalette.memory
        }
    }

    var body: some View {
        let color = Self.color(level)
        let label = level == 4 ? "Critical" : level == 2 ? "Warning" : "Normal"
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            if showsLabel {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color.opacity(0.9))
            }
        }
        .help("Memory pressure")
    }
}

private struct MiniStat: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color == .white ? .white : color)
                .rollingNumber(value)
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label, thin meter and value on one line.
private struct MeterRow: View {
    let label: String
    let value: Double
    let color: Color
    var text: String? = nil
    var labelWidth: CGFloat = 50

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(.white.opacity(0.5))
                .minimumScaleFactor(0.8)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(color.gradient)
                        .frame(width: max(3, geo.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 4)
            Text(text ?? percent(value) + "%")
                .foregroundStyle(.white.opacity(0.85))
                .rollingNumber(text ?? percent(value))
                .frame(minWidth: 26, alignment: .trailing)
                // The same size as the rows around it: the bar gives up the room, not the number.
                .fixedSize()
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .lineLimit(1)
    }
}

private struct TemperatureRow: View {
    let label: String
    let celsius: Double?
    var icon = "thermometer.medium"
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 11)
                .foregroundStyle(.white.opacity(0.4))
            Text(label).foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 2)
            Text(celsius.map(settings.formatTemperature) ?? "–")
                .foregroundStyle(celsius.map(StatsPalette.temperature) ?? .white.opacity(0.85))
                .rollingNumber(celsius.map(settings.formatTemperature) ?? "–")
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .lineLimit(1)
    }
}

/// Top apps with their icons; helpers are already folded into their parent app.
private struct AppList: View {
    let apps: [AppUsage]
    let limit: Int
    let empty: String
    let value: (AppUsage) -> String

    var body: some View {
        VStack(spacing: 3) {
            if apps.isEmpty {
                Text(empty)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(apps.prefix(limit)) { app in
                HStack(spacing: 5) {
                    AppIcon(bundlePath: app.bundlePath, size: 12)
                    Text(app.name)
                        .foregroundStyle(.white.opacity(0.75))
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    Text(value(app))
                        .foregroundStyle(.white.opacity(0.9))
                        .rollingNumber(value(app))
                        .layoutPriority(1)
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .lineLimit(1)
            }
        }
    }
}

// MARK: - Formatting

private func percent(_ v: Double) -> String { "\(Int((min(1, max(0, v)) * 100).rounded()))" }
private func watts(_ v: Double) -> String { "\(formatSmall(v)) W" }
private func rpm(_ v: Double) -> String { v >= 1000 ? String(format: "%.1fk rpm", v / 1000) : "\(Int(v)) rpm" }
private func gigabytes(_ bytes: UInt64) -> String { gigabytes(bytes, digits: 1) + " GB" }
private func gigabytes(_ bytes: UInt64, digits: Int) -> String {
    String(format: "%.\(digits)f", Double(bytes) / 1_073_741_824)
}

extension View {
    /// Digits that roll to their new value, for the Stats page where there's room to watch them.
    /// (The live activities beside the notch change in place instead: less to catch the eye.)
    func rollingNumber<V: Equatable>(_ value: V) -> some View {
        contentTransition(.numericText())
            .animation(.snappy(duration: 0.35), value: value)
    }
}
