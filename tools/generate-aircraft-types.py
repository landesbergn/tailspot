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
  3. display polish: canonical-manufacturer map (standardizes brands),
     strip-leading-brand (kills doubled "Gulfstream G550" style),
     title-cased make with an exceptions map,
     Airbus "A-320neo" -> "A320neo" hyphen fix
  4. OVERRIDES pins designators where the deterministic rule picks a
     poor representative — populated from human review of the output,
     never from memory.

FAA cross-reference:
  - Loads tools/data/faa_aircraft_characteristics.xlsx (stdlib zipfile).
  - Emits MISMATCH lines to stdout for make/model disagreements.
  - Attaches wingspanFt and lengthFt (floats) to entries that have FAA
    data — for future visibility work. Swift Decodable ignores extra keys.

Usage:
  python3 tools/generate-aircraft-types.py              # fetch + write
  python3 tools/generate-aircraft-types.py --input f.json   # offline
  python3 tools/generate-aircraft-types.py --sample 25  # print review sample
  python3 tools/generate-aircraft-types.py --save-disagreements f.txt

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
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

URL = "https://doc8643.icao.int/external/aircrafttypes"
OUT = Path(__file__).resolve().parent.parent / "ios/Tailspot/Tailspot/AircraftTypes.json"
FAA_XLSX = Path(__file__).resolve().parent / "data/faa_aircraft_characteristics.xlsx"

