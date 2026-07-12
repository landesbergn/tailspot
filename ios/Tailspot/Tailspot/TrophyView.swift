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
            // Metallic sheen along the rim — a cheap hairline stroke, NOT a
            // blur. Gives the badge depth without an offscreen render pass.
            HexShape()
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.45), .clear, .black.opacity(0.25)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: max(0.75, size * 0.02)
                )
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
                .offset(x: size * 0.22, y: size * 0.34)
        }
        .frame(width: size, height: size)
        // Rasterize the whole badge — gradients + the multi-path vector icon —
        // into ONE Metal texture. Trophies never animate internally, so the
        // expensive vector work is cached once; compositing the texture during
        // a scroll or a segment page-slide is then trivial. This (with the
        // blur shadows removed above) is the fix for the laggy Trophies tab:
        // ~20 badges each forcing an offscreen blur pass per frame was the
        // cost that survived both the keep-alive ZStack and the TabView.
        .drawingGroup()
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
        // Match `unlockedHex`'s rasterization so locked and unlocked hexes
        // composite identically during a segment page-slide — without this
        // the two paths render through different pipelines and the locked
        // ones could flicker on the Trophies tab transition.
        .drawingGroup()
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
            case "narrowbody":    NarrowBodyIcon().style(color, filled: true)
            case "ticket":        TicketIcon().style(color, lineWidth: 1.8 * scale)
            case "gems":          GemsIcon().style(color, lineWidth: 1.7 * scale)
            case "calendar":      CalendarIcon().style(color, lineWidth: 1.7 * scale)
            case "eye":           EyeIcon().style(color, lineWidth: 1.9 * scale)
            case "hattrick":      TopHatIcon().style(color, lineWidth: 2 * scale)
            case "worldwide":     WorldwideIcon().style(color, lineWidth: 1.9 * scale)
            case "repeat":        RepeatIcon().style(color, lineWidth: 2 * scale)
            case "streak":        FlameIcon().style(color, filled: true)
            case "jumbo":         JumboIcon().style(color, lineWidth: 1.8 * scale)
            case "cargo":         CargoIcon().style(color, lineWidth: 1.8 * scale)
            case "bizjet":        BizjetIcon().style(color, lineWidth: 1.8 * scale)
            case "prop":          PropIcon().style(color, lineWidth: 2 * scale)
            case "star":          StarIcon().style(color, filled: true)
            case "heli":          HeliIcon().style(color, lineWidth: 1.8 * scale)
            case "altitude":      AltitudeIcon().style(color, lineWidth: 2 * scale)
            case "speed":         SpeedIcon().style(color, lineWidth: 2 * scale)
            case "stack":         StackIcon().style(color, filled: true)
            case "clock":         ClockIcon().style(color, lineWidth: 1.9 * scale)
            case "approach":      ApproachIcon().style(color, lineWidth: 2 * scale)
            case "grid":          GridIcon().style(color, filled: true)
            case "home":          HomeIcon().style(color, lineWidth: 1.9 * scale)
            case "weekend":       SunIcon().style(color, lineWidth: 1.9 * scale)
            case "sunrise":       SunriseIcon().style(color, lineWidth: 1.9 * scale)
            case "twin":          TwinIcon().style(color, lineWidth: 1.8 * scale)
            case "coin":          CoinIcon().style(color, lineWidth: 1.8 * scale)
            case "crystal":       CrystalBallIcon().style(color, lineWidth: 1.9 * scale)
            case "bolt":          BoltIcon().style(color, filled: true)
            case "laurel":        LaurelStarIcon(color: color, size: size)
            case "crowns":        CrownsIcon().style(color, lineWidth: 1.8 * scale)
            case "summit":        SummitIcon().style(color, lineWidth: 1.9 * scale)
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
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        // Clean crescent: outer edge bulges far left, the inner "bite" bulges
        // less, both meeting at the top (18,5) and bottom (18,27) points.
        p.move(to: pt(18, 5))
        p.addCurve(to: pt(18, 27), control1: pt(4, 8),  control2: pt(4, 24))    // outer edge
        p.addCurve(to: pt(18, 5),  control1: pt(14, 22), control2: pt(14, 10))  // inner bite
        p.closeSubpath()
        // Two small stars.
        p.addEllipse(in: CGRect(x: 23 * s, y: 9 * s, width: 2.4 * s, height: 2.4 * s))
        p.addEllipse(in: CGRect(x: 25.4 * s, y: 14 * s, width: 1.8 * s, height: 1.8 * s))
        return p
    }
}

