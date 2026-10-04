#!/usr/bin/env swift
// Generates the app icon: a Dock shelf of app tiles above its mirror image.
// Run with:
//   swift Tools/generate_icon.swift
// then rebuild the .icns with Tools/make_icns.sh.
//
// Draws into a fixed 1024px bitmap rather than NSImage.lockFocus, which
// renders at 2x on a Retina display.

import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let canvas = CGFloat(size)
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// MARK: - Tile

let margin = canvas * 0.09
let tile = CGRect(x: margin, y: margin, width: canvas - margin * 2, height: canvas - margin * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012), blur: canvas * 0.03, color: rgb(0, 0, 0, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0.1, 0.1, 0.2))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let body = CGGradient(colorsSpace: space, colors: [rgb(0.16, 0.20, 0.42), rgb(0.06, 0.08, 0.20)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(body, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])

// MARK: - Dock and reflection

let horizon = tile.minY + tile.height * 0.47
let shelfWidth = tile.width * 0.78
let shelfHeight = tile.height * 0.20
let shelf = CGRect(x: tile.midX - shelfWidth / 2, y: horizon + tile.height * 0.025, width: shelfWidth, height: shelfHeight)

let colors: [(CGColor, CGColor)] = [
    (rgb(0.33, 0.78, 1.00), rgb(0.10, 0.48, 0.95)),
    (rgb(0.45, 0.90, 0.45), rgb(0.12, 0.65, 0.30)),
    (rgb(1.00, 0.78, 0.25), rgb(0.98, 0.52, 0.10)),
    (rgb(1.00, 0.45, 0.50), rgb(0.88, 0.18, 0.35)),
]

func drawDock(alpha: CGFloat) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    let shelfPath = CGPath(roundedRect: shelf, cornerWidth: shelfHeight * 0.32, cornerHeight: shelfHeight * 0.32, transform: nil)
    ctx.addPath(shelfPath)
    ctx.setFillColor(rgb(1, 1, 1, 0.16))
    ctx.fillPath()
    ctx.addPath(shelfPath)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.28))
    ctx.setLineWidth(canvas * 0.004)
    ctx.strokePath()

    let inset = shelfHeight * 0.16
    let iconSide = shelfHeight - inset * 2
    let gap = (shelf.width - inset * 2 - iconSide * CGFloat(colors.count)) / CGFloat(colors.count - 1)
    for (i, pair) in colors.enumerated() {
        let rect = CGRect(x: shelf.minX + inset + CGFloat(i) * (iconSide + gap), y: shelf.minY + inset,
                          width: iconSide, height: iconSide)
        let path = CGPath(roundedRect: rect, cornerWidth: iconSide * 0.24, cornerHeight: iconSide * 0.24, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [pair.0, pair.1] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

drawDock(alpha: 1)

// The reflection: the same Dock flipped about the horizon, fading out.
ctx.saveGState()
ctx.translateBy(x: 0, y: horizon * 2)
ctx.scaleBy(x: 1, y: -1)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
drawDock(alpha: 0.55)
// Fade with distance from the horizon (in flipped space, that's upward).
ctx.setBlendMode(.destinationIn)
let fade = CGGradient(colorsSpace: space, colors: [rgb(0, 0, 0, 1), rgb(0, 0, 0, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: horizon + shelfHeight * 1.3), options: [])
ctx.endTransparencyLayer()
ctx.restoreGState()

// The mirror line.
ctx.setFillColor(rgb(1, 1, 1, 0.55))
ctx.fill(CGRect(x: shelf.minX - tile.width * 0.03, y: horizon - canvas * 0.003, width: shelf.width + tile.width * 0.06, height: canvas * 0.006))

ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: "Resources/AppIcon.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
