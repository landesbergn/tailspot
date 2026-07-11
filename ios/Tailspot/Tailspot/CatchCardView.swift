//
//  CatchCardView.swift
//  Tailspot
//
//  The visual artifact for a caught plane — a collectible card with
//  rarity-driven treatment. Common/Uncommon are clean dark cards;
//  Rare and above pick up a conic-gradient holo wash + diagonal foil
//  shine; Legendary additionally gets scattered radial gold-dust
//  hot-spots.
//
//  Layout, from top to bottom:
//
//    ┌──────────────────────────┐   ← rarity rail (5pt top stripe)
//    │ CALLSIGN          [RAR]  │
//    │ ┌──────────────────────┐ │   ← optional photo / placeholder
//    │ │       photo          │ │
//    │ └──────────────────────┘ │
//    │ Boeing 787-9             │   ← model + carrier
//    │ United Airlines          │
//    │  ALT     SPD     DIST    │   ← stat chips (md/lg only)
//    │ [TYPE]          +100 pt  │
//    └──────────────────────────┘
//
//  All three sizes (sm/md/lg) share the same layout; they only
//  differ in absolute dimensions and font sizes. The card is purely
//  presentational — it takes a `CardPlane` value object built by
//  the caller from a Catch + metadata + observed-aircraft state.
//

import SwiftUI

// MARK: - Value object

/// Pure presentational input for the catch card. Built from a Catch
/// (most reliable, since it's a frozen snapshot) or from a live
/// ObservedAircraft + AircraftMetadata pair (for the AR catch
/// moment, before persistence). All optionality lives here; the
/// view falls back to em-dashes / hidden lines when fields are nil.
struct CardPlane: Equatable {
    let callsign: String?
    let model: String?
    let carrier: String?
    let rarity: Rarity
    let type: AircraftType
    /// Optional bits shown in the stat-chip row. Strings (already
    /// formatted) so the view doesn't have to know units.
    let altText: String?
    let speedText: String?
    let distText: String?
    /// Optional URL for a hero photo. When nil we render a striped
    /// placeholder in the rarity tint (matches the design's
    /// PhotoPlaceholder when Planespotters hasn't returned).
    let photoURL: URL?
    /// Where the plane sits in the local catch photo (normalized 0…1;
    /// `Catch.photoFocus`) — anchors the hero's aspect-fill crop on the
    /// plane. nil → center crop (pre-focus rows, remote photos).
    let photoFocus: CGPoint?
    /// Route DISPLAY codes, when the catch carried a route. Builders pass
    /// the traveler-readable code (IATA preferred — "HND" — falling back to
    /// ICAO "RJTT"; see `Catch.displayOrigin`): CardPlane is a presentation
    /// model, so the field keeps its historical name but holds whichever
    /// code should render. The optional human-readable names ("Tokyo" /
    /// "San Francisco") render under them. nil route → slant distance.
    let originIcao: String?
    let destIcao: String?
    let originName: String?
    let destName: String?
    /// Whether this is the observer's first catch of this typecode.
    /// Drives the reveal's "FIRST OF TYPE" ledger line. Display-only —
    /// the backend is authoritative for the awarded bonus.
    let isFirstOfType: Bool
    /// The bonus-round question this catch answered CORRECTLY (game-layer
    /// PR3; route-only per Noah 2026-07-09) — drives the reveal's
    /// "10% ROUTE BONUS +N" ledger line. nil when no round fired, was skipped,
    /// or was wrong (a wrong guess shows no reveal line — the guess screen
    /// already flashed the miss). Mirrors `isFirstOfType`: display-only,
    /// computed off the frozen `Catch` row; the backend re-verifies and is
    /// authoritative for the awarded bonus.
    let guessKind: GuessKind?
    /// The guess bonus amount to show in the ledger, 0 when none/wrong.
    /// Computed off the row's live base via `ScoringBonuses.guessBonus` so it
    /// re-tiers with the base like `firstOfType` does.
    let guessBonusPoints: Int

