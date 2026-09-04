#!/usr/bin/env swift
import AppKit

/// A shard of dark glass on a white ground — BlackGlass's app icon.

let pixels = 1024
let outPNG = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/Resources/AppIcon-1024.png"

/// Irregular, angular sliver — deliberately not a symmetric diamond, so it
/// reads as a broken fragment rather than a gemstone. Normalized to a unit
/// square; callers scale to whatever canvas they're drawing into.
func shardPath(in rect: NSRect) -> NSBezierPath {
    let points: [(CGFloat, CGFloat)] = [
        (0.40, 0.78),
        (0.62, 0.87),
        (0.55, 0.69),
        (0.67, 0.58),
        (0.49, 0.13),
        (0.36, 0.41),
    ]
    let path = NSBezierPath()
    for (index, point) in points.enumerated() {
        let p = NSPoint(x: rect.minX + point.0 * rect.width, y: rect.minY + point.1 * rect.height)
        if index == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.close()
    return path
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
rep.size = NSSize(width: pixels, height: pixels)

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("error: no graphics context\n", stderr)
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
ctx.imageInterpolation = .high
ctx.shouldAntialias = true

// Clean white ground — the shard's dark glass carries all the contrast.
NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: pixels, height: pixels)).fill()

let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
let shard = shardPath(in: canvas)

// Soft shadow so the shard lifts off the white ground instead of looking flat.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.22).cgColor)
NSColor.white.withAlphaComponent(0.001).setFill()
shard.fill()
cg.restoreGState()

// Glassy body: a top-to-bottom gradient between two very dark greys, giving
// the flat fill some depth without needing real refraction.
if let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 0.97),
    NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 0.92),
]) {
    cg.saveGState()
    shard.addClip()
    gradient.draw(in: canvas, angle: -90)
    cg.restoreGState()
}

// A bright glint along the leading edge — the single detail that reads as
// "glass" rather than a flat painted shape.
let glint = NSBezierPath()
glint.move(to: NSPoint(x: canvas.minX + 0.40 * canvas.width, y: canvas.minY + 0.78 * canvas.height))
glint.line(to: NSPoint(x: canvas.minX + 0.49 * canvas.width, y: canvas.minY + 0.13 * canvas.height))
glint.lineWidth = CGFloat(pixels) * 0.012
glint.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.55).setStroke()
glint.stroke()

// Thin dark edge so the shard separates cleanly from light wallpapers/Dock themes.
shard.lineWidth = CGFloat(pixels) * 0.004
NSColor.black.withAlphaComponent(0.5).setStroke()
shard.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("error: png encode failed\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPNG))
print("wrote \(outPNG)")
