// Generates AppIcon.iconset PNGs for the app icon: a warm glowing lightbulb
// on a dark squircle, macOS Big Sur style. Run via `make icon`, which packs
// the output with iconutil.
import AppKit

let canvas: CGFloat = 1024

let master = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    // Apple's icon grid: content squircle is 824x824 centered in 1024.
    let content = NSRect(x: 100, y: 100, width: 824, height: 824)
    NSBezierPath(roundedRect: content, xRadius: 185, yRadius: 185).addClip()

    NSGradient(
        starting: NSColor(srgbRed: 0.17, green: 0.18, blue: 0.24, alpha: 1),
        ending: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.11, alpha: 1))!
        .draw(in: content, angle: -90)

    guard let symbol = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 600, weight: .medium))
    else { return false }

    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor(srgbRed: 1.0, green: 0.84, blue: 0.35, alpha: 1).set()
        rect.fill(using: .sourceAtop)
        return true
    }

    let height: CGFloat = 520
    let width = tinted.size.width * height / tinted.size.height
    let glow = NSShadow()
    glow.shadowColor = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.30, alpha: 0.85)
    glow.shadowBlurRadius = 70
    glow.set()
    tinted.draw(in: NSRect(x: (canvas - width) / 2, y: (canvas - height) / 2,
                           width: width, height: height))
    return true
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "AppIcon.iconset")
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    writePNG(master, pixels: points, to: outDir.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(master, pixels: points * 2,
             to: outDir.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print("Wrote iconset to \(outDir.path)")