/// Red Eye — an almond eye with a pupil.
private struct EyeIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(5, 16))
        p.addQuadCurve(to: pt(27, 16), control: pt(16, 8))    // upper lid
        p.addQuadCurve(to: pt(5, 16), control: pt(16, 24))    // lower lid
        p.addEllipse(in: CGRect(x: 13 * s, y: 13 * s, width: 6 * s, height: 6 * s))  // pupil
        return p
    }
}

/// Hat Trick — a top hat (the hat-trick tradition).
private struct TopHatIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(4, 23)); p.addLine(to: pt(28, 23))      // brim
        p.move(to: pt(9, 23))                                 // crown
        p.addLine(to: pt(10, 7))
        p.addLine(to: pt(22, 7))
        p.addLine(to: pt(23, 23))
        p.move(to: pt(9.6, 18)); p.addLine(to: pt(22.4, 18))  // band
        return p
    }
}

/// Mr. Worldwide — a globe with a flag planted on it.
private struct WorldwideIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.addEllipse(in: CGRect(x: 5 * s, y: 9 * s, width: 17 * s, height: 17 * s))  // globe
        p.move(to: pt(5, 17.5)); p.addLine(to: pt(22, 17.5))                          // equator
        p.move(to: pt(13.5, 9)); p.addCurve(to: pt(13.5, 26), control1: pt(8.5, 14), control2: pt(8.5, 21))
        p.move(to: pt(13.5, 9)); p.addCurve(to: pt(13.5, 26), control1: pt(18.5, 14), control2: pt(18.5, 21))
        p.move(to: pt(22, 4)); p.addLine(to: pt(22, 13))                              // flag pole
        p.move(to: pt(22, 4)); p.addLine(to: pt(27.5, 5.8)); p.addLine(to: pt(22, 7.6))  // pennant
        return p
    }
}

/// Repeat Customer — two arrows cycling round (it comes back around).
private struct RepeatIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(7, 14)); p.addQuadCurve(to: pt(25, 14), control: pt(16, 4))   // top arc
        p.move(to: pt(21, 13)); p.addLine(to: pt(25, 14)); p.addLine(to: pt(24, 10))  // top arrowhead
        p.move(to: pt(25, 18)); p.addQuadCurve(to: pt(7, 18), control: pt(16, 28))  // bottom arc
        p.move(to: pt(11, 19)); p.addLine(to: pt(7, 18)); p.addLine(to: pt(8, 22))    // bottom arrowhead
        return p
    }
}

/// Streak — a flame (you're on fire).
private struct FlameIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(16, 3))
        p.addCurve(to: pt(24, 19), control1: pt(19, 9),  control2: pt(24, 12))
        p.addCurve(to: pt(16, 29), control1: pt(24, 25), control2: pt(20, 29))
        p.addCurve(to: pt(8, 19),  control1: pt(12, 29), control2: pt(8, 25))
        p.addCurve(to: pt(16, 3),  control1: pt(8, 13),  control2: pt(13, 11))
        p.closeSubpath()
        return p
    }
}

/// Heavy Metal — a four-engine giant (wing + 4 engine pods + fuselage + tail).
private struct JumboIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(16, 5)); p.addLine(to: pt(16, 26))            // fuselage
        p.move(to: pt(4, 15)); p.addLine(to: pt(28, 15))            // wing
        p.move(to: pt(11, 26)); p.addLine(to: pt(21, 26))           // tailplane
        for x in [8.0, 12.0, 20.0, 24.0] {                          // 4 engine pods
            p.addRoundedRect(in: CGRect(x: (x - 1.4) * s, y: 16 * s, width: 2.8 * s, height: 4 * s),
                             cornerSize: .init(width: 1 * s, height: 1 * s))
        }
        return p
    }
}

