import AppKit
import CoreImage
import SwiftUI

/// Marking up a picture on the Shelf before it goes anywhere: arrows to point, words to say why,
/// and blocks that pixelate what shouldn't be seen (a name, a token, a face). One colour, picked
/// for this picture: the one of a few that stands out most against it, so the marks always show.
/// Done saves a marked copy beside the original (which is left alone), puts it in the original's
/// place on the Shelf, and copies it, ready to paste.
@MainActor
final class MarkupWindow {
    static let shared = MarkupWindow()
    private var window: NSWindow?

    func open(_ url: URL) {
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        window?.close()
        let pixels = CGSize(width: cg.width, height: cg.height)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // As big as fits in most of the screen, never past the picture's own size in points.
        let points = CGSize(width: pixels.width / (NSScreen.main?.backingScaleFactor ?? 2),
                            height: pixels.height / (NSScreen.main?.backingScaleFactor ?? 2))
        let fit = min(1, screen.width * 0.8 / points.width, (screen.height * 0.8 - 52) / points.height)
        let size = CGSize(width: max(420, (points.width * fit).rounded()), height: (points.height * fit).rounded() + 52)

        let model = MarkupModel(url: url, image: cg)
        let w = MarkupPanel(contentRect: CGRect(origin: .zero, size: size))
        w.title = "Mark Up " + url.lastPathComponent
        w.contentView = NSHostingView(rootView: MarkupView(model: model, close: { [weak self] in self?.close() }))
        w.center()
        w.onCancel = { [weak self] in self?.close() }
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class MarkupPanel: NSPanel {
    var onCancel: (() -> Void)?
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class MarkupModel: ObservableObject {
    enum Tool: String, CaseIterable { case arrow, text, blur }

    /// Everything in the picture's own coordinates, 0…1 from the top left, so the window can be
    /// any size and the saved copy is drawn at full resolution.
    enum Mark: Equatable {
        case arrow(from: CGPoint, to: CGPoint)
        case text(at: CGPoint, String)
        case blur(CGRect)
    }

    let url: URL
    let image: CGImage
    let color: NSColor
    @Published var tool: Tool = .arrow
    @Published var marks: [Mark] = []
    @Published var draft: Mark?
    /// Words being typed where the picture was clicked.
    @Published var typing: CGPoint?
    @Published var words = ""

    init(url: URL, image: CGImage) {
        self.url = url
        self.image = image
        color = Self.standout(against: image)
    }

    func commitWords() {
        if let at = typing, !words.trimmingCharacters(in: .whitespaces).isEmpty { marks.append(.text(at: at, words)) }
        typing = nil
        words = ""
    }

    /// Of a few loud colours, the farthest from the picture's own average.
    private static func standout(against image: CGImage) -> NSColor {
        var px = [UInt8](repeating: 0, count: 4)
        let average: (CGFloat, CGFloat, CGFloat) = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0.5, 0.5, 0.5) }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (CGFloat(buf[0]) / 255, CGFloat(buf[1]) / 255, CGFloat(buf[2]) / 255)
        }
        let candidates: [NSColor] = [.systemOrange, .systemPink, NSColor(red: 0.1, green: 0.85, blue: 1, alpha: 1), .systemYellow, .systemGreen]
        return candidates.max { a, b in distance(a, average) < distance(b, average) } ?? .systemOrange
    }

    private static func distance(_ c: NSColor, _ to: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        let c = c.usingColorSpace(.deviceRGB) ?? c
        return pow(c.redComponent - to.0, 2) * 0.3 + pow(c.greenComponent - to.1, 2) * 0.59 + pow(c.blueComponent - to.2, 2) * 0.11
    }

    // MARK: Saving

