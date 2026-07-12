# Visual Identity — Phase A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the design-token foundation for Tailspot's visual identity. Create `Brand.swift` with the full color + font token set, migrate the five existing SwiftUI view files to consume them, apply the FAA-aligned color semantics (red→amber for compass caution; magenta for tap-pinned), and add the horizontal brand lockup to the Hangar nav header.

**Architecture:** All tokens live in one file (`ios/Tailspot/Tailspot/Brand.swift`) under a `Brand` namespace with nested `Color` and `Font` enums. Existing views are migrated mechanically — every hardcoded `.white`, `.black`, `.green`, etc. and every inline `.font(.system(...))` call gets replaced with the matching `Brand.*` reference. The 74-test suite remains the safety net: zero behavior change is required and verified by `xcodebuild test`.

**Tech Stack:** Swift 6 / SwiftUI on iOS 26.3. Tests via Swift Testing (`@Test`, `#expect`). Build via `xcodebuild test -only-testing:TailspotTests`. Deploy via `bin/deploy` (manual, after the plan is complete).

**Reference:** Design spec at `docs/superpowers/specs/2026-05-18-tailspot-visual-identity-design.md`.

**Commit-message convention:** Every commit in this repo ends with a `Co-Authored-By` trailer. Add this to every commit body produced by this plan:

```
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

The commit-message blocks below show the subject + body; append the trailer when committing.

**Worktree:** Optional but recommended. If you want to isolate Phase A from other work, create a worktree first via the `superpowers:using-git-worktrees` skill. Otherwise this plan operates on `main` (working tree is clean as of plan-write time).

---

## File Structure

**Create:**
- `ios/Tailspot/Tailspot/Brand.swift` — single source of truth for all color and font tokens, plus a `Color(hex:)` helper.
- `ios/Tailspot/TailspotTests/BrandTests.swift` — round-trip tests for the hex helper so the token values can't silently drift.

**Modify (in order of size):**
- `ios/Tailspot/Tailspot/ContentView.swift` — largest migration (~45 hardcoded color/font sites), plus the semantic fixes (red→amber, magenta for tap-pin, count badge → `alertNormal`).
- `ios/Tailspot/Tailspot/HangarView.swift` — token migration (~7 sites), plus replace `navigationTitle("Hangar · \(count)")` with a horizontal lockup as the nav-bar `principal` toolbar item, count moves to a trailing toolbar pill.
- `ios/Tailspot/Tailspot/AircraftDetailView.swift` — token migration (~5 sites).
- `ios/Tailspot/Tailspot/CatchDetailView.swift` — token migration (~3 sites).
- `ios/Tailspot/Tailspot/ReplayReportView.swift` — token migration (~1 site).
- `CLAUDE.md` and `PLAN.md` — note that Phase A shipped, bump test count.

**Not touched:**
- `Aircraft.swift`, `ADSBManager.swift`, `LocationManager.swift`, `MotionManager.swift`, `OpenSkyClient.swift`, `MockADSBSource.swift`, `MetadataCache.swift`, `Catch.swift`, `Geo.swift`, `LockOnEngine.swift`, `Log.swift`, `TailspotApp.swift`, `HangarGrouping.swift`, `ReplayRecorder.swift`, `ReplayAnalyzer.swift` — these are pure logic / data / model files with no UI surface, so they have no colors or fonts to migrate.
- `CameraPreview.swift` — UIKit bridge, no SwiftUI colors.

---

## Task 1: Create `Brand.swift` + the hex Color helper (TDD on the helper)

The hex helper is the only piece with logic worth testing. The token values themselves are constants — wrong-token bugs are caught by visual inspection on device, not unit tests.

**Files:**
- Create: `ios/Tailspot/Tailspot/Brand.swift`
- Create: `ios/Tailspot/TailspotTests/BrandTests.swift`

- [ ] **Step 1: Write the failing test for `Color(hex:)`**

Create `ios/Tailspot/TailspotTests/BrandTests.swift`:

```swift
//
//  BrandTests.swift
//  TailspotTests
//
//  Round-trip tests for the Color(hex:) helper used throughout
//  Brand.swift to define color tokens. The hex literal is the
//  source of truth — these tests pin the channel-extraction so a
//  future Swift bump can't silently change the math.
//

import Testing
import SwiftUI
@testable import Tailspot

@Suite("Brand color hex helper")
struct BrandColorHexTests {

