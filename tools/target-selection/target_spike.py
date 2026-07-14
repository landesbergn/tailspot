#!/usr/bin/env python3
"""
Spike: plausibility-weighted catch-target selection vs the current
nearest-crosshair rule. Replicates the app's geometry + selection from the
replay corpus, plus a synthetic reconstruction of the A319 mis-catch.

Not production code — an offline evaluation to decide whether the design is
worth building. Ranking uses angular offset from the camera axis as a faithful
proxy for screen-pixel distance to the reticle (the projection is ~gnomonic,
so radial angle is monotonic in radial screen distance near the crosshair).
"""
import json, glob, math, os, statistics, sys

# --- constants ported from the app (ADSBManager.swift / ContentView.swift) ---
MIN_ELEV = 1.0
FULL_ELEV = 30.0
CONTRAIL_ELEV = 45.0
NEAR_M = 4_500.0
MAX_M = 13_000.0
CONTRAIL_M = 25_000.0
SMALL_FACTOR = 0.5
FAINT_BAND = 2.0
FAINT_CEIL = 35_000.0
SIZE_FLOOR_ARCMIN = 2.5
BASE_HFOV = 56.0
BASE_VFOV = 72.0
CATCH_ZONE_PX = 100.0
SCREEN_W = 393.0   # iPhone 17 pt width (nominal; only used for px->deg)

def is_small(cs):
    cs = (cs or "").strip()
    return len(cs) > 1 and cs[0] == "N" and cs[1].isdigit()

def wingspan_m(cs):
    # Replay lacks emitterCategory/typecode -> app's fallback: small heuristic.
    return 12.0 if is_small(cs) else 40.0

def curve_cap(elev):
    if elev >= CONTRAIL_ELEV: return CONTRAIL_M
    if elev >= FULL_ELEV:
        f = (elev - FULL_ELEV) / (CONTRAIL_ELEV - FULL_ELEV)
        return MAX_M + f * (CONTRAIL_M - MAX_M)
    f = (elev - MIN_ELEV) / (FULL_ELEV - MIN_ELEV)
    return NEAR_M + max(0.0, f) * (MAX_M - NEAR_M)

def visibility_cap(elev, cs):
    base = curve_cap(elev)
    return base * (SMALL_FACTOR if is_small(cs) else 1.0)

def labelable(elev, slant, cs, faint_active=True):
    """tier != hidden. faint_active=True mirrors the phone build (faint tier
    still shipped); the faint-retirement branch would pass False."""
    if elev <= MIN_ELEV: return False
    cap = visibility_cap(elev, cs)
    if slant < cap: return True                 # full
    if not faint_active: return False
    return slant < min(cap * FAINT_BAND, FAINT_CEIL)

def apparent_arcmin(slant, cs):
    return wingspan_m(cs) / slant * (180/math.pi) * 60 if slant > 0 else float("inf")

def geo(olat, olon, oalt, lat, lon, alt):
    R = 6371000.0
    x = math.radians(lon-olon) * math.cos(math.radians((lat+olat)/2)) * R
    y = math.radians(lat-olat) * R
    gd = math.hypot(x, y)
    dz = (alt or 0) - (oalt or 0)
    slant = math.hypot(gd, dz)
    elev = math.degrees(math.atan2(dz, gd))
    brg = (math.degrees(math.atan2(x, y))) % 360   # from true north
    return brg, elev, slant

def ang_offset(brg, elev, cam_az, cam_el):
    """Great-circle angle between plane direction and camera look axis."""
    def unit(az, el):
        az, el = math.radians(az), math.radians(el)
        return (math.cos(el)*math.sin(az), math.cos(el)*math.cos(az), math.sin(el))
    a = unit(brg, elev); b = unit(cam_az, cam_el)
    dot = max(-1.0, min(1.0, a[0]*b[0]+a[1]*b[1]+a[2]*b[2]))
    return math.degrees(math.acos(dot))

