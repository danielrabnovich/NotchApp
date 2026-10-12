import SwiftUI

/// The Rings Glance: how busy the Mac is as three nested rings, like Activity's. CPU outside, GPU
/// in the middle, memory inside, each in its own color until it's under load (orange, then red).
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
            ring(s.cpuTotal, color: LiveItem.cpu.tint, warm: 0.6, hot: 0.85, inset: 0, line: line)
            ring(s.gpu ?? 0, color: LiveItem.gpu.tint, warm: 0.6, hot: 0.85, inset: line + gap, line: line)
            // macOS keeps memory busy on purpose: it warms only when nearly full.
            ring(memory, color: LiveItem.memory.tint, warm: 0.85, hot: 0.95, inset: 2 * (line + gap), line: line)
        }
        .frame(width: diameter, height: diameter)
        .pixelSnapped()
        .animation(.easeInOut(duration: 0.6), value: s.cpuTotal)
        .animation(.easeInOut(duration: 0.6), value: memory)
    }

    private func ring(_ value: Double, color: Color, warm: Double, hot: Double, inset: CGFloat, line: CGFloat) -> some View {
        let tint = value > hot ? Color(red: 1, green: 0.38, blue: 0.35) : value > warm ? Color(red: 1, green: 0.7, blue: 0.3) : color
        return ZStack {
            Circle().inset(by: inset + line / 2).stroke(tint.opacity(0.22), lineWidth: line)
            Circle().inset(by: inset + line / 2)
                .trim(from: 0, to: min(max(value, 0.02), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