/// Heavy Hauler — a shipping/cargo box.
private struct CargoIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 6 * s, y: 8 * s, width: 20 * s, height: 18 * s),
                         cornerSize: .init(width: 2 * s, height: 2 * s))
        p.move(to: pt(6, 14)); p.addLine(to: pt(26, 14))           // lid line
        p.move(to: pt(16, 8)); p.addLine(to: pt(16, 14))           // seam
        return p
    }
}

/// Business Class — a small sleek swept jet.
private struct BizjetIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 15 * s, y: 5 * s, width: 2 * s, height: 20 * s),
                         cornerSize: .init(width: 1 * s, height: 1 * s))   // thin fuselage
        p.move(to: pt(16, 12)); p.addLine(to: pt(7, 16)); p.addLine(to: pt(16, 15))   // left wing
        p.move(to: pt(16, 12)); p.addLine(to: pt(25, 16)); p.addLine(to: pt(16, 15))  // right wing
        p.move(to: pt(16, 22)); p.addLine(to: pt(12, 25)); p.addLine(to: pt(16, 24))  // tail
        p.move(to: pt(16, 22)); p.addLine(to: pt(20, 25)); p.addLine(to: pt(16, 24))
        return p
    }
}

/// Spinning Props — a three-blade propeller.
private struct PropIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.addEllipse(in: CGRect(x: 14 * s, y: 14 * s, width: 4 * s, height: 4 * s))   // hub
        p.move(to: pt(16, 16)); p.addLine(to: pt(16, 4))     // blade up
        p.move(to: pt(16, 16)); p.addLine(to: pt(26, 22))    // blade lower-right
        p.move(to: pt(16, 16)); p.addLine(to: pt(6, 22))     // blade lower-left
        return p
    }
}

/// Brass Hat — a five-point star (military).
private struct StarIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        let c = CGPoint(x: 16 * s, y: 16.5 * s)
        let outer = 11.5 * s, inner = 4.6 * s
        var p = Path()
        for i in 0..<10 {
            let r = i.isMultiple(of: 2) ? outer : inner
            let a = -Double.pi / 2 + Double(i) * .pi / 5
            let point = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }
}

/// Whirlybird — a helicopter (body + main rotor + tail boom + tail rotor).
private struct HeliIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.addEllipse(in: CGRect(x: 8 * s, y: 13 * s, width: 12 * s, height: 9 * s))   // cabin
        p.move(to: pt(4, 11)); p.addLine(to: pt(22, 11))           // main rotor
        p.move(to: pt(13, 11)); p.addLine(to: pt(13, 13))          // mast
        p.move(to: pt(20, 17)); p.addLine(to: pt(28, 17))          // tail boom
        p.move(to: pt(28, 14)); p.addLine(to: pt(28, 20))          // tail rotor
        p.move(to: pt(10, 22)); p.addLine(to: pt(18, 22))          // skid
        return p
    }
}

/// Mile High — a double up-chevron (way up there).
private struct AltitudeIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(8, 15)); p.addLine(to: pt(16, 6));  p.addLine(to: pt(24, 15))
        p.move(to: pt(8, 24)); p.addLine(to: pt(16, 15)); p.addLine(to: pt(24, 24))
        return p
    }
}

/// Speed Demon — motion lines + a forward chevron.
private struct SpeedIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(4, 11)); p.addLine(to: pt(16, 11))
        p.move(to: pt(4, 16)); p.addLine(to: pt(20, 16))
        p.move(to: pt(4, 21)); p.addLine(to: pt(16, 21))
        p.move(to: pt(20, 9)); p.addLine(to: pt(28, 16)); p.addLine(to: pt(20, 23))   // chevron
        return p
    }
}

