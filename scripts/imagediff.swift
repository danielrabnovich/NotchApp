// Compares two folders of PNGs pixel by pixel (the Home snapshots), writing a diff image for each
// that changed: the new shot dimmed, changed pixels in magenta.
//   imagediff <baseline-dir> <current-dir> <diff-dir> [threshold-percent]
// Prints one line per shot that differs and exits 1 if any differs by more than the threshold
// (default 0.3% of its pixels), 2 if a shot is missing or a different size.
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: imagediff <baseline> <current> <diffs> [threshold%]\n".utf8))
    exit(64)
}
let baseline = URL(fileURLWithPath: args[1]), current = URL(fileURLWithPath: args[2]), diffs = URL(fileURLWithPath: args[3])
let threshold = args.count > 4 ? Double(args[4]) ?? 0.3 : 0.3
let fm = FileManager.default
try? fm.removeItem(at: diffs)
try? fm.createDirectory(at: diffs, withIntermediateDirectories: true)

/// RGBA8 pixels of a PNG.
func pixels(_ url: URL) -> (width: Int, height: Int, data: [UInt8])? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, data)
}

func write(_ data: [UInt8], width: Int, height: Int, to url: URL) {
    var data = data
    guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let names = ((try? fm.contentsOfDirectory(atPath: baseline.path)) ?? [])
    .filter { $0.hasSuffix(".png") && $0 != "sheet.png" }.sorted()
guard !names.isEmpty else {
    FileHandle.standardError.write(Data("No baseline shots in \(baseline.path)\n".utf8))
    exit(2)
}

var failed = false, broken = false, same = 0
for name in names {
    guard let a = pixels(baseline.appendingPathComponent(name)) else { continue }
    guard let b = pixels(current.appendingPathComponent(name)) else {
        print("✗ \(name): missing from this run"); broken = true; continue
    }
    guard a.width == b.width, a.height == b.height else {
        print("✗ \(name): size \(a.width)×\(a.height) → \(b.width)×\(b.height)"); broken = true; continue
    }
    var out = [UInt8](repeating: 0, count: b.data.count)
    var changed = 0
    for i in stride(from: 0, to: a.data.count, by: 4) {
        // A channel moving by more than a few levels (antialiasing noise stays under it).
        let moved = (0..<4).contains { abs(Int(a.data[i + $0]) - Int(b.data[i + $0])) > 8 }
        if moved {
            changed += 1
            out[i] = 255; out[i + 1] = 0; out[i + 2] = 255; out[i + 3] = 255
        } else {
            out[i] = b.data[i] / 4; out[i + 1] = b.data[i + 1] / 4; out[i + 2] = b.data[i + 2] / 4; out[i + 3] = 255
        }
    }
    guard changed > 0 else { same += 1; continue }
    let percent = Double(changed) * 100 / Double(a.width * a.height)
    let over = percent > threshold
    if over { failed = true }
    print("\(over ? "✗" : "·") \(name): \(String(format: "%.2f", percent))% of pixels changed")
    write(out, width: b.width, height: b.height, to: diffs.appendingPathComponent(name))
}
print("\(same) of \(names.count) shots identical; diffs in \(diffs.path)")
exit(broken ? 2 : failed ? 1 : 0)
