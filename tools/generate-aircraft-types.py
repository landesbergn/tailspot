#!/usr/bin/env python3
"""
Generate ios/Tailspot/Tailspot/AircraftTypes.json from ICAO DOC 8643.

Source: https://doc8643.icao.int/external/aircrafttypes — ICAO's
official aircraft type designator data (POST, empty body, ~7,260 rows).
Verified accessible without authentication on 2026-06-06. Licensing:
designator->model mappings are factual reference data; a proper terms
pass is on the pre-App-Store checklist (FAA Order JO 7360.1, public
domain, is the fallback source).

Each unique Designator reduces to ONE canonical (make, model):
  1. most frequent ManufacturerCode wins (ties: alphabetical)
  2. among that manufacturer's rows: shortest ModelFullName
     (ties: alphabetical)
  3. display polish: title-cased make with an exceptions map,
     Airbus "A-320neo" -> "A320neo" hyphen fix
  4. OVERRIDES pins designators where the deterministic rule picks a
     poor representative — populated from human review of the output,
     never from memory.

Usage:
  python3 tools/generate-aircraft-types.py              # fetch + write
  python3 tools/generate-aircraft-types.py --input f.json   # offline
  python3 tools/generate-aircraft-types.py --sample 25  # print review sample

The checked-in JSON diff is the verification surface: review it after
every regeneration.

Regeneration note: the script fetches LIVE ICAO data, so a re-run may
mix unrelated upstream ICAO edits into the diff alongside your
override change. To isolate an override change, save the source once
(curl -s -X POST <URL> -d "" > /tmp/8643.json) and re-run both
before/after with --input /tmp/8643.json.
"""

import argparse
import collections
import json
import random
import re
import sys
import urllib.request
from pathlib import Path

URL = "https://doc8643.icao.int/external/aircrafttypes"
OUT = Path(__file__).resolve().parent.parent / "ios/Tailspot/Tailspot/AircraftTypes.json"

# Makes that must stay fully/partially capitalized (acronyms, brand
# styling). Default rule below title-cases every word (including each
# segment of hyphenated names).
SPECIAL_MAKES = {
    "ATR": "ATR",
    "PZL": "PZL",
    "CASA": "CASA",
    "MBB": "MBB",
    "NAMC": "NAMC",
    "SAAB": "Saab",
    "AGUSTAWESTLAND": "AgustaWestland",
    "MCDONNELL DOUGLAS": "McDonnell Douglas",
    "BAE SYSTEMS": "BAE Systems",
    "DE HAVILLAND": "De Havilland",
    "DE HAVILLAND CANADA": "De Havilland Canada",
    # ICAO encodes "Aero International (Regional)" as "AI(R)"; title-case
    # produces broken "Ai(r)". Map to the recognizable brand name.
    "AI(R)": "Avro",
}