/// Marathon — three stacked bars (a big pile of catches).
private struct StackIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        for y in [9.0, 15.0, 21.0] {
            p.addRoundedRect(in: CGRect(x: 7 * s, y: y * s, width: 18 * s, height: 3.4 * s),
                             cornerSize: .init(width: 1.5 * s, height: 1.5 * s))
        }
        return p
    }
}

/// Around the Clock — a clock face with two hands.
private struct ClockIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.addEllipse(in: CGRect(x: 6 * s, y: 6 * s, width: 20 * s, height: 20 * s))   // face
        p.move(to: pt(16, 16)); p.addLine(to: pt(16, 9))      // hour hand
        p.move(to: pt(16, 16)); p.addLine(to: pt(21, 18))     // minute hand
        return p
    }
}

/// On the Deck — a double down-chevron (low, descending).
private struct ApproachIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(8, 8));  p.addLine(to: pt(16, 17)); p.addLine(to: pt(24, 8))
        p.move(to: pt(8, 17)); p.addLine(to: pt(16, 26)); p.addLine(to: pt(24, 17))
        return p
    }
}

/// Variety Pack / Full Deck — a 2×2 grid of tiles (a varied collection).
private struct GridIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        for (x, y) in [(7.0, 7.0), (18.0, 7.0), (7.0, 18.0), (18.0, 18.0)] {
            p.addRoundedRect(in: CGRect(x: x * s, y: y * s, width: 7 * s, height: 7 * s),
                             cornerSize: .init(width: 1.6 * s, height: 1.6 * s))
        }
        return p
    }
}

/// Homebody — a house.
private struct HomeIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(5, 15)); p.addLine(to: pt(16, 6)); p.addLine(to: pt(27, 15))   // roof
        p.move(to: pt(8, 13)); p.addLine(to: pt(8, 26)); p.addLine(to: pt(24, 26)); p.addLine(to: pt(24, 13))  // walls
        p.move(to: pt(13, 26)); p.addLine(to: pt(13, 19)); p.addLine(to: pt(19, 19)); p.addLine(to: pt(19, 26))  // door
        return p
    }
}

/// Weekend Warrior — a sun.
private struct SunIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        let c = CGPoint(x: 16 * s, y: 16 * s)
        var p = Path()
        p.addEllipse(in: CGRect(x: 11 * s, y: 11 * s, width: 10 * s, height: 10 * s))   // disc
        for i in 0..<8 {                                                                 // 8 rays
            let a = Double(i) * .pi / 4
            let inner = CGPoint(x: c.x + CGFloat(cos(a)) * 8 * s, y: c.y + CGFloat(sin(a)) * 8 * s)
            let outer = CGPoint(x: c.x + CGFloat(cos(a)) * 12.5 * s, y: c.y + CGFloat(sin(a)) * 12.5 * s)
            p.move(to: inner); p.addLine(to: outer)
        }
        return p
    }
}

/// Dawn Patrol — a sun rising over the horizon.
private struct SunriseIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(4, 23)); p.addLine(to: pt(28, 23))                                 // horizon
        p.addArc(center: pt(16, 23), radius: 6 * s, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)  // half sun
        p.move(to: pt(16, 11)); p.addLine(to: pt(16, 8))                                 // up ray
        p.move(to: pt(8, 15));  p.addLine(to: pt(6, 13))                                 // left ray
        p.move(to: pt(24, 15)); p.addLine(to: pt(26, 13))                                // right ray
        return p
    }
}

/// Four Figures / High Roller — a poker chip (a pile of points).
private struct CoinIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        let c = CGPoint(x: 16 * s, y: 16 * s)
        var p = Path()
        p.addEllipse(in: CGRect(x: 4 * s, y: 4 * s, width: 24 * s, height: 24 * s))    // rim
        p.addEllipse(in: CGRect(x: 9 * s, y: 9 * s, width: 14 * s, height: 14 * s))    // inner ring
        for i in 0..<6 {                                                               // 6 edge slots
            let a = Double(i) * .pi / 3 + .pi / 6
            let inner = CGPoint(x: c.x + CGFloat(cos(a)) * 7 * s, y: c.y + CGFloat(sin(a)) * 7 * s)
            let outer = CGPoint(x: c.x + CGFloat(cos(a)) * 12 * s, y: c.y + CGFloat(sin(a)) * 12 * s)
            p.move(to: inner); p.addLine(to: outer)
        }
        return p
    }
}