    init(
        callsign: String?,
        model: String?,
        carrier: String?,
        rarity: Rarity,
        type: AircraftType,
        altText: String? = nil,
        speedText: String? = nil,
        distText: String? = nil,
        photoURL: URL? = nil,
        photoFocus: CGPoint? = nil,
        originIcao: String? = nil,
        destIcao: String? = nil,
        originName: String? = nil,
        destName: String? = nil,
        isFirstOfType: Bool = false,
        guessKind: GuessKind? = nil,
        guessBonusPoints: Int = 0
    ) {
        self.callsign = callsign
        self.model = model
        self.carrier = carrier
        self.rarity = rarity
        self.type = type
        self.altText = altText
        self.speedText = speedText
        self.distText = distText
        self.photoURL = photoURL
        self.photoFocus = photoFocus
        self.originIcao = originIcao
        self.destIcao = destIcao
        self.originName = originName
        self.destName = destName
        self.isFirstOfType = isFirstOfType
        self.guessKind = guessKind
        self.guessBonusPoints = guessBonusPoints
    }
}

// MARK: - CatchCardView

struct CatchCardView: View {
    let plane: CardPlane
    var size: CardSize = .md
    /// 0.0 → no holo overlay; 0.45 → subtle; 0.85 → vivid. Has no
    /// effect on common/uncommon cards (which never carry holo).
    var holoIntensity: Double = 0.85
    /// Rotation in degrees, applied via `.rotationEffect`. Used by
    /// the multi-catch fan reveal and the onboarding card stack.
    var rotation: Angle = .zero

    enum CardSize {
        case sm, md, lg

        struct Dims {
            let width: CGFloat
            let height: CGFloat
            let photoHeight: CGFloat
            let titleFont: CGFloat
            let modelFont: CGFloat
            let pointsFont: CGFloat
            let cornerRadius: CGFloat
            let badge: BadgeSize
        }

        var dims: Dims {
            switch self {
            case .sm: return .init(width: 150, height: 210, photoHeight: 80,  titleFont: 11, modelFont: 10, pointsFont: 11, cornerRadius: 12, badge: .sm)
            case .md: return .init(width: 220, height: 308, photoHeight: 116, titleFont: 13, modelFont: 11, pointsFont: 12, cornerRadius: 14, badge: .md)
            case .lg: return .init(width: 280, height: 400, photoHeight: 150, titleFont: 16, modelFont: 13, pointsFont: 13, cornerRadius: 16, badge: .md)
            }
        }
    }

    private var dims: CardSize.Dims { size.dims }

    /// Holo only shows on rare+ cards (per the design canvas).
    private var showsHolo: Bool {
        holoIntensity > 0 && plane.rarity.ordinal >= Rarity.rare.ordinal
    }

    /// Legendary gets the extra gold-dust radial bloom + a 1.4×
    /// holo boost on top of the standard intensity.
    private var isLegendary: Bool { plane.rarity == .legendary }

