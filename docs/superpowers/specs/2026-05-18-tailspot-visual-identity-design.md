# Tailspot — Visual Identity Spec

**Status:** approved 2026-05-18 (Noah)
**Implementation phases:** A (this session) → B (next session) → C (later)

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

## 3. Typography tokens

`Brand.Font` namespace. SF Mono = the "HUD voice" (instrument-readout feel).
SF Pro = the "collector voice" (human-readable cards, sheets, body).

| Token | Spec | Use |
|---|---|---|
| `font.wordmark` | SF Mono, 24pt bold, +4 letter-spacing, uppercase | The `TAILSPOT` wordmark in headers/splash |
| `font.hudCallsign` | SF Mono, 13pt bold, +1 letter-spacing | Locked-plane callsign |
| `font.hudData` | SF Mono, 10pt regular | Data rows under the callsign (altitude, speed, distance) |
| `font.cardTitle` | SF Pro, 17pt semibold | Aircraft type on a Hangar card |
| `font.cardSubtitle` | SF Pro, 13pt regular | Operator + timestamp on a Hangar card |
| `font.label` | SF Pro, 11pt semibold, +1 tracking, uppercase | Section headers, tags |
| `font.body` | SF Pro, 15pt regular | Default body text in sheets, detail views |
| `font.caption` | SF Pro, 12pt regular | Subdued auxiliary text |

## 4. Brand mark and lockup

### Mark

Corner-bracket reticle framing a plane silhouette.

- **Brackets:** 4 L-shaped corner strokes, arm length ≈ 22% of the icon's bounding square. Stroke 2.5pt at icon size 64, scales proportionally.
- **Plane glyph:** `Image(systemName: "airplane")` (Apple's canonical SF Symbol), centered, tinted `accent.cyan`. Renders pixel-perfect at every size — we never ship a custom-drawn plane.
- **Brackets are `accent.cyan` by default.** Magenta variant for tap-pinned visuals; green variant for catch-confirmed flash.

### Wordmark

`TAILSPOT` in SF Mono, 24pt bold, +4 letter-spacing, color = `text.primary`.
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

All tokens in `ios/Tailspot/Tailspot/Brand.swift`:

```swift
import SwiftUI

enum Brand {
    enum Color {
        // foundations
        static let bgPrimary    = SwiftUI.Color(hex: 0x0A0E1A)
        static let bgElevated   = SwiftUI.Color(hex: 0x1A2030)
        static let bgSurface    = SwiftUI.Color(hex: 0x050810)
        // text
        static let textPrimary   = SwiftUI.Color(hex: 0xE8F4FF)
        static let textSecondary = SwiftUI.Color(hex: 0xA0B0C0)
        static let textTertiary  = SwiftUI.Color(hex: 0x7F8B98)
        // brand accent
        static let cyan          = SwiftUI.Color(hex: 0x00D4FF)
        // alert tiers
        static let alertWarning  = SwiftUI.Color(hex: 0xFF5555)
        static let alertCaution  = SwiftUI.Color(hex: 0xFFB800)
        static let alertAdvisory = SwiftUI.Color(hex: 0xFF6BE6)
        static let alertNormal   = SwiftUI.Color(hex: 0x3DD68C)
    }

    enum Font {
        static let wordmark     = SwiftUI.Font.system(size: 24, weight: .bold, design: .monospaced)
        static let hudCallsign  = SwiftUI.Font.system(size: 13, weight: .bold, design: .monospaced)
        static let hudData      = SwiftUI.Font.system(size: 10, weight: .regular, design: .monospaced)
        static let cardTitle    = SwiftUI.Font.system(size: 17, weight: .semibold, design: .default)
        static let cardSubtitle = SwiftUI.Font.system(size: 13, weight: .regular, design: .default)
        static let label        = SwiftUI.Font.system(size: 11, weight: .semibold, design: .default)
        static let body         = SwiftUI.Font.system(size: 15, weight: .regular, design: .default)
        static let caption      = SwiftUI.Font.system(size: 12, weight: .regular, design: .default)
    }
}

// Helper extension so `Color(hex: 0x0A0E1A)` reads cleanly above.
extension SwiftUI.Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
```

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

## 8. Open items deferred to implementation

- Whether the lockup uses `Image(systemName: "airplane")` literally or a custom SVG export — current decision: SF Symbol, but we'll revisit during Phase B if the brackets-around-symbol composition needs a custom asset.
- Exact splash animation timing — Phase B.
- Hangar rarity scoring algorithm — Phase B.

## 9. Out of scope

- Sound design / audio cues
- Haptic vocabulary beyond what already ships (catch-confirmation haptic)
- Internationalization / localization of text
- Dark / light mode variants — Tailspot is dark-mode-only by design (real sky behind it)
- Custom illustration style for aircraft (deferred to PLAN §9 Planespotters integration)