/// Called It / Clairvoyant — a crystal ball on its stand (you saw the route).
private struct CrystalBallIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.addEllipse(in: CGRect(x: 7 * s, y: 4 * s, width: 18 * s, height: 18 * s))    // ball
        // Inner gleam — a short arc following the upper-left of the ball.
        p.move(to: pt(11, 9.5))
        p.addQuadCurve(to: pt(14.5, 6.8), control: pt(12, 7.4))
        // Stand: a shallow trapezoid under the ball.
        p.move(to: pt(11, 23)); p.addLine(to: pt(9, 27)); p.addLine(to: pt(23, 27)); p.addLine(to: pt(21, 23))
        p.closeSubpath()
        return p
    }
}

/// Hot Streak — a lightning bolt (three in a row, no misses).
private struct BoltIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(18, 3))
        p.addLine(to: pt(8, 18))
        p.addLine(to: pt(14.5, 18))
        p.addLine(to: pt(12.5, 29))
        p.addLine(to: pt(24, 13))
        p.addLine(to: pt(17, 13))
        p.addLine(to: pt(20.5, 3))
        p.closeSubpath()
        return p
    }
}

/// Top Flight — laurel branches wreathing a bold FILLED champion's star
/// (you won the week). Composed rather than a single `Shape` so the star
/// fills while the branches stroke — the CenturionIcon pattern; a stroked
/// star at this radius collapses into a dot at badge size.
private struct LaurelStarIcon: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        let s = size / 32
        ZStack {
            LaurelBranches()
                .stroke(color.opacity(0.75), style: .init(lineWidth: 1.7 * s, lineCap: .round))
            LaurelStar()
                .fill(color)
        }
        .frame(width: size, height: size)
    }
}

/// Four laurel arcs — the CenturionLaurels geometry (left + right branches,
/// open at top and bottom), shared visual language for "victory".
private struct LaurelBranches: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(4, 16));  p.addQuadCurve(to: pt(12, 5),  control: pt(4, 9))
        p.move(to: pt(28, 16)); p.addQuadCurve(to: pt(20, 5),  control: pt(28, 9))
        p.move(to: pt(4, 18));  p.addQuadCurve(to: pt(12, 29), control: pt(4, 25))
        p.move(to: pt(28, 18)); p.addQuadCurve(to: pt(20, 29), control: pt(28, 25))
        return p
    }
}

/// Five-point star sized to sit inside the wreath (smaller than the
/// full-frame military StarIcon).
private struct LaurelStar: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        let c = CGPoint(x: 16 * s, y: 17 * s)
        let outer = 8 * s, inner = 3.2 * s
        var p = Path()
        for i in 0..<10 {
            let r = i.isMultiple(of: 2) ? outer : inner
            let a = -Double.pi / 2 + Double(i) * .pi / 5
            let point = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }
}

/// Dynasty — two stacked crowns (win after win after win).
private struct CrownsIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        // Small crown on top.
        p.move(to: pt(11, 11))
        p.addLine(to: pt(10, 5)); p.addLine(to: pt(13.5, 8))
        p.addLine(to: pt(16, 4)); p.addLine(to: pt(18.5, 8))
        p.addLine(to: pt(22, 5)); p.addLine(to: pt(21, 11))
        p.closeSubpath()
        // Wide crown below.
        p.move(to: pt(8, 27))
        p.addLine(to: pt(6, 16)); p.addLine(to: pt(11.5, 21))
        p.addLine(to: pt(16, 14)); p.addLine(to: pt(20.5, 21))
        p.addLine(to: pt(26, 16)); p.addLine(to: pt(24, 27))
        p.closeSubpath()
        return p
    }
}