# ---------------------------------------------------------------------------
# Canonical-manufacturer map
# Maps UPPERCASE source manufacturer strings (from DOC 8643 ManufacturerCode
# and/or FAA Manufacturer column) to short canonical brand names.
# This is the primary normalization step — strip-brand and title-case run after.
# ---------------------------------------------------------------------------
CANONICAL_MAKE = {
    # Major OEMs
    "AIRBUS": "Airbus",
    "AIRBUS HELICOPTERS": "Airbus Helicopters",
    "EUROCOPTER": "Airbus Helicopters",  # rebranded to Airbus Helicopters
    "BOEING": "Boeing",
    "EMBRAER": "Embraer",
    "CESSNA": "Cessna",
    "TEXTRON AVIATION": "Cessna",        # Cessna parent
    "PIPER": "Piper",
    "GULFSTREAM AEROSPACE": "Gulfstream",
    "GULFSTREAM AMERICAN": "Gulfstream",
    "CANADAIR": "Bombardier",            # Bombardier absorbed Canadair
    "BOMBARDIER": "Bombardier",
    "CIRRUS": "Cirrus",
    "MOONEY": "Mooney",
    "ROBINSON": "Robinson",
    "BEECH": "Beechcraft",
    "RAYTHEON-BEECH": "Beechcraft",
    "RAYTHEON BEECH": "Beechcraft",
    "RAYTHEON": "Beechcraft",            # Raytheon/Hawker Beechcraft era
    "ECLIPSE": "Eclipse",
    "AERONCA": "Aeronca",
    "JUST": "Just Aircraft",
    "LEARJET": "Learjet",
    "DASSAULT": "Dassault",
    "DASSAULT AVIATION": "Dassault",
    "PILATUS": "Pilatus",
    "DIAMOND": "Diamond",
    "SOCATA": "Socata",
    "PIAGGIO": "Piaggio",
    "HONDA": "Honda",
    "QUEST": "Quest",
    "MITSUBISHI": "Mitsubishi",
    "GRUMMAN": "Grumman",
    "GRUMMAN AMERICAN": "Grumman American",
    "DOUGLAS": "Douglas",
    "LOCKHEED": "Lockheed",
    "LOCKHEED MARTIN": "Lockheed Martin",
    "FAIRCHILD": "Fairchild",
    "FAIRCHILD SWEARINGEN": "Fairchild",
    "FAIRCHILD DORNIER": "Fairchild Dornier",
    "ANTONOV": "Antonov",
    "ILYUSHIN": "Ilyushin",
    "SUKHOI": "Sukhoi",
    "IAI": "IAI",
    "LAKE": "Lake",
    "MAULE": "Maule",
    "HELIO": "Helio",
    "ROCKWELL": "Rockwell",
    "NORTH AMERICAN": "North American",
    "NORTH AMERICAN ROCKWELL": "Rockwell",
    "CONVAIR": "Convair",
    "AVIAT": "Aviat",
    "BELLANCA": "Bellanca",
    "TAYLORCRAFT": "Taylorcraft",
    "STINSON": "Stinson",
    "LUSCOMBE": "Luscombe",
    "ERCO": "Erco",
    "AIR TRACTOR": "Air Tractor",
    "REIMS-CESSNA": "Cessna",           # Reims-built Cessna aircraft
    "RILEY-CESSNA": "Cessna",           # Riley conversions of Cessna
    # Hawker / BAE family
    "BRITISH AEROSPACE": "British Aerospace",
    "HAWKER": "Hawker",
    "HAWKER SIDDELEY": "Hawker Siddeley",
    # ATR, CASA, MBB etc stay in SPECIAL_MAKES (CANONICAL_MAKE takes priority)
}

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
    # "A-350-900 XWB" (13). XWB suffix dropped: the string-cleanup
    # fallback produces "A350-900"/"A350-1000" and must CONVERGE with
    # the table value — "XWB" is marketing fluff the fallback can't
    # reconstruct. Pinned by AircraftNamingTests.fallbackConvergesWithTable.
    "A332": ("Airbus", "A330-200"),
    "A359": ("Airbus", "A350-900"),
    "A35K": ("Airbus", "A350-1000"),

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
    # Riley beats Cessna in frequency for C310 (5 vs 4 rows).
    "C182": ("Cessna", "182 Skylane"),
    "C208": ("Cessna", "208 Caravan"),
    "C310": ("Cessna", "310"),
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
    # "T-53" (4) beats "SR-20" (5). Also strip the ICAO hyphen: SR-20 -> SR20.
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

    # ----- Gulfstream -----
    # GLF2: "VC-11" (5) beats "G-1159 Gulfstream 2" (18).
    # GLF5: "C-37" (4) beats "G-5 Gulfstream 5" (16). C-37 is USAF designation.
    #        Also fixes doubled-brand "Gulfstream Aerospace Gulfstream G550".
    # GALX: IAI wins by frequency (2 vs 1), picks "1126 Galaxy" — wrong brand+name.
    "GLF2": ("Gulfstream", "Gulfstream II"),
    "GLF5": ("Gulfstream", "G550"),
    "GALX": ("Gulfstream", "G200"),

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

    # ----- Mitsubishi MU-2 -----
    # "LR-1" (4) ties "MU-2" (4); L < M alphabetically, so LR-1 wins.
    "MU2": ("Mitsubishi", "MU-2"),

    # ----- Embraer ERJ-135/145 -----
    # C-99 (4 chars) beats ERJ-145; VC-99C beats ERJ-135 — Brazilian
    # Air Force designations on the highest-frequency US regional jets.
    "E135": ("Embraer", "ERJ-135"),
    "E145": ("Embraer", "ERJ-145"),

    # ----- Airbus A310 -----
    # T-22 (military) beat the universally-known commercial name.
    "A310": ("Airbus", "A310"),

    # ----- A400M / HS-748 -----
    # More military-designation wins over well-known names.
    "A400": ("Airbus", "A400M Atlas"),
    "A748": ("Hawker Siddeley", "HS-748"),

    # ----- British Aerospace Jetstream 41 -----
    # AI(R)->Avro is right for the RJ Avroliners but not the
    # Jetstream 41, which is a British Aerospace product like its
    # JS31/JS32 siblings.
    "JS41": ("British Aerospace", "Jetstream 41"),

    # ----- Piper PA-28 Cherokee family -----
    # Piper wins by count (23 vs 41 combined for foreign licensees).
    # Shortest Piper model is "PA-28-161 Cadet" (14) — but the user-validated
    # target name is "PA-28 Cherokee" (generic family name). The DOC 8643
    # shortest rule picks a specific variant; override to the canonical family.
    "P28A": ("Piper", "PA-28 Cherokee"),
    "P28R": ("Piper", "PA-28R-201 Arrow"),
    "PA31": ("Piper", "PA-31-300 Navajo"),
    "PA24": ("Piper", "PA-24 Comanche"),

    # ----- Embraer E175 long wing -----
    # DOC 8643 has "175 (long wing)" and "ERJ-170-200 (long wing)".
    # Shortest is "175 (long wing)" but the parenthetical needs removing.
    # Target is "Embraer 175".
    "E75L": ("Embraer", "175"),

    # ----- Mooney M20 -----
    # DOC 8643 shortest MOONEY model is "M-20" — ICAO uses a hyphen.
    # Target is "Mooney M20" (no hyphen). Override to strip the hyphen.
    "M20P": ("Mooney", "M20"),

    # ----- Robinson R44 -----
    # DOC 8643 has "R-44 Astro", "R-44 Raven", "R-44 Clipper".
    # Shortest is "R-44 Astro" (10). Target is "R44" (no hyphen, no variant).
    "R44": ("Robinson", "R44"),

    # ----- Eclipse 500 -----
    # DOC 8643 has "Eclipse 500" and "Eclipse 550"; shortest is "Eclipse 500".
    # BUT polish_make("ECLIPSE") -> "Eclipse", then strip_leading_brand
    # kills "Eclipse" prefix from "Eclipse 500" -> "500". Wrong.
    # Fix: override so the brand stripping doesn't fire for this case.
    "EA50": ("Eclipse", "500"),

    # ----- Just Aircraft SuperSTOL -----
    # ICAO has "JA30 SuperSTOL" and "JA35 SuperSTOL XL" under make "JUST".
    # CANONICAL_MAKE maps JUST -> "Just Aircraft".
    # Shortest model is "JA30 SuperSTOL". Target is "Just Aircraft SuperSTOL".
    # JA30 is the internal model code; override to the marketing name.
    "SSTL": ("Just Aircraft", "SuperSTOL"),

    # ----- Airbus A220 (BCS3) -----
    # ICAO has AIRBUS "A-220-300" and BOMBARDIER "BD-500 CSeries CS300".
    # Tie-breaking: AIRBUS wins alphabetically. Model "A-220-300" becomes
    # "A220-300" after Airbus hyphen fix. Target: "Airbus A220-300". Good.
    # But just in case Bombardier row wins: override.
    "BCS3": ("Airbus", "A220-300"),

    # ----- Airbus H135 (EC35) -----
    # AIRBUS HELICOPTERS wins by count (6 vs 4 for EUROCOPTER).
    # Shortest model from AIRBUS HELICOPTERS: "H-135" (5).
    # Target: "Airbus Helicopters H-135". With CANONICAL_MAKE and no
    # further stripping this should work, but pin it to be safe.
    "EC35": ("Airbus Helicopters", "H-135"),

    # ----- Aeronca 11 Chief (AR11) -----
    # ICAO: AERONCA "11 Chief" (1 row) vs HINDUSTAN "HUL-26 Pushpak" (1 row).
    # Tie-break alphabetically: AERONCA < HINDUSTAN. Should pick Aeronca.
    # Target: "Aeronca 11 Chief". Pin it to avoid tie-break surprises.
    "AR11": ("Aeronca", "11 Chief"),

    # ----- Cessna 195 -----
    # ICAO: CESSNA "195" and "LC-126". Shortest wins: "195" (3 chars).
    # Target: "Cessna 195". Should work, but pin for safety.
    "C195": ("Cessna", "195"),

    # ----- Deferred review candidates (rare on OpenSky free-tier ADS-B) -----
    # B703 (707-300), PA18 (Piper Super Cub), BE10 (Beech King Air 100),
    # C185 (Cessna 185 Skywagon), DHC2 (DHC-2 Beaver) — flag for review
    # if these start appearing in field sessions.
}


