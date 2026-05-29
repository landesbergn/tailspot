# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read PLAN.md first

`PLAN.md` is the single source of truth for product scope, architectural decisions, the phased roadmap (Friday POC ✅, design-canvas port ✅, TestFlight v0 shipping to internal testers ✅, backend next), risks (including the credential-leak incident), and what's still on the table. Read it before proposing structural changes.

## Current state (as of session ending 2026-05-29 [catch-photo bracket overlay + bigger reticles])

**Shipping as TestFlight v0.1.1.** First post-v0 feature drop. Two
landings on main this session, both user-visible to testers.

1. **Catch photos now show which plane you caught.** New
   `CatchPhotoComposer` (pure CG/UIKit, no SwiftUI) decodes the
   captured JPEG, runs the screen→photo pixel transform assuming
   `.resizeAspectFill` (which `CameraPreview` uses), and re-renders
   with the cyan corner-bracket box drawn at the plane's on-screen
   position at capture time. Multi-catch saves one bracket per
   plane on each plane's own photo file.

   The path is: ContentView projects every visible plane to screen
   once per TimelineView frame (`onScreenProjected: [(icao, pos)]`),
   stashes the icao→position map, and threads `screenSize` +
   `positions` through `captureBar` → `captureButton` →
   `performCatch`. At save time the loop looks up `positions[icao]`,
   builds a `CatchPhotoComposer.BracketOverlay`, and calls
   `compose(jpegData:overlay:)`. Fall-through: if compose returns
   nil (bad JPEG, zero-area screen) OR positions misses the icao
   (the plane was on-screen when the button rendered but not in
   the dict at fire time), we save the raw JPEG. No catch is lost.

   `AspectFillTransform` factored out as its own struct so the
   coordinate math is unit-testable without touching UIImage.
   Tests cover same-aspect, wide-photo crops-sides, tall-photo
   crops-top, iPhone 12MP sanity, the compose smoke path, and
   invalid-input fall-throughs (176 tests total — added 7).

2. **Bigger lock-on reticles** for alignment forgiveness. The 56pt
   pinned bracket read tight in field testing: small sensor noise
   or HFOV mis-cal pushed the plane just outside the box. New
   sizes — pinned 140, ambient 96, empty-sky center 200, photo
   overlay 140 (matches pinned so saved photos show the same
   framing). Arm length stays `max(8, boxSize * 0.22)`, so arms
   scale proportionally.

**Tests:** 176 pass (169 baseline + 7 for CatchPhotoComposer).
Reticle bumps don't touch tests — they're presentation constants.

**Doc-staleness hook now guards on main.** `bin/doc-staleness-check`
used to false-fire on feature branches (its check is HEAD-vs-
`origin/main`, which is always ahead on a feature branch even when
that branch is fully pushed to its own remote). Added a one-line
guard: `[ "$current_branch" = "main" ] || exit 0`. Feature-branch
sessions no longer get blocked by the Stop hook — doc updates
land with the merge into main, where the hook still fires.

**MARKETING_VERSION bumped 0.1.0 → 0.1.1** (two configs in
`project.pbxproj`). `CURRENT_PROJECT_VERSION` stays at 1 locally;
Xcode Cloud's `ci_pre_xcodebuild.sh` rewrites it to
`CI_BUILD_NUMBER` per archive.

**Open follow-ups specific to this round:**
- Field-test the new 140pt pinned reticle. If still too tight,
  bump further; if too loose, dial back. The photo-overlay constant
  in `CatchPhotoComposer.bracketScreenBoxSize` must stay in lockstep
  with the live `LockBrackets` size in `ContentView` so saved photos
  match what testers saw.