/// Chart Topper — a summit with a flag planted on the highest peak
/// (#1 on the all-time board).
private struct SummitIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * s, y: y * s) }
        var p = Path()
        // Two-peak ridge; closeSubpath draws the baseline back to the start.
        p.move(to: pt(3, 26))
        p.addLine(to: pt(12, 11))
        p.addLine(to: pt(17, 19))
        p.addLine(to: pt(22, 12))
        p.addLine(to: pt(29, 26))
        p.closeSubpath()
        // Flag on the highest peak (pole + pennant, the WorldwideIcon motif).
        p.move(to: pt(12, 11)); p.addLine(to: pt(12, 3))
        p.move(to: pt(12, 3)); p.addLine(to: pt(17.5, 4.8)); p.addLine(to: pt(12, 6.6))
        return p
    }
}

/// Doubleheader — two overlapping cards (the same thing, twice).
private struct TwinIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 6 * s, y: 9 * s, width: 16 * s, height: 11 * s),
                         cornerSize: .init(width: 2 * s, height: 2 * s))   // back
        p.addRoundedRect(in: CGRect(x: 11 * s, y: 13 * s, width: 16 * s, height: 11 * s),
                         cornerSize: .init(width: 2 * s, height: 2 * s))   // front
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

private struct NarrowBodyIcon: Shape {
    /// Single-aisle silhouette — a slimmer wingspan than WideBodyIcon so the
    /// two read as distinct airframe classes at badge size.
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        p.move(to: .init(x: 16*s, y: 3*s))
        p.addCurve(to: .init(x: 17.4*s, y: 6*s),
                   control1: .init(x: 16.9*s, y: 3*s),
                   control2: .init(x: 17.2*s, y: 4.6*s))
        p.addLine(to: .init(x: 17.7*s, y: 13*s))
        p.addLine(to: .init(x: 24*s, y: 16.6*s))
        p.addLine(to: .init(x: 24*s, y: 18*s))
        p.addLine(to: .init(x: 17.7*s, y: 16.6*s))
        p.addLine(to: .init(x: 17.4*s, y: 22*s))
        p.addLine(to: .init(x: 19.4*s, y: 23.6*s))
        p.addLine(to: .init(x: 19.4*s, y: 24.3*s))
        p.addLine(to: .init(x: 16*s, y: 23.4*s))
        p.addLine(to: .init(x: 12.6*s, y: 24.3*s))
        p.addLine(to: .init(x: 12.6*s, y: 23.6*s))
        p.addLine(to: .init(x: 14.6*s, y: 22*s))
        p.addLine(to: .init(x: 14.3*s, y: 16.6*s))
        p.addLine(to: .init(x: 8*s, y: 18*s))
        p.addLine(to: .init(x: 8*s, y: 16.6*s))
        p.addLine(to: .init(x: 14.3*s, y: 13*s))
        p.addLine(to: .init(x: 14.6*s, y: 6*s))
        p.addCurve(to: .init(x: 16*s, y: 3*s),
                   control1: .init(x: 14.8*s, y: 4.6*s),
                   control2: .init(x: 15.1*s, y: 3*s))
        p.closeSubpath()
        return p
    }
}

private struct TicketIcon: Shape {
    /// Boarding pass — rounded body with a perforation line and two stub rules.
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 4*s, y: 9*s, width: 24*s, height: 14*s),
                         cornerSize: .init(width: 2.5*s, height: 2.5*s))
        // Perforation between stub and body.
        p.move(to: .init(x: 20*s, y: 9*s)); p.addLine(to: .init(x: 20*s, y: 23*s))
        // Two rules on the body.
        p.move(to: .init(x: 7*s, y: 14*s));  p.addLine(to: .init(x: 16*s, y: 14*s))
        p.move(to: .init(x: 7*s, y: 18*s));  p.addLine(to: .init(x: 13*s, y: 18*s))
        return p
    }
}

