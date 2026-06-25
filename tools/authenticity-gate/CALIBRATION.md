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
