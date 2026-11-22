// Renders the TouchBridge app icon (macOS Big Sur+ style) and builds Resources/AppIcon.icns.
// Usage: swift Tools/make-icon.swift   (run from the repository root)
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Apple icon grid: 824×824 rounded square centred in 1024, corner radius ≈ 185, soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.95, alpha: 1).setFill()
    shape.fill()
    ctx.restoreGState()

    // Background gradient: blue → indigo, lit from the top.
    shape.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.33, green: 0.62, blue: 1.00, alpha: 1),
                        NSColor(calibratedRed: 0.27, green: 0.30, blue: 0.93, alpha: 1),
                        NSColor(calibratedRed: 0.35, green: 0.18, blue: 0.78, alpha: 1)])!
        .draw(in: body, angle: -90)

    // A monitor-like screen panel.
    let screen = NSRect(x: 212, y: 300, width: 600, height: 420)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 56, yRadius: 56)
    NSColor.white.withAlphaComponent(0.16).setFill()
    screenPath.fill()
    NSColor.white.withAlphaComponent(0.55).setStroke()
    screenPath.lineWidth = 14
    screenPath.stroke()
    // stand
    NSColor.white.withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: NSRect(x: 452, y: 236, width: 120, height: 52), xRadius: 14, yRadius: 14).fill()

    // Touch ripples + the tapping hand (SF Symbol).
    for (r, a) in [(150.0, 0.18), (105.0, 0.28)] {
        let c = NSPoint(x: 600, y: 560)
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        NSColor.white.withAlphaComponent(a).setStroke()
        ring.lineWidth = 12
        ring.stroke()
    }
    let conf = NSImage.SymbolConfiguration(pointSize: 330, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let hand = NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)?.withSymbolConfiguration(conf) {
        let s = hand.size
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        hand.draw(in: NSRect(x: 590 - s.width * 0.18, y: 600 - s.height * 0.95, width: s.width, height: s.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Resources/AppIcon.icns готов" : "iconutil: ошибка")
