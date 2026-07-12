//
//  Brand.swift
//  Tailspot
//
//  Single source of truth for the Tailspot visual identity.
//  Every color or font value used across the app routes through
//  here so a one-file edit re-themes the whole app.
//
//  Design spec: docs/archive/superpowers/specs/2026-05-18-tailspot-visual-identity-design.md
//
//  Two contexts share one brand:
//    - AR view  → clinical pilot HUD (cyan, mono, restraint)
//    - Hangar   → playful collector cards (carbon-dark base, magenta for rare)
//
//  Color tokens are FAA-aligned per 14 CFR 25.1322(e): amber is
//  reserved for caution only, magenta is the advisory/pinned color,
//  red is for true warnings (never as text on bg.primary), green is
//  used sparingly for safe/acquired states.
//
//  Chrome rule (Noah, 2026-07-10 polish sweep): custom chrome for the
//  GAME surfaces (Hangar, cards, reveals — they earn bespoke bars and
//  transitions), stock-but-branded SYSTEM navigation for the UTILITY
//  screens (Settings, Map, Leaderboard — inline nav titles, branded
//  list chrome). Don't hand-roll nav bars on utility screens and don't
//  put stock bars on game surfaces.
//

import SwiftUI

nonisolated enum Brand {

    // MARK: - Color

    nonisolated enum Color {
        static let bgPrimary    = SwiftUI.Color(hex: 0x0A0E1A)
        static let bgElevated   = SwiftUI.Color(hex: 0x1A2030)
        static let bgSurface    = SwiftUI.Color(hex: 0x050810)

        static let textPrimary   = SwiftUI.Color(hex: 0xE8F4FF)
        static let textSecondary = SwiftUI.Color(hex: 0xA0B0C0)
        static let textTertiary  = SwiftUI.Color(hex: 0x7F8B98)

        static let cyan = SwiftUI.Color(hex: 0x00D4FF)

        /// Dark outline drawn *behind* the cyan HUD lock-on brackets so they
        /// stay legible against a bright sky (cyan-on-blue is low contrast).
        /// Reuses the near-black `bgSurface` value; held at full opacity behind
        /// the (sometimes faded) cyan strokes so even a faint bracket keeps a
        /// crisp dark edge. `CatchPhotoComposer` duplicates this as a `UIColor`
        /// (it stays SwiftUI-independent), so keep the two in sync.
        static let hudBracketHalo = SwiftUI.Color(hex: 0x050810)

        static let alertWarning  = SwiftUI.Color(hex: 0xFF5555)
        static let alertCaution  = SwiftUI.Color(hex: 0xFFB800)
        static let alertAdvisory = SwiftUI.Color(hex: 0xFF6BE6)
        static let alertNormal   = SwiftUI.Color(hex: 0x3DD68C)

        /// Leaderboard podium medals. Not part of the HUD/collector palette —
        /// these are universal gold/silver/bronze semantics — but routed
        /// through Brand so every color in the app lives in one file.
        static let podiumGold   = SwiftUI.Color(hex: 0xFFC74A)
        static let podiumSilver = SwiftUI.Color(hex: 0xC5D0DA)
        static let podiumBronze = SwiftUI.Color(hex: 0xC26B3F)

        /// Reveal-ledger bonus gold (`RP.gold` in the reveal vocabulary) —
        /// the FIRST OF TYPE / ROUTE BONUS ledger tint. Deliberately distinct
        /// from `podiumGold` (medal) and `alertCaution` (FAA amber).
        static let ledgerGold = SwiftUI.Color(hex: 0xFBBF24)

        /// Muted rose for the reveal's "· ALREADY CAUGHT" duplicate stamp —
        /// softer than `alertWarning` red, which is reserved for true warnings.
        static let duplicateRose = SwiftUI.Color(hex: 0xE0556B)
    }

    // MARK: - Radius

    /// Corner-radius scale (Noah, 2026-07-10 polish sweep). Four steps —
    /// every rounded rectangle in the app snaps to one of these:
    ///   chip  — small inline elements: glyph tiles, tags, tight chips
    ///   row   — list rows, input fields, buttons, banners
    ///   card  — cards, sheets-within-screens, grouped surfaces
    ///   hero  — the biggest set pieces (reveal/settled catch card)
    /// Exceptions stay literal: radii computed from a scale factor
    /// (e.g. the reveal ledger's `11 * scale`), per-size design tables
    /// (`CatchCardView` dims), tiny 3–4 pt accents on very small badges
    /// (rounding them to 6 turns them into pills), and the AR HUD
    /// brackets. Capsules stay capsules.
    nonisolated enum Radius {
        static let chip: CGFloat = 6
        static let row:  CGFloat = 12
        static let card: CGFloat = 16
        static let hero: CGFloat = 26
    }

    // MARK: - Font
    //
    // Type rule (Noah, 2026-07-10 polish sweep):
    //   mono   = readouts, data, and ALL-CAPS labels (anything a pilot
    //            would expect fixed-pitch: callsigns, headings, counts)
    //   system = human prose (titles, body copy, buttons)
    //   Prose heads use exactly ONE display size: `Brand.Font.display`.
    //   Don't freelance `.system(size: 24…30, weight: .bold)` heads.

    nonisolated enum Font {
        /// Aviation-flavored monospace. B612 Mono is Airbus's cockpit
        /// display font (SIL OFL 1.1, bundled via UIAppFonts in Info.plist).
        /// Used for callsigns, ICAO codes, headings, badge labels, and the
        /// wordmark — anywhere a pilot would expect a fixed-pitch readout.
        ///
        /// B612 Mono ships in Regular + Bold physical weights only. SwiftUI
        /// weight requests map down: regular/medium/light → Regular face;
        /// semibold/bold/heavy/black → Bold face. Italic is bundled but
        /// callers must select it explicitly via `mono(size:weight:italic:)`.
        static func mono(size: CGFloat,
                         weight: SwiftUI.Font.Weight = .regular,
                         italic: Bool = false) -> SwiftUI.Font {
            let isBold: Bool
            switch weight {
            case .ultraLight, .thin, .light, .regular, .medium:
                isBold = false
            default:
                isBold = true
            }
            let name: String
            switch (isBold, italic) {
            case (false, false): name = "B612Mono-Regular"
            case (true,  false): name = "B612Mono-Bold"
            case (false, true):  name = "B612Mono-Italic"
            case (true,  true):  name = "B612Mono-BoldItalic"
            }
            return .custom(name, size: size)
        }

        static let wordmark    = mono(size: 24, weight: .bold)
        static let hudCallsign = mono(size: 13, weight: .bold)
        static let hudData     = mono(size: 10, weight: .regular)

        /// The single prose-head size (see the type rule above). 26 pt
        /// bold system — chosen against the pre-token heads (24/26/28/30):
        /// big enough to lead a screen, small enough that the tightest
        /// layouts (SE-height onboarding, the 320 pt PermissionRecoveryCard)
        /// keep their line counts.
        static let display = SwiftUI.Font.system(size: 26, weight: .bold)

        static let cardTitle    = SwiftUI.Font.system(size: 17, weight: .semibold, design: .default)
        static let cardSubtitle = SwiftUI.Font.system(size: 13, weight: .regular,  design: .default)
        static let label        = SwiftUI.Font.system(size: 11, weight: .semibold, design: .default)
        static let body         = SwiftUI.Font.system(size: 15, weight: .regular,  design: .default)
        static let caption      = SwiftUI.Font.system(size: 12, weight: .regular,  design: .default)
    }
}

nonisolated extension SwiftUI.Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
