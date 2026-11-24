// Draws Metal-PT's app icon (a gauge on a dark rounded square) with CoreGraphics and writes AppIcon.icns.
//
//     swift scripts/make-icon.swift [OUT_DIR]      # default Resources/MetalPT
//
// Writes OUT_DIR/AppIcon.iconset/*.png (every size iconutil wants), OUT_DIR/AppIcon-1024.png (for review), and
// OUT_DIR/AppIcon.icns via `iconutil`. The iconset folder is removed afterwards. Re-run after changing the drawing
// and commit the new AppIcon.icns.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/MetalPT",
                 isDirectory: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// The icon at `size` pixels square. Drawn on a 1024 grid (macOS icon template: an 824 pt rounded square, centred).
func draw(size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(size) / 1024
    ctx.scaleBy(x: k, y: k)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Background: dark rounded square with a soft vertical gradient and a drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(22, 24, 30))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [rgb(44, 48, 58), rgb(16, 17, 22)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A thin inner highlight along the edge.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
    ctx.setStrokeColor(rgb(255, 255, 255, 0.08))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()

    // Gauge: a 260° arc, its colour running green → amber → red, opening downwards.
    let centre = CGPoint(x: 512, y: 470)
    let radius: CGFloat = 270
    let startDeg: CGFloat = 220   // lower left (CG angles: counter-clockwise from +x)
    let sweep: CGFloat = 260      // clockwise to lower right
    func point(_ deg: CGFloat, _ r: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: centre.x + r * cos(a), y: centre.y + r * sin(a))
    }
    // Track.
    ctx.setLineCap(.round)
    ctx.setLineWidth(56)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.07))
    ctx.addArc(center: centre, radius: radius, startAngle: startDeg * .pi / 180,
               endAngle: (startDeg - sweep) * .pi / 180, clockwise: true)
    ctx.strokePath()
    // Coloured band, drawn as short segments so the colour can sweep along the arc.
    let stops: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
        (0, (52, 211, 153)), (0.55, (250, 204, 21)), (1, (248, 82, 82)),
    ]
    func colour(_ t: CGFloat) -> CGColor {
        for i in 1..<stops.count where t <= stops[i].0 {
            let (t0, c0) = stops[i - 1], (t1, c1) = stops[i]
            let u = (t - t0) / (t1 - t0)
            return rgb(c0.0 + (c1.0 - c0.0) * u, c0.1 + (c1.1 - c0.1) * u, c0.2 + (c1.2 - c0.2) * u)
        }
        let c = stops.last!.1
        return rgb(c.0, c.1, c.2)
    }
    let band: CGFloat = 0.78   // the needle sits near the top of the band
    let segments = 120
    ctx.setLineCap(.butt)
    for i in 0..<segments {
        let t0 = CGFloat(i) / CGFloat(segments) * band
        let t1 = CGFloat(i + 1) / CGFloat(segments) * band + 0.002
        ctx.setStrokeColor(colour(t0 / band * 0.95))
        ctx.addArc(center: centre, radius: radius, startAngle: (startDeg - sweep * t0) * .pi / 180,
                   endAngle: (startDeg - sweep * t1) * .pi / 180, clockwise: true)
        ctx.strokePath()
    }
    // Round caps at both ends of the band.
    for (t, c) in [(CGFloat(0), colour(0)), (band, colour(0.95))] {
        let p = point(startDeg - sweep * t, radius)
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: p.x - 28, y: p.y - 28, width: 56, height: 56))
    }
    // Ticks inside the arc.
    ctx.setLineCap(.round)
    for i in 0...10 {
        let deg = startDeg - sweep * CGFloat(i) / 10
        let major = i % 5 == 0
        ctx.setStrokeColor(rgb(255, 255, 255, major ? 0.75 : 0.4))
        ctx.setLineWidth(major ? 14 : 9)
        ctx.move(to: point(deg, radius - 62))
        ctx.addLine(to: point(deg, radius - (major ? 120 : 100)))
        ctx.strokePath()
    }
    // Needle, pointing at the end of the band.
    let needleDeg = startDeg - sweep * band
    let tip = point(needleDeg, radius - 70)
    let a = needleDeg * .pi / 180
    let side = CGPoint(x: -sin(a) * 22, y: cos(a) * 22)
    let tail = point(needleDeg + 180, 30)   // inside the hub (radius 48)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0, 0, 0, 0.5))
    ctx.move(to: tip)
    ctx.addLine(to: CGPoint(x: tail.x + side.x, y: tail.y + side.y))
    ctx.addLine(to: CGPoint(x: tail.x - side.x, y: tail.y - side.y))
    ctx.closePath()
    ctx.setFillColor(rgb(245, 246, 250))
    ctx.fillPath()
    // Hub.
    ctx.setFillColor(rgb(245, 246, 250))
    ctx.fillEllipse(in: CGRect(x: centre.x - 48, y: centre.y - 48, width: 96, height: 96))
    ctx.restoreGState()
    ctx.setFillColor(rgb(30, 32, 40))
    ctx.fillEllipse(in: CGRect(x: centre.x - 20, y: centre.y - 20, width: 40, height: 40))

    // Under the gauge: five bars of a frame-time graph (no font needed).
    ctx.setFillColor(rgb(255, 255, 255, 0.55))
    for (i, h) in [CGFloat(54), 96, 70, 120, 62].enumerated() {
        let w: CGFloat = 34
        let x = 512 - (5 * w + 4 * 20) / 2 + CGFloat(i) * (w + 20)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 178, width: w, height: h), cornerWidth: 10,
                           cornerHeight: 10, transform: nil))
        ctx.fillPath()
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let fm = FileManager.default
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(draw(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(draw(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
writePNG(draw(size: 1024), to: outDir.appendingPathComponent("AppIcon-1024.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
try? fm.removeItem(at: iconset)
guard p.terminationStatus == 0 else { fatalError("iconutil exited with \(p.terminationStatus)") }
print("wrote \(outDir.appendingPathComponent("AppIcon.icns").path)")
