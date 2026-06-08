# 3D Pinhole Projection for AR Label Placement

**Date:** 2026-06-08
**Status:** Approved design, pre-implementation
**Author:** Claude + Noah
**Scope:** Replace the separable tan projection in `Geo.screenPosition` with a
proper pinhole-camera model that uses the device's full 3D orientation
(heading + gravity-derived elevation + roll). Geometry only — no ML.

---

## 1. Problem

Every AR placement path — the live overlay, lock-on bracket finding, tap-to-ID,
and the offline `ReplayAnalyzer` — funnels through one pure function,
`Geo.screenPosition`. That function currently uses a **separable** projection:

```
xRel = tan(bearing - heading) / tan(hfov/2)
yRel = tan(elevation - camElev) / tan(vfov/2)
```

Screen-x is computed from the bearing delta alone and screen-y from the
elevation delta alone, as if the two axes were independent. They are not. A real
camera is a pinhole that couples them. The error is zero on the optical axis and
grows off-axis and with camera elevation — the documented "~1/cos(camElev)
horizontal exaggeration" and "~25% at 40°" offset. It also ignores device roll
entirely (`Geo.swift` says so in a `LIMITATION` comment): when the phone is
tilted left/right, labels stay axis-aligned instead of rotating with the scene.

This is the *systematic* component of the label-vs-plane offset quantified in the
2026-06-06 field round. The *random* component (compass wobble, ±20° in urban
Berkeley) is sensor noise and explicitly out of scope here — it's the target of
the later visual-confirmation phase.

## 2. Goals / non-goals

**Goals**
- Replace the separable projection with a correct pinhole projection that couples
  azimuth and elevation.
- Account for device **roll**, derived from the gravity vector (not the flaky
  Euler `roll`).
- Improve **every** consumer at once by fixing the single chokepoint, including
  offline re-analysis of recorded sessions.
- Be verifiable **offline**, primarily via analytic unit tests; secondarily via
  replay regression on recorded sensor traces.
- Lay groundwork for visual confirmation: the corrected predicted position
  becomes that feature's fallback.