    func save() {
        commitWords()
        guard let output = render() else { return }
        let base = url.deletingPathExtension().lastPathComponent + " marked"
        let target = ShelfStore.free(url.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension("png"))
        let rep = NSBitmapImageRep(cgImage: output)
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: target)) != nil else { return }
        if !ShelfStore.shared.replace(url, with: target) { ShelfStore.shared.add([target], copy: false) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: output, size: .zero), target as NSURL])
        ActivityCenter.shared.show(.notice(title: "Marked up", detail: "On the Shelf and copied", icon: "pencil.tip.crop.circle"), for: 3)
    }

    /// The picture with its marks, at full size.
    func render() -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGSize(width: w, height: h)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        // Pixelated blocks first, so arrows and words can sit over them.
        for case let .blur(r) in marks {
            let rect = Self.pixels(r, size).integral
            guard let crop = image.cropping(to: rect), let blocky = Self.pixelate(crop) else { continue }
            ctx.draw(blocky, in: CGRect(x: rect.minX, y: CGFloat(h) - rect.maxY, width: rect.width, height: rect.height))
        }
        // The rest is drawn top-down, as it was placed.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let unit = max(2, min(CGFloat(w), CGFloat(h)) / 300)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for mark in marks {
            switch mark {
            case let .arrow(a, b):
                Self.arrowPath(from: Self.pixels(a, size), to: Self.pixels(b, size), width: unit * 2.2).fill(ctx, color)
            case let .text(at, words):
                Self.drawWords(words, at: Self.pixels(at, size), size: unit * 11, color: color)
            case .blur:
                break
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func pixels(_ p: CGPoint, _ size: CGSize) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
    static func pixels(_ r: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    /// Blocks a sixth of the hidden area's shorter side, at least 8 pixels: big enough that text
    /// under them can't be read back.
    private static func pixelate(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(max(8, Double(min(image.width, image.height)) / 6), forKey: kCIInputScaleKey)
        guard let out = filter?.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(out, from: input.extent)
    }

    /// A tapering shaft with a solid head, as one shape.
    static func arrowPath(from a: CGPoint, to b: CGPoint, width: CGFloat) -> CGPath {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(1, hypot(dx, dy))
        let ux = dx / length, uy = dy / length, nx = -uy, ny = ux
        let head = min(length * 0.45, width * 6), half = width * 3
        let neck = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: a.x + nx * width * 0.25, y: a.y + ny * width * 0.25))
        path.addLine(to: CGPoint(x: neck.x + nx * width * 0.6, y: neck.y + ny * width * 0.6))
        path.addLine(to: CGPoint(x: neck.x + nx * half, y: neck.y + ny * half))
        path.addLine(to: b)
        path.addLine(to: CGPoint(x: neck.x - nx * half, y: neck.y - ny * half))
        path.addLine(to: CGPoint(x: neck.x - nx * width * 0.6, y: neck.y - ny * width * 0.6))
        path.addLine(to: CGPoint(x: a.x - nx * width * 0.25, y: a.y - ny * width * 0.25))
        path.closeSubpath()
        return path
    }

    /// Bold words with a soft dark shadow under them, so they read on light and dark alike.
    static func drawWords(_ words: String, at p: CGPoint, size: CGFloat, color: NSColor) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = size * 0.18
        shadow.shadowOffset = .zero
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color, .shadow: shadow]
        NSAttributedString(string: words, attributes: attrs).draw(at: CGPoint(x: p.x, y: p.y - size * 0.6))
    }
}

