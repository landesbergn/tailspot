# Authenticity gate — field test & go/no-go

The v1 authenticity gate (`SkyCheck.swift`) blocks catches when the phone
isn't pointed at open sky — the fix for "catching planes indoors." It
ships **shadow mode** first (logs its verdict, never blocks) so we can
prove it's right before it ever stops a real catch. This is the protocol
for collecting that proof and deciding whether to enable enforcement.

## The bar (go / no-go)

Enforcement may be enabled **only** when:

1. **Zero false blocks** on confirmed-outdoor sessions — including the
   two hard cases: a **night** sky (visible only by lights) and a
   **far/contrail** plane. A real outdoor catch must never be blocked.
2. A **meaningful block rate indoors** (default ≥ 60%) — the gate
   actually stops the indoor cheat.

Rule 1 is the one that matters. Missing a few indoor cheats is fine;
blocking a real night catch is not. The gate is built to fail open, so
the expected failure mode is "didn't block indoors," not "blocked
outdoors" — this test confirms that holds in the field.

## Collect (on device, ~15 min)

The "Sky gate" row in the debug overlay shows `[SHADOW]` / `[ENFORCE]`.
Leave it on **[SHADOW]** for collection.

Capture a spread of short sessions, attempting a catch in each so the
gate fires `outdoor_gate_shadow`:

- **indoor** — point at ceilings and walls in a few rooms (the cases we
  want blocked). Tap catch several times.
- **outdoor** — daytime sky, a normal airliner overhead.
- **night** — a plane at night, visible by its lights only.
- **far** — a distant plane / contrail, barely a speck.

Keep each scene in its own short time window so you can label the events
by when they happened.

## Score

Export the `outdoor_gate_shadow` events (PostHog → export, or pull a
local capture), one JSON object per line, and add a `label` to each based
on the session it came from (`indoor` / `outdoor` / `night` / `far`):

```
{"verdict": "notSky", "edge_density": 0.21, "warmth": 0.30, "label": "indoor"}
{"verdict": "sky",    "mean_luminance": 0.04,              "label": "night"}
```

Then:

```
python3 tools/authenticity-gate/score_gate_session.py observations.jsonl
```

It prints the block rate per label and a PASS/FAIL against the bar.

## Decide

- **PASS** → enable enforcement (U7): flip the runtime default and/or the
  Settings toggle, and record the result in `PLAN.md` §9.
- **FAIL on false blocks** → do **not** enable. Loosen the gate by
  retuning `SkyCheck.Thresholds` (raise `edgeBusy`/`varianceBusy`, raise
  `warmThreshold`) against the same corpus, re-collect, re-score.
- **FAIL on indoor rate only** → optionally tighten, but shipping a gate
  that's merely conservative (under-blocks) is acceptable for v1 — the
  passive telemetry (`catch_deleted`, the "is this right?" answers) still
  measures the problem while we tune.

Retune `SkyCheck.Thresholds` only against captured sessions — never by
eyeballing in the field.