def load_faa_xlsx():
    """
    Load FAA Aircraft Characteristics Database from xlsx.
    Returns dict: icao_code (uppercase) -> {"make": str, "model": str,
                                             "wingspanFt": float|None,
                                             "lengthFt": float|None}
    Uses stdlib zipfile + xml.etree only (no openpyxl).
    """
    if not FAA_XLSX.exists():
        return {}

    ns = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}

    with zipfile.ZipFile(FAA_XLSX) as z:
        # Shared string table
        ss_xml = z.read("xl/sharedStrings.xml")
        ss_root = ET.fromstring(ss_xml)
        shared_strings = []
        for si in ss_root.findall("x:si", ns):
            text = "".join(t.text or "" for t in si.findall(".//x:t", ns))
            shared_strings.append(text)

        # Sheet data
        sheet_xml = z.read("xl/worksheets/sheet1.xml")
        sheet_root = ET.fromstring(sheet_xml)

        rows = []
        for row in sheet_root.findall(".//x:row", ns):
            row_data = {}
            for cell in row.findall("x:c", ns):
                ref = cell.get("r")
                t = cell.get("t")
                v = cell.find("x:v", ns)
                col = "".join(c for c in ref if c.isalpha())
                if v is not None:
                    if t == "s":
                        row_data[col] = shared_strings[int(v.text)]
                    else:
                        row_data[col] = v.text
            rows.append(row_data)

    if not rows:
        return {}

    # First row is header; skip it
    result = {}
    for row in rows[1:]:
        icao = (row.get("A") or "").strip().upper()
        if not icao:
            continue
        faa_mfr = (row.get("C") or "").strip()
        faa_model = (row.get("D") or "").strip()

        def parse_float(s):
            s = (s or "").strip()
            if not s or s == "N/A":
                return None
            try:
                return round(float(s), 1)
            except (ValueError, TypeError):
                return None

        # Wingspan: prefer col P (without winglets), fall back to col Q (with winglets)
        wingspan = parse_float(row.get("P")) or parse_float(row.get("Q"))
        length = parse_float(row.get("R"))

        result[icao] = {
            "make": faa_mfr,
            "model": faa_model,
            "wingspanFt": wingspan,
            "lengthFt": length,
        }

    return result


