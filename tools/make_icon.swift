// Renders the app icon (1024x1024 PNG): a board with sticky notes and a connector.
import Cocoa

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let c = NSColor.self

// Base tile (macOS icon grid: 824pt body centred in 1024)
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = c.black.withAlphaComponent(0.28); sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -10)
sh.set()
NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.93, alpha: 1),
           ending: NSColor(calibratedRed: 0.24, green: 0.27, blue: 0.72, alpha: 1))!.draw(in: tile, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Dot grid
c.white.withAlphaComponent(0.16).setFill()
tile.addClip()
for x in stride(from: 140.0, to: 924.0, by: 56.0) {
    for y in stride(from: 140.0, to: 924.0, by: 56.0) {
        NSBezierPath(ovalIn: NSRect(x: x - 5, y: y - 5, width: 10, height: 10)).fill()
    }
}

func sticky(_ r: NSRect, _ col: NSColor, _ angle: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: r.midX, yBy: r.midY); t.rotate(byDegrees: angle); t.translateX(by: -r.midX, yBy: -r.midY)
    t.concat()
    let s = NSShadow(); s.shadowColor = c.black.withAlphaComponent(0.3); s.shadowBlurRadius = 18; s.shadowOffset = NSSize(width: 0, height: -8)
    s.set()
    col.setFill()
    NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    t.concat()
    c.black.withAlphaComponent(0.22).setFill()
    for i in 0..<3 {
        let w: CGFloat = i == 2 ? r.width * 0.38 : r.width * 0.62
        NSBezierPath(roundedRect: NSRect(x: r.minX + r.width * 0.19, y: r.maxY - r.height * (0.32 + CGFloat(i) * 0.18), width: w, height: 18), xRadius: 9, yRadius: 9).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

// Connector between notes
let line = NSBezierPath()
line.move(to: NSPoint(x: 400, y: 600))
line.curve(to: NSPoint(x: 640, y: 420), controlPoint1: NSPoint(x: 560, y: 600), controlPoint2: NSPoint(x: 480, y: 420))
line.lineWidth = 22; line.lineCapStyle = .round
c.white.setStroke(); line.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 680, y: 420)); head.line(to: NSPoint(x: 618, y: 456)); head.line(to: NSPoint(x: 618, y: 384)); head.close()
c.white.setFill(); head.fill()

sticky(NSRect(x: 190, y: 500, width: 270, height: 270), NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.33, alpha: 1), 5)
sticky(NSRect(x: 600, y: 270, width: 250, height: 250), NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.74, alpha: 1), -6)
sticky(NSRect(x: 600, y: 610, width: 200, height: 200), NSColor(calibratedRed: 0.62, green: 0.89, blue: 0.80, alpha: 1), 8)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
