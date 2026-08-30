// Génère Resources/AppIcon.icns : fond dégradé vert forêt, tracé blanc en zigzag avec deux points.
// Usage : swift make-icon.swift Resources/AppIcon.icns
import AppKit
import Foundation

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = size * 0.045
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = size * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Ombre douce
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(calibratedRed: 0.13, green: 0.45, blue: 0.30, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Dégradé
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(calibratedRed: 0.20, green: 0.62, blue: 0.42, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.08, green: 0.36, blue: 0.26, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    // Courbes de niveau discrètes
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(size * 0.012)
    for i in 0..<5 {
        let r = size * (0.25 + CGFloat(i) * 0.12)
        ctx.addEllipse(in: CGRect(x: size * 0.62 - r / 2, y: size * 0.30 - r / 2, width: r, height: r))
        ctx.strokePath()
    }

    // Tracé
    let p = CGMutablePath()
    p.move(to: CGPoint(x: size * 0.22, y: size * 0.28))
    p.addCurve(to: CGPoint(x: size * 0.50, y: size * 0.52), control1: CGPoint(x: size * 0.28, y: size * 0.55), control2: CGPoint(x: size * 0.40, y: size * 0.30))
    p.addCurve(to: CGPoint(x: size * 0.78, y: size * 0.74), control1: CGPoint(x: size * 0.60, y: size * 0.74), control2: CGPoint(x: size * 0.66, y: size * 0.52))
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor)
    ctx.setLineWidth(size * 0.10)
    ctx.setLineCap(.round)
    ctx.addPath(p)
    ctx.strokePath()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(size * 0.065)
    ctx.addPath(p)
    ctx.strokePath()

    // Points départ / arrivée
    func dot(_ c: CGPoint, _ color: NSColor) {
        let r = size * 0.075
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        let r2 = size * 0.045
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r2, y: c.y - r2, width: 2 * r2, height: 2 * r2))
    }
    dot(CGPoint(x: size * 0.22, y: size * 0.28), NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1))
    dot(CGPoint(x: size * 0.78, y: size * 0.74), NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.25, alpha: 1))
    ctx.restoreGState()
    img.unlockFocus()
    return img
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("TraceIcon.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let sizes: [(String, CGFloat)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes {
    let img = draw(size: px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: tmp.appendingPathComponent("icon_\(name).png"))
}
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", tmp.path, "-o", outPath]
task.launch()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Icône écrite : \(outPath)" : "Échec iconutil")
