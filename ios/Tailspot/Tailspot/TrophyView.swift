//
//  TrophyView.swift
//  Tailspot
//
//  Hex-framed trophy badge with a tier-tinted ring, dark inner well,
//  custom-illustrated icon, and a small tier pip in the bottom-right.
//
//  Locked variant: dashed-outline hex with a padlock glyph; used for
//  achievements the user hasn't unlocked any tier on yet.
//
//  The icon set ported one-for-one from the design canvas's
//  `TROPHY_ICONS` table (`design/game-trophies.jsx`). Each icon is a
//  `Shape` so it scales cleanly with the trophy size.
//

import SwiftUI

struct TrophyView: View {
    let tier: TrophyTier
    let iconName: String
    var size: CGFloat = 56
    var locked: Bool = false

    var body: some View {
        if locked {
            lockedHex
        } else {
            unlockedHex
        }
    }

    // MARK: - Unlocked

    private var unlockedHex: some View {
        let outer = Color(hex: tier.outerHex)
        let inner = Color(hex: tier.innerHex)
        let glow = outer.opacity(0.4)
        let iconColor = outer
        let pip = outer
        return ZStack {
            // Outer ring — tier gradient.
            HexShape()
                .fill(LinearGradient(
                    colors: [outer, inner],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            // Inner well — dark radial with the tier's inner tone.
            HexShape()
                .fill(RadialGradient(
                    gradient: Gradient(colors: [inner, .black.opacity(0.85)]),
                    center: UnitPoint(x: 0.35, y: 0.30),
                    startRadius: 1,
                    endRadius: size * 0.65
                ))
                .padding(size * 0.10)
            // Icon.
            TrophyIcon(name: iconName, size: size * 0.52, color: iconColor)
            // Tier pip in the lower-right.
            Circle()
                .fill(pip)
                .frame(width: size * 0.14, height: size * 0.14)
                .overlay(
                    Circle()
                        .strokeBorder(.black.opacity(0.55), lineWidth: 1.5)
                )
                .shadow(color: glow, radius: 6)
                .offset(x: size * 0.22, y: size * 0.34)
        }
        .frame(width: size, height: size)
        .shadow(color: glow, radius: size * 0.18, x: 0, y: 4)
    }

    // MARK: - Locked

    private var lockedHex: some View {
        ZStack {
            HexShape()
                .fill(Brand.Color.bgSurface)
            HexShape()
                .stroke(
                    Brand.Color.textTertiary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
                .padding(2)
            // Padlock glyph — small SF symbol works fine for the
            // locked state since it's a system metaphor everywhere.
            Image(systemName: "lock.fill")
                .font(.system(size: size * 0.30, weight: .regular))
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Hex shape

/// Pointy-top hexagon traced through the unit-rectangle vertices
/// (50%, 0%) → (95%, 25%) → (95%, 75%) → (50%, 100%) → (5%, 75%) →
/// (5%, 25%). Matches the design canvas's `clip-path: polygon(...)`.
struct HexShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: 0.50 * w, y: 0.00 * h))
        p.addLine(to: CGPoint(x: 0.95 * w, y: 0.25 * h))
        p.addLine(to: CGPoint(x: 0.95 * w, y: 0.75 * h))
        p.addLine(to: CGPoint(x: 0.50 * w, y: 1.00 * h))
        p.addLine(to: CGPoint(x: 0.05 * w, y: 0.75 * h))
        p.addLine(to: CGPoint(x: 0.05 * w, y: 0.25 * h))
        p.closeSubpath()
        return p
    }
}

// MARK: - Icons

/// Switchboard rendering one of the named trophy icons. All icons
/// draw into a `size × size` square, centered, in `color`. Paths
/// are ported from the design canvas's SVGs (viewBox 0 0 32 32),
/// converted to SwiftUI by dividing each coordinate by 32.
struct TrophyIcon: View {
    let name: String
    let size: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            switch name {
            case "catcher":       CatcherIcon().style(color, lineWidth: 2.2 * scale, dashed: true)
            case "widebody":      WideBodyIcon().style(color, filled: true)
            case "regional":      RegionalIcon().style(color)
            case "longlens":      LongLensIcon().style(color, lineWidth: 2 * scale)
            case "world":         WorldIcon().style(color, lineWidth: 2 * scale)
            case "constellation": ConstellationIcon().style(color)
            case "quintet":       QuintetIcon().style(color)
            case "diamond":       DiamondIcon().style(color, lineWidth: 1.8 * scale)
            case "sparkle":       SparkleIcon().style(color, filled: true)
            case "crown":         CrownIcon().style(color, filled: true)
            case "centurion":     CenturionIcon(color: color, size: size).accessibilityHidden(true)
            case "setmaster":     SetMasterIcon().style(color, lineWidth: 1.8 * scale)
            case "night":         NightOwlIcon().style(color, filled: true)
            case "heritage":      HeritageIcon().style(color)
            case "coast":         CoastIcon().style(color, filled: true)
            default:              CatcherIcon().style(color, lineWidth: 2 * scale, dashed: true)
            }
        }
        .frame(width: size, height: size)
    }

