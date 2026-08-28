# Frame is the catch — decision record + design (2026-08-28)

Noah's catch-UX redesign, decided over three interactive rounds in the "Catch
Logic Field Guide" artifact and implemented the same day on
`feat/frame-is-the-catch`. One principle: **pointing the camera is the aim.**
Every invisible circle (catch zone, lock zone, wide-tap search) is deleted, and
the screen edge becomes the only boundary.

## The model

1. **Any plausibly-visible plane on frame is catchable.** Press membership =
   bright (`.full`) visibility-tier planes whose projection lands on screen,
   demoted when the local sky grid reads a confident not-sky under the bracket,
   plus user-asserted planes (guaranteed), ranked by apparent angular size
   (arcmin — zoom never reorders), capped at **3** (`maxCatchTargets`).
2. **The button has one cause**: lit iff membership is non-empty; ×N = chosen
   count; a press catches exactly the chosen set. Disabled only on a
   member-less frame.
3. **Labels have three states**, driven by membership: `chosen` (full-bright,
   shows points — the press), `quiet` (bright-tier past the cap; exists only on
   >3-bright frames), `faint` (in the data, not in the press; tap to promote).
   **What you see full-bright is exactly what a press catches.**
4. **Framing is selection**: zoom or step to isolate. No pins.
5. **Tap = assertion** ("there's a plane here you're not showing me"): promotes
   a faint-tier plane, or rescues a `filtered` / `off-frame` plane from the
   empty-tap diagnosis. Asserted planes live while on frame + 15 s grace
   (`assertedGraceSeconds`), pruned at 1 Hz. Tap on a bright plane = no-op;
   VoiceOver activation reads details.
6. **Catch-time-only detector assignment** (no live tracking): per chosen
   target, ring-search the captured still anchored at its press-pose
   prediction (`CatchPhotoSnapper`), then enforce unique assignment
   (`resolveSnapConflicts` — no detection serves two brackets; loser falls
   back to geometry). **Membership is frozen at the shutter: vision moves
   brackets, never edits the caught set.**

## Decisions (locked 2026-08-28, don't reopen)

| # | Decision |
|---|---|
| D1·2 | Membership = bright tier; occluded demotes; tap promotes. Condition: verify `catch_pipeline_timing` during the Ring 0 soak (Release builds only — Debug snaps 3–5× slower). |
| D2 | Gates 1–3 unchanged (flag, never block). Gate 5 (uncertain aim) retired — its crosshair premise died with the model. |
| D3·2 | Max 3 per press; sight-confidence ranking (no centrality term); chosen three shown full-bright. |
| D4·2 | Detector at catch time only; unique per-target assignment; live tracking is the documented upgrade path (pipeline plumbing kept, `updateTarget` never armed). |
| D5 | Tap-rescue lives while on frame + short grace. |
| D6 | Faint tier stays dimmed — bright = in the press is load-bearing. |
| D7 | Tapping a labeled plane does nothing (v1); VoiceOver reads details. |
| D8 | Bezel-edge ×N flicker ships raw; judge by feel. |
| D9 | Old machinery deleted outright, same PR. |
| D10 | One build, whole model, long Ring 0 soak before merge. |

## What was deleted / kept

**Deleted:** `LockOnEngine` (idle/locked/sticky) + its tests, `pinnedIcao` /
`revealedIcao`, `catchZoneRadius` (100 pt), the 80 px lock zone, the 250 px
wide-tap search, `icaosInZone` / `catchCandidates` / `dominantAimTarget` /
`aimProminence` / `aimConfidence` (the A319 selection machinery), the
lone-plane rule (#145 — subsumed by the general rule), the
disabled-with-planes state, Gate 5, pre-press detector targeting, the
pinned/dimmed label hierarchy.

**Kept unchanged:** the visibility filter + precision doctrine, gates 1–3 +
post-reveal Keep/Discard, the same-day-same-flight duplicate rule, the combo
table (×1.5/×2/×2.5/×3 — cap 3 means ×2.0 is now the practical max), the
shutter-press snapshot rule, grounded/far-tap toasts and the empty ripple,
`closestTargetIcao24` (as tap hit-test only).

**Regression bench:** replay `tapPin` events survive as ground-truth
*assertions*. `ReplayAnalyzer` simulates membership per tick (`chosenIcaos` +
the assertion-stripped `ambientChosenIcaos`); failure-mode 5 is now "ambient
membership excluded the plane the user testified they saw" (crowded out by
ranking), mode 8 is the membership-chose-invisible invariant tripwire. Missed
(1) / offset (3) / lag (4) / empty-tap scoring unchanged.

## Where things live

- Membership + assignment rules: `ios/Tailspot/Tailspot/CatchMembership.swift`
  (pure; tests in `CatchMembershipTests.swift` mirror the signed-off worked
  examples).
- View integration: `ContentView.swift` (projections + membership derived
  per-frame in the TimelineView; asserted-plane store + 1 Hz prune).
- Decision surface (rounds 1–3 + worked examples): artifact
  `bab0c99b-b6a4-483c-8a5f-3d9401bba7e7`.

## Ring 0 soak checklist (before merge)

- Button/badge feel: one cause, count = full-bright labels, bezel flicker
  verdict (D8).
- Dense-frame chosen-three sanity vs. what the eye says (SFO/OAK approach).
- Skyline occlusion demote (no strobing along rooflines).
- Tap promotion + rescue still land; grounded/far toasts intact.
- Multi-catch photo: three brackets, no double-assignment.
- `catch_pipeline_timing` unchanged (the D1·2 condition) — Release-class
  build or accept the Debug skew when reading.