def normalize_make_key(raw):
    """Normalize a manufacturer string for CANONICAL_MAKE/SPECIAL_MAKES lookup."""
    # Collapse \xa0 and other whitespace, strip, uppercase
    return " ".join(raw.split()).upper()


def canonical_make_lookup(raw):
    """
    Return canonical brand string for a raw manufacturer code.
    Priority: CANONICAL_MAKE -> SPECIAL_MAKES -> title-case fallback.
    """
    key = normalize_make_key(raw)
    if key in CANONICAL_MAKE:
        return CANONICAL_MAKE[key]
    if key in SPECIAL_MAKES:
        return SPECIAL_MAKES[key]
    return None


def polish_make(raw):
    """
    Polish a raw ManufacturerCode string to a display brand name.
    1. Check CANONICAL_MAKE (standardized brands).
    2. Check SPECIAL_MAKES (acronyms / special casing).
    3. Strip ICAO numeric disambiguation suffix e.g. "Fairchild (1)" -> "Fairchild".
    4. If already mixed-case, pass through.
    5. Otherwise title-case each word, respecting hyphens.
    """
    raw = " ".join(raw.split())
    key = normalize_make_key(raw)
    if key in CANONICAL_MAKE:
        return CANONICAL_MAKE[key]
    if key in SPECIAL_MAKES:
        return SPECIAL_MAKES[key]
    # Strip ICAO's numeric disambiguation suffixes e.g. "Fairchild (1)" -> "Fairchild"
    raw = re.sub(r"\s*\(\d+\)$", "", raw)
    key = normalize_make_key(raw)  # recompute after strip
    if key in CANONICAL_MAKE:
        return CANONICAL_MAKE[key]
    if key in SPECIAL_MAKES:
        return SPECIAL_MAKES[key]
    upper = raw.upper()
    if raw != upper:
        return raw  # already mixed-case in the source
    # Title-case each word, including segments across hyphens
    # e.g. "BRITTEN-NORMAN" -> "Britten-Norman", "BELL-BOEING" -> "Bell-Boeing"
    def cap_segment(s):
        return "-".join(part.capitalize() for part in s.split("-"))
    return " ".join(cap_segment(w) for w in raw.split())