    private var scale: CGFloat { size / 32 }
}

// MARK: - Icon shapes (ported from the design SVGs)

private struct CatcherIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // Four corner brackets.
        p.move(to: .init(x: 5*s, y: 9*s));  p.addLine(to: .init(x: 5*s,  y: 5*s)); p.addLine(to: .init(x: 9*s,  y: 5*s))
        p.move(to: .init(x: 27*s, y: 9*s)); p.addLine(to: .init(x: 27*s, y: 5*s)); p.addLine(to: .init(x: 23*s, y: 5*s))
        p.move(to: .init(x: 5*s, y: 23*s)); p.addLine(to: .init(x: 5*s,  y: 27*s));p.addLine(to: .init(x: 9*s,  y: 27*s))
        p.move(to: .init(x: 27*s, y: 23*s));p.addLine(to: .init(x: 27*s, y: 27*s));p.addLine(to: .init(x: 23*s, y: 27*s))
        // Center dot.
        p.addEllipse(in: CGRect(x: 13*s, y: 13*s, width: 6*s, height: 6*s))
        // Dashed ring around center.
        p.addEllipse(in: CGRect(x: 9*s, y: 9*s, width: 14*s, height: 14*s))
        return p
    }
}

private struct WideBodyIcon: Shape {
    /// Wide-body silhouette traced from the design's path data.
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        p.move(to: .init(x: 16*s, y: 3*s))
        p.addCurve(to: .init(x: 18*s, y: 6*s),
                   control1: .init(x: 17.2*s, y: 3*s),
                   control2: .init(x: 17.8*s, y: 4.5*s))
        p.addLine(to: .init(x: 18.4*s, y: 12*s))
        p.addLine(to: .init(x: 26.4*s, y: 16.2*s))
        p.addCurve(to: .init(x: 27.6*s, y: 18.0*s),
                   control1: .init(x: 27.2*s, y: 16.6*s),
                   control2: .init(x: 27.6*s, y: 17.2*s))
        p.addLine(to: .init(x: 27.6*s, y: 18.6*s))
        p.addCurve(to: .init(x: 27*s, y: 19*s),
                   control1: .init(x: 27.6*s, y: 18.9*s),
                   control2: .init(x: 27.3*s, y: 19.1*s))
        p.addLine(to: .init(x: 18.4*s, y: 17*s))
        p.addLine(to: .init(x: 18.1*s, y: 22*s))
        p.addLine(to: .init(x: 20.5*s, y: 23.6*s))
        p.addLine(to: .init(x: 20.5*s, y: 24.3*s))
        p.addLine(to: .init(x: 16*s, y: 23.3*s))
        p.addLine(to: .init(x: 11.5*s, y: 24.3*s))
        p.addLine(to: .init(x: 11.5*s, y: 23.6*s))
        p.addLine(to: .init(x: 13.9*s, y: 22*s))
        p.addLine(to: .init(x: 13.6*s, y: 17*s))
        p.addLine(to: .init(x: 5*s, y: 19*s))
        p.addCurve(to: .init(x: 4.4*s, y: 18.6*s),
                   control1: .init(x: 4.7*s, y: 19.1*s),
                   control2: .init(x: 4.4*s, y: 18.9*s))
        p.addLine(to: .init(x: 4.4*s, y: 18*s))
        p.addCurve(to: .init(x: 5.6*s, y: 16.2*s),
                   control1: .init(x: 4.4*s, y: 17.2*s),
                   control2: .init(x: 4.8*s, y: 16.6*s))
        p.addLine(to: .init(x: 13.6*s, y: 12*s))
        p.addLine(to: .init(x: 14*s, y: 6*s))
        p.addCurve(to: .init(x: 16*s, y: 3*s),
                   control1: .init(x: 14.2*s, y: 4.5*s),
                   control2: .init(x: 14.8*s, y: 3*s))
        p.closeSubpath()
        return p
    }
}