    @Test func extractsRedGreenBlueChannels() {
        // 0x336699 — red 51, green 102, blue 153 (all distinct).
        let c = Color(hex: 0x336699)
        // Pull the underlying components via resolve(in:); SwiftUI
        // doesn't expose a stored-channel API, so go via the
        // resolved/CGColor route.
        let resolved = c.resolve(in: EnvironmentValues())
        #expect(abs(Double(resolved.red)   - 51.0/255) < 0.001)
        #expect(abs(Double(resolved.green) - 102.0/255) < 0.001)
        #expect(abs(Double(resolved.blue)  - 153.0/255) < 0.001)
        #expect(abs(Double(resolved.opacity) - 1.0) < 0.001)
    }

    @Test func extractsZeroAndFull() {
        let black = Color(hex: 0x000000).resolve(in: EnvironmentValues())
        #expect(black.red == 0 && black.green == 0 && black.blue == 0)

        let white = Color(hex: 0xFFFFFF).resolve(in: EnvironmentValues())
        #expect(abs(Double(white.red)   - 1.0) < 0.001)
        #expect(abs(Double(white.green) - 1.0) < 0.001)
        #expect(abs(Double(white.blue)  - 1.0) < 0.001)
    }

    @Test func acceptsAlphaOverride() {
        let half = Color(hex: 0x808080, alpha: 0.5).resolve(in: EnvironmentValues())
        #expect(abs(Double(half.opacity) - 0.5) < 0.001)
    }
}
```

- [ ] **Step 2: Run the test, verify FAIL (Brand symbol does not exist)**

Run:
```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests/BrandColorHexTests 2>&1 | tail -10
```

Expected: `** TEST FAILED **` with a compile error like `error: cannot find 'Color(hex:)' initializer` or `error: cannot find type 'Brand'`.

- [ ] **Step 3: Create `Brand.swift` with the full token set + Color hex helper**

Create `ios/Tailspot/Tailspot/Brand.swift`:

```swift
//
//  Brand.swift
//  Tailspot
//
//  Single source of truth for the Tailspot visual identity.
//  Every color or font value used across the app routes through
//  here so a one-file edit re-themes the whole app.
//
//  Design spec: docs/superpowers/specs/2026-05-18-tailspot-visual-identity-design.md
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

import SwiftUI

enum Brand {

    // MARK: - Color

    enum Color {
        // Foundations — desaturated dark base; never used for active UI elements.
        static let bgPrimary    = SwiftUI.Color(hex: 0x0A0E1A)
        static let bgElevated   = SwiftUI.Color(hex: 0x1A2030)
        static let bgSurface    = SwiftUI.Color(hex: 0x050810)

        // Text — primary/secondary/tertiary in decreasing emphasis.
        // tertiary lightened from #5A6A7A to clear WCAG AA normal-text contrast.
        static let textPrimary   = SwiftUI.Color(hex: 0xE8F4FF)
        static let textSecondary = SwiftUI.Color(hex: 0xA0B0C0)
        static let textTertiary  = SwiftUI.Color(hex: 0x7F8B98)

        // Brand accent. Never use for sub-13pt text (FAA: pure cyan is
        // hard to focus at small sizes). Use for brackets, wordmark,
        // locked-state callsign (≥13pt bold), and interactive controls.
        static let cyan = SwiftUI.Color(hex: 0x00D4FF)

        // Alert tiers — strict FAA semantics. Each color = one meaning.
        static let alertWarning  = SwiftUI.Color(hex: 0xFF5555)  // red, immediate action
        static let alertCaution  = SwiftUI.Color(hex: 0xFFB800)  // amber, future action
        static let alertAdvisory = SwiftUI.Color(hex: 0xFF6BE6)  // magenta, selected / pinned
        static let alertNormal   = SwiftUI.Color(hex: 0x3DD68C)  // green, safe / acquired
    }

    // MARK: - Font

    enum Font {
        // SF Mono = "HUD voice" (instrument readout feel)
        static let wordmark    = SwiftUI.Font.system(size: 24, weight: .bold,    design: .monospaced)
        static let hudCallsign = SwiftUI.Font.system(size: 13, weight: .bold,    design: .monospaced)
        static let hudData     = SwiftUI.Font.system(size: 10, weight: .regular, design: .monospaced)

        // SF Pro = "collector voice" (human-readable cards / sheets)
        static let cardTitle    = SwiftUI.Font.system(size: 17, weight: .semibold, design: .default)
        static let cardSubtitle = SwiftUI.Font.system(size: 13, weight: .regular,  design: .default)
        static let label        = SwiftUI.Font.system(size: 11, weight: .semibold, design: .default)
        static let body         = SwiftUI.Font.system(size: 15, weight: .regular,  design: .default)
        static let caption      = SwiftUI.Font.system(size: 12, weight: .regular,  design: .default)
    }
}

