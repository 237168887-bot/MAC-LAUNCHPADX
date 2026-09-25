#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let appIconSet = root.appendingPathComponent("LaunchpadX/Assets.xcassets/AppIcon.appiconset")
let iconComposerAsset = root.appendingPathComponent("LaunchpadX/AppIcon.icon/Assets/AppIcon-512@2x.png")
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawGradient(_ context: CGContext, colors: [CGColor], in rect: CGRect) {
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1]) else { return }
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
}

let size = 1_024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: colorSpace,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setAllowsAntialiasing(true)
context.interpolationQuality = .high

let body = CGRect(x: 112, y: 112, width: 800, height: 800)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: color(0, 0, 0, 0.24))
context.addPath(roundedRect(body, radius: 180))
context.setFillColor(color(0.84, 0.86, 0.89))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(roundedRect(body, radius: 180))
context.clip()
drawGradient(context, colors: [color(0.98, 0.99, 1), color(0.78, 0.81, 0.87)], in: body)
context.restoreGState()
context.addPath(roundedRect(body.insetBy(dx: 5, dy: 5), radius: 175))
context.setStrokeColor(color(1, 1, 1, 0.75))
context.setLineWidth(10)
context.strokePath()

let tileSize: CGFloat = 184
let gap: CGFloat = 30
let startX: CGFloat = 206
let startY: CGFloat = 206
let palette: [(CGColor, CGColor)] = [
    (color(1.00, 0.37, 0.35), color(0.91, 0.13, 0.31)),
    (color(1.00, 0.73, 0.27), color(0.98, 0.47, 0.12)),
    (color(1.00, 0.91, 0.30), color(0.93, 0.72, 0.12)),
    (color(0.38, 0.85, 0.47), color(0.10, 0.67, 0.39)),
    (color(0.32, 0.82, 0.95), color(0.12, 0.58, 0.84)),
    (color(0.32, 0.58, 1.00), color(0.23, 0.34, 0.86)),
    (color(0.60, 0.50, 0.98), color(0.43, 0.34, 0.85)),
    (color(0.97, 0.52, 0.77), color(0.84, 0.26, 0.64)),
    (color(0.69, 0.75, 0.83), color(0.42, 0.51, 0.63)),
]

for row in 0..<3 {
    for column in 0..<3 {
        let tile = CGRect(x: startX + CGFloat(column) * (tileSize + gap),
                          y: startY + CGFloat(2 - row) * (tileSize + gap),
                          width: tileSize, height: tileSize)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -9), blur: 12, color: color(0.13, 0.18, 0.29, 0.26))
        context.addPath(roundedRect(tile, radius: 44))
        context.setFillColor(palette[row * 3 + column].1)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(roundedRect(tile, radius: 44))
        context.clip()
        drawGradient(context, colors: [palette[row * 3 + column].0, palette[row * 3 + column].1], in: tile)
        context.restoreGState()

        context.addPath(roundedRect(tile.insetBy(dx: 2, dy: 2), radius: 42))
        context.setStrokeColor(color(1, 1, 1, 0.42))
        context.setLineWidth(4)
        context.strokePath()
    }
}

let image = context.makeImage()!
let outputs: [(String, Int)] = [
    ("AppIcon-16.png", 16), ("AppIcon-16@2x.png", 32),
    ("AppIcon-32.png", 32), ("AppIcon-32@2x.png", 64),
    ("AppIcon-128.png", 128), ("AppIcon-128@2x.png", 256),
    ("AppIcon-256.png", 256), ("AppIcon-256@2x.png", 512),
    ("AppIcon-512.png", 512), ("AppIcon-512@2x.png", 1_024),
]

for (name, dimension) in outputs {
    let target = appIconSet.appendingPathComponent(name)
    let scaled = CGContext(data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
                           bytesPerRow: dimension * 4, space: colorSpace,
                           bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
    scaled.interpolationQuality = .high
    scaled.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
    let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, scaled.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(target.path)") }
}
try Data(contentsOf: appIconSet.appendingPathComponent("AppIcon-512@2x.png")).write(to: iconComposerAsset)
