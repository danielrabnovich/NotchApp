import SwiftUI

/// The Stats Rings Glance: how busy the Mac is as three nested rings, like Activity's, in the
/// Stats page's own colors so each reads the same in both places: CPU outside (blue), GPU in
/// the middle (purple), memory inside (green). No warning colors: Stats uses orange and yellow
/// for other things (power, wired memory), and the peek has the numbers.
struct StatRings: View {
    var diameter: CGFloat = 22
    @ObservedObject private var stats = SystemMonitor.shared

    var body: some View {
        let s = stats.snapshot
        let memory = s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : 0
        // Whole points keep the rings crisp; at 2 pt the inner ring still has a hole at this size.
        let line: CGFloat = diameter >= 26 ? 3 : 2
        let gap: CGFloat = 1
        ZStack {
            ring(s.cpuTotal, color: StatsPalette.cpu, inset: 0, line: line)
            ring(s.gpu ?? 0, color: StatsPalette.gpu, inset: line + gap, line: line)
            ring(memory, color: StatsPalette.memory, inset: 2 * (line + gap), line: line)
        }
        .frame(width: diameter, height: diameter)
        .pixelSnapped()
        .animation(.easeInOut(duration: 0.6), value: s.cpuTotal)
        .animation(.easeInOut(duration: 0.6), value: memory)
    }

    private func ring(_ value: Double, color: Color, inset: CGFloat, line: CGFloat) -> some View {
        ZStack {
            Circle().inset(by: inset + line / 2).stroke(color.opacity(0.22), lineWidth: line)
            Circle().inset(by: inset + line / 2)
                .trim(from: 0, to: min(max(value, 0.02), 1))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
