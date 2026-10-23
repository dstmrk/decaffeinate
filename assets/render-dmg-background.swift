// Renders the .dmg window background (an arrow from the app to Applications) as a Retina TIFF:
//   swift assets/render-dmg-background.swift <output.tiff>
// The size must match window_rect in assets/dmg-settings.py.
import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("usage: swift render-dmg-background.swift <output.tiff>") }
let size = NSSize(width: 660, height: 400)
let arrowY: CGFloat = 220 // icon centers in dmg-settings.py (y=180 from the top)

func render(scale: Int) -> URL {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size // points, so the @2x rep is tagged 144 dpi
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.96, alpha: 1).setFill() // light: Finder draws the icon labels in black
    NSRect(origin: .zero, size: size).fill()

    let arrow = NSBezierPath()
    arrow.lineWidth = 10
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 280, y: arrowY)); arrow.line(to: NSPoint(x: 380, y: arrowY))
    arrow.move(to: NSPoint(x: 355, y: arrowY + 25)); arrow.line(to: NSPoint(x: 380, y: arrowY)); arrow.line(to: NSPoint(x: 355, y: arrowY - 25))
    NSColor(white: 0.55, alpha: 1).setStroke()
    arrow.stroke()

    let hint = NSAttributedString(string: "Drag Decaffeinate to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 0.4, alpha: 1)])
    hint.draw(at: NSPoint(x: (size.width - hint.size().width) / 2, y: 40))
    NSGraphicsContext.restoreGraphicsState()

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dmg-background@\(scale)x.png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    return url
}

// tiffutil merges the two into one multi-resolution TIFF, which Finder picks from by display density.
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
p.arguments = ["-cathidpicheck", render(scale: 1).path, render(scale: 2).path, "-out", CommandLine.arguments[1]]
try p.run(); p.waitUntilExit()
exit(p.terminationStatus)
