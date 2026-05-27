#!/usr/bin/env swift
//
// generate-icon-options.swift — produces several 1024×1024 icon
// concepts for Tailspot. Outputs to tools/icon-options/ for human
// review. Once you pick one, copy its three files into the active
// AppIcon.appiconset/.
//
// Each variant produces three PNGs:
//   <name>-light.png    (default appearance)
//   <name>-dark.png     (iOS dark-mode home screen)
//   <name>-tinted.png   (iOS user-tinted variant; grayscale source)
//
// The variants try to be visually distinct so a side-by-side review
// is meaningful. SF Symbols are rendered into the bitmap via
// NSImage(systemSymbolName:) so they pull crisp vector glyphs at any
// size — much cleaner than hand-stroked paths.
//
// Usage:
//   swift tools/generate-icon-options.swift
//

import AppKit
import Foundation

let outputDir = URL(fileURLWithPath: "tools/icon-options")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let size = NSSize(width: 1024, height: 1024)

// Brand palette, sampled from Brand.swift.
let cyan = NSColor(srgbRed: 0x00/255.0, green: 0xD4/255.0, blue: 0xFF/255.0, alpha: 1.0)
let cyanLight = NSColor(srgbRed: 0x6A/255.0, green: 0xE8/255.0, blue: 0xFF/255.0, alpha: 1.0)
let navy = NSColor(srgbRed: 0x0A/255.0, green: 0x0E/255.0, blue: 0x12/255.0, alpha: 1.0)
let deepNavy = NSColor(srgbRed: 0x02/255.0, green: 0x05/255.0, blue: 0x08/255.0, alpha: 1.0)
let midNavy = NSColor(srgbRed: 0x13/255.0, green: 0x18/255.0, blue: 0x20/255.0, alpha: 1.0)

// MARK: - Bitmap helpers

func makeBitmap() -> NSBitmapImageRep {
    NSBitmapImageRep(
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
}

func render(into rep: NSBitmapImageRep, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: url)
}

func fillBackground(_ colors: [NSColor], angle: CGFloat = -45) {
    let gradient = NSGradient(colors: colors)!
    gradient.draw(in: NSRect(origin: .zero, size: size), angle: angle)
}

func solidFill(_ color: NSColor) {
    color.setFill()
    NSRect(origin: .zero, size: size).fill()
}

func drawSymbol(_ name: String, tint: NSColor, in rect: NSRect, weight: NSFont.Weight = .bold) {
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
    let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight, scale: .large)
        .applying(.init(paletteColors: [tint]))
    guard let configured = symbol.withSymbolConfiguration(config) else { return }
    // Center within `rect`, preserving the symbol's aspect.
    let sourceSize = configured.size
    let scale = min(rect.width / sourceSize.width, rect.height / sourceSize.height)
    let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    let origin = NSPoint(
        x: rect.midX - drawSize.width / 2,
        y: rect.midY - drawSize.height / 2
    )
    configured.draw(in: NSRect(origin: origin, size: drawSize))
}

func drawHangarPath(centeredIn rect: NSRect, color: NSColor, strokeWidth: CGFloat, filled: Bool = false) {
    let scale = rect.width / 24.0
    let cx = rect.midX
    let cy = rect.midY
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: cx + (x - 12) * scale, y: cy + (12 - y) * scale)
    }
    let outer = NSBezierPath()
    outer.lineWidth = strokeWidth
    outer.lineJoinStyle = .miter
    outer.miterLimit = 4
    outer.move(to: p(3, 11))
    outer.line(to: p(12, 5))
    outer.line(to: p(21, 11))
    outer.line(to: p(21, 20))
    outer.line(to: p(3, 20))
    outer.close()

    if filled {
        color.setFill()
        outer.fill()
    } else {
        color.setStroke()
        outer.stroke()
        let eaves = NSBezierPath()
        eaves.lineWidth = strokeWidth
        eaves.move(to: p(3, 11))
        eaves.line(to: p(21, 11))
        eaves.stroke()
    }
}

