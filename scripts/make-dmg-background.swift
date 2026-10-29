// Draws the disk image window background: a soft gradient, an arrow from the app
// to the Applications folder, and a one-line hint. Usage:
//   swift scripts/make-dmg-background.swift <output.png> [scale]
// The window is 640×400 points; the icons sit at x=170 and x=470, y=190.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let scale = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1) : 1
let size = NSSize(width: 640, height: 400)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(origin: .zero, size: size)
NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.99, blue: 0.98, alpha: 1),
                    NSColor(srgbRed: 0.88, green: 0.95, blue: 0.91, alpha: 1)])!.draw(in: rect, angle: -90)

// Arrow between the two icons (Finder's y runs top-down; Cocoa's bottom-up).
let green = NSColor(srgbRed: 0.04, green: 0.52, blue: 0.36, alpha: 0.85)
let y = size.height - 190
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 250, y: y))
arrow.line(to: NSPoint(x: 378, y: y))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
green.setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 395, y: y))
head.line(to: NSPoint(x: 372, y: y + 16))
head.line(to: NSPoint(x: 372, y: y - 16))
head.close()
green.setFill()
head.fill()

func centered(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let p = NSMutableParagraphStyle()
    p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
    (text as NSString).draw(in: NSRect(x: 0, y: y, width: 640, height: size * 1.6), withAttributes: attrs)
}
centered("VoiceNote Translator", y: 340, size: 22, weight: .semibold, color: NSColor(white: 0.15, alpha: 1))
centered("Drag the app into Applications, then open it from there.", y: 72, size: 13, weight: .regular, color: NSColor(white: 0.35, alpha: 1))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
