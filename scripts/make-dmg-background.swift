// Draws the DMG window background (drag Chillpad onto Applications).
// Usage: swift scripts/make-dmg-background.swift <out.png> <width> <height> <scale>
import AppKit

let args = CommandLine.arguments
let out = args[1]
let W = CGFloat(Double(args[2])!), H = CGFloat(Double(args[3])!), scale = CGFloat(Double(args[4])!)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)   // 1x points, so Finder lays it out at the window size
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Soft graphite gradient, light enough for Finder's dark icon labels in either appearance.
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1).cgColor,
                             NSColor(red: 0.89, green: 0.90, blue: 0.92, alpha: 1).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// Arrow between the two icon slots (icons sit at x 150 and 390, y 140 from the top).
let y = H - 140
ctx.setStrokeColor(NSColor(red: 0.20, green: 0.48, blue: 0.85, alpha: 0.75).cgColor)
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 232, y: y)); ctx.addLine(to: CGPoint(x: 304, y: y))
ctx.move(to: CGPoint(x: 290, y: y + 13)); ctx.addLine(to: CGPoint(x: 305, y: y)); ctx.addLine(to: CGPoint(x: 290, y: y - 13))
ctx.strokePath()

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat, y: CGFloat) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(white: 0.12, alpha: alpha),
        .paragraphStyle: p,
    ]
    NSAttributedString(string: s, attributes: attrs).draw(in: CGRect(x: 0, y: y, width: W, height: size * 1.5))
}
text("Drag Chillpad into Applications", 15, .semibold, 0.85, y: 54)
text("Then open it and scan the QR code with your iPhone", 12, .regular, 0.55, y: 32)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
