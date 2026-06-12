//
//  SilhouetteCardSpike.swift
//  Tailspot
//
//  STAGE-2b CARD-STYLE SPIKE (feat/card-style-spike) — REVIEWABLE ONLY.
//
//  This is a spike artifact, NOT production code. It deliberately does
//  NOT modify CatchCardView. Instead it reproduces enough of the card
//  chrome (size, rarity rail, holo treatment, footer) to drop the three
//  candidate silhouette TREATMENTS into the photo-slot area so Noah can
//  pick a style direction. Stage 2c builds the winner into the real card.
//
//  Three directions, each a `SilhouetteStyle`:
//
//    A — "Blueprint":  fine cyan line-work on a dark gridded ground.
//                      Extends the AR-HUD / B612 cockpit identity.
//    B — "Solid flat": bold filled near-white silhouette on a
//                      rarity-tinted radial glow. Max small-size
//                      readability; the most "trading card" of the three.
//    C — "Duotone + livery band": filled silhouette with a parameterized
//                      airline accent band sweeping behind it, softer
//                      gradient ground.
//
//  The card body code below is a trimmed clone of CatchCardView's layout
//  so the comparison is honest (same dims, same rail, same footer) while
//  keeping the production file untouched.
//

import SwiftUI

// MARK: - Style direction

nonisolated enum SilhouetteStyle: String, CaseIterable, Sendable {
    case blueprint   // A
    case solidFlat   // B
    case duotone     // C

    var shortName: String {
        switch self {
        case .blueprint: return "A — Blueprint"
        case .solidFlat: return "B — Solid flat"
        case .duotone:   return "C — Duotone + livery"
        }
    }

    var oneLiner: String {
        switch self {
        case .blueprint: return "Fine cyan line-work on a gridded dark ground — extends the AR-HUD identity."
        case .solidFlat: return "Bold filled silhouette on a rarity-tinted glow — max readability, most trading-card."
        case .duotone:   return "Filled silhouette over a parameterized airline accent band — softer ground."
        }
    }
}

/// Optional airline livery accent, used by direction C (and ignored by
/// A/B). A real implementation would key this off the operator metadata;
/// the spike passes it explicitly so the sample reads as a United A320.
nonisolated struct LiveryAccent: Equatable, Sendable {
    let primary: Color
    let secondary: Color
    let name: String

    /// United Airlines: deep blue + lighter accent (approximation).
    static let united = LiveryAccent(
        primary: Color(hex: 0x0033A0),
        secondary: Color(hex: 0x4596D8),
        name: "United"
    )
}

// MARK: - The silhouette art slot (the part that actually varies)

/// Renders ONE silhouette in ONE style, sized to fill the given frame.
/// This is the surface Noah is actually judging — everything around it
/// is shared card chrome.
nonisolated struct SilhouetteArt: View {
    let kind: SilhouetteKind
    let style: SilhouetteStyle
    let rarity: Rarity
    var livery: LiveryAccent? = nil

    var body: some View {
        ZStack {
            ground
            artwork
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: ground (behind the silhouette)

    @ViewBuilder
    private var ground: some View {
        switch style {
        case .blueprint:
            ZStack {
                Color(hex: 0x081420)                       // deep blueprint navy
                BlueprintGrid(spacing: 14)
                    .stroke(Brand.Color.cyan.opacity(0.10), lineWidth: 0.5)
            }
        case .solidFlat:
            ZStack {
                Brand.Color.bgSurface
                RadialGradient(
                    gradient: Gradient(colors: [rarity.tint.opacity(0.42), .clear]),
                    center: .center, startRadius: 2, endRadius: 130
                )
            }
        case .duotone:
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0x10182A), Brand.Color.bgSurface],
                    startPoint: .top, endPoint: .bottom
                )
                if let livery {
                    // Diagonal airline accent band sweeping behind the plane.
                    LiveryBand(primary: livery.primary, secondary: livery.secondary)
                }
            }
        }
    }

    // MARK: artwork (the silhouette itself)

    @ViewBuilder
    private var artwork: some View {
        let inset: CGFloat = 12
        GeometryReader { geo in
            let frame = CGRect(origin: .zero, size: geo.size).insetBy(dx: inset, dy: inset)
            ZStack {
                // Helicopter disc underlay (faint), behind blades+body.
                if kind == .heli {
                    HeliRotorDisc()
                        .path(in: frame)
                        .applyDiscStyle(style: style, rarity: rarity)
                }
                switch style {
                case .blueprint:
                    // Stroked outline + a couple of internal reference lines.
                    kind.shape.path(in: frame)
                        .stroke(Brand.Color.cyan.opacity(0.95), lineWidth: 1.4)
                    kind.shape.path(in: frame)
                        .fill(Brand.Color.cyan.opacity(0.07))
                    CenterlineMarks(frame: frame)
                        .stroke(Brand.Color.cyan.opacity(0.35), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                case .solidFlat:
                    kind.shape.path(in: frame)
                        .fill(Color(hex: 0xE8F1FA))                // near-white, bold
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                case .duotone:
                    kind.shape.path(in: frame)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0xF2F6FB), Color(hex: 0xB8C6D6)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                }
            }
        }
    }
}

