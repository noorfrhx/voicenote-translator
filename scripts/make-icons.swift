// Draws the app and extension icons. Run: swift scripts/make-icons.swift
// Writes Resources/AppIcon.icns and extension/icons/icon{16,32,48,128}.png.

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

func draw(size: CGFloat, macStyle: Bool) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        // macOS icons sit inside a margin; extension icons use the full square.
        let inset = macStyle ? size * 0.1 : 0
        let body = rect.insetBy(dx: inset, dy: inset)
        let radius = body.width * 0.225
        let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        if macStyle {
            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = size * 0.03
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.set()
            NSColor.black.setFill()
            shape.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.80, blue: 0.45, alpha: 1),
                            NSColor(srgbRed: 0.04, green: 0.52, blue: 0.36, alpha: 1)])!
            .draw(in: shape, angle: -90)

        // Speech bubble.
        let w = body.width
        let bubble = NSRect(x: body.minX + w * 0.16, y: body.minY + w * 0.27, width: w * 0.68, height: w * 0.52)
        let path = NSBezierPath(roundedRect: bubble, xRadius: w * 0.16, yRadius: w * 0.16)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: bubble.minX + w * 0.14, y: bubble.minY + w * 0.02))
        tail.line(to: NSPoint(x: bubble.minX + w * 0.06, y: body.minY + w * 0.14))
        tail.line(to: NSPoint(x: bubble.minX + w * 0.30, y: bubble.minY + w * 0.01))
        tail.close()
        NSColor.white.setFill()
        path.fill()
        tail.fill()

        // Waveform inside the bubble.
        let bars: [CGFloat] = [0.30, 0.62, 1.0, 0.72, 0.45, 0.85, 0.38]
        let barW = bubble.width * 0.065
        let gap = (bubble.width * 0.7 - barW * CGFloat(bars.count)) / CGFloat(bars.count - 1)
        var x = bubble.minX + bubble.width * 0.15
        NSColor(srgbRed: 0.04, green: 0.52, blue: 0.36, alpha: 1).setFill()
        for b in bars {
            let h = bubble.height * 0.62 * b
            NSBezierPath(roundedRect: NSRect(x: x, y: bubble.midY - h / 2, width: barW, height: h), xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! png(draw(size: CGFloat(base * scale), macStyle: true), pixels: base * scale).write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)

let ext = root.appendingPathComponent("extension/icons")
try! fm.createDirectory(at: ext, withIntermediateDirectories: true)
for size in [16, 32, 48, 128] {
    try! png(draw(size: CGFloat(size), macStyle: false), pixels: size).write(to: ext.appendingPathComponent("icon\(size).png"))
}
print("Icons written.")
