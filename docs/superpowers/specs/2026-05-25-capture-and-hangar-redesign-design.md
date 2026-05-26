# Capture & Hangar Redesign — Design Spec

**Date:** 2026-05-25
**Status:** Approved, ready for implementation plan
**Author:** Noah Landesberg (design partner: Claude)

## 1. Background

The Friday POC (§3.0a) shipped a working AR catch loop and the Phase 1–3 ports landed the Pokédex spine, design-canvas surfaces, and AR ergonomics. After several iterations on the Hangar layout (HangarA list → HangarB grid → filter chips), Noah surfaced a structural concern: **the core UX of catching planes and viewing the collection isn't right yet**. The current implementation works mechanically, but:

- The catch flow has a confusing "lock-then-capture" two-step that doesn't read as one fluid action; the lock state is unclear; the multi-catch surface (magenta zone + dedicated button) is loud before fire and quiet after.
- The Hangar grid reads as an inventory list, not a Pokédex. There's no journey, no gaps, no sense of "what's left to find." Trophies and Sets exist on separate screens, fragmenting the collection narrative.
- The catch detail page is information-dense (photo hero + EARNED + 6-cell stats grid + caught-at + planespotters footer) but doesn't feel collectible. The trading-card moment is missing from the surface that should be its home.

This spec documents the redesigned capture flow and Hangar IA that came out of the 2026-05-25 brainstorming session.

## 2. Goals

**In scope:**

- A single, fluid catch model where the lock label tells you what you're about to bag and the capture button is the only fire trigger.
- A Hangar that reads as a Pokédex journey: Sets are the spine, distinct tails are the unit of collection, duplicate catches don't pay.
- A tail detail page where the PokeCard is the hero and the surrounding chrome is restrained.

**Explicitly out of scope:**

- ARKit drift correction, CV-based reticle alignment, route info ingestion. Those are existing PLAN.md §9 follow-ups, not part of this redesign.
- Backend wiring (real leaderboard, public hangars, push). Mock surfaces stay mocked.
- Map screen, Profile screen, Settings, Onboarding, public/social. All untouched here.
- Re-themeing Brand tokens, AR identity, or capture-bar visuals beyond what this redesign explicitly calls for.

## 3. Capture model

### 3.1 Lock states

The lock engine is reworked so **every visible plane in the frame is a lock candidate**, not just the closest-to-center.

**Default — all-frame lock**

- Every visible plane (above horizon, within ~30 km slant) gets a faint cyan corner-bracket pair and a small label rendered above it: `callsign · rarity teaser`. Example: `UAL248 · RARE`.
- No single "winner." The frame is ambient — each plane has its own marker.
- The capture button is always live.

**Tap-pin — single override**

- User taps a plane in the AR view. That plane's brackets brighten + thicken, its label expands to include model + points hint (`UAL248 · 787-9 · RARE +100`). Other planes' brackets and labels dim to ~35% opacity.
- The capture button drops its multi badge; it now catches only the pinned plane.
- Tapping the pinned plane again clears the pin (back to all-frame).

**Tap empty sky — "try harder" / clear**

- If a plane is currently pinned and the user taps empty sky → clear the pin (back to all-frame).
- If no plane is pinned and the user taps empty sky → widen the search radius from the tap point and pin the nearest visible plane (anywhere in frame). If no plane is within the widened radius, surface a brief `NO AIRCRAFT HERE` ripple at the tap point and stay in all-frame.

### 3.2 Capture button

- Single button at the bottom of the AR view. Replaces the current `multi-catch` floating button and the prior dedicated multi-mode chrome (magenta-dashed zone is removed).
- Visual: cyan-stroked circle, `CAPTURE` label, restrained.
- **Always live** when ≥1 plane passes the visibility filter (above horizon, within `maxVisibleDistanceMeters` — currently 30 km). Disabled (faded ~40% opacity) otherwise. The empty-sky overlay (`emptySkyOverlay`) continues to show the existing status pill in the disabled state.
- **`×N` badge** in the top-right corner of the button when multi (i.e., no pin and ≥2 visible planes). The badge is small and uses the rarity-advisory magenta to signal "this catches more than one." No big banner, no separate button.
- One tap = fire. Catches whatever is locked: the pinned plane (single mode) or every visible plane (all-frame mode).

### 3.3 Catch fire + reveal

**Single catch** — current `CardReveal.swift` flow is preserved unchanged: full-screen takeover, rarity bloom, holo PokeCard, tap to flip.

**Multi-catch (≥2 planes captured at once)** — *this is the hype peak.*

