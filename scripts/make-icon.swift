// Draws the Chillpad icon. Usage: swift scripts/make-icon.swift
// Writes web/icon.png (full-bleed, for the phone's Home Screen) and packaging/AppIcon.icns.
import AppKit

func draw(size S: CGFloat, mac: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let u = S / 512                       // design units
    let rgb = CGColorSpaceCreateDeviceRGB()
    // macOS icons sit on a rounded square with margins; iOS rounds the corners itself.
    let tile = mac ? CGRect(x: 50 * u, y: 50 * u, width: 412 * u, height: 412 * u) : CGRect(x: 0, y: 0, width: S, height: S)
    ctx.saveGState()
    if mac {
        ctx.setShadow(offset: CGSize(width: 0, height: -5 * u), blur: 12 * u, color: NSColor(white: 0, alpha: 0.35).cgColor)
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 92 * u, cornerHeight: 92 * u, transform: nil))
        ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 92 * u, cornerHeight: 92 * u, transform: nil)); ctx.clip()
    }
    let bg = CGGradient(colorsSpace: rgb, colors: [NSColor(red: 0.15, green: 0.15, blue: 0.19, alpha: 1).cgColor,
                                                    NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // Everything below is laid out in a 512 box and scaled into the tile.
    ctx.translateBy(x: tile.minX, y: tile.minY); ctx.scaleBy(x: tile.width / 512, y: tile.height / 512)
    let pad = CGPath(roundedRect: CGRect(x: 96, y: 136, width: 320, height: 240), cornerWidth: 46, cornerHeight: 46, transform: nil)
    ctx.addPath(pad); ctx.setFillColor(NSColor(white: 1, alpha: 0.06).cgColor); ctx.fillPath()
    ctx.addPath(pad); ctx.setStrokeColor(NSColor(white: 1, alpha: 0.18).cgColor); ctx.setLineWidth(5); ctx.strokePath()
    ctx.setLineCap(.round)
    let trail = CGMutablePath()
    trail.move(to: CGPoint(x: 170, y: 210))
    trail.addCurve(to: CGPoint(x: 320, y: 290), control1: CGPoint(x: 230, y: 200), control2: CGPoint(x: 260, y: 300))
    ctx.addPath(trail); ctx.setStrokeColor(NSColor(red: 0.49, green: 0.77, blue: 1, alpha: 0.5).cgColor); ctx.setLineWidth(14); ctx.strokePath()
    let glow = CGGradient(colorsSpace: rgb, colors: [NSColor(red: 0.49, green: 0.77, blue: 1, alpha: 1).cgColor,
                                                      NSColor(red: 0.49, green: 0.77, blue: 1, alpha: 0).cgColor] as CFArray, locations: [0.25, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 320, y: 290), startRadius: 0, endCenter: CGPoint(x: 320, y: 290), endRadius: 70, options: [])
    ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: CGRect(x: 302, y: 272, width: 36, height: 36))
    ctx.restoreGState()
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try! draw(size: 512, mac: false).write(to: URL(fileURLWithPath: "web/icon.png"))
let set = "build/AppIcon.iconset"
try? fm.removeItem(atPath: set)
try! fm.createDirectory(atPath: set, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try! draw(size: CGFloat(pt * scale), mac: true).write(to: URL(fileURLWithPath: "\(set)/\(name)"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", "packaging/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "icons written" : "iconutil failed")