// MARK: - Supporting shapes for the styles

/// A simple square grid for the blueprint ground.
private struct BlueprintGrid: Shape {
    let spacing: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = rect.minX
        while x <= rect.maxX {
            p.move(to: CGPoint(x: x, y: rect.minY))
            p.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }
        var y = rect.minY
        while y <= rect.maxY {
            p.move(to: CGPoint(x: rect.minX, y: y))
            p.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }
        return p
    }
}

/// Dashed centerline + a span tick, blueprint-style annotation feel.
private struct CenterlineMarks: Shape {
    let frame: CGRect
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // vertical centerline
        p.move(to: CGPoint(x: frame.midX, y: frame.minY))
        p.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
        // horizontal span line at ~62% (around the wing)
        let y = frame.minY + frame.height * 0.62
        p.move(to: CGPoint(x: frame.minX, y: y))
        p.addLine(to: CGPoint(x: frame.maxX, y: y))
        return p
    }
}

/// Diagonal airline accent band for direction C.
private struct LiveryBand: View {
    let primary: Color
    let secondary: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // Broad primary band sweeping lower-left → upper-right.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.78))
                    p.addLine(to: CGPoint(x: w, y: h * 0.42))
                    p.addLine(to: CGPoint(x: w, y: h * 0.66))
                    p.addLine(to: CGPoint(x: 0, y: h * 1.02))
                    p.closeSubpath()
                }
                .fill(primary.opacity(0.55))
                // Thin secondary accent stripe above it.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.70))
                    p.addLine(to: CGPoint(x: w, y: h * 0.34))
                    p.addLine(to: CGPoint(x: w, y: h * 0.40))
                    p.addLine(to: CGPoint(x: 0, y: h * 0.76))
                    p.closeSubpath()
                }
                .fill(secondary.opacity(0.65))
            }
        }
    }
}

// MARK: - disc-style helper