def strip_leading_brand(make, model):
    """
    Remove a leading brand word from model if the model repeats it.
    Handles both the canonical make AND the raw source make's first word.
    E.g.:
      make="Gulfstream", model="Gulfstream G550"  -> "G550"
      make="Eclipse",    model="Eclipse 500"       -> "500"
      make="Airbus Helicopters", model="Airbus Helicopters H-135" -> "H-135"

    Also strips parentheticals e.g. "175 (long wing)" -> "175".
    """
    # Strip parentheticals first
    model = re.sub(r"\s*\(.*?\)\s*$", "", model).strip()

    # Build candidate prefixes to strip (longest first to avoid partial strips)
    prefixes = []
    if make:
        prefixes.append(make)  # canonical make, e.g. "Airbus Helicopters"
        # First word of canonical make, e.g. "Airbus"
        first = make.split()[0]
        if first not in prefixes:
            prefixes.append(first)
    # Sort longest first so multi-word prefixes get a chance before single words
    prefixes.sort(key=len, reverse=True)

    for prefix in prefixes:
        # Match if model starts with prefix (case-insensitive) followed by a space
        if re.match(re.escape(prefix) + r"\s+", model, re.IGNORECASE):
            stripped = model[len(prefix):].strip()
            if stripped:  # only strip if something remains
                return stripped

    return model


def polish_model(make, model):
    model = " ".join(model.split())
    if make == "Airbus":
        # ICAO styles Airbus as "A-320neo" / "A-220-300"; the
        # marketing names drop the first hyphen.
        model = re.sub(r"^A-(?=\d)", "A", model)
    # Strip leading brand word(s) from model
    model = strip_leading_brand(make, model)
    return model


# ---------------------------------------------------------------------------
# Aircraft type classification — driven by DOC 8643 AircraftDescription,
# EngineType, WTC (wake turbulence category). Priority (highest first):
#
#   1. Rotorcraft / tiltrotor → ga  (no separate rotorcraft set in Tailspot)
#   2. MIL exact-match set → mil   (EXACT match only — C17 ≠ C172)
#   3. BIZ exact-match set → biz
#   4. Regional prefix regex → regional
#   5. Wide prefix regex / WTC H or J → wide
#   6. Narrow prefix regex / (Jet engine + WTC M) → narrow
#   7. Piston or Electric engine → ga
#   8. Turboprop + WTC L or M → ga
#   9. WTC L → ga
#  10. Default → ga   (the long tail is light aircraft, NOT narrow)
#
# MIL and BIZ are EXACT-MATCH sets — never prefix-match. This is
# critical: C17 (C-17 Globemaster, military) must not match C172 (Cessna).
# ---------------------------------------------------------------------------
BIZ = {
    'GLF5','GLF4','GLF6','GALX','CL30','CL35','CL60',
    'C25A','C25B','C25C','C500','C510','C525','C550','C560','C56X','C680','C68A','C700','C750',
    'E50P','E55P',
    'LJ35','LJ45','LJ60','LJ75','FA7X','FA8X','F2TH','F900',
    'BD100','H25B','ASTR','PRM1','MU2','PC24','LJ31','LJ40','LJ55','C25M',
}
MIL = {
    'C130','C30J','C17','C5M','C5','KC135','KC10','KC46','K35R',
    'B52','C27J','C295','A400','P3','P8','E3CF','E3TF','E6',
    'C12','C12J','U28','RC12','C160','AN12','IL76','A124','C141',
    'VC25','E4','C32','C40','B1','B2','C2','E2',
}

_REGIONAL_RE = re.compile(r'^(CRJ|E17|E19|E75|E70|DH8|AT4|AT7|AT5|SF3|SB20|J41|E45|E13|E14)')
_WIDE_RE     = re.compile(r'^(B74|B77|B78|B76|A33|A34|A35|A38|MD11|IL9|IL8|A124|AN12|AN22|A30|A310)')
_NARROW_RE   = re.compile(r'^(B73|B72|B75|A31|A32|BCS|MD8|MD9|DC9|E290|E190|E195|A19N|A20N|A21N)')