// MARK: - Color hex helper

/// Constructs a SwiftUI Color from a 24-bit RGB hex literal.
/// Used by Brand.Color above so the token values read as their
/// design-spec hex codes rather than as four Double literals each.
extension SwiftUI.Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
```

- [ ] **Step 4: Run tests, verify PASS**

Run:
```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests/BrandColorHexTests 2>&1 | grep -E '\*\* TEST|passed|failed' | tail -5
```

Expected: `** TEST SUCCEEDED **` and 3 passed cases (`extractsRedGreenBlueChannels`, `extractsZeroAndFull`, `acceptsAlphaOverride`).

- [ ] **Step 5: Run the full test suite to confirm nothing else broke**

Run:
```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests 2>&1 | grep -E '\*\* TEST'
```

Expected: `** TEST SUCCEEDED **`. Test count should be 124 (was 121, +3 BrandColorHexTests).

- [ ] **Step 6: Commit**

```bash
git add ios/Tailspot/Tailspot/Brand.swift ios/Tailspot/TailspotTests/BrandTests.swift
git commit -m "$(cat <<'EOF'
Brand: design-token foundation (Phase A scaffolding)

New Brand.swift namespace + a Color(hex:) helper. Every visual
token from the design spec (palette, type) lives here so the rest
of the app can be migrated mechanically and a future retheme is a
single-file edit.

Tests: 121 → 124. Three BrandColorHexTests pin the hex helper's
channel extraction so a Swift version bump can't silently change
the math under the tokens.

No view files migrated yet — that's task 2 onward.

