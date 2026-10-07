// Renders Resources/AppIcon.icns. Run: swift scripts/make_icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle background with a deep gradient.
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    NSColor.black.setFill(); bg.fill()
    ctx.restoreGState()
    bg.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.18, blue: 0.62, alpha: 1),
                        NSColor(srgbRed: 0.93, green: 0.32, blue: 0.47, alpha: 1),
                        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.32, alpha: 1)])!
        .draw(in: rect, angle: -60)

    // The notch, expanded, hanging from the top edge.
    let nw = rect.width * 0.72, nh = rect.height * 0.36
    let notch = CGRect(x: rect.midX - nw / 2, y: rect.maxY - nh, width: nw, height: nh + s * 0.1)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.05, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: notch, xRadius: s * 0.075, yRadius: s * 0.075).fill()
    ctx.restoreGState()

    // Album art tile + visualizer bars inside the notch.
    let art = CGRect(x: notch.minX + nw * 0.1, y: rect.maxY - nh * 0.82, width: nh * 0.55, height: nh * 0.55)
    NSGradient(colors: [NSColor(srgbRed: 1, green: 0.55, blue: 0.35, alpha: 1), NSColor(srgbRed: 0.95, green: 0.3, blue: 0.5, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: art, xRadius: s * 0.025, yRadius: s * 0.025), angle: -45)
    let heights: [CGFloat] = [0.45, 0.85, 0.6, 1.0, 0.5]
    let barW = nw * 0.045, gap = nw * 0.035
    var x = notch.maxX - nw * 0.1 - CGFloat(heights.count) * (barW + gap) + gap
    for h in heights {
        let bh = nh * 0.5 * h
        NSColor(srgbRed: 1, green: 0.7, blue: 0.5, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: art.midY - bh / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: dir.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: dir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
