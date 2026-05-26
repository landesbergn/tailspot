#!/usr/bin/env swift
//
// generate-app-icon.swift — produces 1024×1024 PNGs for Tailspot's
// AppIcon.appiconset, in three variants (light / dark / tinted).
//
// Why this script: a placeholder app icon is a TestFlight blocker
// (or at least an embarrassing default). We don't have a designed
// icon yet, so this generates a workmanlike one from existing brand
// elements — the HangarGlyph peaked-roof pentagon on a cyan→navy
// gradient. Swap in a real designed icon later by replacing the
// three PNGs in AppIcon.appiconset/.
//
// Usage:
//   swift tools/generate-app-icon.swift
//
// Writes:
//   ios/Tailspot/Tailspot/Assets.xcassets/AppIcon.appiconset/icon-light.png
//   ios/Tailspot/Tailspot/Assets.xcassets/AppIcon.appiconset/icon-dark.png
//   ios/Tailspot/Tailspot/Assets.xcassets/AppIcon.appiconset/icon-tinted.png
//
// And rewrites Contents.json to reference them.
//

import AppKit
import Foundation

let outputDir = URL(fileURLWithPath: "ios/Tailspot/Tailspot/Assets.xcassets/AppIcon.appiconset")
let size = NSSize(width: 1024, height: 1024)

// Brand cyan + deep navy, sampled from Brand.swift.
let cyan = NSColor(srgbRed: 0x00/255.0, green: 0xD4/255.0, blue: 0xFF/255.0, alpha: 1.0)
let navy = NSColor(srgbRed: 0x0A/255.0, green: 0x0E/255.0, blue: 0x12/255.0, alpha: 1.0)
let deepNavy = NSColor(srgbRed: 0x02/255.0, green: 0x05/255.0, blue: 0x08/255.0, alpha: 1.0)

// Draws the HangarGlyph (peaked-roof pentagon + horizontal eaves
// line). The original SVG viewBox is 24×24; we map that onto a
// centered square within the canvas.
//
// SVG path summary:
//   Outer: M3 11 L12 5 L21 11 L21 20 L3 20 Z (pentagonal hangar silhouette)
//   Eaves: M3 11 H21 (horizontal line where the roof meets the walls)
func drawHangarGlyph(in canvas: NSSize, color: NSColor, lineWidth: CGFloat) {
    let inset: CGFloat = canvas.width * 0.20    // 20% margin
    let glyphSize: CGFloat = canvas.width - 2 * inset
    let scale = glyphSize / 24.0

    let cx = canvas.width / 2
    let cy = canvas.height / 2

    // Translate (x, y) from SVG coordinates (0,0 top-left, y down)
    // into NSBezierPath's bottom-up coordinate system, centered on
    // the canvas.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let dx = (x - 12) * scale
        let dy = (12 - y) * scale          // flip y
        return CGPoint(x: cx + dx, y: cy + dy)
    }

    let outer = NSBezierPath()
    outer.lineWidth = lineWidth
    outer.lineJoinStyle = .round
    outer.lineCapStyle = .round
    outer.move(to: p(3, 11))
    outer.line(to: p(12, 5))
    outer.line(to: p(21, 11))
    outer.line(to: p(21, 20))
    outer.line(to: p(3, 20))
    outer.close()

    let eaves = NSBezierPath()
    eaves.lineWidth = lineWidth
    eaves.lineCapStyle = .round
    eaves.move(to: p(3, 11))
    eaves.line(to: p(21, 11))

    color.setStroke()
    outer.stroke()
    eaves.stroke()
}

/// Draws into a bitmap rep with explicit pixel dimensions so the
/// output is exactly 1024×1024 px (NSImage's default would scale to
/// 2048×2048 on Retina hosts, which the asset catalog rejects).
func drawIcon(background: (NSColor, NSColor), glyphColor: NSColor, gradientAngle: CGFloat = -45) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let gradient = NSGradient(colors: [background.0, background.1])!
    gradient.draw(in: NSRect(origin: .zero, size: size), angle: gradientAngle)
    drawHangarGlyph(in: size, color: glyphColor, lineWidth: 40)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let png = rep.representation(using: .png, properties: [
        .interlaced: false,
    ]) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG conversion failed"])
    }
    try png.write(to: url)
    print("Wrote \(url.path) (\(png.count) bytes, \(rep.pixelsWide)×\(rep.pixelsHigh) px)")
}

// Light variant — cyan→navy diagonal gradient, white glyph for max
// contrast. This is the default icon users see on light home screens.
let light = drawIcon(
    background: (cyan, navy),
    glyphColor: NSColor.white
)

// Dark variant — darker gradient (deepNavy→pure black), cyan glyph.
// iOS uses this on systems set to dark home-screen icons.
let dark = drawIcon(
    background: (navy, deepNavy),
    glyphColor: cyan
)

// Tinted variant — iOS 17+ takes a grayscale source and applies the
// user-selected tint. We give it a pure dark canvas with a white
// glyph; iOS handles the rest.
let tinted = drawIcon(
    background: (NSColor.black, NSColor.black),
    glyphColor: NSColor.white
)

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
try writePNG(light,  to: outputDir.appendingPathComponent("icon-light.png"))
try writePNG(dark,   to: outputDir.appendingPathComponent("icon-dark.png"))
try writePNG(tinted, to: outputDir.appendingPathComponent("icon-tinted.png"))

// Update Contents.json so Xcode wires the new PNGs to the appropriate
// luminosity slots.
let contents: [String: Any] = [
    "images": [
        [
            "filename": "icon-light.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        ],
        [
            "appearances": [
                ["appearance": "luminosity", "value": "dark"],
            ],
            "filename": "icon-dark.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        ],
        [
            "appearances": [
                ["appearance": "luminosity", "value": "tinted"],
            ],
            "filename": "icon-tinted.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        ],
    ],
    "info": [
        "author": "tailspot-tools",
        "version": 1,
    ],
]

let data = try JSONSerialization.data(
    withJSONObject: contents,
    options: [.prettyPrinted, .sortedKeys]
)
let contentsURL = outputDir.appendingPathComponent("Contents.json")
try data.write(to: contentsURL)
print("Wrote \(contentsURL.path)")