private struct RegionalIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // Small jet.
        p.move(to: .init(x: 21*s, y: 16*s))
        p.addLine(to: .init(x: 14*s, y: 11*s))
        p.addLine(to: .init(x: 14*s, y: 14*s))
        p.addLine(to: .init(x: 10*s, y: 15*s))
        p.addLine(to: .init(x: 10*s, y: 16*s))
        p.addLine(to: .init(x: 14*s, y: 17*s))
        p.addLine(to: .init(x: 14*s, y: 20*s))
        p.addLine(to: .init(x: 21*s, y: 16*s))
        p.closeSubpath()
        // Speed lines.
        p.move(to: .init(x: 3*s,  y: 12*s)); p.addLine(to: .init(x: 9*s,  y: 12*s))
        p.move(to: .init(x: 3*s,  y: 16*s)); p.addLine(to: .init(x: 11*s, y: 16*s))
        p.move(to: .init(x: 3*s,  y: 20*s)); p.addLine(to: .init(x: 9*s,  y: 20*s))
        return p
    }
}

private struct LongLensIcon: Shape {
    /// Telescope outline.
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // Tube.
        p.move(to: .init(x: 5*s, y: 22*s))
        p.addLine(to: .init(x: 21*s, y: 13*s))
        p.addLine(to: .init(x: 25*s, y: 20*s))
        p.addLine(to: .init(x: 9*s, y: 29*s))
        p.closeSubpath()
        // Eyepiece.
        p.move(to: .init(x: 20*s, y: 13*s))
        p.addLine(to: .init(x: 17*s, y: 8*s))
        p.addLine(to: .init(x: 21*s, y: 6*s))
        p.addLine(to: .init(x: 24*s, y: 11*s))
        p.closeSubpath()
        // Stand foot.
        p.addEllipse(in: CGRect(x: 6*s, y: 23*s, width: 4*s, height: 4*s))
        return p
    }
}

private struct WorldIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // Globe outer.
        p.addEllipse(in: CGRect(x: 7*s, y: 7*s, width: 18*s, height: 18*s))
        // Latitude / longitude grid.
        p.move(to: .init(x: 7*s, y: 16*s));  p.addLine(to: .init(x: 25*s, y: 16*s))
        p.move(to: .init(x: 16*s, y: 7*s))
        p.addCurve(to: .init(x: 16*s, y: 25*s),
                   control1: .init(x: 21*s, y: 12*s),
                   control2: .init(x: 21*s, y: 20*s))
        p.move(to: .init(x: 16*s, y: 7*s))
        p.addCurve(to: .init(x: 16*s, y: 25*s),
                   control1: .init(x: 11*s, y: 12*s),
                   control2: .init(x: 11*s, y: 20*s))
        // Orbit dashed ellipse.
        p.addEllipse(in: CGRect(x: 4*s, y: 12*s, width: 24*s, height: 8*s))
        return p
    }
}

private struct ConstellationIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // Three dots at vertices.
        p.addEllipse(in: CGRect(x: 14*s, y: 5*s, width: 4*s, height: 4*s))
        p.addEllipse(in: CGRect(x:  6*s, y: 18*s, width: 4*s, height: 4*s))
        p.addEllipse(in: CGRect(x: 22*s, y: 18*s, width: 4*s, height: 4*s))
        // Connecting lines.
        p.move(to: .init(x: 16*s, y: 9*s));  p.addLine(to: .init(x: 10*s, y: 20*s))
        p.move(to: .init(x: 16*s, y: 9*s));  p.addLine(to: .init(x: 22*s, y: 20*s))
        p.move(to: .init(x: 10*s, y: 20*s)); p.addLine(to: .init(x: 22*s, y: 20*s))
        return p
    }
}

private struct QuintetIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        p.addEllipse(in: CGRect(x:  4*s, y:  7*s, width: 4*s, height: 4*s))
        p.addEllipse(in: CGRect(x:  9*s, y: 13*s, width: 4*s, height: 4*s))
        p.addEllipse(in: CGRect(x: 13.6*s, y: 19.6*s, width: 4.8*s, height: 4.8*s))
        p.addEllipse(in: CGRect(x: 19*s, y: 13*s, width: 4*s, height: 4*s))
        p.addEllipse(in: CGRect(x: 24*s, y:  7*s, width: 4*s, height: 4*s))
        return p
    }
}