func drawCornerBrackets(in rect: NSRect, color: NSColor, thickness: CGFloat, length: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = thickness
    path.lineCapStyle = .round
    // Top-left
    path.move(to: NSPoint(x: rect.minX, y: rect.minY + length))
    path.line(to: NSPoint(x: rect.minX, y: rect.minY))
    path.line(to: NSPoint(x: rect.minX + length, y: rect.minY))
    // Top-right
    path.move(to: NSPoint(x: rect.maxX - length, y: rect.minY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.minY + length))
    // Bottom-left
    path.move(to: NSPoint(x: rect.minX, y: rect.maxY - length))
    path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
    path.line(to: NSPoint(x: rect.minX + length, y: rect.maxY))
    // Bottom-right
    path.move(to: NSPoint(x: rect.maxX - length, y: rect.maxY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - length))
    color.setStroke()
    path.stroke()
}

func drawText(_ string: String, font: NSFont, color: NSColor, in rect: NSRect) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: para,
    ]
    let measured = (string as NSString).size(withAttributes: attrs)
    let origin = NSPoint(
        x: rect.midX - measured.width / 2,
        y: rect.midY - measured.height / 2
    )
    (string as NSString).draw(at: origin, withAttributes: attrs)
}

// MARK: - Variants

/// Variant A — sharp commercial-jet symbol on a vertical navy gradient.
/// Bold and recognizable; reads from a long distance.
func renderPlaneJet(_ rep: NSBitmapImageRep, glyph: NSColor, bg: [NSColor]) {
    render(into: rep) {
        fillBackground(bg, angle: -90)
        let glyphRect = NSRect(x: size.width * 0.18, y: size.height * 0.18,
                               width: size.width * 0.64, height: size.height * 0.64)
        drawSymbol("airplane", tint: glyph, in: glyphRect)
    }
}

/// Variant B — AR lock-on aesthetic: cyan corner brackets with a small
/// plane symbol centered. References the actual app's HUD.
func renderLockOn(_ rep: NSBitmapImageRep, glyph: NSColor, bracket: NSColor, bg: [NSColor]) {
    render(into: rep) {
        fillBackground(bg, angle: -90)
        let bracketsRect = NSRect(x: size.width * 0.22, y: size.height * 0.22,
                                  width: size.width * 0.56, height: size.height * 0.56)
        drawCornerBrackets(in: bracketsRect, color: bracket, thickness: 28, length: 90)
        let planeRect = NSRect(x: size.width * 0.32, y: size.height * 0.32,
                               width: size.width * 0.36, height: size.height * 0.36)
        drawSymbol("airplane", tint: glyph, in: planeRect)
    }
}

/// Variant C — bold T monogram, brand-forward. Mono-style typography.
func renderMonogram(_ rep: NSBitmapImageRep, fg: NSColor, bg: [NSColor]) {
    render(into: rep) {
        fillBackground(bg, angle: -45)
        let font = NSFont.monospacedSystemFont(ofSize: 740, weight: .heavy)
        drawText("T", font: font, color: fg,
                 in: NSRect(origin: .zero, size: size))
    }
}

/// Variant D — high-contrast badge: solid cyan disk on dark, with a
/// dark plane silhouette on top. Looks like a sticker / pin.
func renderBadge(_ rep: NSBitmapImageRep, diskColor: NSColor, glyph: NSColor, bg: NSColor) {
    render(into: rep) {
        solidFill(bg)
        let pad = size.width * 0.10
        let diskRect = NSRect(x: pad, y: pad, width: size.width - 2*pad, height: size.height - 2*pad)
        diskColor.setFill()
        NSBezierPath(ovalIn: diskRect).fill()
        let planeRect = NSRect(x: size.width * 0.22, y: size.height * 0.22,
                               width: size.width * 0.56, height: size.height * 0.56)
        drawSymbol("airplane", tint: glyph, in: planeRect)
    }
}

/// Variant E — refined HangarGlyph: filled cyan pentagon on a dark
/// gradient, no eaves line (cleaner at small sizes). Evolution of the
/// current icon but less stroke-y.
func renderHangarSolid(_ rep: NSBitmapImageRep, fg: NSColor, bg: [NSColor]) {
    render(into: rep) {
        fillBackground(bg, angle: -90)
        let glyphRect = NSRect(x: size.width * 0.18, y: size.height * 0.18,
                               width: size.width * 0.64, height: size.height * 0.64)
        drawHangarPath(centeredIn: glyphRect, color: fg, strokeWidth: 0, filled: true)
    }
}