Spec: docs/superpowers/specs/2026-05-18-tailspot-visual-identity-design.md
EOF
)"
```

---

## Task 2: Migrate `ContentView.swift` — token sweep (no behavior change)

Replace every hardcoded color and font in `ContentView.swift` with the matching `Brand.*` token. This is a mechanical refactor — behavior is unchanged, the existing test suite (`ADSBManagerTests`, `LockOnEngineTests`, etc.) remains the safety net.

This task ONLY migrates tokens. The FAA semantic fixes (red→amber, magenta for pin) are Task 3 to keep the diff reviewable.

**Files:**
- Modify: `ios/Tailspot/Tailspot/ContentView.swift` — every line that has `.white`, `.black`, `.green`, `.yellow`, `.red`, `.gray`, or an inline `.font(.system(...))`.

- [ ] **Step 1: Baseline — confirm tests are green before touching code**

Run:
```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests 2>&1 | grep -E '\*\* TEST'
```

Expected: `** TEST SUCCEEDED **`. If not, stop and fix before continuing.

- [ ] **Step 2: Migrate color references — backgrounds and text**

In `ContentView.swift`, apply these replacements. Show only the lines that change.

**`.black` backgrounds → `Brand.Color.bgPrimary`:**

Find every `Color.black.ignoresSafeArea()` and every `.background(.black.opacity(N), ...)`. Replace `.black` with `Brand.Color.bgPrimary`. Examples:

```swift
// before
Color.black.ignoresSafeArea()
// after
Brand.Color.bgPrimary.ignoresSafeArea()
```

```swift
// before
.background(.black.opacity(0.55), in: .capsule)
// after
.background(Brand.Color.bgPrimary.opacity(0.55), in: .capsule)
```

(Apply the same pattern to every `.black.opacity(...)` call.)

**`.white` text → `Brand.Color.textPrimary`:**

```swift
// before
.foregroundStyle(.white)
// after
.foregroundStyle(Brand.Color.textPrimary)
```

```swift
// before
.foregroundStyle(.white.opacity(0.85))
// after
.foregroundStyle(Brand.Color.textPrimary.opacity(0.85))
```

(Apply the same pattern to every `.white` and `.white.opacity(...)`.)

**`.green` count badge → `Brand.Color.alertNormal`:**

```swift
// before (~line 311)
.background(.green, in: .capsule)
// after
.background(Brand.Color.alertNormal, in: .capsule)
```

**Lock-overlay state colors:**

```swift
// before (~lines 384, 386, 392)
return .init(boxSize: size, color: .yellow, opacity: opacity, showLabel: false)
return .init(boxSize: lockedSize, color: .green, opacity: 1.0, showLabel: true)
return .init(boxSize: lockedSize, color: .green, opacity: fade, showLabel: true)
// after
return .init(boxSize: size, color: Brand.Color.alertCaution, opacity: opacity, showLabel: false)
return .init(boxSize: lockedSize, color: Brand.Color.alertNormal, opacity: 1.0, showLabel: true)
return .init(boxSize: lockedSize, color: Brand.Color.alertNormal, opacity: fade, showLabel: true)
```

(Acquisition = caution; locked + sticky = normal. Matches FAA semantics — acquiring is "future action might be needed" and locked is "safe / acquired.")

**MOCK indicator yellow → `alertCaution`:**

```swift
// before (~line 608)
.foregroundStyle(adsb.useMock ? .yellow : .green)
// after
.foregroundStyle(adsb.useMock ? Brand.Color.alertCaution : Brand.Color.alertNormal)
```

**Recording dot:**

```swift
// before (~line 628)
.foregroundStyle(recorder.isRecording ? .red : .white.opacity(0.85))
// after
.foregroundStyle(recorder.isRecording ? Brand.Color.alertWarning : Brand.Color.textPrimary.opacity(0.85))
```

**Disabled-state grey:**

```swift
// before (~line 664)
.foregroundStyle(latest == nil ? .gray : .white.opacity(0.85))
// after
.foregroundStyle(latest == nil ? Brand.Color.textTertiary : Brand.Color.textPrimary.opacity(0.85))
```

**Shadows (keep black at full opacity — shadows are intentionally dark):**

```swift
// before
.shadow(color: .black.opacity(0.5), radius: 2)
// after — leave unchanged. Shadow black is system-correct.
```

(Do NOT migrate shadow colors. Shadows are not a brand token.)

- [ ] **Step 3: Migrate font references**

Most fonts in ContentView are already correctly using `.system(.caption, design: .monospaced)` style — they're appropriate for the HUD voice. Migrate to named tokens where the size matches a Brand.Font:

```swift
// before (~lines 421, 426, 431, 436)
.font(.caption.monospaced().bold())          // callsign in lock label
.font(.system(size: 11))                      // airline name
.font(.system(size: 11))                      // make/model
.font(.system(size: 10, design: .monospaced)) // alt/speed data
// after
.font(Brand.Font.hudCallsign)
.font(Brand.Font.hudData)
.font(Brand.Font.hudData)
.font(Brand.Font.hudData)
```

For the sensor-readout block (`.font(.system(.caption, design: .monospaced))` at ~line 464), keep as-is — that's the existing debug-overlay style which is OK to leave as a one-off (it's debug UI, not user-facing).

For the wrench/tray buttons (`.font(.system(size: 16, weight: .medium))`), leave as-is — those are icon sizes, not brand-voice text.

- [ ] **Step 4: Run the full test suite, verify still PASS**

Run:
```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests 2>&1 | grep -E '\*\* TEST'
```

Expected: `** TEST SUCCEEDED **`. Test count: 124 (unchanged — this task added no tests).

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/ContentView.swift
git commit -m "$(cat <<'EOF'
ContentView: migrate to Brand tokens (no behavior change)

Mechanical sweep of every hardcoded color and font in ContentView:

- .black backgrounds      → Brand.Color.bgPrimary
- .white text             → Brand.Color.textPrimary
- .green count badge      → Brand.Color.alertNormal
- .yellow lock-acquiring  → Brand.Color.alertCaution
- .green lock-locked      → Brand.Color.alertNormal
- .yellow MOCK indicator  → Brand.Color.alertCaution
- .green LIVE indicator   → Brand.Color.alertNormal
- .red recording dot      → Brand.Color.alertWarning
- .gray disabled-row      → Brand.Color.textTertiary
- HUD label fonts (callsign + data rows) → Brand.Font.hudCallsign / .hudData

Shadow black + icon-size system fonts left as-is — not brand tokens.

FAA semantic adjustments (red→amber for compass-bad, magenta for
tap-pinned) ship in task 3 to keep this diff reviewable.

Tests still green at 124.
EOF
)"
```

---

## Task 3: ContentView — FAA semantic fixes (red→amber compass; magenta tap-pin)

Two real semantic changes (not just token renames):

1. The compass-accuracy-bad warning is currently `.red`. Per FAA, bad compass is a *caution* (future action — recalibrate), not a *warning* (immediate-action red). Switch to `Brand.Color.alertCaution`.
2. Tap-pinned state currently reuses the default cyan brackets and label. Switch to `Brand.Color.alertAdvisory` (magenta) — pilot-display convention for selected/advisory items.

**Files:**
- Modify: `ios/Tailspot/Tailspot/ContentView.swift` — `isHeadingAccuracyBad` color use + `lockOverlay` builder + `lockLabel` callsign color.

- [ ] **Step 1: Migrate compass-accuracy warning from red to amber**

Find this line (`~455`):

```swift
.foregroundStyle(isHeadingAccuracyBad ? .red : .white)
```

