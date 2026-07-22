//
//  Brand.swift
//  Tailspot
//
//  Single source of truth for the Tailspot visual identity.
//  Every color or font value used across the app routes through
//  here so a one-file edit re-themes the whole app — with three
//  deliberate ARTBOARD exceptions that carry local vocabularies
//  (fixed card canvases, the same class the type rule exempts):
//  the reveal's `RP` palette (CatchRevealView), the holo-foil
//  rainbow + dust gold (CatchCardView), and the onboarding
//  illustration sky (OnboardingFlow). Keep them local; document
//  new ones here.
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
//  put stock bars on game surfaces. One blessed exception: the Sets
//  ROOT keeps a stock `.navigationTitle` because it's entered from
//  Profile's stack (its pushed children switch to HangarChildBar —
//  see the note atop SetsScreen.swift).
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
    //   Prose heads use exactly ONE display treatment: `.brandDisplayFont()`.
    //   Don't freelance `.system(size: 24…30, weight: .bold)` heads.
    //
    // Dynamic Type rule (2026-07-12 HIG pass): tokens that render prose or
    // reflowable list content scale with the user's text-size setting —
    // the system tokens map onto built-in text styles whose default sizes
    // exactly match the old fixed sizes (so nothing moves at the default
    // setting), and `mono` takes an optional `relativeTo:` anchor for data
    // that lives in scrollable screens. Two surfaces stay fixed BY CHOICE,
    // not omission: the AR HUD readouts (`hudCallsign`/`hudData` — density
    // over the camera is the point) and the card artboards whose type
    // scales off canvas width (the reveal/settled cards, CatchShareCard).

    nonisolated enum Font {
        /// Mirror of `UIAccessibility.isBoldTextEnabled`, set at launch and
        /// on the bold-text change notification (see `TailspotApp.init`).
        /// Cached because the UIKit getter is MainActor-only and font
        /// tokens are built from nonisolated contexts; a stale read is a
        /// Bool-sized cosmetic race, refreshed on the next body evaluation.
        /// The system-text-style tokens below don't need it (built-in
        /// styles track Bold Text on their own) — it exists for B612 Mono,
        /// which is a custom font and gets no automatic adaptation.
        nonisolated(unsafe) static var boldTextPreferred = false

        /// Aviation-flavored monospace. B612 Mono is Airbus's cockpit
        /// display font (SIL OFL 1.1, bundled via UIAppFonts in Info.plist).
        /// Used for callsigns, ICAO codes, headings, badge labels, and the
        /// wordmark — anywhere a pilot would expect a fixed-pitch readout.
        ///
        /// B612 Mono ships in Regular + Bold physical weights only. SwiftUI
        /// weight requests map down: regular/medium/light → Regular face;
        /// semibold/bold/heavy/black → Bold face. Italic is bundled but
        /// callers must select it explicitly via `mono(size:weight:italic:)`.
        /// When the user turns on Bold Text, every request maps to the Bold
        /// face — the whole of our mono bold-text adaptation (there is no
        /// heavier face to step up to).
        ///
        /// `relativeTo:` opts a call site into Dynamic Type scaling; nil
        /// (the default) keeps the fixed cockpit-instrument size. Rule of
        /// thumb: mono in a ScrollView/List passes an anchor, mono over
        /// the camera or on a fixed card canvas doesn't.
        static func mono(size: CGFloat,
                         weight: SwiftUI.Font.Weight = .regular,
                         italic: Bool = false,
                         relativeTo textStyle: SwiftUI.Font.TextStyle? = nil) -> SwiftUI.Font {
            var isBold: Bool
            switch weight {
            case .ultraLight, .thin, .light, .regular, .medium:
                isBold = false
            default:
                isBold = true
            }
            if boldTextPreferred { isBold = true }
            let name: String
            switch (isBold, italic) {
            case (false, false): name = "B612Mono-Regular"
            case (true,  false): name = "B612Mono-Bold"
            case (false, true):  name = "B612Mono-Italic"
            case (true,  true):  name = "B612Mono-BoldItalic"
            }
            if let textStyle {
                return .custom(name, size: size, relativeTo: textStyle)
            }
            return .custom(name, size: size)
        }

        // Computed (not `static let`) so a Bold Text toggle mid-session is
        // picked up the next time a view body evaluates.
        static var wordmark:    SwiftUI.Font { mono(size: 24, weight: .bold) }
        static var hudCallsign: SwiftUI.Font { mono(size: 13, weight: .bold) }
        static var hudData:     SwiftUI.Font { mono(size: 10, weight: .regular) }

        // System prose tokens, mapped onto the built-in text styles whose
        // default (Large) metrics are IDENTICAL to the old fixed sizes —
        // 17/semibold=headline, 13=footnote, 11=caption2, 15=subheadline,
        // 12=caption — which buys Dynamic Type scaling AND automatic Bold
        // Text adaptation with zero visual change at default settings.
        // (`display`, the old 26 pt head, matches no built-in style; it
        // became the `.brandDisplayFont()` view modifier below.)
        /// Primary-action button label. `.callout`'s default metric is
        /// exactly the 16 pt these buttons always used, so adopting the
        /// text style changes nothing at the default setting — it buys
        /// Dynamic Type scaling + Bold Text adaptation (audit 2026-07-21).
        static var button:       SwiftUI.Font { SwiftUI.Font.callout.weight(.bold) }
        static var cardTitle:    SwiftUI.Font { .headline }
        static var cardSubtitle: SwiftUI.Font { .footnote }
        static var label:        SwiftUI.Font { SwiftUI.Font.caption2.weight(.semibold) }
        static var body:         SwiftUI.Font { .subheadline }
        static var caption:      SwiftUI.Font { .caption }
    }
}

/// The single prose-head treatment (see the type rule above). 26 pt bold
/// system — chosen against the pre-token heads (24/26/28/30): big enough
/// to lead a screen, small enough that the tightest layouts (SE-height
/// onboarding, the 320 pt PermissionRecoveryCard) keep their line counts.
///
/// A ViewModifier rather than a `Font` constant because 26 pt matches no
/// built-in text style and `Font.system(size:weight:)` has no `relativeTo:`
/// overload — `@ScaledMetric(relativeTo: .title)` is SwiftUI's way to
/// scale a custom-size system font with Dynamic Type. Reads
/// `legibilityWeight` for Bold Text (custom-size system fonts don't adapt
/// on their own).
struct BrandDisplayFontModifier: ViewModifier {
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 26
    @Environment(\.legibilityWeight) private var legibilityWeight

    func body(content: Content) -> some View {
        content.font(.system(size: size,
                             weight: legibilityWeight == .bold ? .heavy : .bold))
    }
}

extension View {
    /// Prose-head font: the one sanctioned display size (was
    /// `Brand.Font.display`). Scales with Dynamic Type, anchored to `.title`.
    func brandDisplayFont() -> some View {
        modifier(BrandDisplayFontModifier())
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