private struct DiamondIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // Outer cut.
        p.move(to: .init(x: 16*s, y: 4*s))
        p.addLine(to: .init(x:  6*s, y: 13*s))
        p.addLine(to: .init(x: 16*s, y: 28*s))
        p.addLine(to: .init(x: 26*s, y: 13*s))
        p.closeSubpath()
        // Facets.
        p.move(to: .init(x:  6*s, y: 13*s)); p.addLine(to: .init(x: 26*s, y: 13*s))
        p.move(to: .init(x: 11*s, y: 13*s)); p.addLine(to: .init(x: 16*s, y: 28*s))
        p.move(to: .init(x: 21*s, y: 13*s)); p.addLine(to: .init(x: 16*s, y: 28*s))
        p.move(to: .init(x: 16*s, y: 4*s));  p.addLine(to: .init(x: 11*s, y: 13*s))
        p.move(to: .init(x: 16*s, y: 4*s));  p.addLine(to: .init(x: 21*s, y: 13*s))
        return p
    }
}

private struct SparkleIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // 4-pointed sparkle.
        p.move(to: .init(x: 16*s, y: 2*s))
        p.addLine(to: .init(x: 19*s, y: 15*s))
        p.addLine(to: .init(x: 32*s, y: 16*s))
        p.addLine(to: .init(x: 19*s, y: 19*s))
        p.addLine(to: .init(x: 16*s, y: 32*s))
        p.addLine(to: .init(x: 13*s, y: 19*s))
        p.addLine(to: .init(x: 0*s,  y: 16*s))
        p.addLine(to: .init(x: 13*s, y: 15*s))
        p.closeSubpath()
        // Two small accent dots.
        p.addEllipse(in: CGRect(x: 4.5*s, y: 4.5*s, width: 3*s, height: 3*s))
        p.addEllipse(in: CGRect(x: 24.5*s, y: 24.5*s, width: 3*s, height: 3*s))
        return p
    }
}

private struct CrownIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // Crown body.
        p.move(to: .init(x: 4*s, y: 12*s))
        p.addLine(to: .init(x: 7*s, y: 24*s))
        p.addLine(to: .init(x: 25*s, y: 24*s))
        p.addLine(to: .init(x: 28*s, y: 12*s))
        p.addLine(to: .init(x: 22*s, y: 17*s))
        p.addLine(to: .init(x: 16*s, y: 8*s))
        p.addLine(to: .init(x: 10*s, y: 17*s))
        p.closeSubpath()
        // Three gem dots.
        p.addEllipse(in: CGRect(x:  2*s, y:  9*s, width: 4*s, height: 4*s))
        p.addEllipse(in: CGRect(x: 14*s, y:  4*s, width: 4*s, height: 4*s))
        p.addEllipse(in: CGRect(x: 26*s, y:  9*s, width: 4*s, height: 4*s))
        return p
    }
}

/// Special-case: Centurion needs to render "100" text inside laurel
/// strokes — too awkward to render as a single `Shape`. Compose
/// directly.
private struct CenturionIcon: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        let s = size / 32
        ZStack {
            CenturionLaurels()
                .stroke(color.opacity(0.7), style: .init(lineWidth: 1.6 * s, lineCap: .round))
            Text("100")
                .font(Brand.Font.mono(size: 9 * s, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

private struct CenturionLaurels: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // Left + right laurel arcs (4 strokes).
        p.move(to: .init(x:  4*s, y: 16*s))
        p.addQuadCurve(to: .init(x: 12*s, y:  6*s), control: .init(x: 4*s, y: 10*s))
        p.move(to: .init(x: 28*s, y: 16*s))
        p.addQuadCurve(to: .init(x: 20*s, y:  6*s), control: .init(x: 28*s, y: 10*s))
        p.move(to: .init(x:  4*s, y: 18*s))
        p.addQuadCurve(to: .init(x: 12*s, y: 28*s), control: .init(x: 4*s, y: 24*s))
        p.move(to: .init(x: 28*s, y: 18*s))
        p.addQuadCurve(to: .init(x: 20*s, y: 28*s), control: .init(x: 28*s, y: 24*s))
        return p
    }
}

private struct SetMasterIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // Clipboard frame.
        p.addRoundedRect(in: CGRect(x: 6*s, y: 5*s, width: 20*s, height: 22*s),
                         cornerSize: .init(width: 2.5*s, height: 2.5*s))
        // Three check rows.
        p.move(to: .init(x: 11*s, y: 11*s));  p.addLine(to: .init(x: 13*s, y: 13*s)); p.addLine(to: .init(x: 17*s, y:  9*s))
        p.move(to: .init(x: 11*s, y: 18*s));  p.addLine(to: .init(x: 13*s, y: 20*s)); p.addLine(to: .init(x: 17*s, y: 16*s))
        p.move(to: .init(x: 11*s, y: 25*s));  p.addLine(to: .init(x: 17*s, y: 25*s))
        return p
    }
}

