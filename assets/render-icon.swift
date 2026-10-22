// Renders assets/AppIcon.svg into the .icns at the given path. build.sh runs it on every build:
//   swift assets/render-icon.swift <output.icns>
import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("usage: swift render-icon.swift <output.icns>") }
let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
guard let svg = NSImage(contentsOf: dir.appendingPathComponent("AppIcon.svg")) else { fatalError("can't load AppIcon.svg") }
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", CommandLine.arguments[1]]
try p.run(); p.waitUntilExit()
exit(p.terminationStatus) // non-zero fails build.sh (set -e)
