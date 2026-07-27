import AppKit
import Foundation

func squirclePath(in rect: NSRect, radiusRatio: CGFloat) -> NSBezierPath {
    let radius = rect.width * radiusRatio
    return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let inset = size * 0.0977
    let content = canvas.insetBy(dx: inset, dy: inset)
    let body = squirclePath(in: content, radiusRatio: 0.2237)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.012),
        blur: size * 0.03,
        color: NSColor.black.withAlphaComponent(0.28).cgColor
    )
    NSColor.black.setFill()
    body.fill()
    ctx.restoreGState()

    ctx.saveGState()
    body.addClip()
    let top = NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.96, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.16, green: 0.31, blue: 0.78, alpha: 1)
    NSGradient(starting: top, ending: bottom)?.draw(in: content, angle: -90)

    let glow = NSGradient(
        colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0.0)]
    )
    let glowRect = NSRect(
        x: content.minX - content.width * 0.2,
        y: content.midY,
        width: content.width * 1.4,
        height: content.height * 0.75
    )
    glow?.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)
    ctx.restoreGState()

    ctx.saveGState()
    let ringOuter = content.width * 0.52
    let ringWidth = ringOuter * 0.135
    let ringSpan = ringOuter - ringWidth
    let ringRect = NSRect(
        x: content.midX - ringSpan / 2,
        y: content.midY - ringSpan / 2,
        width: ringSpan,
        height: ringSpan
    )
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.004),
        blur: size * 0.012,
        color: NSColor.black.withAlphaComponent(0.25).cgColor
    )
    let ring = NSBezierPath(ovalIn: ringRect)
    ring.lineWidth = ringWidth
    NSColor.white.setStroke()
    ring.stroke()

    let dot = content.width * 0.205
    let dotRect = NSRect(
        x: content.midX - dot / 2,
        y: content.midY - dot / 2,
        width: dot,
        height: dot
    )
    NSColor.white.setFill()
    NSBezierPath(ovalIn: dotRect).fill()
    ctx.restoreGState()

    ctx.saveGState()
    body.addClip()
    let rim = squirclePath(in: content.insetBy(dx: size * 0.004, dy: size * 0.004), radiusRatio: 0.2237)
    rim.lineWidth = size * 0.008
    NSColor.white.withAlphaComponent(0.22).setStroke()
    rim.stroke()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let specs: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

let dir = "/tmp/iconmake/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, size) in specs {
    let rep = drawIcon(size: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
print("generated \(specs.count) sizes")