private struct GemsIcon: Shape {
    /// A small cluster of three cut gems — distinct from the single DiamondIcon.
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func gem(cx: CGFloat, cy: CGFloat, r: CGFloat, into p: inout Path) {
            p.move(to: .init(x: cx*s, y: (cy - r)*s))
            p.addLine(to: .init(x: (cx + r*0.72)*s, y: cy*s))
            p.addLine(to: .init(x: cx*s, y: (cy + r)*s))
            p.addLine(to: .init(x: (cx - r*0.72)*s, y: cy*s))
            p.closeSubpath()
            // Center facet.
            p.move(to: .init(x: (cx - r*0.72)*s, y: cy*s))
            p.addLine(to: .init(x: (cx + r*0.72)*s, y: cy*s))
        }
        var p = Path()
        gem(cx: 16, cy: 9.5, r: 5.5, into: &p)
        gem(cx: 9.5, cy: 21, r: 4.8, into: &p)
        gem(cx: 22.5, cy: 21, r: 4.8, into: &p)
        return p
    }
}

private struct CalendarIcon: Shape {
    /// Calendar — frame, header rule, two hangers, and a grid of day dots.
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 5*s, y: 7*s, width: 22*s, height: 20*s),
                         cornerSize: .init(width: 2.5*s, height: 2.5*s))
        // Header divider.
        p.move(to: .init(x: 5*s, y: 13*s)); p.addLine(to: .init(x: 27*s, y: 13*s))
        // Hangers.
        p.move(to: .init(x: 11*s, y: 5*s)); p.addLine(to: .init(x: 11*s, y: 9*s))
        p.move(to: .init(x: 21*s, y: 5*s)); p.addLine(to: .init(x: 21*s, y: 9*s))
        // Day dots (2 rows × 3).
        for row in 0..<2 {
            for col in 0..<3 {
                let cx = 10.5 + CGFloat(col) * 5.5
                let cy = 17.5 + CGFloat(row) * 4.5
                p.addEllipse(in: CGRect(x: (cx - 0.9)*s, y: (cy - 0.9)*s, width: 1.8*s, height: 1.8*s))
            }
        }
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

/// Every trophy icon name in the set — the single source of truth for the
/// debug gallery and the preview below.
let trophyIconNames = [
    "catcher", "widebody", "regional", "longlens", "world",
    "constellation", "quintet", "diamond", "sparkle", "crown",
    "centurion", "setmaster", "night", "heritage", "coast",
    "narrowbody", "ticket", "gems", "calendar",
    "eye", "hattrick", "worldwide", "repeat", "streak",
    "jumbo", "cargo", "bizjet", "prop", "star", "heli",
    "altitude", "speed", "stack", "clock",
    "approach", "grid", "home", "weekend", "sunrise", "twin",
    "coin", "crystal", "bolt",
    "laurel", "crowns", "summit",
]

#if DEBUG
/// DEBUG-only grid of every trophy icon (in the earned cyan hex) for visual
/// review — "loop through each badge". Presented from the debug panel.
struct TrophyIconGallery: View {
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 22) {
                ForEach(trophyIconNames, id: \.self) { name in
                    VStack(spacing: 8) {
                        TrophyView(tier: .platinum, iconName: name, size: 76)
                        Text(name)
                            .font(Brand.Font.mono(size: 10, weight: .semibold))
                            .foregroundStyle(Brand.Color.textTertiary)
                    }
                }
            }
            .padding(24)
        }
        .background(Brand.Color.bgPrimary)
    }
}
#endif

#Preview {
    ScrollView {
        let tiers: [TrophyTier] = [.bronze, .silver, .gold, .platinum]
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
            ForEach(0..<trophyIconNames.count, id: \.self) { idx in
                let tier = tiers[idx % tiers.count]
                TrophyView(tier: tier, iconName: trophyIconNames[idx], size: 72)
            }
            TrophyView(tier: .bronze, iconName: "catcher", size: 72, locked: true)
        }
        .padding()
    }
    .background(Brand.Color.bgPrimary)
}
