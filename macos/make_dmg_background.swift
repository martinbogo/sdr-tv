// Renders the disk image background (an arrow from the app to Applications):
//   swift make_dmg_background.swift <out.png> <scale>     (scale 1 or 2; the window is 560x360 points)
import AppKit

let out = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let w: CGFloat = 560, h: CGFloat = 360
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(colors: [NSColor(white: 0.97, alpha: 1), NSColor(white: 0.90, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
// arrow between the icons (centers at x 150 and 410, 170 points from the top)
let y = h - 170
NSColor(white: 0.55, alpha: 1).setStroke()
NSColor(white: 0.55, alpha: 1).setFill()
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 235, y: y)); shaft.line(to: NSPoint(x: 312, y: y))
shaft.lineWidth = 6; shaft.lineCapStyle = .round
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 330, y: y)); head.line(to: NSPoint(x: 308, y: y + 14)); head.line(to: NSPoint(x: 308, y: y - 14))
head.close(); head.fill()
let text = "Drag SDR TV to Applications" as NSString
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                            .foregroundColor: NSColor(white: 0.35, alpha: 1)]
let size = text.size(withAttributes: attrs)
text.draw(at: NSPoint(x: (w - size.width) / 2, y: 40), withAttributes: attrs)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