# designator: (make, model) — pins designators where the deterministic
# reduction picks a poor representative (typically: a short military
# designation beating the commercial name, or a modifier/converter
# company outnumbering the original manufacturer). POPULATED FROM
# POST-GENERATION REVIEW (--sample), never from memory.
#
# Format: "DESIG": ("Make", "Model")
# Models are the final display strings (already polished — no further
# processing is applied to OVERRIDE entries).
OVERRIDES = {
    # ----- Boeing 737 MAX family -----
    # ICAO includes both "737 MAX N" and the shorter "737-N" (re-used
    # designator from pre-MAX era); shortest heuristic always picks
    # "737-N". Override to the MAX marketing name.
    "B37M": ("Boeing", "737 MAX 7"),
    "B38M": ("Boeing", "737 MAX 8"),
    "B39M": ("Boeing", "737 MAX 9"),
    "B3XM": ("Boeing", "737 MAX 10"),

    # ----- Boeing: military/VIP variant beats commercial -----
    # Short military designations (C-22, CT-43, E-4, C-32 …) are
    # 3–5 chars; commercial names are longer, so they lose the
    # shortest-wins heuristic.
    "B721": ("Boeing", "727-100"),
    "B732": ("Boeing", "737-200"),
    "B737": ("Boeing", "737-700"),
    "B742": ("Boeing", "747-200"),
    "B748": ("Boeing", "747-8"),
    "B752": ("Boeing", "757-200"),
    "B762": ("Boeing", "767-200"),
    "B77L": ("Boeing", "777-200LR"),
    "B788": ("Boeing", "787-8 Dreamliner"),
    "B789": ("Boeing", "787-9 Dreamliner"),

    # ----- Airbus: military/VIP variant beats commercial -----
    # "T-24" (4) beats "A-330-200" (9); "ACJ-350-900" (11) beats
    # "A-350-900 XWB" (13).
    "A332": ("Airbus", "A330-200"),
    "A359": ("Airbus", "A350-900 XWB"),
    "A35K": ("Airbus", "A350-1000 XWB"),

    # ----- De Havilland Canada Dash 8 -----
    # DH8A/B/C: US military designations (E-9, P-9, RO-6) win over
    # the commercial "DHC-8-N00 Dash 8" names.
    "DH8A": ("De Havilland Canada", "DHC-8-100 Dash 8"),
    "DH8B": ("De Havilland Canada", "DHC-8-200 Dash 8"),
    "DH8C": ("De Havilland Canada", "DHC-8-300 Dash 8"),

    # ----- ATR 72-600 -----
    # "ATR P-72" (8 chars) beats "ATR-72-600" (10 chars).
    "AT76": ("ATR", "ATR-72-600"),

    # ----- Bombardier/Canadair CRJ family -----
    # ICAO carries "CL-600 Challenger NNN" names (internal program
    # IDs); "CL-600 Challenger 870" etc. beat the commercial CRJ-NNN
    # names on length. Override to the plane-spotter familiar names.
    "CRJ1": ("Bombardier", "CRJ-100"),
    "CRJ2": ("Bombardier", "CRJ-200"),
    "CRJ7": ("Bombardier", "CRJ-700"),
    "CRJ9": ("Bombardier", "CRJ-900"),
    "CRJX": ("Bombardier", "CRJ-1000"),

    # ----- Cessna: military/wrong-make wins -----
    # C-98 (4) beats "208 Caravan 1" (12) for C208.
    # Peterson (4 rows for STOL conversions) beats Cessna (2 rows) for C182.
    # Cessna "401" row accidentally present under C402.
    # TR-20 (4) beats "560 Citation 5" for C560.
    # U-20 (4) beats "550 Citation II" (15) for C550.
    "C182": ("Cessna", "182 Skylane"),
    "C208": ("Cessna", "208 Caravan"),
    "C402": ("Cessna", "402"),
    "C550": ("Cessna", "550 Citation II"),
    "C560": ("Cessna", "560 Citation V"),

    # ----- Beech/Beechcraft: military beats commercial -----
    "BE20": ("Beechcraft", "200 Super King Air"),

    # ----- Bombardier Global Express -----
    # "E-11" (4) beats "BD-700 Global Express" (20).
    "GLEX": ("Bombardier", "BD-700 Global Express"),

    # ----- Pilatus PC-12 -----
    # "U-28" (4) beats "PC-12" (4) alphabetically (U > P), so
    # "U-28" wins the tie. Override to the commercial name.
    "PC12": ("Pilatus", "PC-12"),

    # ----- Dassault Falcon 900 -----
    # "T-18" (4) beats "Falcon 900" (10).
    "F900": ("Dassault", "Falcon 900"),

    # ----- Embraer EMB-120 Brasilia -----
    # "VC-97 Brasilia" (14) loses to "EMB-120 Brasilia" (15) length-wise
    # but "VC-97" is the ICAO shortest Embraer model; the Brazilian
    # Air Force designation starts with V which alphabetically precedes
    # E in EMB — actually EMB is shorter. Let's check: "EMB-120 Brasilia"
    # vs "VC-97 Brasilia" — 15 vs 14. "VC-97" wins on length. Override.
    "E120": ("Embraer", "EMB-120 Brasilia"),

    # ----- Swearingen/Fairchild Metro -----
    # "C-26 Metro" (10) beats all Fairchild SA-227 names. Fairchild (1)
    # is not the original Swearingen brand. Override to recognizable name.
    "SW4": ("Fairchild", "SA-227 Metro"),

    # ----- CASA C-212 Aviocar -----
    # "T-12" (3) beats "C-212 Aviocar" (13).
    "C212": ("CASA", "C-212 Aviocar"),

    # ----- Embraer EMB-110 Bandeirante -----
    # "C-95 Bandeirante" (16) beats "EMB-110 Bandeirante" (18) on length.
    # C-95 is the Brazilian Air Force designation; EMB-110 is the civil name.
    "E110": ("Embraer", "EMB-110 Bandeirante"),

    # ----- Cirrus SR20 -----
    # "T-53" (4) beats "SR-20" (5).
    "SR20": ("Cirrus", "SR20"),

    # ----- De Havilland Canada DHC-3 Otter -----
    # "UC Otter" (7) beats "DHC-3 Otter" (10).
    "DHC3": ("De Havilland Canada", "DHC-3 Otter"),

    # ----- MBB BO 105 -----
    # MBB wins by count; "Hkp9" (4, Swedish military) beats "BO-105" (6).
    "B105": ("MBB", "BO 105"),

    # ----- Bombardier Challenger 600 family -----
    # "C-143" (5) beats "CL-600 Challenger 600" (21).
    "CL60": ("Bombardier", "Challenger 604"),

    # ----- Gulfstream II -----
    # "VC-11" (5) beats "G-1159 Gulfstream 2" (18).
    "GLF2": ("Gulfstream Aerospace", "Gulfstream II"),

    # ----- Cessna Citation VII -----
    # "U-21" (4) beats "650 Citation 3" (12).
    "C650": ("Cessna", "650 Citation VII"),

    # ----- Douglas Super DC-3 -----
    # "R4D-8" (5) beats "Super DC-3" (10).
    "DC3S": ("Douglas", "Super DC-3"),

    # ----- Douglas DC-3 -----
    # "DST" (3) beats "DC-3" (4) on length. DST is the original sleeper
    # transport designation; DC-3 is the universally known name.
    "DC3": ("Douglas", "DC-3"),

    # ----- Beech King Air 90 -----
    # "E-22" (4) beats "90 King Air" on length.
    "BE9L": ("Beechcraft", "90 King Air"),

    # ----- Kamov Ka-27 -----
    # "HH-32" ties "Ka-27" at 5 chars; H < K alphabetically, so HH-32 wins.
    "KA27": ("Kamov", "Ka-27"),

    # ----- Cirrus SF50 Vision Jet -----
    # "SJ-X Vision" (11) wins over "SF-50 Vision" (12) by length.
    # SJ-X was an early prototype name; SF50 is the certified production name.
    "SF50": ("Cirrus", "SF50 Vision Jet"),

    # ----- Gulfstream G550 -----
    # "C-37" (4) beats "G-5 Gulfstream 5" (16). C-37 is the USAF designation.
    "GLF5": ("Gulfstream Aerospace", "Gulfstream G550"),

    # ----- Mitsubishi MU-2 -----
    # "LR-1" (4) ties "MU-2" (4); L < M alphabetically, so LR-1 wins.
    "MU2": ("Mitsubishi", "MU-2"),

    # ----- Embraer ERJ-135/145 -----
    # C-99 (4 chars) beats ERJ-145; VC-99C beats ERJ-135 — Brazilian
    # Air Force designations on the highest-frequency US regional jets.
    "E135": ("Embraer", "ERJ-135"),
    "E145": ("Embraer", "ERJ-145"),

    # T-22 (military) beat the universally-known commercial name.
    "A310": ("Airbus", "A310"),

    # ----- Deferred review candidates (rare on OpenSky free-tier ADS-B) -----
    # B703 (707-300), PA18 (Piper Super Cub), BE10 (Beech King Air 100),
    # C185 (Cessna 185 Skywagon), DHC2 (DHC-2 Beaver) — flag for review
    # if these start appearing in field sessions.
}