def zone_deg(zoom):
    eff_hfov = BASE_HFOV / max(zoom, 1e-6)
    return CATCH_ZONE_PX * (eff_hfov / SCREEN_W)

# --- selectors -----------------------------------------------------------
def current_pick(cands):
    """nearest angular offset to crosshair (what the app does today)."""
    inz = [c for c in cands if c["in_zone"]]
    return min(inz, key=lambda c: c["offset"]) if inz else None

def plausibility_pick(cands, heading_acc, size_bias=1.0):
    """Bayesian-ish: P(aim|plane) ~ exp(-offset^2/2σ^2) * size^bias.
    σ tied to the logged compass accuracy, floored so a good compass ->
    essentially nearest-crosshair (degrades to current behavior)."""
    inz = [c for c in cands if c["in_zone"]]
    if not inz: return None
    sigma = max(4.0, min(heading_acc or 8.0, 25.0))
    best, bs = None, -1.0
    for c in inz:
        prox = math.exp(-(c["offset"]**2) / (2*sigma*sigma))
        score = prox * (c["arcmin"] ** size_bias)
        if score > bs:
            bs, best = score, c
    return best

# --- corpus eval ---------------------------------------------------------
def eval_corpus(paths, faint_active=True):
    ticks_total = both_none = agree = differ = 0
    differ_rows = []
    tapcheck = {"n": 0, "cur_ok": 0, "plaus_ok": 0}
    tap_events_by_ts = {}

    for p in paths:
        try:
            evs = [json.loads(l) for l in open(p) if l.strip()]
        except Exception:
            continue
        taps = [e for e in evs if e.get("type") == "tap-pin"]
        for e in taps:
            tap_events_by_ts.setdefault(p, []).append(e)
        for t in evs:
            if t.get("type") != "tick" or "sensor" not in t: continue
            s = t["sensor"]
            olat, olon, oalt = s.get("latitude"), s.get("longitude"), s.get("altitudeMeters") or 0
            if olat is None: continue
            cam_az = s.get("headingDeg", 0.0)
            cam_el = s.get("cameraElevationDeg", 0.0)
            zoom = s.get("zoomFactor", 1.0) or 1.0
            hacc = s.get("headingAccuracyDeg")
            zdeg = zone_deg(zoom)
            cands = []
            for a in t.get("aircraft", []):
                if a.get("onGround"): continue
                lat, lon = a.get("latitude"), a.get("longitude")
                if lat is None or lon is None: continue
                brg, elev, slant = geo(olat, olon, oalt, lat, lon, a.get("altitudeMeters") or 0)
                cs = a.get("callsign") or a.get("icao24")
                if not labelable(elev, slant, cs, faint_active): continue
                off = ang_offset(brg, elev, cam_az, cam_el)
                cands.append({
                    "icao": a.get("icao24"), "cs": (cs or "").strip(),
                    "offset": off, "slant": slant, "elev": elev,
                    "arcmin": apparent_arcmin(slant, cs),
                    "small": is_small(cs), "in_zone": off <= zdeg,
                    "clears_floor": apparent_arcmin(slant, cs) >= SIZE_FLOOR_ARCMIN,
                })
            ticks_total += 1
            cur = current_pick(cands)
            plaus = plausibility_pick(cands, hacc)
            if cur is None and plaus is None:
                both_none += 1
            elif cur and plaus and cur["icao"] == plaus["icao"]:
                agree += 1
            else:
                differ += 1
                differ_rows.append((cur, plaus, hacc))
    return dict(ticks=ticks_total, both_none=both_none, agree=agree,
                differ=differ, differ_rows=differ_rows)