def aircraft_type(tc, info):
    """
    Compute Tailspot AircraftType string for a typecode + DOC 8643 info dict.
    Returns one of: "narrow", "wide", "regional", "biz", "mil", "ga".
    `info` must have keys AircraftDescription, EngineType, WTC.
    """
    desc = info.get("AircraftDescription", "")
    eng  = info.get("EngineType", "")
    wtc  = info.get("WTC", "")

    # 1. Rotorcraft → ga
    if desc in ("Helicopter", "Gyrocopter", "Tiltrotor"):
        return "ga"

    # 2. Military exact-match
    if tc in MIL:
        return "mil"

    # 3. Bizjet exact-match
    if tc in BIZ:
        return "biz"

    # 4. Regional prefix
    if _REGIONAL_RE.match(tc):
        return "regional"

    # 5. Wide-body prefix or heavy/super-heavy WTC
    if _WIDE_RE.match(tc) or wtc in ("H", "J"):
        return "wide"

    # 6. Narrow prefix or (Jet + medium WTC)
    if _NARROW_RE.match(tc):
        return "narrow"
    if eng == "Jet" and wtc == "M":
        return "narrow"

    # 7. Piston or Electric → ga
    if eng in ("Piston", "Electric"):
        return "ga"

    # 8. Turboprop/Turboshaft + light/medium WTC → ga
    if eng.startswith("Turbo") and wtc in ("L", "M", "L/M"):
        return "ga"

    # 9. Light WTC → ga
    if wtc in ("L", "L/M"):
        return "ga"

    # 10. Default — the long tail is light aircraft, NOT narrow
    return "ga"


def reduce_rows(rows):
    # Build per-designator info dict (desc/eng/wtc from the first matching row).
    # We want the raw DOC 8643 fields for type classification, independent of
    # the make/model OVERRIDE branch (overrides change the display name only).
    by_designator = collections.defaultdict(list)
    desig_info = {}  # designator → {"AircraftDescription", "EngineType", "WTC"}
    for r in rows:
        desig = (r.get("Designator") or "").strip().upper()
        make = (r.get("ManufacturerCode") or "").strip()
        model = (r.get("ModelFullName") or "").strip()
        if desig and make and model:
            by_designator[desig].append((make, model))
            if desig not in desig_info:
                desig_info[desig] = {
                    "AircraftDescription": r.get("AircraftDescription", ""),
                    "EngineType": r.get("EngineType", ""),
                    "WTC": r.get("WTC", ""),
                }

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
        # Type is derived from DOC 8643 classification data (independent of
        # make/model overrides — overrides change display names only).
        atype = aircraft_type(desig, desig_info.get(desig, {}))
        out[desig] = {"make": make, "model": model, "type": atype}
    return out


def build_disagreement_report(doc_out, faa_data):
    """
    For every typecode present in BOTH DOC 8643 output and FAA table,
    check if the canonicalized makes differ OR if the models share no token.
    Returns list of formatted MISMATCH lines.
    """
    lines = []
    for tc in sorted(doc_out.keys()):
        if tc not in faa_data:
            continue
        doc_entry = doc_out[tc]
        faa = faa_data[tc]

        doc_make = doc_entry["make"]
        doc_model = doc_entry["model"]
        faa_mfr_raw = faa["make"]
        faa_model = faa["model"]

        # Canonicalize FAA make for comparison
        faa_make_canon = canonical_make_lookup(faa_mfr_raw) or polish_make(faa_mfr_raw)

        # Check make agreement (case-insensitive)
        make_match = doc_make.lower() == faa_make_canon.lower()

        # Check model agreement: at least one non-trivial token shared
        def tokens(s):
            return set(w.lower() for w in re.split(r"[\s\-/]+", s) if len(w) > 1)
        doc_tokens = tokens(doc_model)
        faa_tokens = tokens(faa_model)
        model_match = bool(doc_tokens & faa_tokens)

        if not make_match or not model_match:
            lines.append(
                f"MISMATCH {tc}: doc='{doc_make} {doc_model}' "
                f"faa='{faa_mfr_raw} {faa_model}'"
            )
    return lines