def polish_make(raw):
    raw = " ".join(raw.split())
    upper = raw.upper()
    if upper in SPECIAL_MAKES:
        return SPECIAL_MAKES[upper]
    # Strip ICAO's numeric disambiguation suffixes e.g. "Fairchild (1)" -> "Fairchild"
    raw = re.sub(r"\s*\(\d+\)$", "", raw)
    upper = raw.upper()  # recompute after strip so mixed-case check is valid
    if raw != upper:
        return raw  # already mixed-case in the source
    # Title-case each word, including segments across hyphens
    # e.g. "BRITTEN-NORMAN" -> "Britten-Norman", "BELL-BOEING" -> "Bell-Boeing"
    def cap_segment(s):
        return "-".join(part.capitalize() for part in s.split("-"))
    return " ".join(cap_segment(w) for w in raw.split())


def polish_model(make, model):
    model = " ".join(model.split())
    if make == "Airbus":
        # ICAO styles Airbus as "A-320neo" / "A-220-300"; the
        # marketing names drop the first hyphen.
        model = re.sub(r"^A-(?=\d)", "A", model)
    return model


def reduce_rows(rows):
    by_designator = collections.defaultdict(list)
    for r in rows:
        desig = (r.get("Designator") or "").strip().upper()
        make = (r.get("ManufacturerCode") or "").strip()
        model = (r.get("ModelFullName") or "").strip()
        if desig and make and model:
            by_designator[desig].append((make, model))

    out = {}
    for desig, pairs in by_designator.items():
        if desig in OVERRIDES:
            make, model = OVERRIDES[desig]
        else:
            counts = collections.Counter(make for make, _ in pairs)
            top = max(counts.items(), key=lambda kv: (kv[1], [-ord(c) for c in kv[0]]))
            # max by count; ties broken alphabetically-first via the
            # negative-ordinal trick (higher count wins, then 'A' beats 'B').
            make_raw = top[0]
            models = sorted(m for mk, m in pairs if mk == make_raw)
            model_raw = min(models, key=lambda m: (len(m), m))
            make = polish_make(make_raw)
            model = polish_model(make, model_raw)
        out[desig] = {"make": make, "model": model}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", help="read rows from a saved JSON file instead of fetching")
    ap.add_argument("--sample", type=int, default=0, help="print N random entries for review")
    args = ap.parse_args()

    if args.input:
        with open(args.input) as fh:
            rows = json.load(fh)
    else:
        req = urllib.request.Request(
            URL, data=b"", method="POST",
            headers={"User-Agent": "tailspot-aircraft-types-generator/1.0"},
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            rows = json.load(resp)

    out = reduce_rows(rows)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1, sort_keys=True)
        fh.write("\n")

    print(f"rows in: {len(rows)}  designators out: {len(out)}  -> {OUT}")
    if args.sample:
        for desig in random.sample(sorted(out), min(args.sample, len(out))):
            e = out[desig]
            print(f"  {desig:5s} {e['make']} {e['model']}")


if __name__ == "__main__":
    main()