    var body: some View {
        ZStack {
            cardBase
            rarityRail
            if showsHolo {
                holoLayer
                foilShine
            }
            if isLegendary {
                goldDust
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
        .rotationEffect(rotation)
    }

    // MARK: - Card layers

    private var cardBase: some View {
        LinearGradient(
            colors: [Brand.Color.bgElevated, Brand.Color.bgSurface],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 5-pt top stripe in the rarity tint. Cheap, instantly readable.
    private var rarityRail: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(plane.rarity.tint)
                .frame(height: 5)
            Spacer()
        }
    }

    /// Holo wash. Angular gradient through the six-color stop wheel,
    /// blended `.overlay` so it stays subtle on dark backgrounds and
    /// pops on lighter elements. Static (no animation in v1 — the
    /// diagonal shine layer provides directional motion later).
    private var holoLayer: some View {
        let stops: [Color] = [
            Color(red: 1.00, green: 0.39, blue: 0.78),    // pink
            Color(red: 0.39, green: 0.78, blue: 1.00),    // cyan
            Color(red: 1.00, green: 0.86, blue: 0.39),    // yellow
            Color(red: 0.39, green: 1.00, blue: 0.71),    // mint
            Color(red: 0.71, green: 0.55, blue: 1.00),    // violet
            Color(red: 1.00, green: 0.39, blue: 0.78),    // pink (close)
        ]
        return AngularGradient(
            colors: stops,
            center: .center,
            startAngle: .degrees(45),
            endAngle: .degrees(45 + 360)
        )
        .blendMode(.overlay)
        .opacity(holoIntensity * (isLegendary ? 1.4 : 1.0))
        .allowsHitTesting(false)
    }

    /// Diagonal foil shine. A bright band running ~115° across the
    /// card, screened on top so it lightens whatever it overlaps.
    private var foilShine: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.30),
                .init(color: .white.opacity(0.18), location: 0.50),
                .init(color: .clear, location: 0.70),
            ],
            startPoint: UnitPoint(x: 0.0, y: 1.0),
            endPoint: UnitPoint(x: 1.0, y: 0.0)
        )
        .blendMode(.screen)
        .allowsHitTesting(false)
    }

    /// Legendary-only gold-dust hot-spots. Four small radial blooms
    /// at fixed proportional positions; cheap to render and unique
    /// to the tier.
    private var goldDust: some View {
        let dustColor = Color(red: 1.0, green: 0.78, blue: 0.29)
        return ZStack {
            ForEach(Self.dustPoints, id: \.x) { p in
                RadialGradient(
                    gradient: Gradient(colors: [dustColor.opacity(0.42), .clear]),
                    center: UnitPoint(x: p.x, y: p.y),
                    startRadius: 0,
                    endRadius: 36
                )
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }

    private static let dustPoints: [CGPoint] = [
        .init(x: 0.20, y: 0.30),
        .init(x: 0.70, y: 0.70),
        .init(x: 0.45, y: 0.15),
        .init(x: 0.85, y: 0.35),
    ]

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row — callsign + rarity badge
            HStack {
                Text(plane.callsign?.trimmedNonEmpty ?? "—")
                    .font(Brand.Font.mono(size: dims.titleFont, weight: .bold))
                    .foregroundStyle(Brand.Color.cyan)
                    .lineLimit(1)
                Spacer(minLength: 4)
                RarityBadge(rarity: plane.rarity, size: dims.badge)
            }
            .padding(.top, 8)

            // Photo (or rarity-tinted striped placeholder).
            photoView
                .frame(height: dims.photoHeight)

            // Title block
            VStack(alignment: .leading, spacing: 2) {
                Text(plane.model?.trimmedNonEmpty ?? "Unknown aircraft")
                    .font(.system(size: dims.titleFont, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .lineLimit(1)
                if let carrier = plane.carrier?.trimmedNonEmpty {
                    Text(carrier)
                        .font(.system(size: dims.modelFont, weight: .regular))
                        .foregroundStyle(Brand.Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Stat chips (md/lg only — too cramped on sm)
            if size != .sm {
                statChips
            }

            // Footer row — type chip + base points
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

    @ViewBuilder
    private var photoView: some View {
        ZStack {
            if let url = plane.photoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        placeholderStripes
                    }
                }
            } else {
                placeholderStripes
            }
            // Photo bevel — top highlight + bottom shadow vignette.
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.06), lineWidth: 0.5)
            LinearGradient(
                colors: [.clear, .black.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
            .blendMode(.multiply)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Striped placeholder in the rarity tint. Replaces the design's
    /// `PhotoPlaceholder` — fills the slot without making it look
    /// like the photo is "missing."
    private var placeholderStripes: some View {
        ZStack {
            plane.rarity.tint.opacity(0.18)
            // Two-tone diagonal stripes.
            GeometryReader { geo in
                Canvas { ctx, _ in
                    let step: CGFloat = 16
                    let total = (geo.size.width + geo.size.height) / step
                    for i in 0...Int(total) {
                        let offset = CGFloat(i) * step
                        var path = Path()
                        path.move(to: CGPoint(x: offset, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: offset))
                        ctx.stroke(
                            path,
                            with: .color(plane.rarity.tint.opacity(0.10)),
                            lineWidth: 6
                        )
                    }
                }
            }
            Image(systemName: "airplane")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(plane.rarity.tint.opacity(0.45))
        }
    }

    private var statChips: some View {
        HStack(spacing: 6) {
            statChip(label: "ALT",  value: plane.altText  ?? "—")
            statChip(label: "SPD",  value: plane.speedText ?? "—")
            statChip(label: "DIST", value: plane.distText ?? "—")
        }
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

// MARK: - CardPlane builders

extension CardPlane {
    /// "500 ft" from meters MSL. Shared by the live catch reveal and
    /// the stored-catch builder so the two can't drift apart.
    static func altText(fromMeters m: Double?) -> String? {
        m.map { "\(Int(($0 * 3.28084).rounded()).formatted(.number)) ft" }
    }

    /// "200 kt" from m/s ground speed.
    static func speedText(fromMps v: Double?) -> String? {
        v.map { "\(Int(($0 * 1.94384).rounded())) kt" }
    }

    /// "12.3 km" from a slant distance — nil (→ the card's "—") when the
    /// distance is the 0 unknown-sentinel. `Catch.slantDistanceMeters` is
    /// non-optional, so rows the server restored (which never stored a
    /// distance) carry 0 instead of nil; "0.0 km" would read as a plane
    /// caught on your head.
    static func distText(fromMeters m: Double) -> String? {
        m > 0 ? String(format: "%.1f km", m / 1000) : nil
    }

    /// Build a card from a persisted Catch. Reads the snapshotted
    /// rarity/type (or backfills via classifier when nil), resolves
    /// the model line to its canonical official name, and formats the
    /// alt/speed snapshotted at the catch moment (nil for rows from
    /// before those fields shipped → the card renders "—").
    init(catchRecord c: Catch) {
        let canonical = AircraftNaming.canonical(
            typecode: c.typecode,
            manufacturer: c.manufacturer,
            model: c.model
        )
        self.init(
            callsign: c.callsign,
            model: canonical.displayName ?? c.model,
            carrier: c.operatorName,
            rarity: c.resolvedRarity,
            type: c.resolvedType,
            altText: Self.altText(fromMeters: c.altitudeMeters),
            speedText: Self.speedText(fromMps: c.velocityMps),
            distText: Self.distText(fromMeters: c.slantDistanceMeters),
            photoURL: c.photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) }
        )
    }
}

// MARK: - String helpers

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 24) {
            CatchCardView(
                plane: .init(
                    callsign: "UAL248",
                    model: "Boeing 787-9",
                    carrier: "United Airlines",
                    rarity: .rare,
                    type: .wide,
                    altText: "FL370",
                    speedText: "478 kt",
                    distText: "12 km"
                ),
                size: .lg
            )
            CatchCardView(
                plane: .init(
                    callsign: "BAW286",
                    model: "Airbus A380",
                    carrier: "British Airways",
                    rarity: .epic,
                    type: .wide,
                    altText: "FL360",
                    speedText: "488 kt",
                    distText: "9 km"
                ),
                size: .md
            )
            CatchCardView(
                plane: .init(
                    callsign: "AF1",
                    model: "Boeing VC-25",
                    carrier: "USAF",
                    rarity: .legendary,
                    type: .mil,
                    altText: "FL400",
                    speedText: "480 kt",
                    distText: "31 km"
                ),
                size: .md
            )
        }
        .padding()
    }
    .background(Brand.Color.bgPrimary)
}