**Non-goals**
- No Vision/CoreML/ML. That is the stacked phase 2 (PLAN §9 #3, "both, geometry
  first").
- No attempt to fix compass wobble / heading noise (random error).
- No change to *which* aircraft are considered visible (`isLikelyVisibleToObserver`
  is untouched) or to the lock-on state machine.

## 3. Approach: gravity-derived pinhole camera

Rejected alternatives (recorded for posterity):
- **Euler rotation matrix** from yaw/pitch/roll — reintroduces the gimbal-lock +
  roll-flip bug that the 2026-06-02 gravity-based `cameraElevationDeg` fix
  removed. The Euler `roll` is unreliable at exactly the portrait-hold pose used
  for spotting (`MotionManager` notes roll swinging ±150° at the singularity).
- **Minimal `/cos(elevation)` patch** — corrects only the dominant azimuth term,
  stays separable, can't represent roll. Ruled out by the decision to include
  roll.

**Chosen: build the camera's 3D orthonormal basis (forward / right / up) in a
local ENU frame, project each target's world-space unit vector through it, then
perspective-divide.** This is consistent with the repo's existing gravity-first,
singularity-free philosophy and gets roll for free from gravity.

**Fallback noted, not built:** `CMDeviceMotion.attitude` exposes the full
rotation matrix directly (no Euler extraction, no gimbal issue). If the on-device
check (§7) reveals the gravity→roll derivation is off, switch the *live* basis
builder to consume that matrix. The scalar replay builder is still needed for
back-compat, so this would be two code paths — only reach for it if the eyeball
demands it.

### 3.1 The math

**Local ENU frame at the observer:** East = +X, North = +Y, Up = +Z.

**Target direction** from bearing `B` (deg clockwise from north) and elevation
`E` (deg above horizon):

```
t = ( cos(E)·sin(B),  cos(E)·cos(B),  sin(E) )
```

**Camera forward** `f` from heading `H` and camera elevation `camEl`
(same form — this makes the new model a strict generalization; `camEl` is the
gravity-derived value, never Euler pitch):

```
f = ( cos(camEl)·sin(H),  cos(camEl)·cos(H),  sin(camEl) )
```

**No-roll up / right** (camera up = world-up projected perpendicular to `f`):

```
u0 = normalize( Ẑ − (Ẑ·f)·f )      // world up, derolled
r0 = f × u0                          // pinned by test: level-north ⇒ r0 = East
```

(Sanity check, level camera looking north: `f = (0,1,0)`, `u0 = (0,0,1)`,
`r0 = f × u0 = (1,0,0) = East`. ✓)

**Roll** `φ` rotates `(r0, u0)` about `f`:

```
r = cos(φ)·r0 + sin(φ)·u0
u = −sin(φ)·r0 + cos(φ)·u0
```

`φ` source:
- **Live path:** derived from the **gravity vector** — the in-screen-plane
  component of gravity gives the on-screen "down", hence roll. This is robust at
  the portrait hold where Euler roll fails. The exact formula and sign are pinned
  by analytic unit tests during implementation.
- **Replay path:** from the recorded `rollRad` if present (approximate, may be
  noisy near the gimbal), else `0`. Documented degradation. New recordings will
  carry gravity (§4) for an exact reconstruction.

**Projection** (perspective divide):

```
xCam = t·r ;  yCam = t·u ;  zCam = t·f
if zCam <= 0 { return nil }          // target behind the camera
xRel = (xCam / zCam) / tan(hfov/2)
yRel = (yCam / zCam) / tan(vfov/2)
if |xRel| > 1 || |yRel| > 1 { return nil }   // off-frame, same as today
screen = ( W/2 + xRel·W/2,  H/2 − yRel·H/2 )  // Y flips (origin top-left)
```

**Relationship to the old model.** On the optical axis (`dB=0, dE=0`) both give
screen center. For a level camera the x term is *identical* to the old
(`tan(dB)/tan(hfov/2)`); the y term gains a `1/cos(dB)` coupling — i.e. a plane
that is both off to the side and above center renders higher than the separable
model claimed. That divergence **is** the fix; it is expected, intended, and is
why some existing tests whose expected numbers were computed from the separable
model will be recomputed analytically (§6).

## 4. Interface & data-flow changes

The change radiates from one chokepoint, so call sites are mechanical.

1. **`Geo.swift` — projection core.** Introduce a small camera-basis abstraction
   so the pinhole projection is testable independent of how the basis was
   derived:
   - `Geo.cameraBasis(gravityX:gravityY:gravityZ:headingDeg:) -> CameraBasis`
     (live path; derives `camEl` and `φ` from gravity).
   - `Geo.cameraBasis(headingDeg:cameraElevationDeg:rollDeg:) -> CameraBasis`
     (replay/back-compat; `rollDeg` defaults to 0).
   - `Geo.screenPosition(targetBearingDeg:targetElevationDeg:basis:screenSize:hfovDeg:vfovDeg:)`
     does the pure pinhole projection given a basis.
   `CameraBasis` is a `nonisolated` value holding the three world unit vectors.
   This keeps the geometry one focused unit; how a basis is obtained (live gravity
   vs replay scalars) is a separate, independently-testable concern.

2. **`ADSBManager.swift` — `ObservedAircraft.screenPosition` wrapper.** Change to
   accept a `CameraBasis` (built by the caller) rather than `cameraElevationDeg`.
   Single wrapper that all UI paths already share.

3. **Callers (mechanical):**
   - `ContentView` (×3 projection sites + the tap-to-ID hit-test): build the basis
     once per frame from `motion.gravityX/Y/Z` + `location.heading`, pass it down.
   - `LockOnEngine` `closestTargetIcao24` helpers (×2): take a `CameraBasis`
     instead of `cameraElevationDeg`.
   - `ReplayAnalyzer`: build the basis from the recorded sensor row — gravity if
     the recording has it (§4.4), else `cameraElevationDeg` + `rollRad`.

4. **Replay format additions (both additive / optional, the `zoomFactor`
   pattern):**
   - **Gravity** `gravityX/Y/Z: Double?` on `SensorSnapshot`, written by
     `recordReplayTick`. Lets future recordings reconstruct the exact live basis.
     Absent on old files → analyzer falls back to `cameraElevationDeg` + `rollRad`.
   - **Tap location** `x: Double?`, `y: Double?` on `TapPin`, written by
     `recordTapPin`. Gives pixel-exact ground truth for future sessions and for
     the eventual visual-confirmation work. Absent on old files → analyzer treats
     a tap-pin as "this icao was confirmed visible" only (today's behavior).
   Both are back-compatible: `ReplayJSONL.decode` already tolerates missing
   optional keys, and `bin/`/analyzer paths degrade gracefully.

## 5. Components & responsibilities

| Unit | Responsibility | Depends on |
|---|---|---|
| `Geo.CameraBasis` + `Geo.cameraBasis(...)` | Turn sensor inputs into 3 world unit vectors | pure math |
| `Geo.screenPosition(...basis...)` | Pinhole project one target through a basis | `CameraBasis` |
| `ObservedAircraft.screenPosition(...basis...)` | Per-aircraft convenience wrapper | `Geo` |
| `ContentView` / `LockOnEngine` | Build basis from live sensors, place labels / find lock target | wrapper |
| `ReplayAnalyzer` | Build basis from recorded sensors (gravity if present) | `Geo`, replay format |
| `ReplayRecorder` | Persist gravity + tap location | replay format |

Each unit is independently testable: the projection core takes a basis and a
target and returns a point; the basis builders take scalars/vectors and return a
basis. Neither needs SwiftUI, a device, or the network.

## 6. Testing & regression strategy

This is the load-bearing section — the explicit ask is "tested, and we can
prevent unexpected regressions."

### 6.1 Analytic unit tests — the gate (no field work)

Pinhole geometry is deterministic, so expected screen positions are
hand-computable. Two distinct layers are tested, because they can fail
independently:

**(a) Basis-builder absolute correctness** — the layer most likely to be wrong,
and the one a "builders agree" check *cannot* catch (both builders can be jointly
wrong the same way). Assert known pose ⇒ known basis against ground truth, not
against the other builder:
- gravity straight down + heading 0° ⇒ `forward ≈ North, up ≈ Up, right ≈ East`.
- pitched-up pose ⇒ `forward` tilts up, `up` tilts back (toward the observer),
  `right` stays horizontal.
- rolled pose ⇒ `right`/`up` rotate about `forward` by the expected angle; pins
  the `φ` sign/convention.
- **then** also assert the two builders agree when fed consistent inputs (a
  gravity vector and its derived `camEl`/`roll`) — a consistency check layered on
  top of, not instead of, the absolute checks above.

**(b) Projection core** — given a (correct) basis, the pinhole formula is right:
- **Reduction invariants:** target on optical axis ⇒ exact center, for several
  `(heading, camEl, roll)` poses. Off-frame target ⇒ `nil`. Behind-camera
  (`zCam ≤ 0`) ⇒ `nil`. North-wrap (heading 350° / bearing 10° ⇒ +20°) still
  correct.
- **Level-camera x-equivalence:** with `camEl=0, roll=0`, screen-x equals the old
  `tan(dB)/tan(hfov/2)` (pins the generalization).
- **Coupling cases:** off-axis targets at `camEl ∈ {20°, 40°}` with hand-computed
  pinhole expectations — these are the cases the old model got wrong; they encode
  the fix as concrete numbers.
- **Edge-of-frame:** the cull test changed from an angular box (`|dB|>hfov/2`) to
  a frustum (`|xRel|>1`); these differ near the corners. A target just inside /
  just outside a corner pins the new boundary so a future edit can't silently
  move it.

### 6.2 Existing tests — intentional vs. accidental change

- `ClosestTargetTests` and the `GeoTests` projection cases will be audited. Tests
  asserting **invariants** (center→center, off-frame→nil, wraparound, which plane
  is closest to a tap) must continue to pass unchanged — they are the regression
  net for "did I break the common case."
- Tests asserting **separable-model-specific pixel numbers** will be recomputed
  from the pinhole model. Each such change will be called out in the
  implementation plan and commit so it's an auditable decision, never a silent
  expected-value edit to make a red test green.

### 6.3 End-to-end pipeline test + replay regression

- **Synthetic full-pipeline test (closes the plumbing gap).** Unit tests in §6.1
  feed a basis straight into the projection; they skip the sensor-row → basis-
  builder-selection → projection plumbing in `ReplayAnalyzer`. Add one
  `ReplayAnalyzerTests` case: construct a tick with a known camera pose + a plane
  at a known world position, compute the expected screen point by hand, run it
  through the analyzer, assert recovery. Cover both the gravity-present and
  gravity-absent (scalar fallback) sensor rows so both basis-builder branches are
  exercised by the plumbing.
- Run `ReplayAnalyzer` over the two committed recordings
  (`replays/*.jsonl`). **Caveat, stated honestly:** these files contain no
  tap-pin events, so they provide **no pixel-exact ground truth** — only a
  smoke/regression signal that the new projection runs end-to-end on real sensor
  traces, returns finite positions, and keeps centered traffic centered.
- **Pixel-exact validation** requires the tap-confirmed pin-protocol recordings on
  Noah's phone (`Documents/replays`). Optional and non-blocking: pull them with
  the documented `devicectl ... copy from` command and compare old-vs-new
  predicted position against the recorded tap location (once §4 tap-capture is
  shipping, or for the icao-only files, against center-proximity as a soft
  metric). The ship gate is §6.1, not this.

### 6.4 Full-suite green

`xcodebuild test -only-testing:TailspotTests` must pass (current baseline 287),
with the only expected-value changes being the audited §6.2 set. New tests net
positive.

## 7. Rollout & risk

**Device eyeball is a ship GATE, not optional polish.** Per §6.3, there is no
strong real-world *offline* ground truth available (committed replays have no
tap-pins; the phone's pin-protocol recordings are icao-only until §4 ships). So
the on-device check is the *only* validation of the new coupled behavior against
reality. The suite proves the math; the device proves the model. Both required
before merge.

Device gate checklist (Noah, after `bin/deploy`):
- Labels sit on planes near the **horizon** AND **overhead** (the two ends of the
  `camEl` range where old/new diverge most).
- Labels stay glued when the phone is deliberately **rolled** left/right.
- **Corner planes** appear/disappear sanely (the §6.2 frustum-vs-box cull change
  only differs near the corners).
- **Lock-on still feels right** — the 80px lock-zone radius was tuned against old
  placements; the new projection shifts where planes land, nudging the effective
  *angular* lock tolerance. Probably fine; confirm tap-to-ID and center lock.

Other risks:
- **Risk: subtle sign/convention error misplaces the common case.** Mitigated by
  §6.1(a) basis-builder absolute tests + (b) reduction invariants (center→center
  across poses) and §6.2 invariant tests kept green.
- **Risk: replay back-compat break.** Mitigated by additive-optional fields and a
  decode test over the existing on-disk files.
- **Risk: roll from gravity wrong near horizon.** Mitigated by explicit roll unit
  tests, `φ` decoupled from `camEl` in the basis builder, and the §3 fallback to
  `CMDeviceMotion.attitude` if the eyeball exposes it.
- **Merge to `main` only after green suite + device gate (main is
  tester-facing).**

## 8. Out of scope (explicit)

- Vision/COCO visual confirmation (phase 2).
- Compass/heading noise reduction.
- Curvature/refraction elevation corrections (still the ~0.1° flat-earth approx).
- Any FOV recalibration beyond the existing `baseHfovDeg/baseVfovDeg` (56/72).
