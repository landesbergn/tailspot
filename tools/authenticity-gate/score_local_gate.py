#!/usr/bin/env python3
"""
L2 localized sky gate — offline reference scorer + calibration harness.

The whole-frame gate (SkyCheck / tune.py) asks "is the WHOLE frame open sky?"
(the indoor cheat). This asks the same of the PATCH UNDER THE BRACKET: "is the
piece of screen where this plane should appear actually open sky, or is a
building / tree in the way?" — the L2 occlusion fix.

This is the OFFLINE reference for `ios/.../LocalSkyGate.swift`. It computes the
patch texture as a full-pixel gradient (most accurate); the Swift runs on the
live preview buffer and approximates texture with a per-tile sub-lattice for
speed, so its `texSmooth` threshold is re-calibrated on-device from the
`catch_local_gate` shadow telemetry. The DECISION LOGIC is identical.

Three signals per bracket point:
  texture     — mean |Δlum| of the pixels in the patch (sky ~0; windows/foliage >> 0)
  warmth      — (R-B)/(R+B): lit windows / sodium-lit facades read warm
  skyFraction — fraction of whole-frame tiles that read as open sky, so a
                textured patch only blocks when there is sky to contrast against

Verdict:
  warm  (lum>=LUM_TRUST and warmth>=WARM_THRESH)        -> NOT_SKY  (warm-lit occluder)
  smooth(texture<=TEX_SMOOTH)                           -> SKY      (day/night/overcast/cloud)
  textured + near-dark (lum<LUM_TRUST)                  -> UNCERTAIN (night guard: noise +
                                                           the plane's own lights read as texture)
  textured + skyFraction>=MIN_SKY_FRACTION              -> NOT_SKY  (occluder, sky available)
  textured + no sky available                           -> UNCERTAIN (fail open)

NOT_SKY blocks (when enforcing); SKY and UNCERTAIN allow. Fail-open by design.

Usage:
  python3 score_local_gate.py <manifest.json>
where manifest is a list of {path, bx, by, expect: "allow"|"block", note?}.
Validated 2026-06-27 against real Bay frames + John's NYC catch screenshots
(3/4 NYC cheat frames blocked; the 4th bracket is on a real sky gap → allowed).
"""
import sys, json
import numpy as np
from PIL import Image

TEX_SMOOTH = 0.014
# 2026-07-20 (GA moderation): the occluder bar split from TEX_SMOOTH. 30 days
# of enforcing telemetry showed 70% of answered occluded flags overridden with
# Keep; the false flags cluster at texture 0.02-0.09 cool (cloud/haze under
# the bracket), true occluders at ~0.10+ texture or 0.13+ warmth. Between the
# bars -> UNCERTAIN (allow).
TEX_OCCLUDER = 0.10
# 0.040 -> 0.070 (2026-07-04): golden-hour skies read 0.045-0.06 warm in the
# shadow telemetry -- the same false-block SkyCheck hit in the field.
# 0.070 -> 0.100 (2026-07-20): field notSky blocks sat at 0.04-0.096 warmth
# (outdoor evening light); real warm-lit occluders/interiors read 0.11+.
WARM_THRESH = 0.100
LUM_TRUST = 0.120
MIN_SKY_FRACTION = 0.20
GRID = 16
PATCH_FRAC = 0.19

SKY, NOT_SKY, UNCERTAIN = "SKY", "NOT_SKY", "UNCERTAIN"
ALLOW = {SKY, UNCERTAIN}


def tile_color(path, grid=GRID):
    """Per-tile mean luminance + warmth."""
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
    H, W, _ = a.shape
    lum = np.zeros((grid, grid)); warm = np.zeros((grid, grid))
    for gy in range(grid):
        y0, y1 = gy * H // grid, (gy + 1) * H // grid
        for gx in range(grid):
            x0, x1 = gx * W // grid, (gx + 1) * W // grid
            t = a[y0:y1, x0:x1, :]
            r, g, b = t[..., 0].mean(), t[..., 1].mean(), t[..., 2].mean()
            lum[gy, gx] = 0.299 * r + 0.587 * g + 0.114 * b
            s = r + b
            warm[gy, gx] = (r - b) / s if s > 1e-6 else 0.0
    return lum, warm