After Task 2's sweep it should already be:

```swift
.foregroundStyle(isHeadingAccuracyBad ? Brand.Color.alertWarning : Brand.Color.textPrimary)
```

Change to:

```swift
.foregroundStyle(isHeadingAccuracyBad ? Brand.Color.alertCaution : Brand.Color.textPrimary)
```

(Was `alertWarning` after Task 2's mechanical migration of `.red`. Now switched to `alertCaution` per FAA — bad compass is "future action," not "immediate action.")

- [ ] **Step 2: Make the lock-overlay style honor `pinnedIcao`**

The current `lockOverlayStyle(for:now:)` switch returns cyan/green based on engine state. For `pinnedIcao != nil`, the entire overlay should render magenta.

Find the function:

```swift
private func lockOverlayStyle(for state: LockOnEngine.State, now: Date) -> LockOverlayStyle {
    let lockedSize: CGFloat = 64
    let acquiringSizeMax: CGFloat = 150
    switch state {
    case .idle:
        return .init(boxSize: 0, color: .clear, opacity: 0, showLabel: false)
    case .acquiring:
        let p = lockOn.acquisitionProgress(now: now)
        let size = acquiringSizeMax - (acquiringSizeMax - lockedSize) * CGFloat(p)
        let opacity = 0.35 + 0.55 * p
        return .init(boxSize: size, color: Brand.Color.alertCaution, opacity: opacity, showLabel: false)
    case .locked:
        return .init(boxSize: lockedSize, color: Brand.Color.alertNormal, opacity: 1.0, showLabel: true)
    case .sticky(_, let lostAt):
        let elapsed = now.timeIntervalSince(lostAt)
        let fade = max(0, 1 - elapsed / lockOn.stickyHoldDuration)
        return .init(boxSize: lockedSize, color: Brand.Color.alertNormal, opacity: fade, showLabel: true)
    }
}
```

Change the function to take `pinnedIcao` into account. When the engine's target matches the pinned icao, the color becomes `alertAdvisory`:

```swift
private func lockOverlayStyle(for state: LockOnEngine.State, now: Date) -> LockOverlayStyle {
    let lockedSize: CGFloat = 64
    let acquiringSizeMax: CGFloat = 150
    // When the engine's current target is the tap-pinned plane,
    // render the overlay in magenta (the FAA advisory color) so
    // it reads as "explicitly selected" vs the cyan/green default.
    let isPinTracking = (pinnedIcao != nil && state.targetIcao24 == pinnedIcao)
    switch state {
    case .idle:
        return .init(boxSize: 0, color: .clear, opacity: 0, showLabel: false)
    case .acquiring:
        let p = lockOn.acquisitionProgress(now: now)
        let size = acquiringSizeMax - (acquiringSizeMax - lockedSize) * CGFloat(p)
        let opacity = 0.35 + 0.55 * p
        let color = isPinTracking ? Brand.Color.alertAdvisory : Brand.Color.alertCaution
        return .init(boxSize: size, color: color, opacity: opacity, showLabel: false)
    case .locked:
        let color = isPinTracking ? Brand.Color.alertAdvisory : Brand.Color.alertNormal
        return .init(boxSize: lockedSize, color: color, opacity: 1.0, showLabel: true)
    case .sticky(_, let lostAt):
        let elapsed = now.timeIntervalSince(lostAt)
        let fade = max(0, 1 - elapsed / lockOn.stickyHoldDuration)
        let color = isPinTracking ? Brand.Color.alertAdvisory : Brand.Color.alertNormal
        return .init(boxSize: lockedSize, color: color, opacity: fade, showLabel: true)
    }
}
```

- [ ] **Step 3: Make the callsign in the lock label honor the pinned state**

In `lockLabel(_:metadata:)`, the callsign is currently always `Brand.Color.textPrimary` (post-Task 2). It should switch to `Brand.Color.cyan` for default-locked and `Brand.Color.alertAdvisory` for pinned. Update the `Text(cs)` line:

```swift
// before (after Task 2)
Text(cs)
    .font(Brand.Font.hudCallsign)
    .foregroundStyle(Brand.Color.textPrimary)
// after
Text(cs)
    .font(Brand.Font.hudCallsign)
    .foregroundStyle(pinnedIcao == obs.aircraft.icao24 ? Brand.Color.alertAdvisory : Brand.Color.cyan)
```

(The callsign was previously plain white — this gives it the cyan accent the spec calls for, switched to magenta when pinned.)

- [ ] **Step 4: Run the full test suite, verify still PASS**

Run:
```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests 2>&1 | grep -E '\*\* TEST'
```

Expected: `** TEST SUCCEEDED **`. Test count: 124.

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/ContentView.swift
git commit -m "$(cat <<'EOF'
ContentView: FAA semantic color fixes (compass + tap-pin)

Two real semantic adjustments, not just token renames:

1. Compass-accuracy bad warning: red → Brand.Color.alertCaution
   (amber). Per FAA 14 CFR 25.1322(e), bad compass is a *caution*
   (future action — recalibrate the figure-8), not a *warning*
   (immediate action). Red was overstating the urgency.

2. Tap-pinned overlay: switches the bracket color AND the callsign
   accent from cyan/green to Brand.Color.alertAdvisory (magenta).
   Magenta is the pilot-display convention for advisory / selected
   items. Distinct from cyan (auto-lock) and amber (caution).

Callsign also picks up its proper cyan accent (was textPrimary).

No engine-state or behavior change — just colors. Tests still
green at 124.
EOF
)"
```

---

## Task 4: Migrate `HangarView.swift` — tokens + horizontal lockup in nav

Smaller token migration (~7 sites), plus the real UI change: replace the `navigationTitle("Hangar · \(count)")` with the brand lockup as the toolbar's `principal` item and move the count to a trailing pill so it stays visible.

**Files:**
- Modify: `ios/Tailspot/Tailspot/HangarView.swift` — token sweep + nav-header lockup.

- [ ] **Step 1: Token sweep**

Find every `.foregroundStyle(...)` and `.background(...)` in `HangarView.swift`. Replace `.white`, `.secondary`, `.tint`, etc. with the matching Brand token.

Examples to find and replace (verify exact lines in the current file before editing):

```swift
// row title — currently uses .body.monospaced()
Text(title)
    .font(.body.monospaced())