private struct NightOwlIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // Moon (rough crescent via path).
        p.move(to: .init(x: 14*s, y: 4*s))
        p.addCurve(to: .init(x: 14*s, y: 28*s),
                   control1: .init(x: 2*s,  y: 4*s),
                   control2: .init(x: 2*s,  y: 28*s))
        p.addCurve(to: .init(x: 11*s, y:  9*s),
                   control1: .init(x: 17*s, y: 24*s),
                   control2: .init(x: 11*s, y: 14*s))
        p.addCurve(to: .init(x: 14*s, y:  4*s),
                   control1: .init(x: 12*s, y:  8*s),
                   control2: .init(x: 13*s, y:  6*s))
        p.closeSubpath()
        // Star dots.
        p.addEllipse(in: CGRect(x: 23*s, y:  8*s, width: 2*s, height: 2*s))
        p.addEllipse(in: CGRect(x: 24.8*s, y: 12.8*s, width: 2.4*s, height: 2.4*s))
        p.addEllipse(in: CGRect(x: 21.2*s, y: 15.2*s, width: 1.6*s, height: 1.6*s))
        return p
    }
}

private struct HeritageIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // Two wings.
        p.move(to: .init(x:  4*s, y: 12*s)); p.addLine(to: .init(x: 28*s, y: 12*s))
        p.move(to: .init(x:  4*s, y: 20*s)); p.addLine(to: .init(x: 28*s, y: 20*s))
        // Struts.
        p.move(to: .init(x: 14*s, y:  8*s)); p.addLine(to: .init(x: 18*s, y: 24*s))
        p.move(to: .init(x: 18*s, y:  8*s)); p.addLine(to: .init(x: 14*s, y: 24*s))
        // Fuselage dot.
        p.addEllipse(in: CGRect(x: 13.5*s, y: 13.5*s, width: 5*s, height: 5*s))
        return p
    }
}

private struct CoastIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        // Stylized coastline mass.
        p.move(to: .init(x:  4*s, y: 10*s))
        p.addQuadCurve(to: .init(x: 10*s, y: 10*s),  control: .init(x:  6*s, y:  8*s))
        p.addQuadCurve(to: .init(x: 14*s, y:  8*s),  control: .init(x: 12*s, y: 10*s))
        p.addQuadCurve(to: .init(x: 18*s, y: 10*s),  control: .init(x: 16*s, y:  6*s))
        p.addQuadCurve(to: .init(x: 28*s, y: 10*s),  control: .init(x: 24*s, y:  8*s))
        p.addLine(to: .init(x: 28*s, y: 18*s))
        p.addQuadCurve(to: .init(x: 18*s, y: 18*s),  control: .init(x: 24*s, y: 20*s))
        p.addQuadCurve(to: .init(x: 14*s, y: 20*s),  control: .init(x: 16*s, y: 18*s))
        p.addQuadCurve(to: .init(x: 10*s, y: 18*s),  control: .init(x: 12*s, y: 20*s))
        p.addQuadCurve(to: .init(x:  4*s, y: 18*s),  control: .init(x:  6*s, y: 20*s))
        p.closeSubpath()
        // Wave line below.
        p.move(to: .init(x:  4*s, y: 22*s))
        p.addQuadCurve(to: .init(x: 28*s, y: 22*s), control: .init(x: 16*s, y: 24*s))
        return p
    }
}

// MARK: - Shape styling helper

private extension Shape {
    /// Render either as a filled fill or as a stroke. Mirrors the
    /// SVG `fill={color}` vs `stroke={color}` distinction.
    @ViewBuilder
    func style(_ color: Color, lineWidth: CGFloat = 1.6, filled: Bool = false, dashed: Bool = false) -> some View {
        if filled {
            self.fill(color)
        } else if dashed {
            self.stroke(color, style: .init(
                lineWidth: lineWidth,
                lineCap: .round,
                dash: [2, 2]
            ))
        } else {
            self.stroke(color, style: .init(
                lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round
            ))
        }
    }
}

#Preview {
    ScrollView {
        let icons = [
            "catcher", "widebody", "regional", "longlens", "world",
            "constellation", "quintet", "diamond", "sparkle", "crown",
            "centurion", "setmaster", "night", "heritage", "coast"
        ]
        let tiers: [TrophyTier] = [.bronze, .silver, .gold, .platinum]
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
            ForEach(0..<icons.count, id: \.self) { idx in
                let tier = tiers[idx % tiers.count]
                TrophyView(tier: tier, iconName: icons[idx], size: 72)
            }
            TrophyView(tier: .bronze, iconName: "catcher", size: 72, locked: true)
        }
        .padding()
    }
    .background(Brand.Color.bgPrimary)
}