def tile_texture(path, grid=GRID):
    """Per-tile mean pixel-gradient (fine texture)."""
    a = np.asarray(Image.open(path).convert("L"), dtype=np.float64) / 255.0
    H, W = a.shape
    gx = np.abs(np.diff(a, axis=1)); gy = np.abs(np.diff(a, axis=0))
    g = np.zeros((H, W)); g[:, :-1] += gx; g[:-1, :] += gy
    out = np.zeros((grid, grid))
    for j in range(grid):
        y0, y1 = j * H // grid, (j + 1) * H // grid
        for i in range(grid):
            x0, x1 = i * W // grid, (i + 1) * W // grid
            out[j, i] = g[y0:y1, x0:x1].mean() / 2
    return out


def patch_texture(path, bx, by, frac=PATCH_FRAC):
    """Pixel-gradient over the patch region around the bracket."""
    a = np.asarray(Image.open(path).convert("L"), dtype=np.float64) / 255.0
    H, W = a.shape
    hw = int(frac * min(H, W) / 2)
    cx, cy = int(bx * W), int(by * H)
    p = a[max(0, cy - hw):min(H, cy + hw), max(0, cx - hw):min(W, cx + hw)]
    if p.shape[0] < 3 or p.shape[1] < 3:
        return 0.0
    return float((np.abs(np.diff(p, axis=1)).mean() + np.abs(np.diff(p, axis=0)).mean()) / 2)


def sky_fraction(lum, warm, tiletex):
    smooth = tiletex <= TEX_SMOOTH
    cool = (warm < WARM_THRESH) | (lum < LUM_TRUST)
    return float((smooth & cool).mean())


def patch_color(lum, warm, bx, by, grid=GRID, patch=3):
    cx = min(grid - 1, max(0, int(bx * grid)))
    cy = min(grid - 1, max(0, int(by * grid)))
    h = patch // 2
    xs = [min(grid - 1, max(0, cx + dx)) for dx in range(-h, h + 1)]
    ys = [min(grid - 1, max(0, cy + dy)) for dy in range(-h, h + 1)]
    L = np.array([lum[y, x] for y in ys for x in xs])
    Wt = np.array([warm[y, x] for y in ys for x in xs])
    return L.mean(), Wt.mean()


def verdict(tex, warm, lum, skyfrac):
    if lum >= LUM_TRUST and warm >= WARM_THRESH:
        return NOT_SKY
    if tex <= TEX_SMOOTH:
        return SKY
    # Night guard (2026-07-04): near-dark, texture is untrustworthy -- sensor
    # noise and the plane's OWN lights read as texture. Fail open.
    if lum < LUM_TRUST:
        return UNCERTAIN
    # Only CLEARLY-cluttered cool patches are occluders (2026-07-20); the
    # texSmooth..texOccluder band is ambiguous cloud/haze -> allow.
    if tex >= TEX_OCCLUDER and skyfrac >= MIN_SKY_FRACTION:
        return NOT_SKY
    return UNCERTAIN


def score(path, bx, by):
    lum, warm = tile_color(path)
    sf = sky_fraction(lum, warm, tile_texture(path))
    plum, pwarm = patch_color(lum, warm, bx, by)
    tex = patch_texture(path, bx, by)
    return verdict(tex, pwarm, plum, sf), dict(tex=tex, warm=pwarm, lum=plum, skyf=sf)


def main(manifest):
    cases = json.load(open(manifest))
    n_ok = 0
    print(f"{'image':40s} {'exp':>6s}  {'tex':>6s} {'warm':>6s} {'lum':>5s} {'skyf':>5s}  {'verdict':>9s}  ok")
    print("-" * 96)
    for c in cases:
        v, p = score(c["path"], c["bx"], c["by"])
        ok = (v in ALLOW) == (c["expect"] == "allow")
        n_ok += ok
        nm = c["path"].split("/")[-1][:40]
        note = "  " + c.get("note", "")
        print(f"{nm:40s} {c['expect']:>6s}  {p['tex']:.4f} {p['warm']:+.3f} {p['lum']:.3f} {p['skyf']:.2f}  "
              f"{v:>9s}  {'OK' if ok else 'MISS'}{note}")
    print("-" * 96)
    print(f"accuracy: {n_ok}/{len(cases)} = {100 * n_ok / len(cases):.0f}%")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "manifest.json")
