#!/usr/bin/env swift
// Draws the app icon and writes build/AppIcon.icns.
//
// Generated rather than checked in so there is no binary blob in the
// tree whose source nobody can find. Run by scripts/build.sh; the
// result is cached, so this only costs anything the first time.

import AppKit
import Foundation

let size: CGFloat = 1024
let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")

try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// macOS icons sit inset inside their canvas — a full-bleed square looks
// oversized next to every other icon in the Dock.
let inset: CGFloat = size * 0.09
let bounds = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let cornerRadius = bounds.width * 0.225

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write(Data("could not allocate bitmap\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let plate = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)

// Deep blue to violet, top-left to bottom-right.
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.14, green: 0.42, blue: 0.98, alpha: 1),
    NSColor(srgbRed: 0.39, green: 0.24, blue: 0.92, alpha: 1),
])
gradient?.draw(in: plate, angle: -55)

// A soft highlight along the top edge, which is what keeps a flat
// gradient from looking like a rectangle of paint.
NSGraphicsContext.current?.saveGraphicsState()
plate.addClip()
let sheen = NSGradient(colors: [
    NSColor(white: 1, alpha: 0.28),
    NSColor(white: 1, alpha: 0.0),
])
sheen?.draw(in: NSRect(x: bounds.minX, y: bounds.midY,
                       width: bounds.width, height: bounds.height / 2), angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()

/// Renders an SF Symbol tinted, on its own transparent canvas.
///
/// The tint has to happen on a transparent backdrop: `sourceAtop`
/// composites onto whatever is already opaque, so doing it straight onto
/// the gradient floods the entire rectangle instead of just the glyph.
func tintedSymbol(_ name: String, pointSize: CGFloat,
                  weight: NSFont.Weight, color: NSColor) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { return nil }

    let canvas = NSImage(size: base.size)
    canvas.lockFocus()
    base.draw(at: .zero, from: NSRect(origin: .zero, size: base.size),
              operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
    canvas.unlockFocus()
    return canvas
}

func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight,
                color: NSColor, center: NSPoint) {
    guard let symbol = tintedSymbol(name, pointSize: pointSize, weight: weight, color: color) else { return }
    symbol.draw(in: NSRect(x: center.x - symbol.size.width / 2,
                           y: center.y - symbol.size.height / 2,
                           width: symbol.size.width, height: symbol.size.height))
}

// One symbol, drawn twice: a soft dark copy underneath acts as a drop
// shadow so the white glyph reads against the lighter end of the
// gradient as well as the darker one.
let glyph = "macbook.and.iphone"
let center = NSPoint(x: size / 2, y: size * 0.47)

drawSymbol(glyph, pointSize: size * 0.52, weight: .regular,
           color: NSColor(srgbRed: 0.06, green: 0.10, blue: 0.35, alpha: 0.35),
           center: NSPoint(x: center.x, y: center.y - size * 0.012))
drawSymbol(glyph, pointSize: size * 0.52, weight: .regular,
           color: NSColor(white: 1, alpha: 1), center: center)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode png\n".utf8))
    exit(1)
}

let master = iconset.appendingPathComponent("icon_512x512@2x.png")
try png.write(to: master)

// iconutil insists on the whole family, by exact filename.
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
]

for (name, pixels) in variants {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = ["-z", "\(pixels)", "\(pixels)", master.path,
                         "--out", iconset.appendingPathComponent(name).path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
}

let icns = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(icns.path)")
