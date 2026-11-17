import AppKit
import Foundation

let side = CGFloat(1024)
let pixels = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
let context = NSGraphicsContext(bitmapImageRep: pixels)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                        xRadius: 208, yRadius: 208)
NSColor(srgbRed: 0.10, green: 0.17, blue: 0.24, alpha: 1).setFill()
tile.fill()

let rope = NSBezierPath()
rope.move(to: CGPoint(x: 178, y: 663))
rope.curve(to: CGPoint(x: 846, y: 663),
           controlPoint1: CGPoint(x: 366, y: 590), controlPoint2: CGPoint(x: 658, y: 590))
rope.lineWidth = 15
rope.lineCapStyle = .round
NSColor(srgbRed: 0.63, green: 0.74, blue: 0.82, alpha: 1).setStroke()
rope.stroke()

let cards: [(CGFloat, CGFloat, NSColor)] = [
    (203, 626, NSColor(srgbRed: 0.80, green: 0.86, blue: 0.88, alpha: 1)),
    (423, 603, NSColor(srgbRed: 0.98, green: 0.73, blue: 0.37, alpha: 1)),
    (643, 626, NSColor(srgbRed: 0.44, green: 0.79, blue: 0.64, alpha: 1))
]
for (x, top, color) in cards {
    let card = NSBezierPath(roundedRect: NSRect(x: x, y: top - 243, width: 178, height: 215),
                            xRadius: 26, yRadius: 26)
    color.setFill()
    card.fill()
    let clip = NSBezierPath(roundedRect: NSRect(x: x + 75, y: top - 51, width: 28, height: 73),
                            xRadius: 12, yRadius: 12)
    NSColor(srgbRed: 0.95, green: 0.98, blue: 1, alpha: 1).setFill()
    clip.fill()
}
NSGraphicsContext.restoreGraphicsState()
guard let png = pixels.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
