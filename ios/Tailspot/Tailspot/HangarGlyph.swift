//
//  HangarGlyph.swift
//  Tailspot
//
//  The hangar icon used wherever we need to evoke the collection
//  ("Hangar") surface — currently the bottom hangar button in
//  ContentView and any inline glyph that wants a hangar shape rather
//  than a generic tray.
//
//  Ports the design-canvas `Icon.hangar` SVG verbatim
//  (design/brand-atoms.jsx:186) so the iOS glyph and the canvas
//  prototype match shape-for-shape: a peaked-roof pentagon with a
//  horizontal line across the eaves.
//

import SwiftUI

/// Stroked hangar shape — peaked roof pentagon + eaves line. Sized
/// to fit the given frame (24×24 native viewBox, scaled uniformly).
///
/// `lineWidth` is in the source coordinate space (24×24); pick 2 for
/// the canvas-default look. Pass `tint` to color the strokes.
struct HangarGlyph: View {
    var lineWidth: CGFloat = 2
    var tint: Color = .primary

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let scale = side / 24
            ZStack {
                // Outer pentagon — peaked roof.
                HangarOutline()
                    .stroke(
                        tint,
                        style: StrokeStyle(
                            lineWidth: lineWidth * scale,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                // Eaves line — horizontal across the roof base.
                HangarEaves()
                    .stroke(
                        tint,
                        style: StrokeStyle(
                            lineWidth: lineWidth * scale,
                            lineCap: .round
                        )
                    )
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

/// Pentagon outline matching the canvas path:
/// `M3 11 L12 5 L21 11 L21 20 L3 20 Z`
/// Coordinates are normalized into the rect (so it scales with the frame).
private struct HangarOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let sx = w / 24, sy = h / 24
        var p = Path()
        p.move(to: CGPoint(x: 3 * sx, y: 11 * sy))
        p.addLine(to: CGPoint(x: 12 * sx, y: 5 * sy))
        p.addLine(to: CGPoint(x: 21 * sx, y: 11 * sy))
        p.addLine(to: CGPoint(x: 21 * sx, y: 20 * sy))
        p.addLine(to: CGPoint(x: 3 * sx, y: 20 * sy))
        p.closeSubpath()
        return p
    }
}

/// Horizontal eaves line: `M3 11 H21`.
private struct HangarEaves: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let sx = w / 24, sy = h / 24
        var p = Path()
        p.move(to: CGPoint(x: 3 * sx, y: 11 * sy))
        p.addLine(to: CGPoint(x: 21 * sx, y: 11 * sy))
        return p
    }
}

#Preview {
    HStack(spacing: 24) {
        HangarGlyph(tint: .cyan)
            .frame(width: 24, height: 24)
        HangarGlyph(tint: .cyan)
            .frame(width: 44, height: 44)
        HangarGlyph(lineWidth: 1.5, tint: .white)
            .frame(width: 22, height: 22)
    }
    .padding(40)
    .background(Color.black)
}
