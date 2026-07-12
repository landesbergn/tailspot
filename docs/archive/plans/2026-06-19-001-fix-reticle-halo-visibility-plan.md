---
title: "fix: Dark halo behind cyan HUD reticle brackets for sky legibility"
type: fix
date: 2026-06-19
---

# fix: Dark halo behind cyan HUD reticle brackets for sky legibility

## Summary

The AR lock-on brackets and center reticle draw in `Brand.Color.cyan`
(`#00D4FF`), which washes out against a bright blue sky. Keep the cyan hue and
add a thin dark outline ("halo") behind every bracket stroke so the brackets
stay legible against a bright sky without changing the app's cyan identity. The
halo is a wider dark under-stroke beneath each corner bracket, applied
identically in the live SwiftUI HUD and in the bracket burned onto the saved
catch photo. Because brackets render at reduced opacity in two cases (ambient
planes at `0.55`, the empty reticle at `0.24`), the caller's opacity fades the
cyan layer only — the halo stays opaque — so a faint bracket still keeps a crisp
dark edge.

Problem frame: reported from field use under bright daytime sky — cyan-on-blue
is low contrast, so the reticle and per-plane brackets are hard to find.

---

## Requirements

Legibility
- R1. Lock-on brackets stay legible against a bright sky (blue and overcast) via
  a dark halo behind the cyan strokes. The halo adds separation only when the
  background is lighter than near-black, so a dark dusk/night sky is a known
  limit carried by the cyan stroke alone — see Risks.
- R2. The unpinned (ambient) per-plane brackets — the originally-reported
  "hard to find planes" case — and the empty-sky center reticle stay legible
  despite rendering at reduced opacity, by keeping the halo opaque while the
  cyan fades (see Key Technical Decisions). Also raise the empty reticle from
  `0.24`.

Consistency and identity
- R3. The cyan hue is preserved and the global `Brand.Color.cyan` token (splash
  wordmark, hangar, callsign text) is unchanged.
- R4. The halo applies to every bracket instance — center reticle, pinned and
  ambient `PlaneLabel` brackets, and the bracket drawn onto the saved catch
  photo — so the HUD reads consistently and the photo matches the live view.

