#!/usr/bin/env python3
"""Score the v1 authenticity (sky) gate against labeled sessions.

The runtime gate (SkyCheck.swift) decides "is the phone pointed at open
sky?" and, when enforcing, blocks a catch on a confident `notSky`. Before
we flip enforcement on we have to prove it blocks indoor attempts WITHOUT
blocking legitimate hard-to-see outdoor catches (night, far/contrail).
This script is that go/no-go check.

Input: a JSONL file where each line is one gate observation — the
properties of an `outdoor_gate_shadow` event (exported from PostHog, or
emitted locally) plus a `label` for the session it came from:

    {"verdict": "sky",    "edge_density": 0.03, "warmth": -0.02, "label": "outdoor"}
    {"verdict": "notSky", "edge_density": 0.21, "warmth":  0.30, "label": "indoor"}
    {"verdict": "sky",    "mean_luminance": 0.04,               "label": "night"}

Labels:
  - "indoor"           -> SHOULD block
  - "outdoor"/"night"/"far" -> MUST NOT block (the false-block bar)

Go / No-Go bar (see FIELD-TEST.md):
  - ZERO false blocks across outdoor/night/far observations.
  - Indoor block rate >= --min-indoor-block (default 0.6).

Usage:
    python3 score_gate_session.py observations.jsonl
    python3 score_gate_session.py observations.jsonl --min-indoor-block 0.6
"""
import argparse
import json
import sys
from collections import defaultdict

ALLOW_LABELS = {"outdoor", "night", "far"}   # must not block
BLOCK_LABELS = {"indoor"}                     # should block


def load(path):
    rows = []
    with open(path) as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"warn: skipping line {i}: {e}", file=sys.stderr)
    return rows


def main():
    ap = argparse.ArgumentParser(description="Score the sky gate vs labeled sessions.")
    ap.add_argument("observations", help="JSONL of gate observations, each with a `label`")
    ap.add_argument("--min-indoor-block", type=float, default=0.6,
                    help="min fraction of indoor observations that must block (default 0.6)")
    args = ap.parse_args()

    rows = load(args.observations)
    if not rows:
        print("no observations found", file=sys.stderr)
        return 2

    by_label = defaultdict(lambda: {"n": 0, "blocked": 0})
    unlabeled = {"n": 0, "blocked": 0}
    for r in rows:
        blocked = (r.get("verdict") == "notSky")
        label = r.get("label")
        bucket = by_label[label] if label else unlabeled
        bucket["n"] += 1
        bucket["blocked"] += 1 if blocked else 0

    print("=== Sky-gate scoring ===")
    for label in sorted(by_label):
        b = by_label[label]
        rate = b["blocked"] / b["n"] if b["n"] else 0.0
        print(f"  {label:8s}  n={b['n']:4d}  blocked={b['blocked']:4d}  ({rate:.0%})")
    if unlabeled["n"]:
        print(f"  (unlabeled n={unlabeled['n']} blocked={unlabeled['blocked']})")

    false_blocks = sum(by_label[l]["blocked"] for l in ALLOW_LABELS if l in by_label)
    allow_n = sum(by_label[l]["n"] for l in ALLOW_LABELS if l in by_label)
    indoor = by_label.get("indoor")
    indoor_rate = (indoor["blocked"] / indoor["n"]) if indoor and indoor["n"] else None

    print("\n=== Go / No-Go ===")
    ok = True
    if allow_n:
        passed = false_blocks == 0
        ok = ok and passed
        print(f"  False blocks on outdoor/night/far: {false_blocks}/{allow_n}  "
              f"[{'PASS' if passed else 'FAIL'}]")
    else:
        print("  No outdoor/night/far observations — cannot certify the false-block bar.")
        ok = False
    if indoor_rate is not None:
        passed = indoor_rate >= args.min_indoor_block
        ok = ok and passed
        print(f"  Indoor block rate: {indoor_rate:.0%} (need >= {args.min_indoor_block:.0%})  "
              f"[{'PASS' if passed else 'FAIL'}]")
    else:
        print("  No indoor observations — cannot certify the indoor-catch bar.")
        ok = False

    print(f"\n  OVERALL: {'PASS — safe to enable enforcement' if ok else 'NOT YET — keep shadow mode'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