def attach_faa_dims(out, faa_data):
    """
    Attach wingspanFt and lengthFt from the FAA table to each entry that
    has a matching ICAO code. Entries without FAA data are unchanged.
    """
    for tc, entry in out.items():
        faa = faa_data.get(tc)
        if not faa:
            continue
        if faa["wingspanFt"] is not None:
            entry["wingspanFt"] = faa["wingspanFt"]
        if faa["lengthFt"] is not None:
            entry["lengthFt"] = faa["lengthFt"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", help="read rows from a saved JSON file instead of fetching")
    ap.add_argument("--sample", type=int, default=0, help="print N random entries for review")
    ap.add_argument("--save-disagreements", metavar="FILE",
                    help="save FAA vs DOC 8643 disagreement report to FILE")
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

    # Load FAA data
    faa_data = load_faa_xlsx()

    # Disagreement report
    disagreements = build_disagreement_report(out, faa_data)
    for line in disagreements:
        print(line)

    if args.save_disagreements:
        with open(args.save_disagreements, "w", encoding="utf-8") as fh:
            fh.write("\n".join(disagreements))
            if disagreements:
                fh.write("\n")
        print(f"Disagreements saved to {args.save_disagreements} ({len(disagreements)} entries)")

    # Attach FAA dims
    attach_faa_dims(out, faa_data)

    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1, sort_keys=True)
        fh.write("\n")

    print(f"rows in: {len(rows)}  designators out: {len(out)}  -> {OUT}")
    if args.sample:
        for desig in random.sample(sorted(out), min(args.sample, len(out))):
            e = out[desig]
            print(f"  {desig:5s} {e['make']} {e['model']} [{e.get('type','')}]")

    # ── Acceptance fixture: 38 real typecodes ────────────────────────────────
    FIXTURE = {
        # narrow
        "A21N": "narrow", "B739": "narrow", "B738": "narrow", "B38M": "narrow",
        "A321": "narrow", "BCS3": "narrow", "B737": "narrow", "A320": "narrow",
        "B39M": "narrow",
        # wide
        "B772": "wide", "B788": "wide", "B77W": "wide", "B77L": "wide",
        # regional
        "E75L": "regional", "CRJ7": "regional",
        # biz
        "E55P": "biz", "CL30": "biz", "C25B": "biz",
        "GLF5": "biz", "C510": "biz", "GALX": "biz",
        # ga
        "C172": "ga", "P28A": "ga", "C182": "ga", "M20P": "ga", "C310": "ga",
        "EA50": "ga", "C195": "ga", "P28R": "ga", "PA31": "ga",
        "EC35": "ga",   # Airbus Helicopters H-135 → rotorcraft → ga
        "SSTL": "ga",   # Just Aircraft SuperSTOL → light GA
        "R44": "ga",    # Robinson R44 → rotorcraft → ga
        "T210": "ga",   # Cessna Turbo Centurion → light turbo
        "SR20": "ga",   # Cirrus SR20 → light piston
        "PA24": "ga",   # Piper Comanche → light piston
        "AR11": "ga",   # Aeronca 11 Chief → heritage piston
        "BE20": "ga",   # Beechcraft King Air 200 → turboprop
    }
    print("\n── Acceptance fixture (38 typecodes) ──")
    all_pass = True
    for tc, expected in sorted(FIXTURE.items()):
        got = out.get(tc, {}).get("type", "MISSING")
        status = "OK" if got == expected else "FAIL"
        if status == "FAIL":
            all_pass = False
            print(f"  {status} {tc}: expected={expected!r} got={got!r}")
    if all_pass:
        print(f"  All {len(FIXTURE)} fixture typecodes classified correctly.")
    else:
        print("  SOME FIXTURE CHECKS FAILED — review type rules before committing.")

    # ── Per-type tally ───────────────────────────────────────────────────────
    tally = collections.Counter(e.get("type", "?") for e in out.values())
    print("\n── Per-type tally ──")
    for t in ["ga", "narrow", "wide", "regional", "biz", "mil", "?"]:
        print(f"  {t:8s} {tally.get(t, 0)}")
    print(f"  total    {sum(tally.values())}")


if __name__ == "__main__":
    main()