// after
Text(title)
    .font(Brand.Font.hudCallsign)
```

```swift
// row subtitle — currently uses .caption + .secondary
Text(subtitle)
    .font(.caption)
    .foregroundStyle(.secondary)
// after
Text(subtitle)
    .font(Brand.Font.caption)
    .foregroundStyle(Brand.Color.textSecondary)
```

```swift
// row trailing time — currently uses .caption2 + .secondary
Text(c.caughtAt, format: .relative(...))
    .font(.caption2)
    .foregroundStyle(.secondary)
// after
Text(c.caughtAt, format: .relative(...))
    .font(Brand.Font.caption)
    .foregroundStyle(Brand.Color.textTertiary)
```

```swift
// section header — currently uses .secondary
.foregroundStyle(.secondary)
// after
.foregroundStyle(Brand.Color.textSecondary)
```

```swift
// row leading airplane icon — currently uses .tint (system tint = blue-ish)
Image(systemName: "airplane")
    .foregroundStyle(.tint)
// after
Image(systemName: "airplane")
    .foregroundStyle(Brand.Color.cyan)
```

- [ ] **Step 2: Replace `navigationTitle` with lockup + trailing count pill**

Find the nav-bar setup in `HangarView.body`. Currently:

```swift
.navigationTitle(titleText)
.navigationBarTitleDisplayMode(.inline)
.toolbar {
    ToolbarItem(placement: .topBarLeading) {
        Button("Done") { dismiss() }
    }
}
```

Change to:

```swift
.navigationBarTitleDisplayMode(.inline)
.toolbar {
    ToolbarItem(placement: .topBarLeading) {
        Button("Done") { dismiss() }
    }
    ToolbarItem(placement: .principal) {
        // Brand lockup: tray glyph + TAILSPOT wordmark, horizontal.
        // The trailing count pill keeps the catch count visible
        // without the wordmark sharing its space.
        HStack(spacing: 8) {
            Image(systemName: "airplane")
                .foregroundStyle(Brand.Color.cyan)
            Text("TAILSPOT")
                .font(Brand.Font.wordmark)
                .foregroundStyle(Brand.Color.textPrimary)
                .tracking(4)
        }
    }
    if !catches.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
            Text("\(catches.count)")
                .font(Brand.Font.hudCallsign)
                .foregroundStyle(Brand.Color.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Brand.Color.bgElevated, in: .capsule)
        }
    }
}
```

Then delete the now-unused `titleText` computed property:

```swift
// delete this whole computed property
private var titleText: String {
    catches.isEmpty ? "Hangar" : "Hangar  ·  \(catches.count)"
}
```

(Note: the wordmark in a nav-bar `principal` slot may visually be a bit large. If field-testing on device shows the wordmark is taller than the nav bar comfortably allows, scale down by overriding the font size to ~14pt with the same letter-spacing — but ship the standard `Brand.Font.wordmark` size first per the spec, and adjust during Phase B if needed.)

- [ ] **Step 3: Run the full test suite, verify still PASS**

Run:
```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests 2>&1 | grep -E '\*\* TEST'
```

Expected: `** TEST SUCCEEDED **`. Test count: 124.

- [ ] **Step 4: Commit**

```bash
git add ios/Tailspot/Tailspot/HangarView.swift
git commit -m "$(cat <<'EOF'
HangarView: migrate to Brand tokens + add nav lockup