/// Variant F — radar-sweep aesthetic: concentric cyan rings on dark,
/// with a small plane in the middle. Suggests scanning the sky.
func renderRadar(_ rep: NSBitmapImageRep, ring: NSColor, glyph: NSColor, bg: NSColor) {
    render(into: rep) {
        solidFill(bg)
        let cx = size.width / 2
        let cy = size.height / 2
        for (i, alpha) in [(0.95, 0.25), (0.75, 0.40), (0.55, 0.60), (0.35, 0.80)].enumerated() {
            let radius = size.width * 0.45 * CGFloat(alpha.0)
            let stroke = ring.withAlphaComponent(CGFloat(alpha.1))
            let circle = NSBezierPath(ovalIn: NSRect(x: cx - radius, y: cy - radius,
                                                     width: radius * 2, height: radius * 2))
            circle.lineWidth = 12 + CGFloat(i) * 4
            stroke.setStroke()
            circle.stroke()
        }
        let planeRect = NSRect(x: size.width * 0.36, y: size.height * 0.36,
                               width: size.width * 0.28, height: size.height * 0.28)
        drawSymbol("airplane", tint: glyph, in: planeRect)
    }
}

// MARK: - Variant catalog

struct Variant {
    let name: String
    let lightDrawer: (NSBitmapImageRep) -> Void
    let darkDrawer: (NSBitmapImageRep) -> Void
    let tintedDrawer: (NSBitmapImageRep) -> Void
}

let variants: [Variant] = [
    Variant(
        name: "A-plane",
        lightDrawer: { renderPlaneJet($0, glyph: cyan, bg: [midNavy, navy]) },
        darkDrawer:  { renderPlaneJet($0, glyph: cyanLight, bg: [navy, deepNavy]) },
        tintedDrawer: { renderPlaneJet($0, glyph: .white, bg: [.black, .black]) }
    ),
    Variant(
        name: "B-lockon",
        lightDrawer: { renderLockOn($0, glyph: .white, bracket: cyan, bg: [midNavy, navy]) },
        darkDrawer:  { renderLockOn($0, glyph: cyanLight, bracket: cyan, bg: [navy, deepNavy]) },
        tintedDrawer: { renderLockOn($0, glyph: .white, bracket: .white, bg: [.black, .black]) }
    ),
    Variant(
        name: "C-monogram",
        lightDrawer: { renderMonogram($0, fg: .white, bg: [cyan, navy]) },
        darkDrawer:  { renderMonogram($0, fg: cyan, bg: [navy, deepNavy]) },
        tintedDrawer: { renderMonogram($0, fg: .white, bg: [.black, .black]) }
    ),
    Variant(
        name: "D-badge",
        lightDrawer: { renderBadge($0, diskColor: cyan, glyph: navy, bg: navy) },
        darkDrawer:  { renderBadge($0, diskColor: cyan, glyph: deepNavy, bg: deepNavy) },
        tintedDrawer: { renderBadge($0, diskColor: .white, glyph: .black, bg: .black) }
    ),
    Variant(
        name: "E-hangar-solid",
        lightDrawer: { renderHangarSolid($0, fg: cyan, bg: [midNavy, navy]) },
        darkDrawer:  { renderHangarSolid($0, fg: cyanLight, bg: [navy, deepNavy]) },
        tintedDrawer: { renderHangarSolid($0, fg: .white, bg: [.black, .black]) }
    ),
    Variant(
        name: "F-radar",
        lightDrawer: { renderRadar($0, ring: cyan, glyph: .white, bg: navy) },
        darkDrawer:  { renderRadar($0, ring: cyanLight, glyph: cyanLight, bg: deepNavy) },
        tintedDrawer: { renderRadar($0, ring: .white, glyph: .white, bg: .black) }
    ),
]

for v in variants {
    let lightRep = makeBitmap()
    v.lightDrawer(lightRep)
    try writePNG(lightRep, to: outputDir.appendingPathComponent("\(v.name)-light.png"))

    let darkRep = makeBitmap()
    v.darkDrawer(darkRep)
    try writePNG(darkRep, to: outputDir.appendingPathComponent("\(v.name)-dark.png"))

    let tintedRep = makeBitmap()
    v.tintedDrawer(tintedRep)
    try writePNG(tintedRep, to: outputDir.appendingPathComponent("\(v.name)-tinted.png"))

    print("Wrote \(v.name) (light/dark/tinted) — 1024×1024 each")
}

print("Done. Review the PNGs in tools/icon-options/; pick one and tell Claude to install it.")
