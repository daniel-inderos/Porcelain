#!/usr/bin/env swift
// Generates Assets/icon-1024.png: a porcelain squircle with a git branch
// graph drawn as kintsugi-style gold lines. Run scripts/make_app_icon.sh to
// regenerate the full .icns from this.

import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("No graphics context")
}

// macOS icon grid: the squircle occupies the center ~824pt of the canvas.
let inset: CGFloat = 100
let squircleRect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let squircle = NSBezierPath(roundedRect: squircleRect, xRadius: 185, yRadius: 185)

// Drop shadow behind the tile.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.30).cgColor)
NSColor.white.setFill()
squircle.fill()
context.restoreGState()

// Porcelain glaze: cool white vertical gradient.
context.saveGState()
squircle.addClip()
let glaze = NSGradient(colors: [
    NSColor(calibratedRed: 0.985, green: 0.984, blue: 0.972, alpha: 1),
    NSColor(calibratedRed: 0.937, green: 0.945, blue: 0.957, alpha: 1),
    NSColor(calibratedRed: 0.886, green: 0.902, blue: 0.925, alpha: 1)
])!
glaze.draw(in: squircle, angle: -90)

// Soft highlight across the upper third, like light on a glazed surface.
let highlight = NSGradient(
    starting: NSColor.white.withAlphaComponent(0.55),
    ending: NSColor.white.withAlphaComponent(0.0)
)!
let highlightPath = NSBezierPath(
    ovalIn: CGRect(x: squircleRect.minX - 120, y: squircleRect.maxY - 290, width: squircleRect.width + 240, height: 420)
)
highlight.draw(in: highlightPath, angle: -90)
context.restoreGState()

// Kintsugi git graph: a main line with one branch that diverges and merges,
// drawn in gold. Git history flows bottom to top.
func goldStroke(_ path: NSBezierPath, width: CGFloat) {
    context.saveGState()
    context.setShadow(offset: .zero, blur: 14, color: NSColor(calibratedRed: 0.72, green: 0.53, blue: 0.13, alpha: 0.45).cgColor)
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSColor(calibratedRed: 0.78, green: 0.60, blue: 0.18, alpha: 1).setStroke()
    path.stroke()
    context.restoreGState()

    // Brighter core line for a metallic feel.
    path.lineWidth = width * 0.52
    NSColor(calibratedRed: 0.93, green: 0.78, blue: 0.38, alpha: 1).setStroke()
    path.stroke()
}

let mainLine = NSBezierPath()
mainLine.move(to: NSPoint(x: 448, y: 212))
mainLine.curve(to: NSPoint(x: 424, y: 512), controlPoint1: NSPoint(x: 470, y: 320), controlPoint2: NSPoint(x: 410, y: 420))
mainLine.curve(to: NSPoint(x: 444, y: 812), controlPoint1: NSPoint(x: 436, y: 600), controlPoint2: NSPoint(x: 426, y: 720))

let branchLine = NSBezierPath()
branchLine.move(to: NSPoint(x: 436, y: 340))
branchLine.curve(to: NSPoint(x: 636, y: 470), controlPoint1: NSPoint(x: 520, y: 360), controlPoint2: NSPoint(x: 624, y: 392))
branchLine.curve(to: NSPoint(x: 628, y: 600), controlPoint1: NSPoint(x: 644, y: 514), controlPoint2: NSPoint(x: 640, y: 560))
branchLine.curve(to: NSPoint(x: 436, y: 712), controlPoint1: NSPoint(x: 612, y: 668), controlPoint2: NSPoint(x: 520, y: 700))

goldStroke(branchLine, width: 30)
goldStroke(mainLine, width: 34)

// Commit nodes.
func commitDot(at point: NSPoint, radius: CGFloat) {
    let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 10, color: NSColor(calibratedRed: 0.72, green: 0.53, blue: 0.13, alpha: 0.5).cgColor)
    NSColor(calibratedRed: 0.80, green: 0.62, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(ovalIn: rect).fill()
    context.restoreGState()

    let innerRect = rect.insetBy(dx: radius * 0.34, dy: radius * 0.34)
    NSColor(calibratedRed: 0.96, green: 0.84, blue: 0.48, alpha: 1).setFill()
    NSBezierPath(ovalIn: innerRect).fill()
}

commitDot(at: NSPoint(x: 448, y: 212), radius: 40)
commitDot(at: NSPoint(x: 444, y: 812), radius: 40)
commitDot(at: NSPoint(x: 636, y: 528), radius: 34)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Could not encode PNG")
}

let outputURL = URL(fileURLWithPath: "Assets/icon-1024.png")
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: outputURL)
print("Wrote \(outputURL.path)")