Token sweep:
- Row title font  → Brand.Font.hudCallsign (was .body.monospaced)
- Row subtitle    → Brand.Font.caption + Brand.Color.textSecondary
- Trailing time   → Brand.Color.textTertiary (was .secondary)
- Section header  → Brand.Color.textSecondary
- Row plane icon  → Brand.Color.cyan (was system .tint)

Nav-header change:
- Replace navigationTitle("Hangar · N") with the horizontal brand
  lockup (airplane glyph + TAILSPOT wordmark in SF Mono) as the
  toolbar's principal item.
- Move the catch count to a trailing toolbar pill so it stays
  visible alongside the brand.

Tests still green at 124.
EOF
)"
```

---

## Task 5: Migrate `AircraftDetailView.swift`

Smallest meaningful migration. Mostly text colors via the `row(_:_:)` helper + the catch button tint.

**Files:**
- Modify: `ios/Tailspot/Tailspot/AircraftDetailView.swift`

- [ ] **Step 1: Token sweep**

Apply these specific replacements (verify with the current file):

```swift
// row helper — currently uses .secondary
private func row(_ label: String, _ value: String) -> some View {
    HStack {
        Text(label)
        Spacer()
        Text(value).foregroundStyle(.secondary)
    }
}
// after
private func row(_ label: String, _ value: String) -> some View {
    HStack {
        Text(label)
        Spacer()
        Text(value).foregroundStyle(Brand.Color.textSecondary)
    }
}
```

```swift
// catch button — currently uses .green tint
.buttonStyle(.borderedProminent)
.tint(.green)
// after
.buttonStyle(.borderedProminent)
.tint(Brand.Color.alertNormal)
```

```swift
// footer text — currently uses .secondary
Text(footerText)
    .font(.footnote)
    .foregroundStyle(.secondary)
// after
Text(footerText)
    .font(Brand.Font.caption)
    .foregroundStyle(Brand.Color.textSecondary)
```

- [ ] **Step 2: Run tests, verify PASS**

Run:
```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests 2>&1 | grep -E '\*\* TEST'
```

Expected: `** TEST SUCCEEDED **`. Test count: 124.

- [ ] **Step 3: Commit**

```bash
git add ios/Tailspot/Tailspot/AircraftDetailView.swift
git commit -m "AircraftDetailView: migrate to Brand tokens"
```

---

## Task 6: Migrate `CatchDetailView.swift`

Three text sites + section backgrounds.

**Files:**
- Modify: `ios/Tailspot/Tailspot/CatchDetailView.swift`

- [ ] **Step 1: Token sweep**

```swift
// row helper — currently uses .secondary
Text(value).foregroundStyle(.secondary)
// after
Text(value).foregroundStyle(Brand.Color.textSecondary)
```

(Apply the same `Brand.Color.textSecondary` to every `.foregroundStyle(.secondary)` in the file.)

- [ ] **Step 2: Run tests, verify PASS**

Run:
```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests 2>&1 | grep -E '\*\* TEST'
```

Expected: `** TEST SUCCEEDED **`. Test count: 124.

- [ ] **Step 3: Commit**

```bash
git add ios/Tailspot/Tailspot/CatchDetailView.swift
git commit -m "CatchDetailView: migrate to Brand tokens"
```

---

## Task 7: Migrate `ReplayReportView.swift`

One color site — the monospaced report text.

**Files:**
- Modify: `ios/Tailspot/Tailspot/ReplayReportView.swift`

- [ ] **Step 1: Token sweep**

```swift
// before
Text(summary)
    .font(.system(.caption2, design: .monospaced))
    .textSelection(.enabled)
// after
Text(summary)
    .font(Brand.Font.hudData)
    .foregroundStyle(Brand.Color.textPrimary)
    .textSelection(.enabled)
