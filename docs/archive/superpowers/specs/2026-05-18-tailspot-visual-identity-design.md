# Tailspot — Visual Identity Spec

**Status:** approved 2026-05-18 (Noah); **reconciled to shipping code 2026-06-13.**
**Implementation phases:** A ✅ · B ✅ · C ✅ (all shipped over subsequent sessions — see CHANGELOG).

> **2026-06-13 reconciliation note.** This doc is the original approved
> design intent. Where the shipping app diverged, the divergence has been
> folded in below and flagged `[shipped]`. The two biggest truths the
> original draft did not anticipate:
> 1. **The HUD font is B612 Mono, not SF Mono** — Airbus's actual cockpit
>    display typeface (SIL OFL 1.1), bundled in-app. A stronger identity
>    choice than the system monospace the draft assumed. See §3.
> 2. **The game-system color tokens (rarity tiers, aircraft-type tints)**
>    are now a first-class part of the palette, living in `GameSystem.swift`
>    alongside `Brand.swift`. See §2.5.

---

## 1. Brand summary

Tailspot has two contexts and one brand. The same color, type, and mark system
serves both, with discipline about which palette tones get used where.

| Context | Treatment | Why |
|---|---|---|
| **AR view** (camera + lock-on) | Clinical pilot HUD | Has to read on top of a real sky. Demands legibility, precision, restraint. |
| **Hangar** (collection) | Playful collector cards | The dopamine payoff. Cards with character, type badges, count pills. |

The brand mark anchors both: corner-bracket reticle + plane silhouette,
horizontal lockup with the SF Mono `TAILSPOT` wordmark.

## 2. Color tokens

All colors live behind a `Brand.Color` namespace. Editing one file re-themes
the whole app. Hex values are sRGB.

### Foundations

| Token | Hex | Use |
|---|---|---|
| `bg.primary` | `#0A0E1A` | Default screen background (night sky) |
| `bg.elevated` | `#1A2030` | Cards, sheets, overlay panels |
| `bg.surface` | `#050810` | Deepest layer — debug panels, card backs |

### Text

| Token | Hex | Use | Min contrast vs `bg.primary` |
|---|---|---|---|
| `text.primary` | `#E8F4FF` | Body, headlines | 17.3 : 1 ✓ AAA |
| `text.secondary` | `#A0B0C0` | Muted info, captions | 8.7 : 1 ✓ AAA |
| `text.tertiary` | `#7F8B98` | Labels, timestamps | 5.5 : 1 ✓ AA |

> Earlier draft used `#5A6A7A` for tertiary (3.5 : 1) — fails AA for normal text. Lightened to clear AA.

### Brand accent

| Token | Hex | Use | Rule |
|---|---|---|---|
| `accent.cyan` | `#00D4FF` | Brackets, wordmark, locked callsign, interactive controls | **Never for sub-13pt text.** Pure cyan is hard to focus at small sizes (per FAA Chapter 3.7). |

### Alert tiers (FAA-aligned)

Strict semantics per `14 CFR 25.1322(e)`. Each color = exactly one meaning,
never decorative.

| Token | Hex | Meaning | Constraint |
|---|---|---|---|
| `alert.warning` | `#FF5555` | Red. Immediate action required. | Never as text directly on `bg.primary` — use on `bg.elevated` padding only. |
| `alert.caution` | `#FFB800` | Amber. Future action required. | Reserved for true cautions (compass-accuracy bad, rate-limited, etc.). Not for count pills, decoration, or pinned-state. |
| `alert.advisory` | `#FF6BE6` | Magenta. Advisory / selected / pinned. | Standard pilot-display advisory color. Replaces amber for tap-pin and rarity tags. |
| `alert.normal` | `#3DD68C` | Green. Catch confirmed, lock acquired. | Sparing use — green is associated with "landing gear down" in flight decks; we don't want to dilute it. |

### Combinations to avoid (per FAA)

- Red on `bg.primary` directly (avoid red-on-black)
- Saturated red and blue adjacent (false depth perception)
- Yellow on white, green on white, blue on black
- Any sub-13pt text in cyan or pure blue

### 2.5 Game-system tints `[shipped]`