Verification
- R5. The units land recommended starting values; the final halo width, halo
  color, and reticle opacity are confirmed on Noah's device against a real sky
  before shipping (the simulator can't render the camera feed).

---

## Key Technical Decisions

- Halo as a dark under-stroke, not a shadow or blur. Draw each corner bracket
  twice — a wider dark stroke underneath, then the cyan stroke on top, with
  round caps and joins. It is deterministic and crisp, and reproducible
  identically in both SwiftUI (`stroke`) and Core Graphics (`strokePath`), so
  the live HUD and the saved-photo bracket match exactly. A SwiftUI
  `.shadow`/blur would not map onto the composer's CG path and reads muddier.
- Keep cyan as the stroke; the halo is a new parameter on the shared renderer.
  `LockBrackets` gains halo color and width parameters that default to on, so
  all three call sites (empty reticle, pinned, ambient) inherit the halo from a
  single change. The global `Brand.Color.cyan` token is not touched.
- Apply caller opacity to the cyan stroke only; keep the halo near-opaque.
  `LockBrackets` currently applies `.opacity()` to the whole view, which would
  fade the dark halo along with the cyan — losing the contrast boost exactly
  where the original complaint lives, since the unpinned ambient brackets render
  at `0.55`. Fade only the cyan layer and hold the halo at/near full opacity, so
  even a faint bracket keeps a crisp dark edge. One mechanism covers both the
  ambient brackets (`0.55`) and the empty reticle. Additionally bump the empty
  reticle from `0.24` toward ~`0.5–0.6` (tunable, confirm on-device).
- Halo color is a dark token, defined once per rendering path. Add
  `Brand.Color.hudBracketHalo` reusing the existing `bgSurface` value (`#050810`,
  a near-black) for the SwiftUI side, and a matching `UIColor` literal
  (`red: 5/255, green: 8/255, blue: 16/255`) in `CatchPhotoComposer` — mirroring
  how the composer already duplicates cyan as a `UIColor` to stay
  SwiftUI-independent.
- Halo geometry scales with line width. Under-stroke width is
  `lineWidth + 2 × haloWidth`; recommended `haloWidth ≈ 1.5–2 pt` on-screen
  (tunable). In the composer, scale `haloWidth` by `1 / AspectFillTransform.scale`
  exactly like `lineWidth`, so the photo halo matches the on-screen halo
  proportionally.

---

## Implementation Units

### U1. Add halo to `LockBrackets` and raise the empty-reticle opacity

- Goal: every on-screen bracket (center reticle, pinned and ambient plane
  brackets) renders cyan strokes over a thin dark halo that stays opaque even
  when the bracket itself is faded, and the empty-sky reticle is bumped to a
  visible opacity.
- Requirements: R1, R2, R3, R4
- Dependencies: none
- Files:
  - `ios/Tailspot/Tailspot/ContentView.swift` — `LockBrackets` struct (add
    `haloColor`/`haloWidth` params; draw a dark under-stroke per corner; apply
    `opacity` to the cyan layer only); `emptyReticle` (opacity `0.24` →
    ~`0.55`). The `PlaneLabel` call sites need no change beyond inheriting the
    new defaults.
  - `ios/Tailspot/Tailspot/Brand.swift` — add `Brand.Color.hudBracketHalo`.
- Approach: in `LockBrackets.body`, for each `CornerBracket` corner draw two
  stacked strokes — first `haloColor` at `lineWidth + 2*haloWidth`, then the
  existing `color` at `lineWidth` — keeping `.round` caps. Apply the caller's
  `opacity` to the cyan layer only (not the whole `ZStack`) so the halo stays
  opaque at low caller opacity. Default `haloWidth` so existing callers
  (`PlaneLabel`, `emptyReticle`) get the halo without passing it. All bracket
  rendering routes through `LockBrackets`, so the default-on halo covers every
  lock-on state (idle/acquiring/locked/sticky) uniformly; confirm no separate
  acquisition-arc renderer bypasses it.
- Patterns to follow: the existing `LockBrackets` / `CornerBracket` stroke
  construction in the same file; the `Brand.Color` token style in `Brand.swift`.
- Test scenarios: Test expectation: none — pure SwiftUI visual styling with no
  branching logic. Visibility is verified on-device per R5.
- Verification: on Noah's iPhone under a bright blue sky, the empty reticle and
  the ambient plane brackets are clearly visible; cyan elsewhere (splash,
  hangar, callsigns) is unchanged; project builds and the unit suite stays green.

### U2. Match the halo in the catch-photo bracket overlay

- Goal: the bracket drawn onto a saved catch JPEG carries the same dark halo as
  the live HUD, so the photo matches what the user saw.
- Requirements: R4, R5
- Dependencies: U1 (mirror the same halo color and width ratio chosen there)
- Files: `ios/Tailspot/Tailspot/CatchPhotoComposer.swift` — `drawCornerBrackets`
  (stroke a dark under-pass before the cyan pass per corner); add a
  `bracketHaloColor` (`UIColor`) and `bracketScreenHaloWidth` constant; scale
  the halo width by `1 / transform.scale` in `compose`.
- Approach: before each existing cyan `strokePath()`, add a halo pass on the same
  path — `setStrokeColor(bracketHaloColor)` + `setLineWidth(lineWidth +
  2*haloWidth)` + `strokePath()` — then the existing cyan pass. Reuse the
  per-corner path construction; keep round caps/joins and the `format.scale = 1`
  native-resolution render. Floor the scaled `haloWidth` (≥ ~0.5 px at photo
  resolution) so it never collapses to nothing when `AspectFillTransform.scale`
  is small.
- Patterns to follow: the existing corner-by-corner CG stroking in
  `drawCornerBrackets`; the existing duplicated-cyan `UIColor` constant in the
  same file; the `lineWidth / transform.scale` scaling already done in
  `compose`.
- Test scenarios (regression — these existing `CatchPhotoComposerTests` stay
  green; the halo changes drawing only, not behavior):
  - Covers R4. `composeReturnsNewJPEGForValidInput` still returns valid JPEG
    bytes (`FF D8` header) with the halo pass added.
  - `composeReturnsNilForInvalidJPEG` and `composeReturnsNilForZeroScreenSize`
    still hold — the guards are unchanged.
  - The `AspectFillTransform` math tests remain unaffected.
  - Pixel-level halo appearance is verified on-device via a real catch photo,
    not asserted in unit tests.
- Verification: take a catch on-device and confirm the saved photo's bracket
  shows the dark halo and reads against a bright-sky background;
  `xcodebuild test -only-testing:TailspotTests` is green (especially the
  `CatchPhotoComposer` suite).

---

## Scope Boundaries

- In scope: the corner-bracket reticle/label rendering (`LockBrackets`) and the
  catch-photo bracket overlay (`CatchPhotoComposer`), plus the one halo token in
  `Brand.swift` and the empty-reticle opacity.
- Out of scope:
  - Changing the cyan hue or the global `Brand.Color.cyan` token — explicitly
    decided against; the HUD keeps its cyan identity.
  - Adaptive / background-aware halo or reticle color (sense background
    brightness and switch the halo to a light edge for dark skies) — the
    follow-up if dusk/night legibility becomes a real complaint, not needed for
    the bright-sky case this fix targets.
  - The capture button and the empty-tap ripple — the capture button already
    sits on a dark `bgPrimary.opacity(0.7)` backing and the ripple is transient;
    neither is a bracket. Left as-is.
  - The callsign/rarity label text in `PlaneLabel` — already readable on its
    dark pill backing. Revisit only if field-testing shows the text itself
    washes out.

---

## Risks and Verification Notes

- Visual-only change: it must be eyeballed on-device against a real sky — the
  simulator has no camera feed. A sim build only confirms it compiles and tests
  pass.
- Dark backgrounds: a near-black halo adds no separation against a dark
  dusk/night sky, or where a bracket overlaps a dark fuselage in a catch photo —
  the cyan stroke alone carries those cases. If dusk/night legibility becomes a
  real complaint, a background-aware or light inner-stroke fallback is the
  follow-up (out of scope here).
- A halo too wide reads heavy/muddy; too thin doesn't help. Land conservative
  defaults and tune with Noah.
- Live/photo parity: U1 and U2 share the halo color and width ratio by
  convention — two code paths with no shared constant across the SwiftUI/UIKit
  boundary, same as today's duplicated cyan. Tuning one means updating the
  other; add a cross-referencing "keep in sync" comment in both files.
- Performance: extra stroke passes per bracket at 30 Hz are negligible; no
  concern.

---

## Open Questions

- Empty-reticle opacity: with the halo held opaque (see Key Technical
  Decisions), the bumped reticle opacity may need less of a bump — or none.
  Confirm the exact value on-device.
- Exact values (`haloWidth`, `hudBracketHalo` darkness, reticle opacity) are
  placeholders pending Noah's on-device pass.