```

- [ ] **Step 2: Run tests, verify PASS**

Run:
```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests 2>&1 | grep -E '\*\* TEST'
```

Expected: `** TEST SUCCEEDED **`. Test count: 124.

- [ ] **Step 3: Commit**

```bash
git add ios/Tailspot/Tailspot/ReplayReportView.swift
git commit -m "ReplayReportView: migrate to Brand tokens"
```

---

## Task 8: Update docs + final test pass

**Files:**
- Modify: `CLAUDE.md` — add Phase A to shipped list, bump test count to 124, note brand tokens live in `Brand.swift`.
- Modify: `PLAN.md` §9 — add Phase A to the shipped list at the bottom; leave Phase B + C as pending.

- [ ] **Step 1: Update CLAUDE.md "Current state" section**

In CLAUDE.md, find the bulleted "Beyond the POC, currently shipping:" list and add an entry near the top:

```markdown
- **Brand tokens (Phase A).** Every color and font in the SwiftUI views routes through `Brand.swift` — a single-file edit re-themes the whole app. FAA-aligned semantics: cyan brand accent (brackets, callsigns, wordmark), amber strictly for cautions, magenta for tap-pinned/advisory, green for safe/acquired, red for warnings (never as text on `bg.primary`). Spec: `docs/superpowers/specs/2026-05-18-tailspot-visual-identity-design.md`.
```

Then update the test count line:

```markdown
- **124 unit tests** in `TailspotTests/` ...
```

(Was 121. Add `...and `BrandColorHexTests` (hex helper round-trip).` to the trailing list of test suites.)

- [ ] **Step 2: Update PLAN.md §9 shipped list**

In PLAN.md, find the "Shipped 2026-05-13 → 2026-05-17" header. Update the date range to include today and add Phase A to the bottom:

```markdown
**Shipped 2026-05-13 → 2026-05-18 (was queued in this section earlier):**

...

- ~~Visual identity Phase A — design tokens + light retheme~~ ✅ — `Brand.swift` namespace with all color + font tokens; five SwiftUI view files migrated to consume them; FAA semantic fixes (compass-bad red→amber, tap-pin cyan→magenta); horizontal lockup added to `HangarView` nav header. Phase B (Hangar v1 polish, HUD label redesign, splash) and Phase C (app icon, onboarding) remain pending.
```

- [ ] **Step 3: Final full test suite run**

Run:
```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests 2>&1 | grep -E '\*\* TEST|Executed'
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit docs**

```bash
git add CLAUDE.md PLAN.md
git commit -m "$(cat <<'EOF'
Docs: Phase A of visual identity shipped (Brand tokens)

CLAUDE.md "Current state" + PLAN.md §9 updated. Test count 121→124
(BrandColorHexTests). Brand.swift is the single source of truth for
every color and font in the SwiftUI views; FAA semantic alignment
is applied throughout.

Spec: docs/superpowers/specs/2026-05-18-tailspot-visual-identity-design.md
Plan: docs/superpowers/plans/2026-05-18-visual-identity-phase-a.md
EOF
)"
```

- [ ] **Step 5: Confirm doc-staleness hook is silent and show the unpushed commit list**

```bash
bin/doc-staleness-check && echo OK
git log origin/main..HEAD --oneline
```

Expected: hook prints `OK` (silent — docs touched in some unpushed commits). The commit list should show 8 commits (one per task above).

- [ ] **Step 6: Hand off to the user for field test + push**

Print to the chat:

> Phase A complete. 8 commits ahead of origin, tests green at 124. Build is NOT auto-deployed — run `bin/deploy` when ready, then field-test:
>
> 1. AR view: lock label callsign should be cyan (was white). Brackets unchanged.
> 2. Aim at a plane, tap-pin it: brackets + callsign + label border should all turn magenta (was cyan/green).
> 3. Recompute compass calibration: the bad-compass heading line should now be amber (was red).
> 4. Open Hangar: nav header should show airplane glyph + "TAILSPOT" lockup + a trailing count pill (was a single-line title).
> 5. Catches list: airplane icons should be cyan, row title in mono, subtitles + times in greys per the spec.
>
> When happy, `git push origin main`.

---

## Out of scope for this plan

These belong to Phase B (next session, ~1–2 d) and Phase C (later, ~3–4 d) per the spec:

**Phase B**
- Redesigned HUD lock label with proper hierarchy (callsign / operator / type / data row tiers)
- Hangar v1 polish — dedupe by icao24 within sections + "×N" pill + swipe-to-delete + rarity logic and "RARE" pill
- Brand splash screen on launch (wordmark lockup, ~600ms hold, crossfade)
- Caution badge component (replaces the inline `formatHeading` amber)

**Phase C**
- App icon SVG → PNG export pipeline (every iOS size variant)
- First-launch onboarding (permissions + compass-calibration teach)
- Settings / About screen reskin