# --- synthetic A319 scene ------------------------------------------------
def synthetic_a319():
    # Observer at NYC couch coords, sea level.
    olat, olon, oalt = 40.78119, -73.95634, 40.0
    # Camera pointed steeply up toward the A319 (matches the photo).
    # A319: 39,725 ft, 12.9 km slant -> ~70 deg elev. Place it ~6 deg off
    # the crosshair (a plausible aim error); azimuth arbitrary.
    cam_az, cam_el = 200.0, 64.0
    def plane(cs, elev, slant_m, off_az, off_el):
        return {"cs": cs, "elev": elev, "slant": slant_m,
                "offset": math.hypot(off_az, off_el),
                "arcmin": apparent_arcmin(slant_m, cs),
                "small": is_small(cs), "in_zone": True,
                "icao": cs, "clears_floor": apparent_arcmin(slant_m, cs) >= SIZE_FLOOR_ARCMIN}
    a319 = plane("AAL999", 69.8, 12900.0, off_az=2.0, off_el=5.0)      # 6.4 deg off, big-but-far
    closer = plane("JBU100", 58.0, 3200.0, off_az=7.0, off_el=6.0)      # 9.2 deg off, closer/lower
    scene = [a319, closer]
    print("  SYNTHETIC A319 scene (both in zone; crosshair aimed near the A319):")
    for c in scene:
        print(f"    {c['cs']:<8} elev {c['elev']:.0f}deg  slant {c['slant']/1000:.1f}km  "
              f"size {c['arcmin']:.1f}'  offset {c['offset']:.1f}deg")
    cur = current_pick(scene)
    for hacc, tag in [(4.0, 'good compass'), (15.0, 'NYC compass')]:
        plaus = plausibility_pick(scene, hacc)
        print(f"    current -> {cur['cs']:<8} | plausibility ({tag}, sigma~{max(4,min(hacc,25)):.0f}deg) -> {plaus['cs']}")
    # A319-only scene: nothing closer present.
    print("  A319-ONLY scene (the closer plane was NOT labelable / not in feed):")
    only = [a319]
    print(f"    current -> {current_pick(only)['cs']} | plausibility -> {plausibility_pick(only,15.0)['cs']}  "
          f"(both catch the A319 -> needs a prominence gate, see notes)")

if __name__ == "__main__":
    d = os.path.dirname(sys.argv[1]) if len(sys.argv) > 1 else "."
    paths = sorted(glob.glob(os.path.join(d, "replay-*.jsonl")))
    print(f"=== corpus: {len(paths)} replay sessions ===")
    r = eval_corpus(paths, faint_active=True)
    print(f"ticks={r['ticks']}  no-target={r['both_none']}  "
          f"agree={r['agree']}  DIFFER={r['differ']}  "
          f"({100*r['differ']/max(1,r['ticks']-r['both_none']):.0f}% of target-bearing ticks)")
    rows = r["differ_rows"]
    if rows:
        cur_km = [c["slant"]/1000 for c,p,h in rows if c]
        plaus_km = [p["slant"]/1000 for c,p,h in rows if p]
        cur_sz = [c["arcmin"] for c,p,h in rows if c]
        plaus_sz = [p["arcmin"] for c,p,h in rows if p]
        print(f"  when they differ (n={len(rows)}):")
        print(f"    current pick   median slant {statistics.median(cur_km):.1f}km  size {statistics.median(cur_sz):.1f}'")
        print(f"    plausibility   median slant {statistics.median(plaus_km):.1f}km  size {statistics.median(plaus_sz):.1f}'")
        closer = sum(1 for c,p,h in rows if c and p and p["slant"] < c["slant"])
        bigger = sum(1 for c,p,h in rows if c and p and p["arcmin"] > c["arcmin"])
        print(f"    plausibility picked the CLOSER plane in {closer}/{len(rows)}; the BIGGER (more visible) in {bigger}/{len(rows)}")
        # how far the current pick sat from crosshair when overridden
        cur_off = [c["offset"] for c,p,h in rows if c]
        plaus_off = [p["offset"] for c,p,h in rows if p]
        print(f"    offset: current {statistics.median(cur_off):.1f}deg vs plausibility {statistics.median(plaus_off):.1f}deg from crosshair")
    print()
    print("=== synthetic A319 mis-catch ===")
    synthetic_a319()
