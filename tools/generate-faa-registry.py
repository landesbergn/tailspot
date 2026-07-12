#!/usr/bin/env python3
"""
Generate the bundled FAA-registry fallback assets:
  ios/Tailspot/Tailspot/faa-aircraft.bin   (icao24 -> model index)
  ios/Tailspot/Tailspot/faa-models.json    (index -> [make, model, type])

Source: FAA Releasable Aircraft Database
  https://registry.faa.gov/database/ReleasableAircraft.zip  (~73 MB)
  - MASTER.txt   : one row per US registration; carries MODE S CODE HEX
                   (the icao24) + MFR MDL CODE.
  - ACFTREF.txt  : MFR MDL CODE -> manufacturer, model, TYPE-ACFT,
                   TYPE-ENG.

Why this exists: OpenSky's crowd-sourced aircraft DB 404s on a real
slice of US traffic (verified: Cirrus SR20 a9eefa, Embraer E175
a8d71c). The community aggregators (hexdb.io, adsbdb) 404 too — they
share OpenSky's data lineage. The FAA registry is the authoritative
source for every US tail, so it's the fallback when OpenSky has
nothing. US-only by construction (foreign registries aren't covered).

Compact format (so the bundle stays ~3.5 MB, not 14 MB of JSON):
  faa-aircraft.bin : big-endian (UInt32 icao24, UInt16 modelIndex)
                     records, SORTED by icao24 for binary search.
  faa-models.json  : array of [make, model, type]; modelIndex points
                     in. ~44k distinct tuples (< 65536 -> UInt16).

The make is canonicalized (Cirrus, Embraer, Pilatus…); the model is
the FAA model string lightly cleaned; type is one of the app's
AircraftType raw values, derived from TYPE-ACFT/ENG + model family.

STALENESS: this is a snapshot. The FAA registry updates ~daily; new or
re-registered aircraft after a regen won't be found until the next
regen. Acceptable for a ~1.6%-of-catches fallback; the strategic home
for this data is the backend (see
docs/archive/superpowers/research/2026-06-07-adsb-metadata-sources.md).

Usage:
  python3 tools/generate-faa-registry.py            # download + build
  python3 tools/generate-faa-registry.py --zip f.zip   # use a local zip
"""

import argparse
import csv
import io
import json
import os
import re
import struct
import urllib.request
import zipfile
from pathlib import Path

URL = "https://registry.faa.gov/database/ReleasableAircraft.zip"
OUT = Path(__file__).resolve().parent.parent / "ios/Tailspot/Tailspot"

# Canonical manufacturer brands for the common US fleet. The long tail
# falls back to corporate-suffix stripping + title case.
CANON = {
    "CIRRUS DESIGN CORP": "Cirrus", "CIRRUS": "Cirrus",
    "EMBRAER": "Embraer", "EMBRAER S A": "Embraer",
    "PILATUS AIRCRAFT LTD": "Pilatus",
    "CESSNA": "Cessna", "TEXTRON AVIATION": "Cessna", "CESSNA AIRCRAFT": "Cessna",
    "PIPER": "Piper", "PIPER AIRCRAFT INC": "Piper",
    "BEECH": "Beechcraft", "HAWKER BEECHCRAFT CORP": "Beechcraft", "RAYTHEON AIRCRAFT COMPANY": "Beechcraft",
    "GULFSTREAM AEROSPACE": "Gulfstream",
    "BOMBARDIER INC": "Bombardier", "CANADAIR": "Bombardier", "LEARJET INC": "Bombardier",
    "MOONEY": "Mooney", "MOONEY AIRPLANE CO INC": "Mooney",
    "DIAMOND AIRCRAFT IND INC": "Diamond", "DIAMOND AIRCRAFT": "Diamond",
    "ROBINSON HELICOPTER CO": "Robinson", "ROBINSON HELICOPTER": "Robinson",
    "BOEING": "Boeing", "AIRBUS": "Airbus", "AIRBUS INDUSTRIE": "Airbus",
    "BELL": "Bell", "BELL HELICOPTER TEXTRON": "Bell", "SIKORSKY": "Sikorsky",
    "DASSAULT": "Dassault", "DASSAULT AVIATION": "Dassault",
    "HONDA AIRCRAFT CO LLC": "Honda", "QUEST AIRCRAFT": "Quest",
}

