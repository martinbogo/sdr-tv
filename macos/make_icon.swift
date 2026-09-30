// Renders the app icon: swift make_icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.20, blue: 0.30, alpha: 1),
                        NSColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1)])!.draw(in: shape, angle: -90)
    // rabbit-ear antenna
    let base = NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.64)
    NSColor(white: 0.85, alpha: 1).setStroke()
    for dx in [-0.22, 0.22] {
        let p = NSBezierPath()
        p.move(to: base)
        p.line(to: NSPoint(x: rect.midX + rect.width * CGFloat(dx), y: rect.maxY - rect.height * 0.08))
        p.lineWidth = s * 0.022; p.lineCapStyle = .round
        p.stroke()
    }
    // screen with a glow
    let screen = NSRect(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.16,
                        width: rect.width * 0.72, height: rect.height * 0.48)
    let sp = NSBezierPath(roundedRect: screen, xRadius: s * 0.035, yRadius: s * 0.035)
    NSColor(white: 0.92, alpha: 1).setFill(); sp.fill()
    let inner = screen.insetBy(dx: s * 0.025, dy: s * 0.025)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1),
                        NSColor(red: 0.45, green: 0.25, blue: 0.95, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: inner, xRadius: s * 0.02, yRadius: s * 0.02), angle: -35)
    // "HD" hint of signal: three bars
    NSColor.white.withAlphaComponent(0.9).setFill()
    for i in 0..<3 {
        let w = inner.width * 0.07, h = inner.height * (0.22 + 0.16 * CGFloat(i))
        NSBezierPath(roundedRect: NSRect(x: inner.midX - inner.width * 0.14 + CGFloat(i) * inner.width * 0.1,
                                         y: inner.minY + inner.height * 0.22, width: w, height: h),
                     xRadius: w / 3, yRadius: w / 3).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                   ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