private extension Path {
    /// Style the helicopter rotor disc per direction.
    @ViewBuilder
    func applyDiscStyle(style: SilhouetteStyle, rarity: Rarity) -> some View {
        switch style {
        case .blueprint:
            self.stroke(Brand.Color.cyan.opacity(0.30), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
        case .solidFlat:
            self.fill(Color(hex: 0xE8F1FA).opacity(0.10))
                .overlay(self.stroke(Color(hex: 0xE8F1FA).opacity(0.25), lineWidth: 1))
        case .duotone:
            self.fill(.white.opacity(0.06))
                .overlay(self.stroke(.white.opacity(0.20), lineWidth: 1))
        }
    }
}

// MARK: - Spike card (trimmed clone of CatchCardView — DO NOT ship)

/// A card that puts `SilhouetteArt` in the photo slot. Mirrors
/// CatchCardView's dimensions/rail/holo/footer so the style comparison
/// is fair, but is a spike-only clone (production card is untouched).
nonisolated struct SilhouetteSpikeCard: View {
    let plane: CardPlane
    let kind: SilhouetteKind
    let style: SilhouetteStyle
    var livery: LiveryAccent? = nil
    var size: CatchCardView.CardSize = .md
    var holoIntensity: Double = 0.85

    private var dims: CatchCardView.CardSize.Dims { size.dims }

    private var showsHolo: Bool {
        holoIntensity > 0 && plane.rarity.ordinal >= Rarity.rare.ordinal
    }
    private var isLegendary: Bool { plane.rarity == .legendary }

    var body: some View {
        ZStack {
            cardBase
            rarityRail
            if showsHolo {
                holoLayer
                foilShine
            }
            content
        }
        .frame(width: dims.width, height: dims.height)
        .clipShape(RoundedRectangle(cornerRadius: dims.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: dims.cornerRadius)
                .strokeBorder(plane.rarity.tint, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.55), radius: 20, x: 0, y: 14)
        .shadow(color: plane.rarity.tint.opacity(0.25), radius: 18, x: 0, y: 0)
    }

    private var cardBase: some View {
        LinearGradient(
            colors: [Brand.Color.bgElevated, Brand.Color.bgSurface],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var rarityRail: some View {
        VStack(spacing: 0) {
            Rectangle().fill(plane.rarity.tint).frame(height: 5)
            Spacer()
        }
    }

    private var holoLayer: some View {
        let stops: [Color] = [
            Color(red: 1.00, green: 0.39, blue: 0.78),
            Color(red: 0.39, green: 0.78, blue: 1.00),
            Color(red: 1.00, green: 0.86, blue: 0.39),
            Color(red: 0.39, green: 1.00, blue: 0.71),
            Color(red: 0.71, green: 0.55, blue: 1.00),
            Color(red: 1.00, green: 0.39, blue: 0.78),
        ]
        return AngularGradient(colors: stops, center: .center,
                               startAngle: .degrees(45), endAngle: .degrees(45 + 360))
            .blendMode(.overlay)
            .opacity(holoIntensity * (isLegendary ? 1.4 : 1.0))
            .allowsHitTesting(false)
    }

    private var foilShine: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.30),
                .init(color: .white.opacity(0.18), location: 0.50),
                .init(color: .clear, location: 0.70),
            ],
            startPoint: UnitPoint(x: 0, y: 1), endPoint: UnitPoint(x: 1, y: 0)
        )
        .blendMode(.screen)
        .allowsHitTesting(false)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(plane.callsign ?? "—")
                    .font(Brand.Font.mono(size: dims.titleFont, weight: .bold))
                    .foregroundStyle(Brand.Color.cyan)
                    .lineLimit(1)
                Spacer(minLength: 4)
                RarityBadge(rarity: plane.rarity, size: dims.badge)
            }
            .padding(.top, 8)

            // THE SLOT UNDER TEST.
            SilhouetteArt(kind: kind, style: style, rarity: plane.rarity, livery: livery)
                .frame(height: dims.photoHeight)

            VStack(alignment: .leading, spacing: 2) {
                Text(plane.model ?? "Unknown aircraft")
                    .font(.system(size: dims.titleFont, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .lineLimit(1)
                if let carrier = plane.carrier {
                    Text(carrier)
                        .font(.system(size: dims.modelFont, weight: .regular))
                        .foregroundStyle(Brand.Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if size != .sm {
                HStack(spacing: 6) {
                    statChip(label: "ALT",  value: plane.altText  ?? "—")
                    statChip(label: "SPD",  value: plane.speedText ?? "—")
                    statChip(label: "DIST", value: plane.distText ?? "—")
                }
            }

            HStack {
                TypeBadge(type: plane.type, size: dims.badge)
                Spacer(minLength: 4)
                Text("+\(plane.rarity.basePoints) pt")
                    .font(Brand.Font.mono(size: dims.pointsFont + 2, weight: .bold))
                    .foregroundStyle(plane.rarity.tint)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, dims.width * 0.06)
        .padding(.bottom, 10)
    }

    private func statChip(label: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(Brand.Font.mono(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Brand.Color.textTertiary)
            Text(value)
                .font(Brand.Font.mono(size: 10, weight: .bold))
                .foregroundStyle(Brand.Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Brand.Color.bgSurface.opacity(0.85), in: .rect(cornerRadius: 4))
    }
}

// MARK: - Raw silhouette check card (large, plain ground)

/// A large single silhouette on a plain ground for proportion-checking.
/// Drawn in the "solid flat" treatment (the most legible) so shape
/// problems aren't hidden by line-work.
nonisolated struct SilhouetteCheckCard: View {
    let kind: SilhouetteKind
    var body: some View {
        ZStack {
            Color(hex: 0x12161F)
            GeometryReader { geo in
                let frame = CGRect(origin: .zero, size: geo.size).insetBy(dx: 28, dy: 28)
                ZStack {
                    if kind == .heli {
                        HeliRotorDisc().path(in: frame)
                            .fill(.white.opacity(0.06))
                        HeliRotorDisc().path(in: frame)
                            .stroke(.white.opacity(0.22), lineWidth: 1)
                    }
                    kind.shape.path(in: frame)
                        .fill(Color(hex: 0xE8F1FA))
                }
            }
            VStack {
                Spacer()
                Text(kind.label)
                    .font(Brand.Font.mono(size: 12, weight: .bold))
                    .foregroundStyle(Brand.Color.textSecondary)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: 320, height: 380)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