private extension CGPath {
    func fill(_ ctx: CGContext, _ color: NSColor) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addPath(self)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

private struct MarkupView: View {
    @ObservedObject var model: MarkupModel
    let close: () -> Void
    @FocusState private var typingFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                let fitted = fit(geo.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: model.image, scale: 1).resizable().interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                    Canvas { ctx, size in draw(&ctx, size: size) }
                        .frame(width: fitted.width, height: fitted.height)
                        .allowsHitTesting(false)
                    if let at = model.typing {
                        TextField("Say something", text: $model.words)
                            .textFieldStyle(.plain)
                            .font(.system(size: max(1, min(fitted.width, fitted.height) / 300) * 11, weight: .bold))
                            .foregroundStyle(Color(nsColor: model.color))
                            .frame(width: max(120, fitted.width - at.x * fitted.width - 8), alignment: .leading)
                            .focused($typingFocus)
                            .onSubmit { model.commitWords() }
                            .offset(x: at.x * fitted.width, y: at.y * fitted.height - 10)
                            .onAppear { typingFocus = true }
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .contentShape(Rectangle())
                .gesture(drawing(in: fitted))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black)
        }
        .background(KeyCommands(undo: { if !model.marks.isEmpty { model.marks.removeLast() } }, save: { model.save(); close() }))
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 64) // the window's buttons
            ForEach(MarkupModel.Tool.allCases, id: \.self) { tool in
                Button { model.commitWords(); model.tool = tool } label: {
                    Label(tool == .arrow ? "Arrow" : tool == .text ? "Words" : "Hide",
                          systemImage: tool == .arrow ? "arrow.up.right" : tool == .text ? "textformat" : "square.grid.3x3.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(model.tool == tool ? Color(nsColor: model.color).opacity(0.3) : .white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(tool == .blur ? "Drag over what shouldn't be seen" : tool == .text ? "Click where the words go" : "Drag from the tail to the point")
            }
            Spacer()
            Button("Undo") { if !model.marks.isEmpty { model.marks.removeLast() } }
                .disabled(model.marks.isEmpty)
            Button("Cancel", action: close)
            Button("Done") { model.save(); close() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.marks.isEmpty && model.words.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private func fit(_ size: CGSize) -> CGSize {
        let w = CGFloat(model.image.width), h = CGFloat(model.image.height)
        let s = min(size.width / w, size.height / h)
        return CGSize(width: (w * s).rounded(), height: (h * s).rounded())
    }

    private func drawing(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let a = norm(v.startLocation, size), b = norm(v.location, size)
                switch model.tool {
                case .arrow: model.draft = .arrow(from: a, to: b)
                case .blur: model.draft = .blur(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
                case .text: break
                }
            }
            .onEnded { v in
                let a = norm(v.startLocation, size), b = norm(v.location, size)
                switch model.tool {
                case .text:
                    model.commitWords()
                    model.typing = b
                case .arrow:
                    if hypot((b.x - a.x) * size.width, (b.y - a.y) * size.height) > 8 { model.marks.append(.arrow(from: a, to: b)) }
                case .blur:
                    if abs(b.x - a.x) * size.width > 4, abs(b.y - a.y) * size.height > 4, case let .blur(r)? = model.draft { model.marks.append(.blur(r)) }
                }
                model.draft = nil
            }
    }

    private func norm(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x / size.width)), y: min(1, max(0, p.y / size.height)))
    }

    /// The same marks the saved copy gets, drawn at the window's size (blocks as a frosted stand-in).
    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let color = Color(nsColor: model.color)
        let unit = max(1, min(size.width, size.height) / 300)
        for mark in model.marks + (model.draft.map { [$0] } ?? []) {
            switch mark {
            case let .arrow(a, b):
                let path = Path(MarkupModel.arrowPath(from: MarkupModel.pixels(a, size), to: MarkupModel.pixels(b, size), width: unit * 2.2))
                ctx.fill(path, with: .color(color))
            case let .text(at, words):
                let p = MarkupModel.pixels(at, size)
                ctx.draw(Text(words).font(.system(size: unit * 11, weight: .bold)).foregroundColor(color), at: p, anchor: .leading)
            case let .blur(r):
                let rect = MarkupModel.pixels(r, size)
                ctx.fill(Path(rect), with: .color(.gray.opacity(0.85)))
                // A grid, so it reads as blocks to come.
                let step = max(6, min(rect.width, rect.height) / 6)
                var grid = Path()
                for x in Swift.stride(from: rect.minX, through: rect.maxX, by: step) { grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY)) }
                for y in Swift.stride(from: rect.minY, through: rect.maxY, by: step) { grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y)) }
                ctx.stroke(grid, with: .color(.black.opacity(0.25)), lineWidth: 1)
            }
        }
    }
}

/// ⌘Z takes back the last mark; ⌘S is Done.
private struct KeyCommands: View {
    let undo: () -> Void
    let save: () -> Void
    var body: some View {
        ZStack {
            Button("", action: undo).keyboardShortcut("z", modifiers: .command)
            Button("", action: save).keyboardShortcut("s", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}