- The bracket's center is the *predicted* screen position (from
  ADS-B + extrapolation + projection). Eventually the long-term
  fix for "box should land on the actual plane" is CV detection
  (PLAN §9 #3 Vision + COCO airplane class) — let the bracket
  snap to the detected airplane bbox rather than the prediction.
  Until that lands, the bigger box is the cheap forgiveness.
- The typography sweep + onboarding fixes (B612 Mono, "reticles"
  copy, permissions in onboarding step 2, figure-8 removed) from
  the prior session were NOT pushed — they're sitting in a stash
  on Noah's machine (`stash@{0}`). When they land, the
  `ContentView.swift` `captureBar`/`captureButton` area is the
  likely merge-conflict surface against this session's wiring.

## Current state (as of session ending 2026-05-26 [TestFlight v0 prep])

**TestFlight v0 prep — landed 2026-05-26.** Everything required to
build, sign, and upload a TestFlight build is in place. See
`docs/testflight-handoff.md` for the step-by-step. Highlights:

- **Credentials baked via xcconfig + Info.plist.** Tailspot.xcconfig
  (committed) `#include?`s Tailspot.secrets.xcconfig (gitignored,
  holds real OpenSky values). Build-time substitution flows into
  Info.plist keys `OpenSkyClientID` / `OpenSkyClientSecret`. New
  resolution order in `OpenSkyClient.init`: explicit creds → env
  vars → `Bundle.main.infoDictionary` → nil/anonymous. Env-var path
  preserves Noah's existing dev loop; the bundle path is the only
  one that survives TestFlight / home-screen / `devicectl` launches.
  **Security accepted:** the values are in the shipped binary,
  extractable from any `.ipa`. v0 risk for 1-2 trusted testers;
  backend proxy is the path for wider distribution (PLAN.md §1).
- **Manual `Info.plist`** at `ios/Tailspot/Info.plist` replaces the
  previously-auto-generated one. Adds `ITSAppUsesNonExemptEncryption=false`
  and the custom OpenSky keys. The Tailspot target switched from
  `GENERATE_INFOPLIST_FILE=YES` + `INFOPLIST_KEY_*` build settings to
  `INFOPLIST_FILE=Info.plist`. The Info.plist sits at the project
  root (outside the synchronized `Tailspot/` folder) so it's not
  bundled as a duplicate resource.
- **Privacy manifest** at `ios/Tailspot/Tailspot/PrivacyInfo.xcprivacy`.
  Declares UserDefaults (`CA92.1`) + FileTimestamp (`0A2A.1`)
  required-reason API usage, and the two data categories we collect
  (precise location + photos — app-functionality only, not linked
  to identity, not tracking). Update when the backend ships.
- **Version + build number scheme.** `MARKETING_VERSION=0.1.0`,
  `CURRENT_PROJECT_VERSION=1`. Bump `CURRENT_PROJECT_VERSION` on
  every TestFlight upload (App Store Connect requires monotonic
  per marketing version); bump `MARKETING_VERSION` on meaningful
  feature drops.
- **App icon.** Programmatically generated 1024×1024 PNGs (3
  luminosity variants — light / dark / tinted) via
  `tools/generate-app-icon.swift`. Cyan→navy gradient + HangarGlyph,
  consistent with brand tokens. Re-run the script to regenerate,
  or replace the PNGs directly in `AppIcon.appiconset/`.
- **xcconfig precedence trick.** `Tailspot.xcconfig` defines
  `OPENSKY_CLIENT_ID =` (empty) as default, then `#include?`s the
  optional secrets file. Last-wins is xcconfig precedence — when
  the secrets file is present its assignments override the empty
  defaults; when missing, the empty defaults stand and Info.plist
  resolves to empty strings (anonymous mode). The `?` on
  `#include?` makes missing-file a no-error condition.

**Tests:** 169 still pass. The credential change is additive (env-var
fallback preserves existing tests that don't touch OpenSky live calls).

**Open follow-ups specific to TestFlight:**
- App Store Connect record creation, signing, Archive + Upload all
  live in Apple UIs — see `docs/testflight-handoff.md`.
- Privacy policy URL needed if/when adding external testers (>10
  beyond your team). Internal testers are sufficient for v0.

**Xcode Cloud (added 2026-05-26):** Apple's CI runs two scripts
checked into `ios/Tailspot/ci_scripts/`:

- `ci_post_clone.sh` materializes `Tailspot.secrets.xcconfig` from
  workflow env vars (`OPENSKY_CLIENT_ID` / `_SECRET`, both marked
  secret in the workflow's Environment Variables). When env vars
  are absent the script no-ops; build runs anonymous.
- `ci_pre_xcodebuild.sh` seds `CURRENT_PROJECT_VERSION` in
  `project.pbxproj` to match Apple's `CI_BUILD_NUMBER` before
  archive. Without this every CI archive shipped with
  `CFBundleVersion=1` and App Store Connect silently dropped
  subsequent uploads as duplicates — Xcode Cloud reported "build
  succeeded" while TestFlight stayed pinned to Build 1 forever.
  Local builds keep the committed value (1); only Xcode Cloud
  rewrites.

**Xcode Cloud setup gotchas that ate hours this session:**
1. Workflow's "Project or Workspace" field defaults to repo root;
   our project is at `ios/Tailspot/Tailspot.xcodeproj` — must be set
   explicitly or builds fail with the misleading "scheme Tailspot
   does not exist" error.
2. Workflow needs a TestFlight distribution **Post-Action**
   ("TestFlight Internal Testing"), separate from the Archive
   action. Without it, the archive succeeds but never reaches
   TestFlight.
3. Don't put trailing whitespace/newlines in env-var values; App
   Store Connect's UI rejects with "invalid value due to invalid
   value" without saying which character offended.

**Post-TestFlight polish landed same day (2026-05-26):**
- App icon swapped from the generated HangarGlyph-on-gradient to
  the B-lockon concept (cyan AR corner brackets framing a white
  airplane symbol on a navy gradient — references the AR mechanic).
  Generator: `tools/generate-icon-options.swift`. Picked variant's
  three PNGs (light/dark/tinted) committed in `AppIcon.appiconset/`;
  `tools/icon-options/` is gitignored.
- `ComingSoonPill` + `ComingSoonBanner` components (`ComingSoonPill.swift`).
  Applied to Leaderboard, Public Hangar, and Notifications screens
  with amber `hammer.fill` glyph so testers know these are mocks
  pending backend.
- Debug wrench toggle in `ContentView` wrapped in `#if DEBUG`.
  TestFlight (Release) builds show no wrench; local Xcode dev
  (Debug) keeps it.
- 8 Swift 6 prep warnings cleared (Log isolation, PhotoCaptureDelegate
  nonisolated, HangarGrouping no longer claims nonisolated when it
  touches `@MainActor Catch` state, MultiCatchReveal @ViewBuilder
  drop, Trophies closure @Sendable).
- Hangar glyph swapped to SF Symbol `airplane.path.dotted` (plane
  with dashed trail). Replaces the hand-drawn peaked-pentagon Shape
  in `HangarGlyph.swift`. Callers unchanged — same `HangarGlyph(tint:)`
  API, `lineWidth` retained as unused param for source compat.
- Settings → bottom of page renders `Tailspot 0.1.0 (build N) · tap
  to copy`. Tap copies the version line to the clipboard with a
  soft haptic; testers paste it verbatim into bug reports.

## Current state (as of session ending 2026-05-25 [Capture & Hangar redesign IMPLEMENTED])

**Capture & Hangar redesign — landed 2026-05-25, end-to-end.** Spec at `docs/superpowers/specs/2026-05-25-capture-and-hangar-redesign-design.md`; plan at `docs/superpowers/plans/2026-05-25-capture-and-hangar-redesign.md` (20 phased tasks); subagent-driven execution committed 24 commits between `ba47e78` and `93eec57`. All 169 unit tests pass.

**Catch model & engine spine (T1–T4):**
- `Catch.exists(icao24:in:)` static helper gates insertion. `CatchTests::duplicateInsertIsRejected` replaces the old `storesMultipleCatchesIncludingDuplicates`.
- `HangarRow.firstCatch` returns the earliest catch in `allCatches` (used by `CatchDetailView`'s first-caught panel for legacy multi-catch rows).
- New `ModelSlot.swift` — view-model bundling `(entry: PokeSetEntry, tails: [HangarRow])`. `HangarGrouping.resolveSlots(for:in:)` produces `[ModelSlot]` for a given set, reusing the existing `Sets.swift` matcher (now exposed as `PokeSets.matches(catch:entry:)`).
- `LockOnEngine` simplified to 3 states (`idle / locked / sticky`). `.acquiring`, `acquisitionDuration`, `acquisitionProgress` removed. `forceLock` is the only entry to `.locked`; new `unpin()` returns to idle.

**Capture flow (T5–T8):**
- AR overlay renders **ambient labels on every visible plane** — faint cyan corner-bracket pair + `callsign · RARITY` label via new `PlaneLabel` + `LockBrackets` private structs in `ContentView`. Pinned plane brightens (56×56, 2.5pt strokes, full opacity); others dim to ~35%. Per-plane metadata via `ambientMetadata` content-keyed `.task(id: visibleIcaoSignature)` prefetch, pruned to currently-visible icaos so the view dict doesn't grow monotonically.
- Tap behavior is 4-branch: ≤100px hit on plane → toggle pin / re-pin; empty sky with pin → clear pin; empty sky without pin → widen to 250px and pin nearest; truly empty → brief `NO AIRCRAFT HERE` cyan ripple. Radii scale with zoom (capped at half-screen).
- Capture button is unified — `CaptureMode { .disabled, .single, .multi }` derived per-frame. Magenta `×N` badge in the top-right corner only for multi (no pin, ≥2 visible). Disabled (~40% opacity) when frame is empty. The prior multi-catch button + magenta-zone overlay are deleted.
- `performCatch(mode:)` merges the old `performAutoCatch` / `performMultiCatch` paths into one entry. Per-icao `Catch.exists` gate; new tails inserted; duplicates accumulated in a separate list. One JPEG captured per fire, attached to each new row. `captureInFlight` flag guards re-entry. `presentReveal(newCatches:duplicates:)` routes ≤1 to single CardReveal and ≥2 to staggered MultiCatchReveal.

**Reveal moments (T9–T11):**
- New `RevealAudio.swift` — thin wrapper around `AudioServicesPlaySystemSoundID` + `UIImpactFeedbackGenerator`. 5-rung ascending chime ladder (Tink → BeginRecording → Anticipate → Headset In → Photo Shutter).
- `CardReveal` gains `isDuplicate: Bool = false`. On duplicate: diagonal red-bordered `ALREADY CAUGHT` stamp over the card front (hidden on flip-back); rarity bloom + rare+ light rays gated off; status pill swaps green NEW CARD → amber RE-CATCH. The PokeCard itself still renders (back-flip works).
- `MultiCatchReveal` reworked around a state-driven stagger: `@State revealedIndex` ticks via a `.task` loop, sleeping ~250ms between cards. Each non-duplicate landing fires `RevealAudio.tap(step:)` with a fresh-count-based step (chime ladder ascends by new tails, not absolute index). Combo banner builds: `CATCH ×1 → COMBO ×N +M pts` (magenta accent). Dups render inline with a smaller stamp and don't contribute to the combo. `comboMultiplier(for:)` static API preserved for `MultiCatchComboTests`.

**Hangar shell + 3-view structure (T12–T14):**
- New `HangarSegmentedSwitcher.swift` — cyan-on-bgElevated 3-segment control. `HangarSegment { .sets, .recent, .trophies }`. Default `.sets`. Persists via `@AppStorage("tailspot.hangar.view")`.
- `HangarView` body is now just toolbar (Lockup + count pill) + switcher + the three view bodies; filter chips, the inline `LazyVGrid`, and the per-grid delete state are all gone (delete moved into `HangarRecentView`).
- New `HangarRecentView.swift` — chronological dedup'd MiniCard grid sorted by first-catch desc; long-press → context-menu Delete with confirmation alert. Owns its own `rowToDelete` state.
- New `HangarTrophiesView.swift` — the inner body of the former standalone `TrophiesScreen` extracted intact (hero strip + Earned / In progress / Locked partition + 13-achievement × 4-tier ladder with hex-frame icons). `TrophiesScreen.swift` reduced to a 21-line thin wrapper for any remaining standalone push paths. `ProfileScreen` lost its `RECENT MEDALS` strip + the Trophies callsite (Trophies is now Hangar-only; Map stays on Profile).

**Sets drill-down (T15–T17):**
- New `HangarSetsView.swift` — vertical list of 7 rich set tiles (one per `AircraftType`, ordered Narrow / Wide / Regional / Biz / Mil / GA / Heritage per `PokeSets.all`). Each tile = type-glyph chip + set title + slot-progress `M / N` + thumbnail strip (caught slots get a 1pt type-tint top rail + `entry.modelTokens.first?.uppercased()` label; locked slots show centered `?`). 0/N sets fade to 55% opacity. Tap → `SetDetailRoute(setId: String)`.
- New `SetDetailView.swift` — set detail screen. Header (40pt type chip + set title + `M of N caught` mono + 3pt progress bar + optional next-milestone teaser). 2-col `LazyVGrid` of slot cells. Caught cell: 2pt rarity top rail + `#NN` prefix + `entry.canonicalName` + `×K tails` count in type tint. Locked cell: dim `?` + canonicalName; tap → `.sheet(item:)` `LockedSlotHint` (~220pt detent) with `entry.summary` as the secondary hint line.
- New `ModelSlotDetailView.swift` — between Set detail and Tail detail. Header: `#NN · SET-NAME` breadcrumb + canonical model name + `K distinct tail(s)`. Vertical list of `HangarRow`s for tails of this model: 3pt rarity left rail + cyan callsign + `icao24 · operator` muted mono + right-aligned relative `firstCatch.caughtAt`. Tap → `HangarRow` (resolves to `CatchDetailView`).

**Tail detail rewrite (T18):**
- `CatchDetailView` rewritten per spec § 8 (net -222 lines). **PokeCard `.lg` is the hero, front-and-center.** Floating chrome pills (chevron-back + ShareLink) on `.ultraThinMaterial` discs; system nav bar hidden via `.toolbar(.hidden, for: .navigationBar)` + `.navigationBarBackButtonHidden(true)`. Below the card: EARNED panel (rarity-tinted, `+basePoints pts`, rarity label + type) and First-caught panel (earliest `Catch.caughtAt` + observer lat/lon with N/S/E/W). Planespotters attribution chip only when a Planespotters photo is rendered. **Dropped:** 320pt photo hero, 6-cell stats grid, catch-log timeline, separate headline block. Photo-slot priority owned by `PokePlane.photoURL`: catch JPEG → Planespotters thumbnail (fetched on `.task` for the no-JPEG case, then `PokePlane` rebuilt with the URL) → striped rarity placeholder (PokeCard's own fallback).

**MiniCard cleanup (T19):**
- `MiniCardView` drops the `×N` count pill — post-T1/T8 dedup means `row.count` is always 1 going forward and the badge was meaningless visual noise.

**Tests:** 169 pass. New tests added: `duplicateInsertIsRejected`, `hangarRowFirstCatchIsEarliestInAllCatches`, `resolveSlotsForSetGroupsCaughtTailsByEntry`, `idleStaysIdleEvenWithVisibleTarget`, `forceLockMovesIdleToLocked`, `updateWithNilFromLockedMovesToSticky`, `stickyExpiresToIdleAfterDuration`, `stickyRecoversToLockedOnSameTarget`, `ticksAloneNeverEnterLocked`, `unpinClearsActiveLock`, `unpinClearsSticky`, plus follow-up assertions. Removed `.acquiring`-state tests.

**Open follow-ups (spec § 11):** Audio source can swap from `AudioServicesPlaySystemSoundID` to bundled AIFFs / `AVAudioEngine` synth if the chime ladder needs tuning. All-frame label density fallback at ≥10 visible planes (closest-5 + brackets-only for the rest) not implemented; punt until field-testing shows the need. `nextMilestoneLine` in SetDetailView is stubbed (returns nil) until a trophy-to-set mapping is wired. Some minor dead code: `HangarFilter` enum in `HangarView.swift` (T15 didn't claim it; safe to delete in a sweep). `LockOnEngine.icaosInZone` is now orphaned (no callers post-T7).

## Current state (as of session ending 2026-05-22 [HangarB grid + DetailA])

**Hangar switched from list to card grid (HangarB).** First two passes implemented `HangarA` (list with section grouping); Noah called it out and asked for `HangarB` — the trading-card grid view. New shape:

- **`MiniCardView.swift`** (new) — port of canvas `MiniCard` (detail-hangar-profile.jsx:408-440). Rounded 12pt card with vertical `bgElevated → bgSurface` gradient fill, 1pt solid rarity border, 2pt rarity-tinted top rail, header row (cyan callsign + small RarityBadge), 66pt photo slot (catch JPEG if present, else striped placeholder in the rarity tint), title (model + operator), footer row (small TypeBadge + ×N pill). Sized to whatever width LazyVGrid hands it; content-driven height. Diagonal stripe pattern in `StripesShape` matches the canvas `repeating-linear-gradient(135deg, ...)`.
- **`HangarView` rebuilt as a 2-col `LazyVGrid`** over `Brand.Color.bgPrimary`, fed by `HangarGrouping.group(catches, by: .recent).first.rows` (dedup'd flat list). Section grouping is gone — filters replace it.
- **`HangarFilter` enum** (`.all`, `.rarePlus`, `.type(AircraftType)`) plus a horizontal-scrolling filter chip row above the grid. Always shows "All · N"; appends "Rare+ · K" when K > 0; one chip per non-empty AircraftType bucket sorted by enum ordering. Active chip is cyan with dark text; inactive is `bgElevated` with secondary text.
- **Delete moved from swipeActions to long-press context menu.** SwiftUI grid views don't support `swipeActions`, so the existing delete-confirmation alert is now triggered by tap-and-hold → Delete on the card. Same multi-catch-delete-all behavior as before.
- **Segmented picker (By type / By airline / Recent) removed.** The Recent-mode dedupe path is what the grid uses internally; the visible knob is now the filter chips.

**`CatchDetailView` rewritten as DetailA — photo-led collector card.** Old grouped-list layout is gone. New shape:

- **320pt photo hero** with a top-to-bottom gradient fade from clear → `bgPrimary`. Source priority: user's catch photo → live Planespotters → diagonal-striped rarity-tinted placeholder. The Planespotters fetch is gated `!hasCatchPhoto` so we don't burn a network call when the user already has their own moment shot.
- **Floating chrome pills** over the hero: `chevron.left` (dismiss) on the left, `square.and.arrow.up` (ShareLink) on the right. `.ultraThinMaterial`-filled discs with a 0.10-white border — matches canvas `ChromePill`. The system nav bar is hidden via `.toolbar(.hidden, for: .navigationBar)` + `.navigationBarBackButtonHidden(true)` so the chrome lives on the photo and not in a separate iOS bar.
- **Badge row** anchored to the bottom-leading of the hero: medium RarityBadge + medium TypeBadge + relative-time pill (`● 2m ago`) in the `alertNormal` (green) theme.
- **Headline:** small cyan callsign · ICAO line, big 30pt display model name, 13pt muted operator.
- **EARNED panel:** rarity-tinted box. Left = `+\(rarity.basePoints) pts`. Right = rarity label + `Type · \(type)`. 1pt rarity border + 10% rarity-tinted background.
- **2-col stats grid** sized to what the `Catch` model actually carries: `DISTANCE` (slant km) · `ICAO24` · `TIMES CAUGHT` (×N) · `FIRST CAUGHT` (earliest date in `allCatches`) · `BEST RANGE` (min slant across history) · `POINTS` (`basePoints * count`). The canvas's ALTITUDE / SPEED / BEARING / REGISTRATION cells need new fields on the `Catch` SwiftData model — flagged for follow-up; not faked.
- **CAUGHT AT panel:** abbreviated date + time, then observer lat/lon with N/S/E/W hemisphere letters in mono.
- **Planespotters attribution** at the bottom (text button → `openURL`), only rendered when the photo came from Planespotters (suppressed for catch-photo runs and notAvailable).

The earlier PokeCardView hero + Identity rows + Caught-N-times timeline are removed — the new layout subsumes that information into the hero + EARNED + CAUGHT-AT structure. PokeCardView itself is still used by `CardReveal` (the catch-moment full-screen flash) so no code is unused.

## Current state (as of session ending 2026-05-22 [Hangar canvas port — second pass])

**Hangar canvas — second-pass tightening (2026-05-22).** Per Noah's "closer but still doesn't match" — fixed the chrome and density that were still off:

- **Toolbar redesigned** to match canvas `HangarA` nav: small Lockup (cyan `HangarGlyph` + `TAILSPOT` at 13pt mono with 2pt tracking) on the left, accent pill (`"N catches"` in cyan on `cyan.opacity(0.16)`) on the right. Done button dropped; the sheet still dismisses via swipe-down. `toolbarBackground(Brand.Color.bgPrimary, for: .navigationBar)` so the nav background blends with the body — no system gray bar.
- **Stats row removed.** The canvas never showed `caught / unique / rare` — they were a Tailspot addition. Dropped along with all four supporting methods (`statsRow`, `statPill`, `statDivider`, `uniqueIcaoCount`, `rareUniqueCount`).
- **Cards slimmed.** Row vertical padding 12 → 10 to drop the crowded feeling. Subtitle simplified to canvas's `{model} · {distance}` form regardless of grouping mode (was switching between operator and type to avoid restating the section header — but the canvas just always shows the model). Single dot separator `" · "` instead of double-space.
- **Callsigns are now cyan** — `.t-hud-callsign` in the canvas is `color: var(--accent)`, mine was rendering them in `textPrimary` (white). Fixed.

## Current state (as of session ending 2026-05-22 [Hangar canvas port + AR capture-bar overhaul])

**AR capture bar — landed 2026-05-22 (also bundles compass-debounce hysteresis).** The floating multi-catch capture button is gone; a unified bottom capture bar in `ContentView` now hosts the hangar glyph (left), a big central capture button, and the profile glyph (right). The capture button reads the per-frame target / multi-candidate state inside the `TimelineView`, exposes `captureMode`, and routes to `captureButtonSingle` / `captureButtonMulti` / `captureButtonIdle`. The legacy 3s sustained tap-pin auto-catch (`autoCatchHoldDuration` / `autoCatchTask` / `autoCaughtPin`) is **removed** — the user explicitly hits the capture button now. A `captureInFlight` flag guards re-entry. Compass-warning thresholds were tightened: `compassBadThreshold` bumped 10° → 25° (typical urban CL accuracy is 10–20° even when the compass is fine, so 10° fired the badge constantly), with hysteresis at 15° and a 4s continuous-bad-reading debounce before `showCompassWarning` flips on. `updateCompassWarning(accuracy:)` is the new entry point; `isHeadingAccuracyBad` proxies the latched state.

**Hangar canvas-port pass — shipped 2026-05-22.** Two layered fixes addressing "the app still looks pretty different from the designs I shared with you":

- **New `HangarGlyph.swift`** — peaked-roof pentagon + horizontal eaves line, ported verbatim from `design/brand-atoms.jsx:186` `Icon.hangar` SVG (`M3 11 L12 5 L21 11 L21 20 L3 20 Z` outer + `M3 11 H21` eaves). Replaces `tray.full.fill` in the bottom Hangar button (`ContentView.swift:954`). Sized to a 26×26 frame inside the existing 56×56 chip; `lineWidth: 2` matches the canvas stroke.
- **`HangarView` chrome flipped to match `detail-hangar-profile.jsx` HangarA.** Rows are visually unchanged in data but resemble the canvas card style now:
  - `List` style: `.insetGrouped` → `.plain` + `.scrollContentBackground(.hidden)` + `.background(Brand.Color.bgPrimary)` so the dark canvas base shows through.
  - Rows: each is a `bgElevated` rounded card with a **3pt solid rarity-tinted left stripe at the card edge** (was inside the type-chip before — moved out per canvas). Type chip became **solid type-color (36×36) with dark glyph text** instead of faded-tint with type-color text. Row separators hidden; padding 12×14 with the row clipped to a 8pt corner radius.
  - Section headers redesigned: small uppercase tracked label + `N CAUGHT` mono caption. Count is **total catch events, not unique-row count**, matching the canvas's "WIDE-BODY · 6 CAUGHT" semantics — uses `group.rows.reduce(0) { $0 + $1.count }`.
  - 3rd segmented option added: **Recent** — single flat list of dedup'd rows sorted by recency, section header suppressed.

  **Tradeoff documented:** `.plain` list style makes section headers sticky on scroll. The canvas doesn't show stickiness, but ditching `List` would mean rebuilding swipe-to-delete by hand. Accepted stickiness; revisit if Noah pushes back.

- **`HangarGrouping.recent`** — new mode. Skips bucketing entirely: every dedup'd row lands in a single `HangarGroup` titled `recentTitle`, with rows sorted most-recent-first. `key(for:mode:)` returns `recentTitle` for completeness. `HangarGroupingTests` adds 3 cases: dedupe + sort, empty input, ignores grouping-key fields.
- **`HangarView.rowSubtitle` extended** with `.recent` case — shows aircraft type as the subtitle since there's no section header to disambiguate.

**Also landed 2026-05-22 — OpenSky credential propagation through the deploy loop.** `bin/deploy` now extracts `OPENSKY_CLIENT_ID` / `_SECRET` from the user-only scheme XML via `xmllint`, JSON-encodes them, and forwards via `xcrun devicectl device process launch --environment-variables` (plus the alternative `DEVICECTL_CHILD_*` env-var path for belt-and-suspenders). Without this, deploys ran the app anonymous (400 credits/day) and exhausted the OpenSky quota in ~1.3h. Dry-run output redacts the JSON. **Caveat: env vars only persist for that one launched process — if Noah relaunches via the home-screen icon, creds are gone and "API limit" returns.** Durable fix (xcconfig → Info.plist baking) is the obvious next step but not yet shipped. `ADSBManager` gained `lastErrorIsTransient` so the empty-sky pill can render auto-recovering 429 backoffs softly, plus `liveSourceIsAuthed` (proxies `OpenSkyClient.hasCredentials`) for the debug overlay; the 429 string changed from "Rate limit hit — backing off (next try in Ns)" to "API limit · retry in Ns". `OpenSkyClient.init` logs `credentials MISSING (anonymous)` vs `present (authed)` via `Log.openSky.notice` so device launches reveal auth state in the log stream.

## Current state (as of session ending 2026-05-21 [Design-canvas QA pass — 9 fixes landed])

**Friday POC (§3.0a) DELIVERED May 5–7, 2026.** Field-tested in Berkeley with real planes; labels land on or near actual aircraft.

**Phase 0c — Remote-deploy loop (§3.0c) DELIVERED 2026-05-13.** Bash-driven build / install / launch / log-stream pipeline so Claude can iterate directly on Noah's paired iPhone. See "Remote-deploy loop" below.

**Beyond the POC, currently shipping:**

- **Game-system spine — Pokédex rarity + types + PokeCard.** Shipped 2026-05-20 as Phase 1 of the design-canvas handoff (claude.ai/design; 33 artboards captured in `design/`). `GameSystem.swift` defines `Rarity` (5 tiers — `.common` 10pt, `.uncommon` 25, `.rare` 100, `.epic` 500, `.legendary` 2000 — with `.tint` colors `0x8595A5 / 0x4ECCA3 / 0x00D4FF / 0x9B5DE5 / 0xFFB800` and an `ordinal` helper) and `AircraftType` (7 categories — `.narrow .wide .regional .biz .mil .ga .heritage` — each with a single-letter glyph + tint color). `AircraftClassifier.classify(manufacturer:model:operatorName:)` is a deterministic curated rule table: first matching `Rule` wins; operator-token gate is **any-of** (so the operator-gated VC-25 rule only fires when operator contains "usaf" or "air force", and a civilian 747-2 falls through to the rare 747 bucket). `Catch` gained `rarity: String?` + `aircraftType: String?` raw-value columns (SwiftData lightweight migration tolerates nil for pre-existing rows); the init runs the classifier so new rows are born with a snapshotted (rarity, type) pair, and `resolvedRarity`/`resolvedType` computed properties backfill via the classifier on read for legacy rows. `HangarRarity` (binary common/rare) was deleted — subsumed by the new system. **HangarRow.rarity now returns `Rarity`, not `HangarRarity`.** `BadgeViews.swift` ships SwiftUI `RarityBadge` (mono-font tier-tinted pill with bordered chip styling; legendary gets a leading ★), `TypeBadge` (rounded chip with dark-circle glyph well + label on type-tinted background), and `TagRow` (combined). `PokeCardView` is the hero collectible: 3 sizes (`sm` 150×210 / `md` 220×308 / `lg` 280×400), rarity-tinted 5pt top rail, 1.5pt rarity border + 18pt rarity glow + 20pt drop shadow, rare+ tiers get a conic-gradient holo wash blended `.overlay` + a diagonal foil shine blended `.screen`, legendary additionally gets 4 radial gold-dust hot-spots blended `.screen`. Photo slot uses the catch's `photoFilename` on disk if present, otherwise a striped placeholder in the rarity tint. Applied to: (1) `CatchDetailView` — the PokeCard is the first List section, hero size `.lg`, sits above the existing catch-photo / Planespotters / Identity / Caught-N-times sections; Identity gains "Rarity" + "Type" rows. (2) Hangar row — the leading airplane glyph is replaced by a type-glyph chip with a rarity-tinted 3pt vertical stripe; inline `RarityBadge` (size `.sm`) appears next to the callsign for rare+ tiers only (common/uncommon stay quiet). The "rare unique" stat pill now counts unique airframes at rare-or-higher. (3) AR lock label — adds a `TagRow` (`.sm`) right under the callsign once metadata has landed, so users get an instant tier read before tapping in. Catch-flash overlay's RARE-CATCH sub-pill triggers on rare+ (`row.resolvedRarity.ordinal >= Rarity.rare.ordinal`). The handoff prototype source lives in `design/` (HTML/JSX, ~340K) — open with `python3 -m http.server 4173 --directory design && open http://127.0.0.1:4173/`.

  **All visible surfaces of the design canvas are ported.** Backend-dependent surfaces (Leaderboard, Public Hangar, real push notifications) ship as preview UI with mock data.

- **Design-canvas QA pass — shipped 2026-05-21 (Phase 3 follow-up).** Reviewed every screen against the design canvas's accessibility tree and landed 9 structural fixes: (1) `TrophiesScreen` now partitions the roster into **Earned** / **In progress** (locked but ≥25% to next tier) / **Locked** (rendered as "???" hidden-trophy rows so the user has discoverable surface). Hero strip headline shows "N of M · K close to unlocking" when applicable. **Note: numerator semantic is "achievements with at least one tier unlocked", not "total tier-unlocks" — design canvas shows the latter; we accept the mismatch.** (2) `OnboardingFlow` step 4 (Pick a handle) gained an inline `availabilityPill` (● AVAILABLE / TOO SHORT / BAD CHARS), a 2×2 suggestions grid with 4 handles, and a Public-profile toggle (binds to the same `@AppStorage("tailspot.profile.public")` key as `SettingsScreen` — canonical default `true`). Step label changed to "FINAL STEP · PUBLIC HANDLE". (3) `ProfileScreen` identity hero rebuilt with an avatar disc showing user initials + handle row + "joined <Month YYYY>" derived from earliest catch + a "PUBLIC" pill in the top-right. (4) `ProfileScreen` stats row swapped "Longest km" → "Medals" (count of unlocked achievements) to match the design's 4-stat row CATCHES / UNIQUE / RARE+ / MEDALS. (5) `CardReveal` adds a "tap card to flip" / "tap card to flip back" hint between the card and the buttons. (6) `SetsScreen` set-detail tiles now show numbered prefixes (`#01`, `#02`...) in the top-leading corner; uncaught entries read "Not yet caught" instead of "???". Browser hero gained a "POKÉDEX-STYLE" tagline + "Sets by type" sub-headline. (7) `HangarView` empty state rebuilt: scroll view with a hero block ("Go outside.") + magnifying-glass disc + "Open AR view" button, followed by a **SETS TO COLLECT** preview row of Narrow / Wide / Regional / Heritage with type tints + entry counts. Replaces the bare `ContentUnavailableView`. (8) `NotificationsScreen` rewritten into the design's section structure: **PUSH** (master allow) / **NEARBY AIRCRAFT** (rare-or-epic / legendary / first-of-type / multi-catch) / **PROGRESS** (trophies / set-complete / weekly) / **QUIET HOURS** (overnight / weekends). 9 toggles, all @AppStorage-backed. (9) `LeaderboardScreen` adds a "CLIMB" coaching banner below the rows when the user is outside the top 10, computed from the gap between the user and the rank-10 row.

- **Phase 3 — AR ergonomics + multi-catch, shipped 2026-05-21.** The compass caution badge is now interactive — tap opens `CompassCalibrationSheet` (`CompassCalibrationSheet.swift`) which explains the magnetometer-drift cause, shows the figure-8 motion via the (now shared) `Figure8Animation` view, and renders a live HEADING / ACCURACY readout with a `calibratedThisSession` latch that flips the sheet's headline + dismiss button to a green "All good" state once accuracy drops under ±10°. Empty-sky AR state: `ContentView.emptySkyOverlay(rawCount:)` renders a faint 88×88 center reticle plus a status pill at ~82% screen height — "SCANNING SKY…" / "NO AIRCRAFT IN VIEW · N IN RANGE" / "NO AIRCRAFT IN RANGE" depending on `adsb.observed.count` and `adsb.lastFetched`. Status dot uses an `EmptyPulse` ViewModifier for breathing animation (disabled when an error is surfaced — the message wins). Multi-catch mechanic (`MultiCatchReveal.swift` + `ContentView` integration): `icaosInZone(...)` (sibling to `closestTargetIcao24` in `LockOnEngine.swift`) returns every visible icao24 whose screen projection lands inside a `zoneRadius` circle around the screen center. When ≥2 are present AND no plane is pinned AND the engine isn't `.locked`/`.sticky`, the AR view paints a pulsing magenta-dashed capture frame (RoundedRectangle, lineWidth 2, dash [10, 6]) and surfaces a "[N]× CATCH · ×M COMBO" magenta capture button at the bottom. Tap fires `performMultiCatch(icaos:)` — captures one JPEG, inserts N Catch rows (each with its own copy of the photo), and presents the new `MultiCatchReveal` full-screen sheet: magenta backdrop, staggered fan of up to 5 PokeCards with rarity holo, three-line combo receipt (Base / Combo (+pts) / Awarded), View-in-Hangar / Keep-spotting buttons. Combo multiplier ladder: 2→×1.5, 3→×2.0, 4→×2.5, 5+→×3.0 (exposed as `MultiCatchReveal.comboMultiplier(for:)` for testing). Single-catch path (`performAutoCatch` + tap-pin) is unchanged. `LockOnEngine.State` gained an `isLockedOrSticky` convenience for the suppression check.

- **Phase 2 — every other surface from the canvas, shipped 2026-05-20.** Card-reveal catch moment (`CardReveal.swift` + `CardBackView`) replaces the green flash; full-screen takeover with rarity bloom + light rays (rare+), entry-pill, holo PokeCard at `.lg`, tap to flip to the Pokédex back. Trophies (`Trophies.swift` + `TrophyView.swift` + `TrophiesScreen.swift`): 13 achievements with 4-tier ladders (bronze/silver/gold/platinum), 15 custom `Shape`-based hex-framed icons ported from the canvas SVGs, derived purely from Hangar contents via `TrophyProgressInputs`. Sets (`Sets.swift` + `SetsScreen.swift`): 7 Pokédex sets organized by `AircraftType`, 39 curated `PokeSetEntry` slots with locked-silhouette grid + completion pills. Rarity / Types reference (`ReferenceScreens.swift`): static doc surfaces explaining the 5 tiers + 7 types. Profile (`ProfileScreen.swift`): the gamification hub — `ProfileStats` aggregate (totalPoints = Σ basePoints, unique airframes, rare+ unique, longest slant km, per-rarity counts), identity hero + 4-stat row + rarity breakdown strip + horizontal recent-trophies row + quick links + section links. Map (`MapScreen.swift`): MapKit `Map` (iOS 17+ API) with one rarity-tinted pin per catch, legendary halo, rarity filter chips, auto-fit camera. Leaderboard / Share / Public hangar (`PublicScreens.swift`): mock anonymous-global leaderboard with the user injected by points; `ShareCardSheet` using `ImageRenderer` + `ShareLink`; placeholder public-hangar screen reachable from leaderboard rows. Settings (`SettingsScreen.swift`) + Notifications (`NotificationsScreen.swift`) with @AppStorage toggles for handle, public-hangar, rare-alerts, etc. (no real push delivery until backend). Onboarding (`OnboardingFlow.swift` + `RootView`): 4-step flow gated by `@AppStorage("tailspot.onboarding.completed")`. `TailspotApp` now hosts `RootView` so onboarding lands before AR on first launch. `ContentView` gained a `profileButton` next to the hangar/debug buttons, and `performAutoCatch` triggers `pendingReveal` (full-screen `CardReveal` sheet) instead of the old 900 ms green flash.

  **Where things live (Phase 2 file map):**
  - Game system: `GameSystem.swift` (Rarity / AircraftType / classifier — Phase 1), `Sets.swift`, `Trophies.swift`
  - Components: `BadgeViews.swift` (RarityBadge / TypeBadge / TagRow), `PokeCardView.swift`, `TrophyView.swift` (+ 15 icon shapes + HexShape)
  - Screens: `CardReveal.swift`, `TrophiesScreen.swift`, `SetsScreen.swift`, `ReferenceScreens.swift`, `ProfileScreen.swift`, `MapScreen.swift`, `PublicScreens.swift`, `SettingsScreen.swift`, `NotificationsScreen.swift`, `OnboardingFlow.swift`
  - Stats: `ProfileStats` lives in `ProfileScreen.swift`; `TrophyProgressInputs` + `Trophies.inputs(from:)` live in `Trophies.swift`; `PokeSets.status(of:against:)` + `PokeSets.progress(of:against:)` live in `Sets.swift`.

  **Don't refactor the v0 AR / catch flow further** — the next priorities (PLAN §9) are backend wiring and the multi-catch AR mechanic. Visual surfaces are largely settled; field-test before iterating further.

- **AR lock-on interaction.** Clean default view (just camera). Aim within ~80 px of a plane's projected position → yellow corner brackets close in for ~0.6 s → snap solid green with a label showing callsign / airline / make+model / altitude · speed. 2 s sticky-hold after target leaves. Tap the locked label → detail sheet. **Tap any visible plane** → pin the lock to it instantly (no acquisition delay; engine `forceLock`), with explicit-pin precedence over the center-driven heuristic. Tap the pinned plane again to unpin; tap empty sky to clear. State machine in `LockOnEngine.swift`; visuals + gestures in `ContentView.swift`.
- **Brand tokens (Phase A).** Every color and font in the SwiftUI views routes through `Brand.swift` — a single-file edit re-themes the whole app. FAA-aligned semantics: cyan brand accent (brackets, callsigns, wordmark, **lock indicator at all locked-ish states**), amber for caution (acquiring + true cautions), red for warnings (never as text on `bg.primary`). Horizontal brand lockup (airplane glyph + TAILSPOT in SF Mono) replaces the title in the Hangar nav. Spec: `docs/superpowers/specs/2026-05-18-tailspot-visual-identity-design.md`; plan: `docs/superpowers/plans/2026-05-18-visual-identity-phase-a.md`. **Field-tested 2026-05-18:** per Noah's call, the spec's magenta-for-tap-pin and green-for-locked were dropped — cyan owns the lock indicator from acquisition complete onward, whether reached via auto-lock or tap. The `Brand.Color.alertAdvisory` (magenta) and `Brand.Color.alertNormal` (green) tokens still exist but no longer appear in the AR view; reserve for future use (rare-aircraft tag, catch-confirmed flash).
- **Pinch-to-zoom.** Camera supports 1×–5× digital zoom via `AVCaptureDevice.videoZoomFactor`. The projection math reads the current zoom and divides the effective FOV (`baseHfov/zoom`, `baseVfov/zoom`) so lock brackets stay glued to planes as the user zooms in. A faint `2.0×` pill appears in the top-center while zoomed. Pinch gesture lives on a `Color.clear` background layer alongside the tap-to-ID `SpatialTapGesture`, both attached `.simultaneously` so they don't fight; the locked label's own tap (further up the Z-stack) still wins for label hits.
- **Catch flow v0.** "Catch this plane" button in `AircraftDetailView` inserts a `Catch` SwiftData row (icao24, callsign, model, manufacturer, **operatorName**, caughtAt, observer lat/lon, slant distance). `ModelContainer` set up in `TailspotApp`. Each tap is a discrete event; dedupe is a Hangar concern.
- **Hangar v1 (collection).** Tray glyph in the top-trailing corner of `ContentView` (with green count badge) opens `HangarView` as a sheet. Inset-grouped list of every `Catch`, sectioned by aircraft type (manufacturer + model) by default; segmented picker toggles to airline grouping (uses the `operatorName` column). **Catches sharing an icao24 collapse into one row** with a `×N` count pill; tap → read-only `CatchDetailView` of the most-recent catch (no live re-fetch — a catch from yesterday should look the same tomorrow). **Swipe-to-delete** with a confirm alert wipes every catch sharing that row's icao24. Grouping + dedupe logic is a pure function in `HangarGrouping.swift` (`HangarRow` collapses by icao24); 9 dedicated tests.
- **Aircraft type lookup.** Per-icao24 fetch from OpenSky's `/metadata/aircraft/icao/{icao24}` via `OpenSkyClient.aircraftMetadata`, lazily on lock-acquisition or detail-sheet appearance. In-memory LRU `MetadataCache` (cap 500) dedups; 404s are cached as known-misses.
- **Live/Mock ADS-B toggle** (in the debug overlay). 5 hand-picked mock aircraft with metadata fixtures (BOEING 737-800 / AIRBUS A320 / etc.); the 5th has no metadata, intentionally, so the cache-miss path is field-testable.
- **Heading-accuracy color cue.** Heading line in the sensor readout turns red when `CLHeading.headingAccuracy > 15°`.
- **Visibility filter.** AR overlay AND debug aircraft list both show only aircraft above the horizon AND within 30 km slant distance. Bbox fetch is still 50 km — out-of-range planes are hidden, not dropped.
- **Debug overlay, hidden by default.** Wrench glyph in the top-right toggles the sensor readout (top) and nearby-aircraft list (bottom). The LIVE/MOCK toggle lives in the sensor readout.
- **Forward-extrapolation** of ADS-B positions to "now"; **1 Hz re-annotation** for smooth bracket tracking; **OAuth2 client-credentials** auth against OpenSky (4000 credits/day registered tier); **429-aware backoff**.
- **Replay recorder v0.** Tap the **Record session** row in the debug overlay (just under the LIVE/MOCK row) — a 1 Hz loop captures one `tick` per second containing the full sensor state (GPS + heading + pitch/roll/yaw + camera elevation) plus a snapshot of every currently-visible aircraft. Lines append to `Documents/replays/replay-<utc>.jsonl` on the device. The line format is documented in `ReplayRecorder.swift`; retrieve via `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.landesberg.Tailspot --source Documents/replays --destination ./replays`. Round-trip tests + recorder lifecycle tests live in `ReplayRecorderTests.swift`.
- **Replay analyzer v0.** `ReplayAnalyzer` reads a recorded `.jsonl` (or an in-memory `[ReplayEvent]`) and runs each tick back through the same annotation + visibility + lock-on logic the live app uses, emitting one `ReplayTickReport` per tick (per-aircraft bearing/elevation/slant + visibility flag + screen projection, plus the closest-to-center icao24 and the lock-on engine state after the tick). The annotation logic itself lives on `ObservedAircraft.annotate(_:observer:now:)` — both the live `ADSBManager.reAnnotate` and the analyzer call it, so engine tweaks land in both paths simultaneously.
- **Replay report viewer.** `ReplayReport.describe()` formats the analyzer output as a multi-line monospaced String (header + per-tick blocks with observer pose, sorted aircraft, closest-to-center marker, lock state). `ReplayReportView` is a SwiftUI sheet that loads + analyzes + displays the report. The debug overlay has an "Analyze last recording" row backed by `ReplayRecorder.mostRecentRecording()` (most-recently-modified `.jsonl` in `Documents/replays/`); greyed out when no recordings exist.
- **Planespotters photo integration.** `PlanespottersClient` (`nonisolated struct`, `Sendable`) fetches photo metadata by icao24 from `https://api.planespotters.net/pub/photos/hex/{icao24}` (unauthenticated; misses return empty array, not 404). **Required: a descriptive `User-Agent` header** — Planespotters returns HTTP 403 to generic `URLSession` UAs with an instructive error body. Tailspot sends `Tailspot/0.1 (+https://github.com/landesbergn/tailspot)` (see `PlanespottersClient.defaultUserAgent`). Returns `PlanePhoto?` (thumbnailLargeURL, thumbnailURL, photographer, Planespotters link). Per TOS: no disk caching — image bytes load via `AsyncImage` which uses iOS's URLCache; API response memoized in `PlanespottersCache` actor (cap 200, keyed lowercase icao24, per-session only). `CatchDetailView` (which now takes a `HangarRow`, not a single `Catch`) renders a hero photo section above Identity; hidden when no photo. Attribution: `"© [photographer] · planespotters.net"` text-button opens Safari via `UIApplication.shared.open(photo.link)`. `PlanespottersClient.shared` singleton shares the cache across all views.
- **CatchDetailView shows full catch history.** Now takes a `HangarRow` (not just one `Catch`). Sections: photo (live, hidden if Planespotters has no record) → Identity (from the most-recent catch — callsign, icao, type, operator) → "Caught N times" listing every catch event chronologically with date+time, slant distance, and observer lat/lon. Tap the row in Hangar drills into this view.
- **~164 unit tests** in `TailspotTests/` covering geometry, OpenSky decoding, annotation, sort, error handling, extrapolation, visibility predicate, screen projection, aircraft-metadata decoding, MetadataCache LRU+miss-as-hit semantics, ADSBManager metadata-cache-and-fallback, SwiftData Catch persistence (including the operatorName default, **classifier-driven rarity/type snapshotting at insert, classifier backfill for nil legacy fields, explicit init-time rarity overriding classifier**), LockOnEngine state transitions (idle/acquiring/locked/sticky/**forceLock**), HangarGrouping (both modes, fallbacks, sort order, empty input, whitespace folding), the replay format (JSONL round-trip incl. **tapPin/unpin**, partial-line tolerance, recorder lifecycle, Aircraft→AircraftSnapshot conversion), the replay analyzer (empty input, session-start header, GPS-less tick skips annotation, on-ground drop, visibility filter, lock acquires → locks → goes sticky across multi-tick sequences, file-based analyze round-trip, `describe()` formatter, **tap-pin forces lock, unpin falls back, dead-pin falls back to center-driven**), `closestTargetIcao24` (center-default, empty zone returns nil, tap point picks nearest plane, empty-sky tap returns nil, narrow FOV/zoom pushes off-axis planes out of zone), BrandColorHexTests (hex helper round-trip), **PlanespottersClientTests** (wire-format decode, empty-array miss, PlanePhoto value construction, bad-URL guard, cache notFetched-vs-hit-nil), **AircraftClassifierTests** (legendary VC-25 + SR-71 + B-2, epic A380 + 747-8, rare 787 + A350 + 777 + 747 + C-130 + KC-, uncommon A220 + 737 MAX, common 737NG + A320 + E175 + Cessna 172, operator gate any-of semantics, case-insensitive matching, nil-input defaults, Embraer-with-no-model regional hint, determinism — same input same output, plus a regression test that every entry from the legacy `HangarRarity.rareModelTokens` list still resolves to rare-or-higher), and **GameSystemEnumTests** (base-points ladder, monotonic ordinals, every type has non-empty display fields, rarity rawValue round-trip).

**Deliberately not yet built (from the design canvas in `design/`):** the card-reveal catch moment, multi-catch 3-fan, Pokédex card-flip back, Trophies screen + custom hex-frame illustrations, Sets / Pokédex set-detail, anonymous-global leaderboard, share card, public-hangar visit, world map of catches, Profile / Settings / Notifications screens, 4-step onboarding + handle setup, Rarity / Types reference screens. **Other deliberately-not-built items:** backend, ARKit drift correction, visual confirmation (CV/ML on the camera feed), origin/destination route info, device-side `os.Logger` capture (only system-emitted lines reach `bin/log-tail` today; see PLAN.md §9 #4). See PLAN.md §9 for the prioritized backlog. Don't try to "fix" what isn't built.

## Working model

- Solo developer (Noah) with no prior iOS experience. Claude writes code; Noah runs it on his iPhone 16 (iOS 26.3.1) and reports back.
- Field-test location: Berkeley/Oakland CA — under SFO/OAK approach corridors, dense ADS-B coverage. OpenSky free-tier MLAT is excluded, so most small GA, helicopters, and military traffic are invisible. Expect this.
- Preference: **explain-as-we-go.** When introducing a Swift / SwiftUI / iOS pattern Noah hasn't seen, narrate it in the commit message or inline comments. He is learning iOS in parallel with shipping.
- Pick the simplest viable iOS choice at every fork: SwiftUI over UIKit, SwiftData over Core Data, Apple-native libs over third-party, no Cocoapods/SPM deps yet.

## Build and run

Two paths:

- **Claude-driven (default this session and after):** `bin/deploy` — builds via `xcodebuild`, installs via `xcrun devicectl`, launches on Noah's paired iPhone wirelessly. See "Remote-deploy loop" below for details and rules. There is no CI; Claude runs the unit-test suite before deploys.
- **Manual (Noah's IDE workflow):** Xcode `⌘R` against the connected iPhone. Useful when you want Xcode's debugger / live `os_log` console.

The iOS Simulator cannot provide real GPS, compass, or camera, so the iPhone is required for any runtime / field testing.

### Remote-deploy loop

For tighter iteration than ⌘R-in-Xcode, the repo ships a Bash-driven loop:

- `bin/deploy [--no-build] [--no-launch] [--dry-run]` — builds via `xcodebuild`, installs via `xcrun devicectl`, launches the app on Noah's paired iPhone. The device UDID, scheme, and paths come from `tools/deploy/config.sh`; override locally via `tools/deploy/config.local.sh` (gitignored). Wireless dev pairing must already be active (confirm with `xcrun devicectl list devices`). `--launch` is implicit; use `--no-launch` to install without auto-starting.
- `bin/log-tail [-n N] [-f]` — reads `~/Library/Logs/tailspot/device.log`. **Currently a no-op stub:** the host macOS `log` binary on this machine does not accept `--device <UDID>`, so `bin/log-start` exits 0 with a notice and no streaming runs. Fix planned (PLAN.md §9 #3); until then, inspect runtime behavior via Xcode's Console or `os_log` viewer.
- All app-side logging flows through `Log.swift` (subsystem `com.landesberg.tailspot`).

Rules:
- **Run unit tests before `bin/deploy`** when touching testable code. The loop will happily deploy a broken build.
- If `xcrun devicectl install` fails (e.g., "developer disk image could not be mounted"), surface the message and stop — don't silently retry. Most such failures need Noah's action: unlock the phone, re-pair via USB, or open Xcode once to mount the DDI.
- The device UDID in `tools/deploy/config.sh` is Noah's. A different developer overrides via `tools/deploy/config.local.sh`.

### Doc-staleness Stop hook

`.claude/settings.json` registers a `Stop` hook that runs `bin/doc-staleness-check` at the end of each Claude turn. The check:

1. Looks for unpushed commits on `main` (`git log origin/main..HEAD`).
2. If any exist and **none** of them touched `CLAUDE.md` or `PLAN.md`, emits `{"decision":"block","reason":"..."}` so the turn doesn't end — Claude is asked to refresh the docs (`Current state` in CLAUDE.md and §9 in PLAN.md) and push before stopping.
3. Otherwise silent.

The point: a session can be cleared at any time and the next agent reads docs that match what's on disk. The script self-locates via `git rev-parse --show-toplevel`, so it works regardless of the cwd the hook fires from. `.claude/settings.json` itself is gitignored (everything under `.claude/` is) — to make this hook follow the repo to other machines, add `!.claude/settings.json` to `.gitignore` and commit.

### OpenSky credentials

For LIVE mode the app authenticates via OAuth2 client-credentials. OpenSky's anonymous tier (400 credits/day) is exhausted in ~1.3 hr at the 20 s default poll rate; the registered tier (4000 credits/day) is comfortable for testing.

**Canonical path (post-TestFlight):** edit `ios/Tailspot/Tailspot.secrets.xcconfig` (gitignored) with your OpenSky `client_id` + `client_secret`. The committed `Tailspot.xcconfig` `#include?`s it, which feeds Info.plist via `$(OPENSKY_CLIENT_ID)` substitution; `OpenSkyClient.init` reads them from `Bundle.main.infoDictionary` at runtime. Same file Xcode Cloud reads (via `ci_post_clone.sh` writing it from workflow env vars).

`OpenSkyClient.init`'s resolution order is **explicit → env vars → Bundle**. Env vars from the user-only xcscheme still work, but **prefer the xcconfig path**: a stale xcscheme value will silently win over a fresh secrets file and waste a debugging hour (this happened once already this session). Single source of truth = the xcconfig.

OpenSky's OAuth endpoint is on the **older Keycloak path with the `/auth/` prefix** — `https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token`. The modern path without `/auth/` returns 404. This is empirically verified and documented in a comment in `OpenSkyClient.swift`. The API docs are at https://openskynetwork.github.io/opensky-api/rest.html.

## Tests

Unit tests live in `ios/Tailspot/TailspotTests/` and use Swift Testing (`@Test`, `#expect`, `@Suite`) — not XCTest. UI tests in `TailspotUITests/` exist as Xcode template scaffolding but are slow (~3 min on cold sim) and not part of the regular workflow.

**Claude runs the unit tests after substantive code changes** with:
```
xcodebuild test \
  -project ios/Tailspot/Tailspot.xcodeproj \
  -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests
```
First run is slow (~3 min, sim cold-boot). Cached subsequent runs are ~30–60 s. Run before committing whenever you touch testable code (Geo, Aircraft decoding, ADSBManager, OpenSky client, or anything they depend on).

The current suite (82 tests) covers:
- `GeoTests`: distance, bearing (cardinal + 0/360 sweep), elevation, project round-trip, **screenPosition** (target straight ahead → center, out-of-FOV → nil, 0/360° wraparound from high & low headings, elevation above center).
- `AircraftDecodingTests`: full positional-JSON decode, null-position throws, FailableDecodable swallows bad entries, callsign trim, geo-vs-baro altitude precedence, all-altitudes-null → 0.
- `ADSBManagerTests`: annotation correctness, on-ground filtering, sort-by-slant-distance, error → `lastError` without crashing, success clears previous error, `lastFetched` timestamp, mock-source integration produces 5 aircraft, rate-limit error surfaces as backoff message, forward-extrapolation (moves along track / no-ops when timestamp/velocity missing / age-too-large), visibility predicate (above-horizon-and-close, below horizon, exactly-horizon, too-far, edge-of-range).
- `AircraftMetadataDecodingTests`: full /metadata/aircraft/icao payload, tolerates missing/null optionals, throws on missing icao24.
- `MetadataCacheTests`: not-fetched vs hit-nil-miss distinction, LRU eviction at cap.
- `ADSBManagerMetadataTests`: cache consultation, dedupe of repeated lookups, errors don't poison the cache (use `CountingMetadataSource` fixture).
- `CatchTests`: SwiftData `Catch` insert/fetch (including `operatorName`), duplicates allowed, nil-optional metadata tolerated, `operatorName` defaults to nil when omitted. Uses `ModelConfiguration(isStoredInMemoryOnly: true)` so tests don't touch disk.
- `LockOnEngineTests`: full state-machine coverage (idle / acquiring / locked / sticky) and `acquisitionProgress` ramp.
- `HangarGroupingTests`: pure-function grouping for the Hangar view — both modes (aircraft type, airline), fallback chain (manufacturer-only / model-only / Unknown), Unknown bucket sorts last, rows within a group sort most-recent-first, empty input → empty array, whitespace trimming and empty-string folding for both modes.
- `ReplayRecorderTests` + `ReplayJSONLTests`: JSONL one-line-per-event encoding, round-trip equality for session-start + ticks, partial-line tolerance (trailing line with no newline is dropped, not thrown), blank-line tolerance, recorder writes a session-start automatically, eventCount bumps, start-twice throws `alreadyRecording`, stop is idempotent, `recordTick` no-ops when not recording, `Aircraft → AircraftSnapshot` field preservation.
- `ReplayAnalyzerTests`: empty events → empty report, session-start populates header, tick without GPS skips annotation, visible aircraft annotates + acquires lock on first tick, below-horizon/far aircraft fails visibility filter, on-ground aircraft is dropped entirely, lock graduates acquiring → locked after `acquisitionDuration`, lock → sticky when target disappears, file-based `analyze(fileURL:)` round-trips through `ReplayRecorder` + `ReplayJSONL`.
- `ClosestTargetTests`: standalone tests for `closestTargetIcao24` — center default picks nearest, all-off-axis returns nil, `at: tapPoint` overrides center, tap-in-empty-sky returns nil, narrow FOV (zoom > 1) pushes off-axis planes out of the lock zone.

`ADSBManager.init(liveSource:mockSource:)` has defaulted params so production uses real sources and tests substitute a `FixedSource` fixture. **Do not break this default-init shape** — `ContentView`'s `@StateObject private var adsb = ADSBManager()` depends on it.

## Credentials: xcconfig is canonical, scheme env vars are a footgun

**Canonical path (post-TestFlight):** `ios/Tailspot/Tailspot.secrets.xcconfig` (gitignored) holds the real OpenSky values; the committed `Tailspot.xcconfig` `#include?`s it; Info.plist substitutes `$(OPENSKY_CLIENT_ID)` / `$(OPENSKY_CLIENT_SECRET)`; `OpenSkyClient.init` reads them from `Bundle.main.infoDictionary` at runtime. Same file Xcode Cloud writes via `ci_post_clone.sh` from workflow env vars. **One source of truth.**

**The xcscheme path still works but is deprecated** — `OpenSkyClient.init` checks `ProcessInfo.environment` after explicit creds but before the bundle. The historical pattern was to add env vars to a user-only xcscheme. **Don't.** A stale xcscheme value silently wins over a fresh secrets file (this bit us once already this session — fresh xcconfig creds didn't work because the user had an old xcscheme value still set from earlier). If you must use the scheme path for dev, keep one source populated, not both.

Rules that still apply:

1. **The committed shared scheme is bare** — no env vars. `.gitignore` allows exactly one shared scheme file (`Tailspot.xcscheme`) via a `!` exception so `xcodebuild` works on fresh clones; every other `*.xcscheme` is ignored, but **gitignore does NOT protect already-tracked files**. If you ever do touch the shared scheme, **always `git diff` the staged set before committing**. Look for `OPENSKY_CLIENT_SECRET`, `EnvironmentVariable`, or `paste-your-` (the placeholder text in `Tailspot.secrets.example.xcconfig` — finding this in a diff means you staged the example template, not the real secrets file, which is fine; finding the real secret means abort).
2. **If a secret leaks**: tell Noah immediately, rotate on OpenSky's API console (don't wait), update `Tailspot.secrets.xcconfig` locally, push a new build to Xcode Cloud (which picks up the new env vars). Both prior leaks in this repo's history are still recoverable from GitHub's dangling-objects cache; rotation is the actual mitigation, not history rewriting.
3. **Rotation warns testers.** The secret is baked into shipped binaries; rotating it OAuth-fails every old TestFlight build until the tester updates. Communicate ahead of any rotation (see Workflow notes).

## MainActor default isolation (Xcode 26)

The Xcode 26 app template sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Every type, extension, and global is implicitly `@MainActor` unless explicitly marked otherwise. New in Xcode 26; affects every file we add.

Convention in this repo:

- **UI / state-holding types stay MainActor.** `LocationManager`, `MotionManager`, `ADSBManager`, SwiftUI views — all rely on @Published mutations being main-thread-safe by construction.
- **Pure data, geometry, and Sendable cross-actor types are explicitly `nonisolated`.** `Aircraft`, `FailableDecodable`, the `ADSBSource` protocol, `OpenSkyClient`, `MockADSBSource`, `Geo` and its private number-extension all carry `nonisolated`.
- **Extensions get their own isolation.** `nonisolated struct Aircraft` does NOT propagate to `extension Aircraft: Decodable {}` — that extension also needs `nonisolated extension Aircraft: Decodable`. Same for any other extensions on nonisolated types.

If you see a warning like *"main actor-isolated conformance of X to Y cannot be used in nonisolated context"* — the fix is almost always `nonisolated` on the extension.

## Architectural baseline

These decisions are settled (PLAN.md §1) and shouldn't be relitigated without a real reason:

- **Plane identification is geometric, not visual.** Inputs are GPS + true-north heading + camera elevation + ADS-B aircraft positions; the ID is angular correlation, not ML/CoreML object detection. **However**, per PLAN.md §1.1a, the *AR reticle placement* may eventually use CV (Vision + YOLOv8 COCO airplane class) to lock onto the actual plane image rather than the predicted position. Deferred but planned.
- **Backend from day 1**, not optional — needed for ADS-B caching, anti-cheat, sync, leaderboards. **Not yet built.** Phase 1.
- **Disambiguation is a v1 design problem**, not polish: when multiple aircraft fall within the angular tolerance, render an overlay tag for *each* and let the user tap one. Already in code.
- **OpenSky free tier** is the v1 ADS-B provider — Tailspot is free with no monetization, so OpenSky's non-commercial terms fit. The `ADSBSource` protocol abstracts this; swapping to a paid provider is one file's worth of work.
- **Photos:** commissioned illustrated cards (aircraft type × airline livery), not real photos. Sidesteps licensing.

## Key code patterns

These are the load-bearing patterns in the current codebase. Understand them before refactoring.

### ADSBSource protocol + injectable manager

`ADSBManager.init(liveSource: ADSBSource = OpenSkyClient(), mockSource: ADSBSource = MockADSBSource())` lets the UI use real sources and tests inject fixtures. The `useMock` `@Published` flag switches between them at runtime; flipping it kicks an immediate refresh via `refreshNow()`.

### Split fetch from annotation

`ADSBManager` runs **two** concurrent Tasks:

1. **`pollTask`** — every `pollInterval` (20 s default), calls `source.aircraftInBbox(...)` and stashes the result in private `rawAircraft`. Backs off exponentially to a 120 s cap on `ClientError.rateLimited` (429).
2. **`reAnnotationTask`** — every `reAnnotationInterval` (1 s default), re-reads `rawAircraft`, forward-extrapolates each plane via `Aircraft.extrapolatedPosition(at: Date())`, recomputes bearing/elevation/distance from the current observer location, publishes `observed`.

This is what makes AR reticles glide smoothly between fetches. Keep these decoupled — don't merge them back into one loop.

### Pitch vs. camera elevation

`CMAttitude.pitch ≈ +π/2` when the phone is held upright in portrait, not 0. Camera elevation above the horizon is `90° − pitch`. Wrapped in `MotionManager.cameraElevationDeg`. **Never pass raw `motion.pitch` into projection math** — always `motion.cameraElevationDeg`. Both `Geo.screenPosition` and `ObservedAircraft.screenPosition` take `cameraElevationDeg`, not `phonePitchDeg`, for this reason.

### LocationManager `headingOrientation`

Pinned to `.portrait` in `LocationManager.init` so true-north heading is reported relative to a stable reference even if iOS rotates the UI. Don't remove this line.

### Visibility filter

`ObservedAircraft.isLikelyVisibleToObserver` (`elevationDeg > 0 && slantDistanceMeters < 30_000`) gates BOTH the AR overlay AND the bottom list in `ContentView`. (Earlier versions left the list unfiltered as a debug view; the 30 km cap was tightened from 100 km after field testing.) If a user reports "missing plane labels," check whether the plane is below horizon or past 30 km first — that's the filter doing its job, not a bug. Tune `maxVisibleDistanceMeters` to change.

### CMMotion / CLLocation / AVCapture concurrency

- Sensor wrappers (`LocationManager`, `MotionManager`) are `ObservableObject` classes with `@Published` properties; owned by a SwiftUI view via `@StateObject`.
- A file that uses `@Published` / `ObservableObject` but does **not** `import SwiftUI` must `import Combine` explicitly — SwiftUI re-exports Combine but pure model files don't get it transitively.
- All `@Published` mutations must happen on the main thread. Background callbacks (CMMotion queue, AVCapture queue, URLSession completion) hop via `DispatchQueue.main.async` before mutating state. `ADSBManager` sidesteps this with `@MainActor` on the class.
- Camera (`AVCaptureSession`) configuration and `startRunning` run on a dedicated serial `DispatchQueue` — never on main.
- The motion-manager reference frame is `.xArbitraryZVertical` (gravity-aligned only). True-north alignment comes from `CLLocationManager`'s heading. Revisit when ARKit lands.

### Logging through `Log.swift`

All app-side logging flows through `Log.swift`, a thin enum of `os.Logger` instances grouped by category:

```swift
Log.openSky.info("token cache hit")
Log.adsb.error("metadata lookup failed for \(icao, privacy: .public)")
Log.ui.notice("camera setup failed")
```

The subsystem is always `"com.landesberg.tailspot"` — `bin/log-tail` predicates on this so the Mac sees a filtered stream instead of the device's full firehose. Use `privacy: .public` on string interpolations whose contents you actually want to read in `log` output (Apple redacts string interpolations by default).

**Do not `print(...)` from app code.** Existing `print` calls were migrated; new ones won't be visible in the deploy-loop logs.

### OpenSky OAuth token caching

`OpenSkyClient` uses `OSAllocatedUnfairLock<CachedToken?>` for its token cache so the class can be `Sendable` without an `actor`. Tokens refresh when within 30 s of expiry. Don't replace this with an actor unless you also rework the `ADSBSource` protocol's isolation.

### Metadata lookup + cache

Per-icao24 metadata (manufacturer / model / registration / operator) is fetched via `OpenSkyClient.aircraftMetadata(icao24:)` and stored in a per-session `MetadataCache` actor (cap 500, bounded LRU). `ADSBManager.metadata(for:)` is the single entry point: cache hit → return; miss → fetch + cache (including `nil` 404 results as known-misses, so we don't re-fetch them). Transport errors are NOT cached so a later tap retries. Consumed by `AircraftDetailView.task` and `ContentView.task(id: lockOn.state.targetIcao24)`.

### Lock-on state machine

`LockOnEngine` is a pure state machine (`idle` / `acquiring` / `locked` / `sticky`) — no SwiftUI, no screen geometry. `ContentView` runs a 30 Hz `TimelineView`, computes `closestTargetIcao24(...)` against the visible aircraft each frame, and feeds it into `engine.update(...)`. Visuals (yellow → green corner brackets + identification label) read directly from `engine.state` and `engine.acquisitionProgress(now:)`. Tuning knobs: `engine.acquisitionDuration` (0.6 s), `engine.stickyHoldDuration` (2.0 s), and the `lockZoneRadius` argument to `closestTargetIcao24` (80 px). Tests live in `LockOnEngineTests.swift` and cover every transition.

### Catch flow + SwiftData

`Catch` is a v1 `@Model` class with a flat schema (icao24, callsign, model, manufacturer, `operatorName`, caughtAt, observerLat/Lon, slantDistanceMeters). `operatorName` was added in Hangar v0; existing rows from before that field shipped come back as nil (SwiftData lightweight migration). Duplicates of the same icao24 are explicitly allowed — dedupe is a Hangar concern, not a model concern. `ModelContainer` is created in `TailspotApp.init` and injected via `.modelContainer(_)`; views consume via `@Environment(\.modelContext)`. Tests use `ModelConfiguration(isStoredInMemoryOnly: true)` so the suite doesn't touch disk.

### Hangar collection

`HangarView` is a sheet presented from `ContentView` (tray glyph in the top-trailing corner; green count badge fed by a lightweight `@Query` in ContentView). Inside the sheet a `@Query(sort: \Catch.caughtAt, order: .reverse)` powers an inset-grouped `List`, sectioned via `HangarGrouping.group(_:by:)` — a **pure function** in its own file so the grouping logic is unit-testable without spinning up SwiftUI. The grouping segmented picker lives inline as the first list section (not the toolbar), so the nav title can keep showing the catch count.

Two grouping modes today: `.aircraftType` (manufacturer + model) and `.airline` (operatorName). Each mode has its own fallback chain ending in a single "Unknown" bucket that always sorts to the end. Row subtitles deliberately show whichever of (operator, type) ISN'T already in the section header so rows add information instead of restating it.

`CatchDetailView` is a **read-only snapshot** — no live re-fetch of metadata or position. A catch is a frozen moment; tomorrow's metadata/distance must not retroactively rewrite it. v0 has **no dedupe** (each tap = each row in its section) and **no delete UI**; both are deferred. If catches grow to hundreds, the per-body re-grouping in `HangarView.groupedList` will want memoization.

### Replay recorder

`ReplayRecorder` is a `@MainActor ObservableObject` that writes JSONL to `Documents/replays/replay-<utc>.jsonl`. One `session-start` header line, then one `tick` line per recorded moment. JSONL (not a single JSON array) so a crash mid-write leaves a still-decodable file — `ReplayJSONL.decode(_:)` drops a trailing partial line silently.

`ReplayEvent` is a discriminated union: `case sessionStart(SessionStart)` and `case tick(Tick)`. Wire format keeps the `type` discriminator flat with the payload fields (`{"type":"tick", "timestamp": ..., "sensor": ..., "aircraft": [...]}`) so individual lines stay readable by eye. Bump `ReplayRecorder.schemaVersion` when an existing field's meaning changes.

`AircraftSnapshot` is **separate from `Aircraft`** even though it carries the same fields. Aircraft has a positional OpenSky-shaped `Decodable`; the replay format wants stable named-key Codable. Keeping them separate means future OpenSky decoder changes don't ripple into recorded files.

`SensorSnapshot.zoomFactor` is `Double?` (optional) for back-compat — files recorded before camera zoom shipped don't have the field; the analyzer treats nil as 1.0.

**Tap-pin events ARE captured.** `ReplayEvent.tapPin(TapPin)` and `ReplayEvent.unpin(Unpin)` get written between ticks whenever the user tap-pins or clears. The analyzer sorts all events by timestamp (so a future merged or concatenated input source can't reorder them at the millisecond level), walks them in order, maintains a running `pinnedIcao`, and on `.tapPin` calls `engine.forceLock(...)` so the replay's lock-on path matches live behavior. Pinned plane no longer visible → analyzer's per-tick `pinStillVisible` check falls back to the center-driven target (same as ContentView).

ContentView drives the recorder via a `.task(id: recorder.isRecording)` loop that fires `recordReplayTick()` once per second while recording, then exits when the user taps **Record session** off. The 1 Hz cadence is enough to drive lock-on / projection validation; visual-confirmation work that needs per-frame samples will want a faster tick (or a separate stream).

Retrieve recorded files from the phone with: `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.landesberg.Tailspot --source Documents/replays --destination ./replays`. (The recorder doesn't ship a UI export today — `Documents/` is the universal escape hatch.)

### Camera zoom + tap-to-ID

Two coupled AR interactions:

- **Zoom** is digital (`AVCaptureDevice.videoZoomFactor`), 1×–5× capped in `CameraPreview.zoomRange`. ContentView owns the `zoom` `@State`, pipes it to `CameraPreview`, and divides `baseHfovDeg / baseVfovDeg` by it when computing screen positions. `PreviewView.setZoom` guards on `lastAppliedZoom` so the constant `updateUIView` calls (driven by the 30 Hz TimelineView) don't thrash `device.lockForConfiguration`.
- **Tap-to-ID** sets `pinnedIcao` and immediately `forceLock`s the engine onto the tapped plane — no 0.6 s acquisition delay, because the user explicitly pointed. `closestTargetIcao24` grew an `at: CGPoint?` parameter (default = screen center); the tap handler calls it with the tap location and a generous 100 px radius. Tap rules:
  - empty sky → clear pin (back to center-driven lock)
  - same plane as current pin → toggle off
  - different plane → switch pin + force-lock
- Pin housekeeping: `.onChange(of: lockOn.state.targetIcao24)` clears the pin when the engine moves off it (sticky-expired, or center-driven switched). The TimelineView body checks `pinStillVisible` before feeding the pin into `engine.update`, so a stale pin can't lock the bracket-finder onto a missing icao.

Pinch + tap share a `Color.clear` background layer via `.gesture` + `.simultaneousGesture`. The locked label's `.onTapGesture` (further up the Z-stack) still wins for taps that land on it. `lockZoneRadius` stays in pixels (UI affordance, not angular tolerance) — at high zoom, the same 80 px covers a tighter angular wedge, which is exactly the disambiguation tap-to-ID needs.

`baseHfovDeg` (56°) and `baseVfovDeg` (72°) are approximations for the iPhone 16 main wide camera in portrait. Refine by querying `AVCaptureDevice.activeFormat.videoFieldOfView` if drift becomes visible.

### Replay analyzer

`ReplayAnalyzer` is the offline-replay side. Pure-Swift `@MainActor struct` with three tuning knobs (`screenSize`, FOV degrees, `lockZoneRadius`) and one method: `analyze(_: [ReplayEvent]) -> ReplayReport` (or `analyze(fileURL:)` for the file shortcut). It walks events in order, builds a fresh `LockOnEngine`, and feeds each tick through:

1. Reconstruct observer `CLLocation` from the sensor row (nil if no GPS fix yet — those ticks get an empty `aircraft` array).
2. For each aircraft snapshot, `ObservedAircraft.annotate(_:observer:now:)` (the same helper `ADSBManager.reAnnotate` uses) computes bearing/elevation/slant.
3. Filter by `isLikelyVisibleToObserver`.
4. Project each visible plane to screen, call `closestTargetIcao24(...)`, drive the lock-on engine.
5. Emit one `ReplayTickReport` per tick, including the engine state after.

Why this design: when you change projection math, visibility cutoffs, or lock-on tuning, the live app picks it up *and* recorded sessions re-analyze with the new behavior. No copy-paste between live and replay paths. The "no human-readable summary yet" gap (PLAN §9 #3 follow-up) is the next thing to fill — the structured report is already accurate.

### Debug overlay toggle

The sensor readout and aircraft-list panels are hidden by default; a wrench glyph in the top-right corner toggles them via `@State var showDebug`. The LIVE/MOCK source toggle lives inside the sensor readout — so it's only reachable when debug is on. Field-testing UI stays clean.

## Repository layout

See PLAN.md §8 for the file-by-file layout. Quick highlights:

- `PLAN.md` — product + technical plan
- `CLAUDE.md` — this file
- `ios/Tailspot/Tailspot.xcodeproj/xcshareddata/xcschemes/Tailspot.xcscheme` — the **only** shared scheme; gitignored from accidental modification. Read "Credentials and the shared-scheme trap" before editing this file or running `git add ios/`.
- `ios/Tailspot/Tailspot/` — Xcode project source. Uses **Xcode 16 synchronized folders**: any `*.swift` dropped into this directory is automatically added to the Xcode project. No manual "Add Files to Project" step.
- `backend/`, `shared/`, `tools/replay-harness/` — planned (PLAN.md §8); not created yet.

## Permission strings

`NSCameraUsageDescription` and `NSLocationWhenInUseUsageDescription` live in the target's **Info** tab in Xcode (Custom iOS Target Properties), not in any source file under version control. Adding a new permission requires a manual Xcode UI step — Claude cannot add them via file edits. Flag it explicitly when needed.

## Workflow notes

**Now that TestFlight is shipping to real testers** (since 2026-05-26), `main` is a tester-facing branch: any push there can be picked up by the next Xcode Cloud build and installed on a tester's phone. The rules below changed accordingly.

- **`main` is shippable.** Don't push WIP. For changes that take more than a day, work on a feature branch and merge to main only when the change is tested locally. Single-commit fixes can go to main if tested first.
- **Build numbers auto-bump in CI.** `ios/Tailspot/ci_scripts/ci_pre_xcodebuild.sh` rewrites `CURRENT_PROJECT_VERSION` to match `CI_BUILD_NUMBER` for every Xcode Cloud archive. **Don't touch `CURRENT_PROJECT_VERSION` in `project.pbxproj` manually** — the committed value stays at `1`; CI changes it per-build.
- **Bump `MARKETING_VERSION` deliberately.** Edit `project.pbxproj` to go `0.1.0 → 0.1.1` for a bugfix batch, `0.2.0` for a new feature surface, etc. Bump this for any TestFlight build that introduces user-visible changes you want testers to notice in the version string. Build number stays auto-incrementing.
- **Run tests before pushing.** `xcodebuild test ...` (see Tests section). When touching Geo / Aircraft / ADSBManager / OpenSky / Mock / their tests, a green local run is non-negotiable — failing tests waste a 5-15 minute CI cycle.
- **Inspect `git diff --cached` before every commit** for `OPENSKY`, `client_secret`, or `EnvironmentVariable` strings. If you see them, abort and fix the scheme before committing. Two leaks in this repo's history already.
- **SwiftData migrations stay lightweight.** Once testers have catches, every model change must be additive (new optional fields with defaults). Breaking schema changes lose tester data. If you ever need a breaking change, bump model version explicitly with a custom migration.
- **Don't rotate OpenSky creds without warning testers.** The secret is in the shipped binary; rotating it OAuth-fails every old TestFlight build until the tester updates. They'll see "API limit" forever. Communicate ahead of rotations. The real fix is the backend proxy (PLAN.md §1).
- **Watch crash logs.** App Store Connect → Tailspot → TestFlight → Crashes aggregates them from real testers — free diagnostic surface, check after every TestFlight build.
- **Settings → bottom of page shows the version + build, tap to copy.** When a tester reports a bug, ask them to tap the footer in Settings; they paste `Tailspot 0.1.1 (build N)` directly into the report.
- **Don't force-push to `main` without explicit user authorization.** The auto-mode classifier will deny it. If a leak requires history rewriting, surface the request to Noah with the trade-offs spelled out and let him decide.
- **Don't commit credentials in any form** — not in `.swift` files, not in `.xcscheme` files, not in plist values, not in commit messages, not in `Tailspot.secrets.xcconfig` (gitignored, but verify it's not staged before committing).

## Open questions still on the table

PLAN.md §6 lists deferred questions with working defaults: photo strategy (illustrated cards), privacy posture (location-when-in-use), launch region (US + Western Europe), backend hosting (Fly.io + Postgres). Don't promote a default to a real decision without asking Noah.

## Where to pick up

PLAN.md §9 is the authoritative backlog. **As of 2026-05-26, TestFlight v0 is live** — internal testers can install Build 11+ (the first build with the CFBundleVersion-bump CI script working end-to-end). The app icon is the B-lockon concept; Hangar glyph is SF Symbol `airplane.path.dotted`; mock surfaces have `ComingSoonBanner`s; debug wrench is gated to Debug builds; Settings shows a tap-to-copy version footer. See the Current state entry at the top.

Earlier landings (left for context): full design-canvas port (Trophies, Sets, Profile hub, MapKit map, mock Leaderboard + ShareLink, Settings, Notifications, 4-step Onboarding); Capture & Hangar redesign (all-frame ambient labels, unified capture button with multi-catch, 3-state lock engine, segmented Hangar with Sets/Recent/Trophies, model-slot drill-down, PokeCard-first tail detail); Hangar v1 (dedupe + swipe-delete); replay recorder + analyzer; camera zoom + tap-to-ID; Brand tokens; Planespotters photo integration; Game-system spine.

Top of the queue now (per PLAN.md §9):

1. **Backend wiring** (PLAN §9 #2) — real anonymous leaderboard, public-hangar visits, push notifications, curated rarity-table refresh. Multi-week effort. Until then, Leaderboard + Public Hangar render mock data and Notifications toggles just persist intent.
2. **Visual confirmation** (Vision + COCO airplane class; PLAN §9 #3).
3. **Capture `os_log` output from the device** (PLAN §9 #4).
4. **Multi-catch AR state + 3-card fan reveal** (PLAN §9 #5) — detect 2-5 visible planes in a single magenta capture frame, hold-to-capture, fan-reveal N cards. CardReveal is parameterizable for multi; the AR detection logic is the new work.

Lower priority: OpenSky secret rotation (#6, demoted per Noah).

**Phase B and Phase C** of the original visual identity (HUD label redesign, Hangar polish, app icon, onboarding) are largely superseded by the design-canvas direction now landing in PLAN §9 #2-#6. Don't relitigate Phase B/C — port the canvas surfaces directly.

**Design source.** The canvas handoff lives in `design/` (HTML/JSX prototype, ~340K). Open with `python3 -m http.server 4173 --directory design && open http://127.0.0.1:4173/`. 33 artboards across 10 sections — splash/brand, onboarding, AR home, AR states, catch flow, detail, hangar, sets, gamification (rarity / types / trophies / trophy-unlock), public surfaces (leaderboard, map, share, public-hangar), profile/settings/notifs. **The prototype is for reference, not for direct porting** — recreate visuals in SwiftUI; don't port the JSX structure.

**Using the deploy loop:** `bin/deploy` builds, installs, and launches on Noah's paired iPhone. Always `xcodebuild test ...` before deploying when product code changes. The phone has to be unlocked for `devicectl process launch` to succeed; on a Locked error, ask Noah to unlock and retry the launch step. If `xcodebuild` itself can't find the destination (UDID returns "Unable to find a destination"), check `xcrun devicectl list devices` — state `unavailable` means the phone needs USB re-pair or Xcode opened once to re-establish the handshake.