These did not exist in the original draft; they emerged with the collection
game and now carry real semantic weight. They live in **`GameSystem.swift`**
(not `Brand.swift`) because they are bound to game enums — but they are part
of the one palette. They are **decorative/categorical**, which is why they sit
outside the strict FAA alert set; they must never be mistaken for alert tiers
(note `rare` deliberately equals `accent.cyan`, and `legendary` equals
`alert.caution`'s amber — used here as a tier color, not a caution).

**Rarity tiers** (card borders, badges, the AR HUD rarity tag):

| Tier | Hex |
|---|---|
| common | `#8595A5` |
| uncommon | `#4ECCA3` |
| rare | `#00D4FF` |
| epic | `#9B5DE5` |
| legendary | `#FFB800` |

**Aircraft-type tints** (type pills in cards / detail):

| Type | Hex |
|---|---|
| narrow | `#5B9DDB` |
| wide | `#7E5FE6` |
| regional | `#3DD68C` |
| biz | `#E6B847` |
| mil | `#88936A` |
| ga | `#E66B7A` |
| heritage | `#E68847` |

## 3. Typography tokens

`Brand.Font` namespace. Two voices: the **"HUD voice"** (instrument-readout
feel) and the **"collector voice"** (human-readable cards, sheets, body).

> **`[shipped]` — the HUD voice is B612 Mono, not SF Mono.** The original
> draft assumed the system monospace (`design: .monospaced`). The app instead
> bundles **B612 Mono** — the open-source typeface Airbus designed for cockpit
> displays (SIL OFL 1.1, declared in `Info.plist` via `UIAppFonts`). It is the
> literal instrument font, which is exactly the identity we were reaching for.
> The collector voice remains **SF Pro** (`design: .default`).
>
> B612 Mono ships in **Regular + Bold physical faces only** (plus their
> italics). The `mono(size:weight:italic:)` helper maps SwiftUI weight
> requests down: `ultraLight…medium` → Regular face, `semibold…black` → Bold
> face. Italic must be requested explicitly. Letter-spacing / uppercasing
> from the original draft are applied at the call site, not baked into the
> token.

| Token | Spec `[shipped]` | Use |
|---|---|---|
| `font.wordmark` | B612 Mono, 24pt bold (call site adds +4 tracking, uppercase) | The `TAILSPOT` wordmark in headers/splash |
| `font.hudCallsign` | B612 Mono, 13pt bold | Locked-plane callsign |
| `font.hudData` | B612 Mono, 10pt regular | Data rows under the callsign (altitude, speed, distance) |
| `font.cardTitle` | SF Pro, 17pt semibold | Aircraft type on a Hangar card |
| `font.cardSubtitle` | SF Pro, 13pt regular | Operator + timestamp on a Hangar card |
| `font.label` | SF Pro, 11pt semibold (call site adds tracking, uppercase) | Section headers, tags |
| `font.body` | SF Pro, 15pt regular | Default body text in sheets, detail views |
| `font.caption` | SF Pro, 12pt regular | Subdued auxiliary text |

> Beyond these named tokens, callers reach for `Brand.Font.mono(size:weight:)`
> directly for one-off HUD readouts (section labels, debug panel, pills) — the
> mono face is the recurring "this is an instrument" signal across the app.

## 4. Brand mark and lockup

### Mark

Corner-bracket reticle framing a plane silhouette.

- **Brackets:** 4 L-shaped corner strokes, arm length ≈ 22% of the icon's bounding square. Stroke 2.5pt at icon size 64, scales proportionally.
- **Plane glyph:** `Image(systemName: "airplane")` (Apple's canonical SF Symbol), centered, tinted `accent.cyan`. Renders pixel-perfect at every size — we never ship a custom-drawn plane.
- **Brackets are `accent.cyan` by default.** Magenta variant for tap-pinned visuals; green variant for catch-confirmed flash.

### Wordmark

`TAILSPOT` in B612 Mono, 24pt bold, +4 letter-spacing, color = `text.primary`.
Plain — no special treatment on individual letters.

### Lockup

Horizontal: icon + 14pt gap + wordmark, vertically center-aligned to each
other. Icon size = 56pt at the standard horizontal lockup; scales
proportionally with the wordmark when used at larger or smaller scales.

Used in:

- Splash screen (centered, scaled up — icon ~96pt + wordmark 32pt)
- Nav header on detail screens (left-aligned, scaled down — icon ~24pt + wordmark 14pt)
- About / settings (centered, standard scale)

The mark alone (no wordmark) is used:

- App icon
- Tab bar / nav button icons
- Loading indicators

## 5. Component recipes

How the tokens compose into the recurring UI pieces.

### Lock label (AR HUD)

```
┌─────────────────────────────┐
│ UAL248               ← font.hudCallsign, accent.cyan (or magenta if pinned)
│ United Airlines      ← font.hudData, text.primary
│ Boeing 737-800       ← font.hudData, text.primary
│ FL370 · 478kt · 12km ← font.hudData, text.secondary
└─────────────────────────────┘
```

- Background: `bg.primary` at 88% opacity, backdrop blur 4pt
- Border: 1pt solid white at 8% opacity (default) / `accent.advisory` (pinned)
- Padding: 8pt vertical × 10pt horizontal
- Corner radius: 4pt
- Positioned below the lock brackets, 8pt gap

### Hangar card row

```
┌──────────────────────────────────┐
│ ✈  UAL248                  ×3   │   ← row
│    Boeing 737-800 · 12.4km  2m   │
└──────────────────────────────────┘
```

- Row background: `bg.elevated`, corner radius 8pt
- Padding: 12pt vertical × 14pt horizontal
- Layout: airplane SF Symbol (28pt, `accent.cyan`) + body + meta
- Callsign: `font.hudCallsign` (or fallback to icao24)
- Subtitle: `font.cardSubtitle` (operator · distance)
- Count pill: SF Mono 10pt bold on `text.primary` 10% background, 2pt × 7pt padding, fully rounded
- Time: `font.caption`, `text.tertiary`
- **Rare row variant:** 3pt left border in `accent.advisory`; "RARE" pill at top of body in magenta

### Zoom pill

- `bg.primary` at 55% opacity, 4pt × 10pt padding, fully rounded
- `font.hudCallsign` (SF Mono 11pt bold), `text.primary`
- Top-center of screen, visible only when zoom > 1.0

### Caution badge

- `bg.primary` at 92% opacity, 1pt `alert.caution` border, 4pt radius
- 4pt × 10pt padding
- Warning glyph (SF Symbol `exclamationmark.triangle`) + `font.hudData` text, both in `alert.caution`
- Top-center, slides in/out

### Wordmark / nav header

- Lockup left-aligned, 16pt from leading edge
- Background: `bg.primary` at 95% opacity, 1pt `bg.elevated` bottom border
- Height: 56pt

## 6. Code architecture

Foundation, text, accent, and alert tokens live in
`ios/Tailspot/Tailspot/Brand.swift`; the rarity/type tints (§2.5) live in
`ios/Tailspot/Tailspot/GameSystem.swift`. Actual shipping `Brand.swift`:

```swift
import SwiftUI

nonisolated enum Brand {
    nonisolated enum Color {
        static let bgPrimary    = SwiftUI.Color(hex: 0x0A0E1A)
        static let bgElevated   = SwiftUI.Color(hex: 0x1A2030)
        static let bgSurface    = SwiftUI.Color(hex: 0x050810)

        static let textPrimary   = SwiftUI.Color(hex: 0xE8F4FF)
        static let textSecondary = SwiftUI.Color(hex: 0xA0B0C0)
        static let textTertiary  = SwiftUI.Color(hex: 0x7F8B98)

        static let cyan = SwiftUI.Color(hex: 0x00D4FF)

        static let alertWarning  = SwiftUI.Color(hex: 0xFF5555)
        static let alertCaution  = SwiftUI.Color(hex: 0xFFB800)
        static let alertAdvisory = SwiftUI.Color(hex: 0xFF6BE6)
        static let alertNormal   = SwiftUI.Color(hex: 0x3DD68C)
    }

    nonisolated enum Font {
        /// B612 Mono = Airbus's cockpit display font (SIL OFL 1.1, bundled
        /// via UIAppFonts). Ships Regular + Bold faces only; SwiftUI weight
        /// requests map down (regular/medium → Regular, semibold+ → Bold).
        static func mono(size: CGFloat,
                         weight: SwiftUI.Font.Weight = .regular,
                         italic: Bool = false) -> SwiftUI.Font {
            let isBold: Bool
            switch weight {
            case .ultraLight, .thin, .light, .regular, .medium: isBold = false
            default:                                            isBold = true
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

        static let cardTitle    = SwiftUI.Font.system(size: 17, weight: .semibold, design: .default)
        static let cardSubtitle = SwiftUI.Font.system(size: 13, weight: .regular,  design: .default)
        static let label        = SwiftUI.Font.system(size: 11, weight: .semibold, design: .default)
        static let body         = SwiftUI.Font.system(size: 15, weight: .regular,  design: .default)
        static let caption      = SwiftUI.Font.system(size: 12, weight: .regular,  design: .default)
    }
}

// Helper extension so `Color(hex: 0x0A0E1A)` reads cleanly above.
nonisolated extension SwiftUI.Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
```

> `nonisolated` on the enums + the `Color(hex:)` extension is required under
> Xcode 26's MainActor-default isolation — these are pure value tokens used
> from any actor. (Drift-prone: a new top-level token missing `nonisolated`
> compiles as a warning under `xcodebuild` but errors in Swift 6 language
> mode — Noah's IDE build catches it.)

### Migration plan

Every existing view that hardcodes a color or font value gets migrated to a
`Brand.Color.*` / `Brand.Font.*` reference. The migration is mechanical —
behavior identical, just routed through the token namespace.

Spot-check files that need touching for Phase A:

- `ContentView.swift` — lock overlay, hud label, zoom pill, debug overlay, hangar button badge
- `AircraftDetailView.swift` — text colors, button tint
- `HangarView.swift` — card rows, picker, section headers
- `CatchDetailView.swift` — list backgrounds, text colors
- `LockOnEngine.swift` — bracket color (cyan/magenta)
- `ReplayReportView.swift` — text colors

## 7. Phase scope

Brand identity ships in three phases. Each phase commits separately so the
risk is contained and Phase A can be field-verified before Phase B starts.

> **`[shipped]` status (2026-06-13):** all three phases landed across
> subsequent sessions (token migration, magenta-pinned state, splash screen,
> Hangar dedupe + swipe-delete + rarity, app icon, 4-step onboarding, Settings
> with full brand application). The bullets below are preserved as the
> original plan-of-record; treat them as history, not a to-do list. The live
> Hangar later moved toward native iOS `List` structure + Brand skin (zoom
> transitions, haptics) — a direction the original component spec predates.

### Phase A — Tokens + light retheme (this session, ~3–4 hrs)

**Goal:** every existing UI element pulls colors and fonts from `Brand.*`.
No new components, no behavior change.

- Create `Brand.swift` with the full token set above
- Migrate every hardcoded color and font in the 6 spot-check files to `Brand.*`
- **Adopt magenta for tap-pinned state.** Currently the pinned target reuses the default cyan brackets/label. Switch the brackets and label-border to `Brand.Color.alertAdvisory` whenever `pinnedIcao != nil`. Done in `ContentView`'s `lockOverlay` builder.
- **Align colors with FAA semantics:**
  - `formatHeading()` bad-accuracy text is currently `.red` — that's wrong per FAA (red = warning / immediate action). Bad compass is a *caution* (future action). Switch to `Brand.Color.alertCaution`.
  - The `[MOCK]` tag in `adsbStatusRow` (`.yellow`) reads as caution-toned, which is consistent — the user should know data is fake. Map to `Brand.Color.alertCaution`.
  - The hangar tray-icon count badge (currently `.green`) maps to `Brand.Color.alertNormal` — "safe / successful accumulation" is the right FAA reading.
  - The recording-row red dot is an iOS recording-indicator convention; intentional FAA-deviation. Keep red, but map to `Brand.Color.alertWarning` so it's still a brand token.
- Add the **horizontal lockup** to the `HangarView` nav header — replaces the current `navigationTitle("Hangar · \(count)")`. Count moves to a trailing toolbar pill so it stays visible.
- Tertiary text upgrade: any view using a hardcoded grey for timestamps/labels gets `Brand.Color.textTertiary`.

**Not in Phase A:** custom Hangar card layout (just retheme the existing
rows), splash screen, app icon assets, onboarding.

### Phase B — Component rebuild (~1–2 days, separate session)

**Goal:** the Hangar feels like a collector and the AR HUD feels like a pilot
HUD — not just recolored versions of today's components.

- Redesign HUD lock label with proper hierarchy (callsign accented, operator second, type third, data row tertiary) per the §5 recipe
- Hangar v1 polish:
  - Dedupe catches by icao24 within each section (one row per plane, count pill = ×N)
  - Swipe-to-delete with a confirm alert
  - Rarity logic (decide what counts as rare — e.g., aircraft type seen < 3 times globally, or a curated list)
  - "RARE" pill + magenta border on rare rows
- Brand splash screen on launch (wordmark lockup, ~600ms hold, crossfade to AR view)
- Caution badge component (replaces the current red-text heading-accuracy treatment)

### Phase C — Full identity (later)

- App icon SVG → PNG export pipeline (every iOS size variant)
- First-launch onboarding (permissions explainer + compass-calibration teach)
- Settings / About screen with full brand application

## 8. Open items deferred to implementation `[resolved]`

- ~~Lockup: SF Symbol vs custom SVG~~ → **SF Symbol held.** The mark uses
  `Image(systemName: "airplane")`; no custom plane asset ships.
- ~~Splash animation timing~~ → shipped (~600 ms hold, crossfade to AR view).
- ~~Hangar rarity scoring algorithm~~ → shipped as the **activity-rarity
  model** (see `2026-06-08-activity-rarity-design.md`); rarity is typecode-
  first and consistency-tested against `AircraftTypes.json`.

**New open item (post-spec, 2026-06-13):** the **card hero treatment** is
unsettled. v1 ships real per-tail photos (Planespotters). A 3D-model card
direction was prototyped and approved in feel but parked for visual
consistency; flat traced silhouettes also exist as a fallback. No settled
"card front" recipe yet — the most likely subject of the next design pass.

## 9. Out of scope

- Sound design / audio cues
- Haptic vocabulary beyond what already ships (catch-confirmation haptic)
- Internationalization / localization of text
- Dark / light mode variants — Tailspot is dark-mode-only by design (real sky behind it)
- Custom illustration style for aircraft (deferred to PLAN §9 Planespotters integration)
