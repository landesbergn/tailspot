# Sky-gate calibration (2026-06-25)

`SkyCheck.Thresholds` were tuned against a labeled image set so the gate
**passes plane/sky shots** and **blocks interiors**.

## Set

48 public photos (Wikimedia Commons), hand-QA'd for labels:
- **24 PASS** — aircraft in flight / overhead, varied: jets, biplanes,
  formations, night, clouds, contrails, urban, a sign obstruction.
- **24 BLOCK** — interiors, varied: living rooms, bedrooms, kitchens,
  halls, ornate ceilings, warm-wood and cool/blue-lit rooms.

## Method

`tune.py` ports `SkyCheck.extract` + `verdict` exactly (12×12 grid sample;
rule = **busy AND warm**) and grid-searches ~30k threshold combinations,
scoring pass-recall (planes allowed) and block-recall (interiors blocked).

## Result — the trade-off

| config | (edge, var, warm) | balanced | planes pass | interiors blocked |
|---|---|---|---|---|
| before | 0.12, 0.06, 0.18 | 0.56 | 100% | **12%** |
| open (pass≈100%) | 0.155, 0.0475, 0.02 | 0.75 | 100% | 50% |
| **CHOSEN** | **0.08, 0.0275, 0.02** | **0.79** | **96%** | **63%** |
| strict (max-balanced) | 0.08, 0.0275, −0.04 | 0.85 | 83% | 88% |

The trade-off is fundamental: passing every plane caps interior-blocking at
~50%; blocking ~88% of interiors costs ~17% false-blocks. **`warmThreshold`
is the dial.** We chose the **fail-open knee** (96% pass / 63% block) because
the gate ships enforcing with a one-tap **"Catch anyway"** that recovers the
rare false-block, and `catch_gate_override` measures how often it's wrong.

## Limits

Heuristic ceiling is ~85% balanced on this set. Intrinsic misses:
**cool/blue-lit interiors** read as sky-like; **warm/cluttered skies**
(sunset, plane behind wires) read as interior-like. To exceed this, a small
on-device indoor/outdoor (or sky-segmentation) classifier is the path —
revisit if the real-user override rate is high.

## Update — field test (2026-06-25)

On device, a plain **warm-lit ceiling** read `edge 0.02` (as smooth as the
sky), so the "busy AND warm" rule never fired — a blank ceiling has no
clutter to detect. Recalibrated to block on **warmth alone** (drop the
busy requirement): `warmThreshold 0.04`, `lumTrust 0.12`. Now ~92% of
plane/sky frames pass and ~67% of interiors block, including smooth warm
ceilings. Cost: warm/golden skies can false-block (recoverable via "Catch
anyway"); **cool-lit interiors still slip through** — the learned
classifier (backlogged) is the real fix.

## Re-tune

`python3 tune.py <dir-of-pass-*.jpg-and-block-*.jpg>` → operating points;
copy the chosen `(edge, var, warm)` into `SkyCheck.Thresholds`.

## Update — telemetry retune (2026-07-20, GA moderation)

The original labeled images are no longer on disk, but by 2026-07-20 there
was a better validator: 30 days of **enforcing field telemetry** with
user labels (`catch_suspect_kept` / `catch_suspect_discarded`). Both changes
only *raise* thresholds (strictly fewer blocks), so validation reduces to
"do the frames that should still block stay above the new bars" — and the
telemetry answers that directly.

- **SkyCheck `warmThreshold` 0.07 → 0.10.** 30 of 36 field `notSky` blocks
  sat at warmth 0.04–0.096 (outdoor evening/golden light — the reported
  false "Not many planes indoors." nags, which also suppress ambient
  labels); the clearly-indoor cluster reads 0.11–0.19 (corpus warm ceilings
  ~0.13+). Cost: mildly-warm interiors join the cool-lit ones that already
  slip through — the learned classifier remains the real fix.
- **LocalSkyGate: `texOccluder = 0.10` split from `texSmooth = 0.014`, warm
  0.07 → 0.10.** Of the answered occluded flags, 22/31 were overridden with
  Keep (~70% false). Joined to their recorded features, the false flags
  cluster at texture 0.02–0.09, cool, sky in frame — cloud/haze under the
  bracket, which the single `texSmooth` bar read as a building. True
  occluders read ~0.10+ texture or 0.13+ warmth. Re-scored on the 30 days:
  flags drop 39 → 8 (17 of 22 Keep-answered false flags removed; every
  high-texture / warm-lit true block survives). The cool mild-texture cheat
  class this gives up is queued for the L4 detector gate to own.