_REGIONAL = re.compile(r"\b(ERJ|EMB-1|RJ-?[0-9]|CRJ|CL-?6|DHC-?8|DASH ?8|ATR|SAAB|DORNIER|DO ?328|J-?41)\b", re.I)
_BIZ = re.compile(r"\b(GULFSTREAM|G-?IV|G-?V|G-?\d{3}|CITATION|LEARJET|CHALLENGER|FALCON|PHENOM|HAWKER|BD-?100|PC-?24|GLOBAL|HONDAJET|HA-?420)\b", re.I)
_CORP = re.compile(r"\b(AIRCRAFT|COMPANY|CORP|CORPORATION|INC|CO|AVIATION|S A|INDUSTRIE|AEROSPACE|LTD|GMBH|HELICOPTER|DESIGN|LLC|IND)\b")


def canon_make(raw):
    u = re.sub(r"\s+", " ", raw).strip().upper()
    if u in CANON:
        return CANON[u]
    u = _CORP.sub("", u).strip()
    return " ".join(w.capitalize() for w in u.split()) or raw.title()


def aircraft_type(make, model, type_acft, type_eng):
    # FAA TYPE-ACFT: 4=fixed single, 5=fixed multi, 6=rotorcraft,
    # 9=gyroplane, H=hybrid lift, 1=glider 2=balloon 3=blimp 7=weight-shift
    # 8=powered-parachute O=other. TYPE-ENG: 4=turbojet 5=turbofan.
    if type_acft in ("6", "9", "H"):
        return "ga"  # rotorcraft live in the GA set (PokeSets puts R44 there)
    if type_acft in ("1", "2", "3", "7", "8", "O"):
        return "ga"
    if _BIZ.search(model) or _BIZ.search(make):
        return "biz"
    if _REGIONAL.search(model):
        return "regional"
    if type_acft == "5" and type_eng in ("4", "5"):
        return "biz"  # US-registered multi-jet not caught above is almost always a bizjet
    return "ga"  # singles / props


def norm_header(h):
    return h.replace("﻿", "").replace("ï»¿", "").strip()


def load_zip_bytes(args):
    if args.zip:
        return open(args.zip, "rb").read()
    req = urllib.request.Request(URL, headers={"User-Agent": "tailspot-faa-registry/1.0"})
    with urllib.request.urlopen(req, timeout=180) as resp:
        return resp.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", help="path to a local ReleasableAircraft.zip")
    args = ap.parse_args()

    zf = zipfile.ZipFile(io.BytesIO(load_zip_bytes(args)))

    acft = {}
    with zf.open("ACFTREF.txt") as fb:
        r = csv.reader(io.TextIOWrapper(fb, encoding="latin-1", newline=""))
        ix = {norm_header(h): i for i, h in enumerate(next(r))}
        for row in r:
            if len(row) < 5:
                continue
            acft[row[ix["CODE"]].strip()] = (
                row[ix["MFR"]].strip(), row[ix["MODEL"]].strip(),
                row[ix["TYPE-ACFT"]].strip(), row[ix["TYPE-ENG"]].strip(),
            )

    tuples, order, recs = {}, [], []
    def idx_of(t):
        if t not in tuples:
            tuples[t] = len(order)
            order.append(t)
        return tuples[t]

    with zf.open("MASTER.txt") as fb:
        r = csv.reader(io.TextIOWrapper(fb, encoding="latin-1", newline=""))
        ix = {norm_header(h): i for i, h in enumerate(next(r))}
        hx, cd = ix["MODE S CODE HEX"], ix["MFR MDL CODE"]
        for row in r:
            if len(row) <= hx:
                continue
            hexc = row[hx].strip().lower()
            code = row[cd].strip()
            if not hexc or code not in acft:
                continue
            mfr, model, ta, te = acft[code]
            mk = canon_make(mfr)
            t = (mk, re.sub(r"\s+", " ", model).strip(), aircraft_type(mk, model, ta, te))
            try:
                iv = int(hexc, 16)
            except ValueError:
                continue
            recs.append((iv, idx_of(t)))

    recs.sort()
    assert len(order) < 65536, f"too many distinct tuples for UInt16: {len(order)}"

    buf = bytearray()
    for iv, i in recs:
        buf += struct.pack(">IH", iv, i)
    (OUT / "faa-aircraft.bin").write_bytes(buf)
    with open(OUT / "faa-models.json", "w", encoding="utf-8") as fh:
        json.dump([list(t) for t in order], fh, ensure_ascii=False)

    print(f"records: {len(recs)}  tuples: {len(order)}  "
          f"bin: {len(buf)//1024} KB  json: {os.path.getsize(OUT/'faa-models.json')//1024} KB")


if __name__ == "__main__":
    main()
