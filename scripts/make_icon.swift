import AppKit
import Foundation

let output = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let factor = CGFloat(pixels) / 1024
    let transform = AffineTransform(scale: factor)
    (transform as NSAffineTransform).concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 204, yRadius: 204)
    NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.25, alpha: 1),
               ending: NSColor(calibratedRed: 0.045, green: 0.065, blue: 0.10, alpha: 1))!.draw(in: background, angle: 90)
    func arrow(x: CGFloat, down: Bool, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath(); path.lineWidth = 64; path.lineCapStyle = .round; path.lineJoinStyle = .round
        let top: CGFloat = 698, bottom: CGFloat = 326
        path.move(to: NSPoint(x: x, y: down ? top : bottom))
        path.line(to: NSPoint(x: x, y: down ? bottom : top))
        path.move(to: NSPoint(x: x - 106, y: down ? bottom + 106 : top - 106))
        path.line(to: NSPoint(x: x, y: down ? bottom : top))
        path.line(to: NSPoint(x: x + 106, y: down ? bottom + 106 : top - 106))
        path.stroke()
    }
    arrow(x: 346, down: true, color: NSColor(calibratedRed: 0.20, green: 0.79, blue: 0.56, alpha: 1))
    arrow(x: 678, down: false, color: NSColor(calibratedRed: 0.27, green: 0.57, blue: 1, alpha: 1))
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