- Background dims to near-black.
- Cards fan in **staggered**: ~250 ms per card. Each card landing triggers a haptic tap (UIImpactFeedbackGenerator `medium`) and an ascending audio chime (one of N tones; pitch increases with card index).
- **Combo banner** builds across the reveal: appears at top after the first card lands, then updates with each subsequent card. Sequence: `CATCH ×1` → `…×2` → `COMBO ×3 +250 pts`. Banner uses the rarity-advisory magenta accent.
- Loudest moment is the final card landing — full audio cue + slight screen shake + the combo banner snapping to its terminal value.
- Buttons at the bottom: `KEEP SPOTTING` (primary, cyan) and `View in Hangar` (secondary text button).

Existing `MultiCatchReveal.swift` is the foundation; restyle for the stagger + audio + combo build per this spec.

### 3.4 Duplicate catches

A "tail" is a unique `icao24`. A duplicate catch is one whose `icao24` already exists in the user's collection.

- **Reveal still fires.** The card appears with a diagonal red-bordered `ALREADY CAUGHT` stamp across the holo. No rarity bloom; no haptic build; minimal sound.
- **No DB row inserted.** SwiftData `Catch.init` is preceded by a `@Query` (or a `fetch` in the catch insertion path) that checks `predicate(icao24 == X)`. If a match exists, skip the insert.
- **No score / combo credit.** In multi-catch, duplicates appear inline in the fan with the stamp; the combo banner reads only the new tails (a 3-plane catch with 1 duplicate → `COMBO ×2 +250`).

### 3.5 What's removed from current capture flow

