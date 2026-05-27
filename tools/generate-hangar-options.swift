#!/usr/bin/env swift
//
// generate-hangar-options.swift — v4. Abandoning the hand-drawn
// Bezier approach. SF Symbols are professionally designed; rendering
// candidates from Apple's library is faster and produces better
// icons than anything I can hand-stroke in AppKit.
//
// Curated from `airplane.*`, `paperplane.*`, `tray.*`, `archive*`,
// `square.grid.*`, `building.*`. Each candidate fits one of these
// metaphors:
//   - Plane (the object being collected)
//   - Container / tray / archive (the place that holds them)
//   - Grid (the collection itself)
//

import AppKit
import Foundation

let outputDir = URL(fileURLWithPath: "tools/hangar-options")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
for url in (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)) ?? [] {
    try? FileManager.default.removeItem(at: url)
}

let tileSize = NSSize(width: 512, height: 512)
let cyan = NSColor(srgbRed: 0x00/255.0, green: 0xD4/255.0, blue: 0xFF/255.0, alpha: 1.0)
let navy = NSColor(srgbRed: 0x0A/255.0, green: 0x0E/255.0, blue: 0x12/255.0, alpha: 1.0)
let textGray = NSColor(srgbRed: 0x7A/255.0, green: 0x83/255.0, blue: 0x90/255.0, alpha: 1.0)

func makeBitmap(size: NSSize) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
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

func fillBackground(_ color: NSColor, size: NSSize) {
    color.setFill()
    NSRect(origin: .zero, size: size).fill()
}

func drawSymbol(_ name: String, color: NSColor, fraction: CGFloat = 0.65, in canvas: NSSize) {
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        // Some SF Symbols are availability-gated. If missing, draw a
        // placeholder mark so we know which candidate failed.
        color.setStroke()
        let xRect = NSBezierPath(rect: NSRect(x: canvas.width*0.3, y: canvas.height*0.3,
                                              width: canvas.width*0.4, height: canvas.height*0.4))
        xRect.lineWidth = 8
        xRect.stroke()
        return
    }
    let pointSize = canvas.height * fraction
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold, scale: .large)
        .applying(.init(paletteColors: [color]))
    guard let configured = symbol.withSymbolConfiguration(config) else { return }
    let aspect = configured.size.width / configured.size.height
    let drawH = canvas.height * fraction
    let drawW = drawH * aspect
    let originX = canvas.width / 2 - drawW / 2
    let originY = canvas.height / 2 - drawH / 2
    configured.draw(in: CGRect(x: originX, y: originY, width: drawW, height: drawH))
}

func drawLabel(_ string: String, at point: NSPoint, fontSize: CGFloat = 17) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
        .foregroundColor: textGray,
        .paragraphStyle: para,
    ]
    let measured = (string as NSString).size(withAttributes: attrs)
    (string as NSString).draw(at: NSPoint(x: point.x - measured.width / 2,
                                          y: point.y - measured.height / 2),
                              withAttributes: attrs)
}

// MARK: - SF Symbol candidates

struct Candidate {
    let symbol: String
    let label: String
}

let candidates: [Candidate] = [
    // Plane-direct (the object)
    Candidate(symbol: "airplane",          label: "airplane"),
    Candidate(symbol: "airplane.departure", label: "airplane.departure"),
    Candidate(symbol: "airplane.arrival",   label: "airplane.arrival"),

    // Storage / container metaphors
    Candidate(symbol: "tray.full.fill",    label: "tray.full.fill"),
    Candidate(symbol: "archivebox.fill",   label: "archivebox.fill"),
    Candidate(symbol: "shippingbox.fill",  label: "shippingbox.fill"),

    // Grid / collection metaphors
    Candidate(symbol: "square.grid.2x2.fill",     label: "square.grid.2x2.fill"),
    Candidate(symbol: "square.grid.3x3.fill",     label: "square.grid.3x3.fill"),
    Candidate(symbol: "rectangle.stack.fill",     label: "rectangle.stack.fill"),

    // Aviation-adjacent
    Candidate(symbol: "paperplane.fill",   label: "paperplane.fill"),
    Candidate(symbol: "building.2.fill",   label: "building.2.fill"),
    Candidate(symbol: "house.lodge.fill",  label: "house.lodge.fill"),
]

for c in candidates {
    let rep = makeBitmap(size: tileSize)
    render(into: rep) {
        fillBackground(navy, size: tileSize)
        drawSymbol(c.symbol, color: cyan, in: tileSize)
    }
    let safe = c.symbol.replacingOccurrences(of: ".", with: "_")
    try writePNG(rep, to: outputDir.appendingPathComponent("\(safe).png"))
    print("Wrote \(safe).png  (\(c.symbol))")
}

// MARK: - Combined grid

let gridCols = 4
let gridRows = (candidates.count + gridCols - 1) / gridCols
let labelHeight: CGFloat = 60
let cellPadding: CGFloat = 20
let cellW = tileSize.width + cellPadding * 2
let cellH = tileSize.height + labelHeight + cellPadding * 2
let gridSize = NSSize(width: cellW * CGFloat(gridCols),
                      height: cellH * CGFloat(gridRows))

let gridRep = makeBitmap(size: gridSize)
render(into: gridRep) {
    fillBackground(navy, size: gridSize)
    for (i, c) in candidates.enumerated() {
        let col = i % gridCols
        let row = i / gridCols
        let xOrigin = CGFloat(col) * cellW + cellPadding
        let yOriginAppKit = gridSize.height - CGFloat(row + 1) * cellH + cellPadding

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: xOrigin, yBy: yOriginAppKit + labelHeight)
        transform.concat()
        drawSymbol(c.symbol, color: cyan, in: tileSize)
        NSGraphicsContext.restoreGraphicsState()

        drawLabel(c.label,
                  at: NSPoint(x: xOrigin + tileSize.width / 2,
                              y: yOriginAppKit + labelHeight / 2),
                  fontSize: 18)
    }
}
try writePNG(gridRep, to: outputDir.appendingPathComponent("_grid.png"))
print("Wrote _grid.png")
print("Done. To browse the FULL SF Symbols library yourself, download Apple's SF Symbols app: https://developer.apple.com/sf-symbols/")