- The 3 s sustained tap-pin auto-catch (already removed in the AR capture-bar overhaul; this is just a note that it doesn't return).
- The magenta-dashed multi-zone outline (no separate multi mode chrome).
- The floating "[N]× CATCH · ×M COMBO" multi-catch button (subsumed by the unified capture button).
- The `closest-to-center` single-target heuristic for label rendering (lock engine is now all-frame; tap-pin handles single-target intent).

## 4. Hangar shell

### 4.1 Structure

The Hangar is a sheet presented from `ContentView` (existing trigger from the bottom hangar button is unchanged).

- **Toolbar:** small Lockup (cyan `HangarGlyph` + `TAILSPOT` 13 pt mono with 2 pt tracking) on the left; `N catches` accent pill (cyan on `cyan.opacity(0.16)`) on the right. Unchanged from current implementation.
- **View switcher** directly below the toolbar: segmented control with three segments — `Sets` · `Recent` · `Trophies`. Default selection: **Sets**. Selection persists across sheet opens via `@AppStorage("tailspot.hangar.view")`.
- Content area swaps based on selection.

### 4.2 Profile fallout

Trophies moves OUT of Profile and INTO the Hangar.

- `ProfileScreen.swift` removes its `RECENT MEDALS` strip and the `Trophies` quick link.
- The existing standalone `TrophiesScreen.swift` is either deleted or its body is repurposed as the Hangar Trophies view body. Implementation-time choice; both options preserve the existing 13-achievement × 4-tier ladder logic in `Trophies.swift`.
- Map and the rest of Profile are untouched.

## 5. Sets view (default)

### 5.1 Set landing

A scrolling list of 7 set tiles, one per `AircraftType`, ordered: Narrow / Wide / Regional / Biz / Mil / GA / Heritage. Each tile is **rich** — large enough to show the gap pattern at a glance.

**Tile anatomy:**

- Type-glyph chip (30 × 30, solid type tint, dark mono letter) leading.
- Set title (`Narrow-body`).
- **Slot-progress count** `M / N` in mono, type tint, where **M is the number of model slots with at least one distinct tail caught**, and N is the total number of model slots in the set. (Distinct-tail counts surface at the model-slot level — see §5.2 and §5.3.)
- **Thumbnail strip** below: one mini cell per model slot in the set, rendered left-to-right in slot order. Caught slots render with a 1 pt top rail in the type tint and the model abbreviation. Uncaught slots render as a darker placeholder with a centered `?`.
- A set with zero catches still shows in the landing (faded tile, no thumbnail rail — just `?` cells). Tapping into a 0/N set takes the user to a fully-silhouetted slot grid.

Tap any tile → push to Set detail.

### 5.2 Set detail

**Header:**

- Large type-glyph chip (36 × 36) + set title (14 pt bold).
- `M of N caught` mono count, type tint — **same slot-progress count as the landing tile**, not a tail count.
- Thin progress bar (height 3) in the type tint, M/N filled.
- **Next-milestone line** below (`2 MORE FOR SILVER`, mono small caps) — pulls from the `Trophies` ladder when the set has an associated achievement, otherwise hidden.

**Slot grid:**

- 2-col LazyVGrid, one cell per `PokeSetEntry`.
- **Caught slot:** rounded card with a 2 pt top rail in the type tint, `#NN` mono prefix top-leading, model name (`737-800`), and `×K tails` count in mono type tint where K is the distinct-tail count for that model. Tap → push to Model slot detail.
- **Locked slot:** dimmer card, no rail, `#NN` prefix, centered `?` glyph, and the expected model name in muted mono. Tap → bottom sheet with a one-line hint: `Catch a 737 MAX to fill #06` plus the operator hint if the entry has one.

### 5.3 Model slot detail (new screen)

A new screen between Set detail and Tail detail.

**Header:**

- `#NN · SET-NAME` mono breadcrumb.
- Model display name (`Boeing 737-800`, 14 pt bold).
- `K distinct tails` mono count, cyan.

**Tail list:**

- Vertical list of cards, one per distinct tail (icao24) the user has caught of this model. Sorted by first-catch date desc.
- Tail card anatomy: left rail (rarity tint; thin gray rail if non-rare), callsign in cyan mono, `icao24 · operator` muted mono subtitle, relative timestamp (`2d ago`) trailing.
- Tap a tail → push Tail detail.

## 6. Recent view

- Flat 2-col `LazyVGrid` of `MiniCardView`, one per distinct tail (no repeats), sorted by first-catch date desc.
- No filter chips. Filters are a Sets-view affordance; Recent is "what I just got."
- Tap → Tail detail.
- Long-press → context-menu Delete. After §9.1's dedup-by-tail change, exactly one Catch row exists per icao24, so the existing `deleteAlertTitle` always reads the singular branch (`Delete catch of UAL248?`). The plural branch (`Delete all N catches of …?`) becomes unreachable; the plan should remove it.

## 7. Trophies view

A port of the existing `TrophiesScreen` content into the Hangar's Trophies segment.

- Same partition: **Earned** / **In progress** (locked but ≥25% to next tier) / **Locked** (rendered as `???` hidden-trophy rows).
- Hero strip headline: `N of M · K close to unlocking` where N is achievements with at least one tier unlocked, M is the total roster size, K is the count of in-progress entries (≥25% but not yet earned). (Numerator semantic matches current implementation; design canvas uses tier-unlocks but we accept the mismatch.)
- Tap an entry → keep the existing trophy detail behavior (or a small reveal sheet; implementation-time choice).

## 8. Tail detail (`CatchDetailView` rewrite)

Replaces the current DetailA layout. **The PokeCard is the hero, not the photo.**

**Layout (top to bottom):**

1. **Floating chrome pills** anchored to the top of the view, over the card area: chevron-left back (dismisses to caller — Set/Recent/etc.) and share (`ShareLink`). Use `.ultraThinMaterial` discs, white-10% hairline border. The system nav bar is hidden via `toolbar(.hidden)` so the chrome lives on the page.

2. **PokeCardView at `.lg` size**, centered, front-and-center. Photo source priority: user's catch JPEG (`Catch.photoFilename`) → Planespotters (`PlanespottersClient`, gated `!hasCatchPhoto`) → striped rarity-tinted placeholder. The PokeCard's existing rarity bloom, holo wash, foil shine, and (for legendary) gold-dust treatments are preserved.

3. **EARNED panel** (rarity-tinted box, 1 pt rarity border, ~10% rarity tint background):
   - Left: `EARNED` mono small-caps + `+\(rarity.basePoints) pts` in big mono cyan/tier-color.
   - Right: rarity label + `Type · \(type)` muted mono.

4. **First-caught panel** (`Brand.Color.bgElevated`, rounded 10):
   - `FIRST CAUGHT` mono small-caps label.
   - Catch timestamp formatted as `May 22, 2026 · 5:24 PM`. Pulls from the **earliest** `Catch.caughtAt` in `row.allCatches` (relevant for legacy rows that pre-date §9.1's dedup-on-insert; for new rows, first = only).
   - Observer lat/lon (from that earliest catch) in mono with N/S/E/W hemispheres.

5. **Attribution** (only when the rendered photo came from Planespotters): text button → `openURL(photo.link)`, copy is `© \(photographer) · planespotters.net`.

**Dropped from current `CatchDetailView`:**

- 320 pt photo hero (the photo now lives inside the PokeCard's photo slot).
- 6-cell stats grid (distance, icao24, times caught, first caught, best range, points).
- Catch log / timeline of repeats (duplicates are no longer counted).
- Headline (callsign · icao + big model name + operator). The PokeCard surface carries this info now.

## 9. Data-model & engine changes

### 9.1 SwiftData `Catch`

- **Insertion gated on uniqueness.** Before inserting a `Catch`, the catch path (`performAutoCatch`, `performMultiCatch`) `fetch`es for `Catch.icao24 == new.icao24`. If a row exists, the insert is skipped and the reveal renders the duplicate state for that card.
- Existing rows are preserved as-is. No migration needed; legacy duplicates (if any exist locally) remain. A one-time cleanup is optional but not required by this spec.

### 9.2 Hangar grouping & model-slot resolution

- Add a "model slot" layer above `HangarRow`. New view-model type — provisional name `ModelSlot` — bundles `(entry: PokeSetEntry, tails: [HangarRow])`. Used by Set detail (grid) and Model slot detail (list).
- The mapping from a `Catch` to a `PokeSetEntry` slot uses the **existing `Sets.swift` matching logic** (already exercised by `PokeSetsTests::boeing787CatchFillsWideBodySlot` et al). No new matcher is introduced; one Catch maps to at most one slot, and an icao24 may not match any slot (those rows still surface in Recent but don't contribute to a set's progress).
- `HangarRow` itself is unchanged. The model layer is computed on demand from the dedup'd row list (`HangarGrouping.group(catches, by: .recent).first?.rows`) plus the `PokeSets.all` declarations.

### 9.3 Lock engine

`LockOnEngine.swift` is reworked to track per-icao24 lock state across the visible set, not a single `targetIcao24`. Possible shape:

- New state: `.allFrame(visible: [String])` — every visible plane has a label and bracket.
- Pin behavior is preserved (`forceLock(icao:)`), but during all-frame the engine emits per-plane lock-info for the AR overlay to render.
- The single-target `closestTargetIcao24` helper survives — used only when a pin is in effect or when capturing all-frame to enumerate everything in the lock zone (which now equals "visible").

Concrete shape (acquisition timing, sticky-hold, transitions) is an implementation decision — the plan should propose it.

### 9.4 Capture path

`ContentView.performAutoCatch` (single) and `performMultiCatch` (multi) merge into a single entry point parameterized by the lock state.

- Take the set of icao24s to catch (one for pin, N for all-frame).
- For each icao24: `fetch` for existing rows; if none, insert + add to "new tails" list; if exists, add to "duplicates" list.
- Capture one camera JPEG (existing) and attach to each new Catch row (existing behavior — each row gets its own copy of the JPEG path).
- Present the appropriate reveal: `CardReveal` for single new, `MultiCatchReveal` with stagger + combo for multi (including any duplicates marked with the stamp).

## 10. Testing

The existing 165-test suite stays green. New tests to add:

- **HangarGrouping ModelSlot aggregation** — given a set of `HangarRow`s with assorted models and tails, the `ModelSlot` aggregator produces the correct per-model distinct-tail count and tail list.
- **Catch insertion deduplication** — given an existing `Catch(icao24: X)`, inserting a new `Catch(icao24: X)` is a no-op (no row added).
- **Lock engine all-frame mode** — given a set of visible aircraft, the engine produces one lock entry per plane; the `closestTargetIcao24` helper still resolves correctly when needed.

Existing tests that assert "duplicates allowed" semantics in `CatchTests` need to flip to the new behavior. Specifically `storesMultipleCatchesIncludingDuplicates` is replaced with `duplicateInsertIsRejected`.

## 11. Open questions / follow-ups

1. **Audio cues.** The reveal's haptic build-up is well-supported (UIKit feedback generators); the audio chime needs a tone source. Plan should choose: bundled small AIFF files? `AudioServicesPlaySystemSound` with iOS system sounds? Synthesize via `AVAudioEngine`?
2. **All-frame label density.** When 10+ planes are visible, all-frame labels could crowd the screen. The plan should propose a fallback (e.g., labels only for the 5 closest-to-center planes; brackets-only for the rest).
3. **Trophies view nav source-of-truth.** The Profile screen currently has Trophies quick link + recent-trophies strip. Both must redirect to the Hangar Trophies view; the plan should specify whether Profile pushes the Hangar sheet open to Trophies (most direct) or relies on a new shared view.
4. **Model-slot back-navigation.** If a user lands in Tail detail via Recent (one level deep) vs. via Sets → Set detail → Model slot (three levels deep), the back gesture differs. Acceptable as long as `NavigationStack` handles it; spec doesn't dictate.

## 12. Cross-references

- Current AR / capture implementation: `ios/Tailspot/Tailspot/ContentView.swift`, `LockOnEngine.swift`, `CardReveal.swift`, `MultiCatchReveal.swift`.
- Current Hangar / detail: `HangarView.swift`, `HangarGrouping.swift`, `MiniCardView.swift`, `CatchDetailView.swift`.
- Game system foundation: `GameSystem.swift`, `Sets.swift`, `Trophies.swift`.
- Brand tokens: `Brand.swift`.
- Prior visual identity spec: `docs/superpowers/specs/2026-05-18-tailspot-visual-identity-design.md`.
- Design canvas reference: `design/screens/detail-hangar-profile.jsx`, `design/screens/ar-and-catch.jsx`, `design/brand-atoms.jsx`.
