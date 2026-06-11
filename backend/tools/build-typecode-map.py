#!/usr/bin/env python3
"""
Build backend/data/faa-typecode-map.json — a mapping from an FAA ACFTREF
"MFR MDL CODE" to an ICAO type designator (DOC 8643), for the WP 1.4b
typecode-enrichment pass.

WHY THIS EXISTS
---------------
The FAA MASTER.txt registry says *which airframe* a US tail is (via its
"MFR MDL CODE"), and ACFTREF.txt resolves that code to messy ALL-CAPS
manufacturer/model strings ("CESSNA" / "172N"). But neither file carries the
ICAO type *designator* ("C172") that the metadata service needs to reach DOC
8643's clean names + rarity. This script builds that bridge once, offline, and
commits the result. The ingest then reads the committed JSON at runtime — no
fuzzy matching on the hot path, fully deterministic.

THREE-PASS MAPPING STRATEGY (documented precedence; first hit wins)
-------------------------------------------------------------------
For each ACFTREF (manufacturer, model) we try, in order:

  1. FAMILY RULES — a curated table of (canonical-make, model-prefix) -> ICAO
     designator. This is where the tail mass lives: Cessna 172*, Piper PA-28*,
     Beech 36* etc. are thousands of registered tails apiece spread across dozens
     of sub-variant model codes (172M/172N/172S...), but they all resolve to a
     handful of DOC 8643 series designators. Each rule's target designator is
     grounded in an actual DOC 8643 ModelFullName for that designator (see the
     inline `# DOC:` comment on every rule) — never guessed from memory.

  2. AIRCRAFT-CHARACTERISTICS XLSX JOIN — the FAA's
     `faa_aircraft_characteristics.xlsx` carries the ICAO designator (col A)
     alongside FAA-style manufacturer (col C) + model (col D). We normalize both
     sides (uppercase, strip punctuation, collapse whitespace, conservative
     series-suffix reduction) and join. FAA naming on both sides → matches well.

  3. DOC 8643 EXACT/NORMALIZED JOIN — normalized (make, model) of the ACFTREF row
     against AircraftTypes.json's (make + model). Catches airframes the xlsx
     (only ~388 high-traffic types) doesn't list.

  4. OVERRIDES — a small per-code hand table for high-tail-count airframes the
     automated passes miss, each grounded in the actual ACFTREF + DOC strings.

VALIDATION
----------
  * Every emitted designator MUST be a key in AircraftTypes.json (the set of
    VALID outputs). A rule pointing at a non-existent designator fails the build.
  * >= 20 known (make, model) -> designator spot-checks must pass, or the build
    fails loudly.

INPUT DATA (not committed — downloaded to a temp dir)
-----------------------------------------------------
ACFTREF.txt / MASTER.txt come from the FAA Releasable Aircraft Database
(https://registry.faa.gov/database/ReleasableAircraft.zip). The FAA's Akamai
front 403s curl's default User-Agent — pass a browser UA
("Mozilla/5.0 ...") and the GET succeeds (HTTP 200). MASTER is only needed to
report tail-weighted coverage; the committed map is keyed by ACFTREF code.

USAGE
-----
  python3 backend/tools/build-typecode-map.py \
      --acftref /tmp/faa/ACFTREF.txt \
      --master  /tmp/faa/MASTER.txt \
      --types   ios/Tailspot/Tailspot/AircraftTypes.json \
      --xlsx    tools/data/faa_aircraft_characteristics.xlsx \
      --out     backend/data/faa-typecode-map.json

--master is optional (omit to skip tail-weighted coverage). Defaults resolve
relative to the repo root when the script lives at backend/tools/.
"""

import argparse
import csv
import json
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# ---------------------------------------------------------------------------
# Normalization helpers
# ---------------------------------------------------------------------------


def norm(s: str) -> str:
    """Uppercase, punctuation/whitespace runs -> single spaces, trimmed."""
    return " ".join(re.sub(r"[^A-Z0-9]+", " ", (s or "").upper()).split())


def norm_tight(s: str) -> str:
    """Uppercase, drop ALL non-alphanumerics (no spaces)."""
    return re.sub(r"[^A-Z0-9]", "", (s or "").upper())


# Canonical manufacturer map: raw FAA/DOC manufacturer string (normalized) -> a
# stable short brand key used only as a JOIN KEY (not for display). Mirrors the
# spirit of tools/generate-aircraft-types.py's CANONICAL_MAKE, scoped to the
# brands that carry real US-registry tail mass. Extend conservatively.
MAKE_CANON = {
    "CIRRUS DESIGN CORP": "CIRRUS",
    "CIRRUS DESIGN": "CIRRUS",
    "CIRRUS": "CIRRUS",
    "CIRRUS AIRCRAFT": "CIRRUS",
    "CESSNA": "CESSNA",
    "CESSNA AIRCRAFT CO": "CESSNA",
    "CESSNA AIRCRAFT": "CESSNA",
    "TEXTRON AVIATION": "CESSNA",
    "TEXTRON AVIATION INC": "CESSNA",
    "PIPER": "PIPER",
    "PIPER AIRCRAFT INC": "PIPER",
    "PIPER AIRCRAFT": "PIPER",
    "PIPER AIRCRAFT CORPORATION": "PIPER",
    "NEW PIPER AIRCRAFT INC": "PIPER",
    "THE NEW PIPER AIRCRAFT INC": "PIPER",
    "BOEING": "BOEING",
    "BOEING COMPANY": "BOEING",
    "THE BOEING COMPANY": "BOEING",
    "AIRBUS": "AIRBUS",
    "AIRBUS INDUSTRIE": "AIRBUS",
    "AIRBUS SAS": "AIRBUS",
    "AIRBUS CANADA": "AIRBUS",
    "AIRBUS INDUSTRIE A G": "AIRBUS",
    "EMBRAER": "EMBRAER",
    "EMBRAER S A": "EMBRAER",
    "EMBRAER SA": "EMBRAER",
    "EMBRAER EMPRESA BRASILEIRA": "EMBRAER",
    "EMBRAER AIRCRAFT": "EMBRAER",
    "BEECH": "BEECH",
    "BEECHCRAFT": "BEECH",
    "BEECHCRAFT CORP": "BEECH",
    "BEECH AIRCRAFT CORP": "BEECH",
    "RAYTHEON AIRCRAFT COMPANY": "BEECH",
    "RAYTHEON AIRCRAFT CO": "BEECH",
    "HAWKER BEECHCRAFT CORP": "BEECH",
    "MOONEY": "MOONEY",
    "MOONEY AIRCRAFT CORP": "MOONEY",
    "MOONEY INTERNATIONAL CORP": "MOONEY",
    "MOONEY AVIATION COMPANY INC": "MOONEY",
    "MOONEY AIRPLANE CO INC": "MOONEY",
    "GULFSTREAM": "GULFSTREAM",
    "GULFSTREAM AEROSPACE": "GULFSTREAM",
    "GULFSTREAM AEROSPACE CORP": "GULFSTREAM",
    "GULFSTREAM AMERICAN CORP": "GULFSTREAM",
    "BOMBARDIER": "BOMBARDIER",
    "BOMBARDIER INC": "BOMBARDIER",
    "BOMBARDIER AEROSPACE": "BOMBARDIER",
    "BOMBARDIER INC CANADAIR": "BOMBARDIER",
    "CANADAIR": "BOMBARDIER",
    "CANADAIR LTD": "BOMBARDIER",
    "LEARJET": "LEARJET",
    "LEARJET INC": "LEARJET",
    "GATES LEARJET": "LEARJET",
    "GATES LEARJET CORP": "LEARJET",
    "ROBINSON HELICOPTER COMPANY": "ROBINSON",
    "ROBINSON HELICOPTER": "ROBINSON",
    "ROBINSON": "ROBINSON",
    "DASSAULT": "DASSAULT",
    "DASSAULT AVIATION": "DASSAULT",
    "DASSAULT BREGUET": "DASSAULT",
    "PILATUS": "PILATUS",
    "PILATUS AIRCRAFT LTD": "PILATUS",
    "PILATUS AIRCRAFT": "PILATUS",
    "DIAMOND": "DIAMOND",
    "DIAMOND AIRCRAFT IND INC": "DIAMOND",
    "DIAMOND AIRCRAFT": "DIAMOND",
    "DIAMOND AIRCRAFT IND GMBH": "DIAMOND",
    "MCDONNELL DOUGLAS": "MCDONNELL DOUGLAS",
    "MCDONNELL DOUGLAS AIRCRAFT CO": "MCDONNELL DOUGLAS",
    "MCDONNELL DOUGLAS CORPORATION": "MCDONNELL DOUGLAS",
    "AERONCA": "AERONCA",
    "AERONCA AIRCRAFT CORP": "AERONCA",
    "BELL": "BELL",
    "BELL HELICOPTER": "BELL",
    "BELL HELICOPTER TEXTRON": "BELL",
    "BELL HELICOPTER TEXTRON CANADA": "BELL",
    "BELL HELICOPTER TEXTRON INC": "BELL",
    "AIR TRACTOR": "AIR TRACTOR",
    "AIR TRACTOR INC": "AIR TRACTOR",
    "GRUMMAN": "GRUMMAN",
    "GRUMMAN AMERICAN AVN CORP": "GRUMMAN AMERICAN",
    "GRUMMAN AMERICAN AVIATION CO": "GRUMMAN AMERICAN",
    "GRUMMAN ACFT ENG CORP": "GRUMMAN",
    "MAULE": "MAULE",
    "MAULE AIRCRAFT CORP": "MAULE",
    "MAULE AEROSPACE TECHNOLOGY": "MAULE",
    "MAULE AEROSPACE TECHNOLOGY INC": "MAULE",
    "AMERICAN CHAMPION": "AMERICAN CHAMPION",
    "AMERICAN CHAMPION AIRCRAFT": "AMERICAN CHAMPION",
    "ATR": "ATR",
    "ATR GIE AVIONS DE TRANSPORT REG": "ATR",
    "SOCATA": "SOCATA",
    "AEROSPATIALE": "SOCATA",
    "EADS SOCATA": "SOCATA",
    "DAHER SOCATA": "SOCATA",
    "DAHER AEROSPACE": "SOCATA",
    "COMPAGNIE DAHER": "SOCATA",
    "DAHER": "SOCATA",
    "AVIAT": "AVIAT",
    "AVIAT INC": "AVIAT",
    "AVIAT AIRCRAFT INC": "AVIAT",
    "CHRISTEN INDUSTRIES INC": "AVIAT",
    "CUB CRAFTERS": "CUB CRAFTERS",
    "CUB CRAFTERS INC": "CUB CRAFTERS",
    "CUBCRAFTERS INC": "CUB CRAFTERS",
    "STINSON": "STINSON",
    "UNIVERSAL STINSON": "STINSON",
    "BELLANCA": "BELLANCA",
    "BELLANCA AIRCRAFT CORP": "BELLANCA",
    "BELLANCA INC": "BELLANCA",
    "CHAMPION": "AMERICAN CHAMPION",
    "AMERICAN CHAMPION AIRCRAFT CORP": "AMERICAN CHAMPION",
    "VANS AIRCRAFT INC": "VANS",
    "VANS AIRCRAFT": "VANS",
    "VAN S AIRCRAFT INC": "VANS",
    "HONDA AIRCRAFT CO LLC": "HONDA",
    "HONDA AIRCRAFT CO": "HONDA",
    "ECLIPSE AVIATION CORP": "ECLIPSE",
    "ECLIPSE AEROSPACE INC": "ECLIPSE",
    "ONE AVIATION CORP": "ECLIPSE",
    "SIKORSKY": "SIKORSKY",
    "SIKORSKY AIRCRAFT CORP": "SIKORSKY",
    "MITSUBISHI": "MITSUBISHI",
    "MITSUBISHI HEAVY IND LTD": "MITSUBISHI",
    "AIRBUS HELICOPTERS": "AIRBUS HELICOPTERS",
    "AIRBUS HELICOPTERS INC": "AIRBUS HELICOPTERS",
    "AIRBUS HELICOPTERS DEUTSCHLAND": "AIRBUS HELICOPTERS",
    "EUROCOPTER": "AIRBUS HELICOPTERS",
    "EUROCOPTER DEUTSCHLAND GMBH": "AIRBUS HELICOPTERS",
    "EUROCOPTER FRANCE": "AIRBUS HELICOPTERS",
    "AMERICAN EUROCOPTER": "AIRBUS HELICOPTERS",
    "AEROSPATIALE HELICOPTER CORP": "AIRBUS HELICOPTERS",
    "BELL TEXTRON CANADA LTD": "BELL",
    "BELL TEXTRON INC": "BELL",
    "BELL TEXTRON": "BELL",
    "ICON AIRCRAFT INC": "ICON",
    "ICON AIRCRAFT": "ICON",
    "ROCKWELL": "ROCKWELL",
    "ROCKWELL INTERNATIONAL": "ROCKWELL",
    "ROCKWELL INTERNATIONAL CORP": "ROCKWELL",
    "NORTH AMERICAN": "NORTH AMERICAN",
    "NORTH AMERICAN AVIATION INC": "NORTH AMERICAN",
    "RYAN": "RYAN",
    "RYAN AERONAUTICAL": "RYAN",
    "RYAN AIRCRAFT": "RYAN",
    "GLOBE": "GLOBE",
    "TEMCO": "TEMCO",
    "ERCOUPE": "ERCOUPE",
    "ALON": "ALON",
    "REPUBLIC": "REPUBLIC",
    "LAKE": "LAKE",
    "LAKE AIRCRAFT": "LAKE",
    "IAI": "IAI",
    "IAI LTD": "IAI",
    "ISRAEL AIRCRAFT INDUSTRIES": "IAI",
    "HAWKER": "BEECH",
    "HAWKER BEECHCRAFT CORP": "BEECH",
    "RAYTHEON CORPORATE JETS INC": "BEECH",
    "GRUMMAN ACFT ENG CORP SCHWEIZER": "GRUMMAN",
    "GRUMMAN ACFT ENG COR SCHWEIZER": "GRUMMAN",
    "DEHAVILLAND": "DE HAVILLAND",
    "DE HAVILLAND": "DE HAVILLAND",
    "DE HAVILLAND INC": "DE HAVILLAND",
    "DEHAVILLAND INC": "DE HAVILLAND",
    "TAYLORCRAFT": "TAYLORCRAFT",
    "TAYLORCRAFT AVIATION CORP": "TAYLORCRAFT",
    "TAYLORCRAFT AVIATION": "TAYLORCRAFT",
    "LANCAIR": "LANCAIR",
    "LANCAIR COMPANY": "LANCAIR",
    "LANCAIR INTERNATIONAL INC": "LANCAIR",
    "COLUMBIA AIRCRAFT MFG": "COLUMBIA AIRCRAFT",
    "COLUMBIA AIRCRAFT MFG CORP": "COLUMBIA AIRCRAFT",
    "AERO COMMANDER": "AERO COMMANDER",
    "AERO": "AERO COMMANDER",
    "AERO COMMANDER DIV": "AERO COMMANDER",
    "ROCKWELL COMMANDER": "AERO COMMANDER",
    "AMERICAN": "AMERICAN",
    "AMERICAN AVIATION": "AMERICAN",
    "AMERICAN AVIATION CORP": "AMERICAN",
    "CONSOLIDATED AERONAUTICS": "CONSOLIDATED AERONAUTICS",
    "CONSOLIDATED AERONAUTICS INC": "CONSOLIDATED AERONAUTICS",
    "AGUSTA": "AGUSTA",
    "AGUSTAWESTLAND": "AGUSTAWESTLAND",
    "LEONARDO": "LEONARDO",
    "LEONARDO SPA": "LEONARDO",
}


# Brands whose FAA registrant string drifts across many subsidiary spellings
# ("EMBRAER S A" / "EMBRAER EXECUTIVE AIRCRAFT" / "EMBRAER-EMPRESA BRASILEIRA").
# A leading-token prefix collapses them all to one canonical key.
MAKE_PREFIX_CANON = {
    "EMBRAER": "EMBRAER",
    "CIRRUS": "CIRRUS",
    "ROBINSON": "ROBINSON",
    "AIR TRACTOR": "AIR TRACTOR",
    "EUROCOPTER": "AIRBUS HELICOPTERS",
    # Airbus Helicopters must be checked BEFORE the bare "AIRBUS" prefix so the
    # rotorcraft brand isn't swallowed by the airliner canon.
    "AIRBUS HELICOPTERS": "AIRBUS HELICOPTERS",
    "AIRBUS CANADA": "AIRBUS",
    "AIRBUS": "AIRBUS",
    "VANS": "VANS",
    "CUB CRAFTERS": "CUB CRAFTERS",
    "TAYLORCRAFT": "TAYLORCRAFT",
    "DE HAVILLAND": "DE HAVILLAND",
    "DEHAVILLAND": "DE HAVILLAND",
    "QUEST AIRCRAFT": "QUEST AIRCRAFT",
    "NANCHANG": "NANCHANG",
    "AERO VODOCHODY": "AERO VODOCHODY",
    "LANCAIR": "LANCAIR",
    "COLUMBIA AIRCRAFT": "COLUMBIA AIRCRAFT",
    "AGUSTAWESTLAND": "AGUSTAWESTLAND",
    "AGUSTA": "AGUSTA",
    "LEONARDO": "LEONARDO",
    "CONSOLIDATED AERONAUTICS": "CONSOLIDATED AERONAUTICS",
}


def canon_make(raw: str) -> str:
    n = norm(raw)
    if n in MAKE_CANON:
        return MAKE_CANON[n]
    for prefix, canon in MAKE_PREFIX_CANON.items():
        if n == prefix or n.startswith(prefix + " "):
            return canon
    return n


def strip_leading_make(canon: str, model_norm: str) -> str:
    """Remove a leading run of make tokens from a normalized model string.

    The xlsx/DOC model strings are often "Cirrus SR22" / "Cessna 172"; the make
    prefix is noise for joining against ACFTREF's make-less model column.
    """
    toks = model_norm.split()
    mk = canon.split()
    i = 0
    while i < len(toks) and i < len(mk) and toks[i] == mk[i]:
        i += 1
    return " ".join(toks[i:]) if i else model_norm


def model_variants(model: str):
    """Yield candidate normalized model keys for the automated joins, most
    specific first. Conservative series-suffix reduction so '172M' also tries
    '172', 'PA-28-181' also tries 'PA28', 'M20J' also tries 'M20'."""
    base = norm(model)
    tight = norm_tight(base)
    seen = set()

    def emit(v):
        if v and v not in seen:
            seen.add(v)
            return True
        return False

    if emit(tight):
        yield tight
    # NNN + optional trailing letters: 172M -> 172, 182P -> 182
    m = re.match(r"^(\d{2,4})[A-Z]{0,3}$", tight)
    if m and emit(m.group(1)):
        yield m.group(1)
    # PAxx... -> PAxx (drop dash-number sub-series): PA28181 -> PA28
    m = re.match(r"^(PA\d{2})", tight)
    if m and emit(m.group(1)):
        yield m.group(1)
    # Mooney M20J -> M20
    m = re.match(r"^(M\d{2})", tight)
    if m and emit(m.group(1)):
        yield m.group(1)


# ---------------------------------------------------------------------------
# Pass 1: family rules — (canon_make, model-prefix-regex) -> ICAO designator.
#
# Ordered list; FIRST matching rule wins, so put more-specific prefixes (172RG,
# PA-28R) BEFORE the broad series (172, PA-28). Every target designator carries a
# `# DOC:` note with the AircraftTypes.json ModelFullName that grounds it. The
# regex matches against norm(model) (uppercased, punctuation->spaces).
# ---------------------------------------------------------------------------
FAMILY_RULES = [
    # --- Cessna singles (retractable variants first) -------------------------
    ("CESSNA", r"^172RG(?!\d)", "C72R"),   # DOC: Cessna 172RG Cutlass
    ("CESSNA", r"^177RG(?!\d)", "C77R"),   # DOC: Cessna 177RG Cardinal
    ("CESSNA", r"^R182(?!\d)", "C82R"),    # DOC: Cessna R182 Skylane RG
    ("CESSNA", r"^TR?182(?!\d)", "C82R"),  # TR182 turbo retract -> same RG designator
    ("CESSNA", r"^P210(?!\d)", "P210"),    # DOC: Cessna P210 Centurion
    ("CESSNA", r"^T210(?!\d)", "T210"),    # DOC: Cessna T210 Turbo Centurion
    ("CESSNA", r"^(A|TU|T|U|P)?206(?!\d)", "C206"),  # DOC: Cessna 206 Stationair (incl A206/U206/TU206/P206)
    ("CESSNA", r"^(A|T)?185(?!\d)", "C185"),  # DOC: Cessna 185 Skywagon (A185F etc)
    ("CESSNA", r"^140(?!\d)", "C140"),     # DOC: Cessna 140
    ("CESSNA", r"^A?150(?!\d)", "C150"),   # DOC: Cessna 150 (incl A150 Aerobat)
    ("CESSNA", r"^A?152(?!\d)", "C152"),   # DOC: Cessna 152 (incl A152 Aerobat)
    ("CESSNA", r"^336(?!\d)", "C336"),     # DOC: 336 Skymaster
    ("CESSNA", r"^M?337", "C337"),         # DOC: 337 Super Skymaster (M337 military)
    ("CESSNA", r"^170(?!\d)", "C170"),     # DOC: Cessna 170
    ("CESSNA", r"^172(?!\d)", "C172"),     # DOC: Cessna 172
    ("CESSNA", r"^175(?!\d)", "C175"),     # DOC: Cessna 175 Skylark
    ("CESSNA", r"^177(?!\d)", "C177"),     # DOC: Cessna 177
    ("CESSNA", r"^180(?!\d)", "C180"),     # DOC: Cessna 180
    ("CESSNA", r"^(T)?182(?!\d)", "C182"), # DOC: Cessna 182 Skylane
    ("CESSNA", r"^188(?!\d)", "C188"),     # DOC: Cessna 188 Husky / Ag Wagon
    ("CESSNA", r"^190(?!\d)", "C190"),     # DOC: Cessna 190
    ("CESSNA", r"^195(?!\d)", "C195"),     # DOC: Cessna 195
    ("CESSNA", r"^(T)?210(?!\d)", "C210"), # DOC: Cessna 210
    # --- Cessna twins --------------------------------------------------------
    ("CESSNA", r"^T?310(?!\d)", "C310"),   # DOC: Cessna 310 (incl T310R)
    ("CESSNA", r"^S550", "C550"),          # DOC: 550 Citation II (S550 Citation S/II)
    ("CESSNA", r"^S551", "C550"),          # DOC: 550 (S551)
    ("CESSNA", r"^T303(?!\d)", "C303"),    # DOC: Cessna T303 Crusader
    ("CESSNA", r"^335(?!\d)", "C335"),     # DOC: Cessna 335
    ("CESSNA", r"^340(?!\d)", "C340"),     # DOC: Cessna 340
    ("CESSNA", r"^401(?!\d)", "C402"),     # DOC: Cessna 402 (401/402 share the C402 designator)
    ("CESSNA", r"^402(?!\d)", "C402"),     # DOC: Cessna 402
    ("CESSNA", r"^404(?!\d)", "C404"),     # DOC: Cessna 404 Titan
    ("CESSNA", r"^414(?!\d)", "C414"),     # DOC: Cessna 414
    ("CESSNA", r"^421(?!\d)", "C421"),     # DOC: Cessna 421
    ("CESSNA", r"^425(?!\d)", "C425"),     # DOC: Cessna 425 Conquest 1
    ("CESSNA", r"^441(?!\d)", "C441"),     # DOC: Cessna 441 Conquest 2
    # --- Piper PA-28 / PA-32 retractables before the broad series ------------
    ("PIPER", r"^PA[\s-]*28RT", "P28T"),  # DOC: Piper PA-28RT-201 Arrow 4
    ("PIPER", r"^PA[\s-]*28R[\s-]*201T", "P28S"),  # DOC: PA-28R-201T Turbo Arrow
    ("PIPER", r"^PA[\s-]*28R", "P28R"),   # DOC: Piper PA-28R-201 Arrow
    ("PIPER", r"^PA[\s-]*28[\s-]*23[56](?!\d)", "P28B"),  # DOC: PA-28-236 Dakota (235/236)
    ("PIPER", r"^PA[\s-]*28", "P28A"),    # DOC: Piper PA-28 Cherokee (140/150/160/161/180/181)
    ("PIPER", r"^PA[\s-]*32RT", "P32T"),  # DOC: PA-32RT-300T Turbo Lance 2
    ("PIPER", r"^PA[\s-]*32R", "P32R"),   # DOC: Piper PA-32R-300 Lance
    ("PIPER", r"^PA[\s-]*32", "PA32"),    # DOC: Piper PA-32 6X (Cherokee Six / Saratoga)
    # --- Piper broad series --------------------------------------------------
    ("PIPER", r"^J2(?!\d)", "J2"),            # DOC: Piper J-2 Cub
    ("PIPER", r"^J3(?!\d)", "J3"),            # DOC: Piper J-3 Cub
    ("PIPER", r"^J3C", "J3"),             # DOC: Piper J-3 Cub
    ("PIPER", r"^J4(?!\d)", "J4"),            # DOC: Piper J-4 Cub Coupe
    ("PIPER", r"^J5(?!\d)", "J5"),            # DOC: Piper J-5 Cub Cruiser
    ("PIPER", r"^PA[\s-]*15", "PA15"),    # DOC: Piper PA-15 Vagabond
    ("PIPER", r"^L[\s-]*21", "PA18"),     # DOC: PA-18 (L-21 is the military Super Cub)
    ("PIPER", r"^PA[\s-]*42[\s-]*1000", "PAY4"),  # DOC: PA-42-1000 Cheyenne 400
    ("PIPER", r"^PA[\s-]*42", "PAY3"),    # DOC: PA-42-720 Cheyenne 3
    ("PIPER", r"^PA[\s-]*31T", "PAY2"),   # DOC: PA-31T Cheyenne (T1->PAY1/T->PAY2)
    ("PIPER", r"^PA[\s-]*60", "AEST"),    # DOC: Aerostar 600/601/602 (PA-60)
    ("PIPER", r"^PA[\s-]*11", "PA11"),    # DOC: Piper PA-11 Cub Special
    ("PIPER", r"^PA[\s-]*12", "PA12"),    # DOC: Piper PA-12 Super Cruiser
    ("PIPER", r"^PA[\s-]*14", "PA14"),    # DOC: Piper PA-14 Family Cruiser
    ("PIPER", r"^PA[\s-]*16", "PA16"),    # DOC: Piper PA-16 Clipper
    ("PIPER", r"^PA[\s-]*17", "PA17"),    # DOC: Piper PA-17 Vagabond
    ("PIPER", r"^PA[\s-]*18", "PA18"),    # DOC: Piper PA-18 Super Cub
    ("PIPER", r"^PA[\s-]*20", "PA20"),    # DOC: Piper PA-20 Pacer
    ("PIPER", r"^PA[\s-]*22", "PA22"),    # DOC: Piper PA-22 Colt / Tri-Pacer
    ("PIPER", r"^PA[\s-]*23", "PA23"),    # DOC: Piper PA-23-150 Apache / Aztec
    ("PIPER", r"^PA[\s-]*24", "PA24"),    # DOC: Piper PA-24 Comanche
    ("PIPER", r"^PA[\s-]*25", "PA25"),    # DOC: Piper PA-25 Pawnee
    ("PIPER", r"^PA[\s-]*30", "PA30"),    # DOC: Piper PA-30 Twin Comanche
    ("PIPER", r"^PA[\s-]*31", "PA31"),    # DOC: Piper PA-31-300 Navajo
    ("PIPER", r"^PA[\s-]*34", "PA34"),    # DOC: Piper PA-34 Seneca
    ("PIPER", r"^PA[\s-]*36", "PA36"),    # DOC: Piper PA-36 Pawnee Brave
    ("PIPER", r"^PA[\s-]*38", "PA38"),    # DOC: PA-38 Tomahawk
    ("PIPER", r"^PA[\s-]*39", "PA30"),    # DOC: PA-30 Twin Comanche (PA-39 is the counter-rotating variant)
    ("PIPER", r"^PA[\s-]*44", "PA44"),    # DOC: Piper PA-44 Seminole
    ("PIPER", r"^PA[\s-]*46", "PA46"),    # DOC: PA-46-350P M350 (Malibu/Mirage/Matrix)
    # --- Beechcraft Bonanza / Baron / King Air / Twin Beech ------------------
    # Beech variants prefix a single series letter ("V35B", "E-55", "C23") and
    # the King Airs carry a "65-" Queen-Air-lineage prefix ("65-A90", "65-B80").
    # P = the optional leading "[A-Z]-?" model letter; handle 65- separately.
    ("BEECH", r"^[A-Z]?[\s-]?35(?!\d)", "BE35"),   # DOC: 35 Bonanza (V-tail, incl V35/M35)
    ("BEECH", r"^[A-Z]?[\s-]?33(?!\d)", "BE33"),   # DOC: 33 Bonanza (Debonair, F33A)
    ("BEECH", r"^[A-Z]?[\s-]?36(?!\d)", "BE36"),   # DOC: 36 Bonanza 36 (A36/G36)
    ("BEECH", r"^[A-Z]?[\s-]?55(?!\d)", "BE55"),   # DOC: 55 Baron (incl E-55, 56TC->no)
    ("BEECH", r"^[A-Z]?[\s-]?58(?!\d)", "BE58"),   # DOC: 58 Baron
    ("BEECH", r"^[A-Z]?[\s-]?76(?!\d)", "BE76"),   # DOC: 76 Duchess
    ("BEECH", r"^[A-Z]?[\s-]?95(?!\d)", "BE95"),   # DOC: 95 Travel Air
    ("BEECH", r"^[A-Z]?[\s-]?60(?!\d)", "BE60"),   # DOC: 60 Duke (B-60)
    ("BEECH", r"^65[\s-]*A?B?C?[\s-]*90", "BE9L"),  # DOC: 90 King Air (65-A90 lineage)
    ("BEECH", r"^65[\s-]*B?80", "BE80"),       # DOC: 80 Queen Air (65-B80)
    ("BEECH", r"^65(?!\d)", "BE65"),           # DOC: 65 Queen Air
    ("BEECH", r"^[A-Z]?[\s-]?90(?!\d)", "BE9L"),   # DOC: 90 King Air (C90/E90/F90)
    ("BEECH", r"^F90(?!\d)", "BE9L"),          # DOC: 90 King Air (F90 is a 90-series)
    ("BEECH", r"^[A-Z]?[\s-]?100(?!\d)", "BE10"),  # DOC: 100 King Air (A100/B100)
    ("BEECH", r"^[A-Z]?[\s-]?200(?!\d)", "BE20"),  # DOC: 200 Super King Air (B200)
    ("BEECH", r"^B300(?!\d)", "B350"),         # DOC: 350 Super King Air
    ("BEECH", r"^300(?!\d)", "BE30"),          # DOC: 300 Super King Air
    ("BEECH", r"^350(?!\d)", "B350"),          # DOC: 350 Super King Air
    ("BEECH", r"^99(?!\d)", "BE99"),           # DOC: 99 Airliner
    ("BEECH", r"^1900(?!\d)", "B190"),         # DOC: Beechcraft 1900
    ("BEECH", r"^[A-Z]?[\s-]?18(?!\d)", "BE18"),   # DOC: Beechcraft 18 (Twin Beech, H-18)
    ("BEECH", r"^[A-Z]?[\s-]?23(?!\d)", "BE23"),   # DOC: 23 Musketeer / Sundowner (C23)
    ("BEECH", r"^[A-Z]?[\s-]?24(?!\d)", "BE24"),   # DOC: 24 Sierra
    ("BEECH", r"^[A-Z]?[\s-]?19(?!\d)", "BE19"),   # DOC: 19 Sport (B19)
    ("BEECH", r"^[A-Z]?[\s-]?17(?!\d)", "BE17"),   # DOC: 17 Staggerwing (D17S/G17S/F17D)
    ("BEECH", r"^77(?!\d)", "BE77"),           # DOC: 77 Skipper
    ("BEECH", r"^400(?!\d)", "BE40"),          # DOC: 400A Beechjet
    ("BEECH", r"^HAWKER[\s-]*4000", "HA4T"),   # DOC: Hawker 4000
    # The C-45 is the MILITARY Twin Beech 18 — match it BEFORE the Model-45
    # Mentor rule (which would otherwise swallow "C-45" via its [A-Z]? prefix).
    ("BEECH", r"^C[\s-]?45", "BE18"),          # DOC: 18 (C-45 military Twin Beech)
    # T-34 Mentor (Beech Model 45): A45 / D-45 / T-34A/B (piston) and T-34C.
    ("BEECH", r"^T[\s-]*34C", "T34T"),         # DOC: T-34C Turbo Mentor
    ("BEECH", r"^T[\s-]*34", "T34P"),          # DOC: 45 Mentor (T-34A/B)
    ("BEECH", r"^[ABDE][\s-]?45", "T34P"),     # DOC: 45 Mentor (A45/D-45 piston Mentor)
    ("BEECH", r"^45(?!\d)", "T34P"),           # DOC: 45 Mentor (bare 45)
    ("BEECH", r"^[A-Z]?[\s-]?99(?!\d)", "BE99"),   # DOC: 99 Airliner (C-99)
    # --- Airbus airliners (FAA "A3NN-NNN" with engine/neo suffix) ------------
    # The "-NNN" suffix encodes the engine; "N"/"NX" marks the neo. Match the
    # base family, with neo variants taking precedence.
    ("AIRBUS", r"^A318", "A318"),                       # DOC: A318
    ("AIRBUS", r"^A319[\s-]*1?[\d]*N", "A19N"),         # A319neo (…-171N etc)
    ("AIRBUS", r"^A319", "A319"),                       # DOC: A319
    ("AIRBUS", r"^A320[\s-]*2[\d]*N", "A20N"),          # A320neo (…-251N/271N)
    ("AIRBUS", r"^A320", "A320"),                       # DOC: A320
    ("AIRBUS", r"^A321[\s-]*2[\d]*N", "A21N"),          # A321neo (…-271N/271NX/253NX)
    ("AIRBUS", r"^A321", "A321"),                       # DOC: A321
    ("AIRBUS", r"^A330[\s-]*9", "A339"),                # A330-900neo
    ("AIRBUS", r"^A330[\s-]*8", "A338"),                # A330-800neo
    ("AIRBUS", r"^A330[\s-]*2", "A332"),                # A330-200
    ("AIRBUS", r"^A330[\s-]*3", "A333"),                # A330-300
    ("AIRBUS", r"^A350[\s-]*9", "A359"),                # A350-900
    ("AIRBUS", r"^A350[\s-]*10", "A35K"),               # A350-1000
    ("AIRBUS", r"^A380", "A388"),                       # A380-800
    ("AIRBUS", r"^A300", "A306"),                       # A300-600 family
    ("AIRBUS", r"^A310", "A310"),                       # A310
    ("AIRBUS", r"^BD[\s-]*500[\s-]*1A11", "BCS3"),      # A220-300 (BD-500-1A11)
    ("AIRBUS", r"^BD[\s-]*500[\s-]*1A10", "BCS1"),      # A220-100 (BD-500-1A10)
    # --- Cirrus --------------------------------------------------------------
    ("CIRRUS", r"^SR20(?!\d)", "SR20"),    # DOC: Cirrus SR20
    ("CIRRUS", r"^SR22T(?!\d)", "S22T"),   # DOC: Cirrus SR-22T
    ("CIRRUS", r"^SR22(?!\d)", "SR22"),    # DOC: Cirrus SR-22
    ("CIRRUS", r"^SF50(?!\d)", "SF50"),    # DOC: Cirrus SF50 Vision Jet
    # --- Mooney M20 ----------------------------------------------------------
    ("MOONEY", r"^M20[KLMRST](?!\d)", "M20T"),  # DOC: M-20K 231 (turbo/K-derived)
    ("MOONEY", r"^M20", "M20P"),            # DOC: Mooney M20 (piston A-J)
    ("MOONEY", r"^M22", "M22"),             # DOC: Mooney M-22 Mustang
    # --- Robinson ------------------------------------------------------------
    ("ROBINSON", r"^R22", "R22"),   # DOC: Robinson R-22
    ("ROBINSON", r"^R44", "R44"),   # DOC: Robinson R44
    ("ROBINSON", r"^R66", "R66"),   # DOC: Robinson R-66
    # --- Grumman American light singles --------------------------------------
    ("GRUMMAN AMERICAN", r"^AA[\s-]*1", "AA1"),  # DOC: AA-1 (Yankee/Trainer/Tr2)
    ("GRUMMAN AMERICAN", r"^AA[\s-]*5", "AA5"),  # DOC: AA-5 Tiger / Cheetah
    ("GRUMMAN", r"^AA[\s-]*1", "AA1"),
    ("GRUMMAN", r"^AA[\s-]*5", "AA5"),
    # --- Diamond -------------------------------------------------------------
    ("DIAMOND", r"^DA[\s-]*20", "DV20"),  # DOC: DA-20 Falcon (DV20/DA20)
    ("DIAMOND", r"^DA[\s-]*40", "DA40"),  # DOC: DA-40 Katana / Star
    ("DIAMOND", r"^DA[\s-]*42", "DA42"),  # DOC: DA-42 Twin Star
    ("DIAMOND", r"^DA[\s-]*62", "DA62"),  # DOC: DA-62
    # --- Boeing airliners (model-number prefixes) ----------------------------
    ("BOEING", r"^737[\s-]*7", "B737"),  # DOC: 737-700
    ("BOEING", r"^737[\s-]*8", "B738"),  # DOC: 737-800
    ("BOEING", r"^737[\s-]*9", "B739"),  # DOC: 737-900
    ("BOEING", r"^737[\s-]*6", "B736"),  # DOC: 737-600
    ("BOEING", r"^737[\s-]*5", "B735"),  # DOC: 737-500
    ("BOEING", r"^737[\s-]*4", "B734"),  # DOC: 737-400
    ("BOEING", r"^737[\s-]*3", "B733"),  # DOC: 737-300
    ("BOEING", r"^757[\s-]*2", "B752"),  # DOC: 757-200
    ("BOEING", r"^757[\s-]*3", "B753"),  # DOC: 757-300
    ("BOEING", r"^767[\s-]*2", "B762"),  # DOC: 767-200
    ("BOEING", r"^767[\s-]*3", "B763"),  # DOC: 767-300
    ("BOEING", r"^767[\s-]*4", "B764"),  # DOC: 767-400
    ("BOEING", r"^777[\s-]*2", "B772"),  # DOC: 777-200
    ("BOEING", r"^777[\s-]*3", "B77W"),  # DOC: 777-300ER
    ("BOEING", r"^787[\s-]*8", "B788"),  # DOC: 787-8 Dreamliner
    ("BOEING", r"^787[\s-]*9", "B789"),  # DOC: 787-9 Dreamliner
    # --- Embraer / regional --------------------------------------------------
    # FAA names the E-Jet family by its program number: "ERJ 170-100*" is the
    # E170, "ERJ 170-200*" is the stretched E175 (DOC E75L), "ERJ 190-100*" the
    # E190. Order the -200 (175) rule before -100 (170) doesn't matter (distinct
    # prefixes), but list explicitly.
    ("EMBRAER", r"^ERJ[\s-]*170[\s-]*200", "E75L"),  # DOC: 175 (ERJ 170-200 = E175)
    ("EMBRAER", r"^ERJ[\s-]*170[\s-]*100", "E170"),  # DOC: 170
    ("EMBRAER", r"^ERJ[\s-]*175", "E75L"),           # DOC: 175
    ("EMBRAER", r"^ERJ[\s-]*170", "E170"),           # DOC: 170 (bare 170)
    ("EMBRAER", r"^ERJ[\s-]*190[\s-]*200", "E195"),  # DOC: 195 (ERJ 190-200 = E195)
    ("EMBRAER", r"^ERJ[\s-]*190", "E190"),           # DOC: 190
    ("EMBRAER", r"^ERJ[\s-]*195", "E195"),           # DOC: 195
    ("EMBRAER", r"^EMB[\s-]*110", "E110"),  # DOC: EMB-110 Bandeirante
    ("EMBRAER", r"^EMB[\s-]*120", "E120"),  # DOC: EMB-120 Brasilia
    ("EMBRAER", r"^EMB[\s-]*135", "E135"),  # DOC: ERJ-135 (EMB-135 variants)
    ("EMBRAER", r"^EMB[\s-]*145", "E145"),  # DOC: ERJ-145 (EMB-145 variants)
    ("EMBRAER", r"^EMB[\s-]*505", "E55P"),  # DOC: EMB-505 Phenom 300
    ("EMBRAER", r"^EMB[\s-]*500", "E50P"),  # DOC: EMB-500 Phenom 100
    ("EMBRAER", r"^EMB[\s-]*545", "E545"),  # DOC: EMB-545 Legacy 450
    ("EMBRAER", r"^EMB[\s-]*550", "E550"),  # DOC: EMB-550 Legacy 500
    # --- Pilatus -------------------------------------------------------------
    ("PILATUS", r"^PC[\s-]*12", "PC12"),  # DOC: Pilatus PC-12
    ("PILATUS", r"^PC[\s-]*24", "PC24"),  # DOC: Pilatus PC-24
    # --- Learjet -------------------------------------------------------------
    ("LEARJET", r"^23(?!\d)", "LJ23"),   # DOC: Learjet 23
    ("LEARJET", r"^24(?!\d)", "LJ24"),   # DOC: Learjet 24
    ("LEARJET", r"^25(?!\d)", "LJ25"),   # DOC: Learjet 25
    ("LEARJET", r"^31(?!\d)", "LJ31"),   # DOC: Learjet 31
    ("LEARJET", r"^35(?!\d)", "LJ35"),   # DOC: Learjet 35
    ("LEARJET", r"^36(?!\d)", "LJ35"),   # DOC: LJ35 covers the 36
    ("LEARJET", r"^45(?!\d)", "LJ45"),   # DOC: Learjet 45
    ("LEARJET", r"^55(?!\d)", "LJ55"),   # DOC: Learjet 55
    ("LEARJET", r"^60(?!\d)", "LJ60"),   # DOC: Learjet 60
    # --- Cessna Citation jets (5xx series; specific CJ sub-models first) ------
    ("CESSNA", r"^525C(?!\d)", "C25C"),  # DOC: 525C Citation CJ4
    ("CESSNA", r"^525B(?!\d)", "C25B"),  # DOC: 525B Citation CJ3
    ("CESSNA", r"^525A(?!\d)", "C25A"),  # DOC: 525A Citation CJ2
    ("CESSNA", r"^525(?!\d)", "C525"),   # DOC: 525 CitationJet
    ("CESSNA", r"^500(?!\d)", "C500"),   # DOC: 500 Citation
    ("CESSNA", r"^501(?!\d)", "C500"),   # DOC: 501 is the single-pilot Citation I -> C500
    ("CESSNA", r"^510(?!\d)", "C510"),   # DOC: 510 Citation Mustang
    ("CESSNA", r"^550(?!\d)", "C550"),   # DOC: 550 Citation II
    ("CESSNA", r"^551(?!\d)", "C550"),   # DOC: 551 is the single-pilot Citation II/SP -> C550
    ("CESSNA", r"^560XL", "C56X"),       # DOC: 560XL Citation XLS (560XL/560XLS)
    ("CESSNA", r"^560(?!\d)", "C560"),   # DOC: 560 Citation V
    ("CESSNA", r"^650(?!\d)", "C650"),   # DOC: 650 Citation VII
    ("CESSNA", r"^680A", "C68A"),        # DOC: 680A Citation Latitude
    ("CESSNA", r"^680(?!\d)", "C680"),   # DOC: 680 Citation Sovereign
    ("CESSNA", r"^700(?!\d)", "C700"),   # DOC: 700 Citation Longitude
    ("CESSNA", r"^750(?!\d)", "C750"),   # DOC: 750 Citation 10
    ("CESSNA", r"^208(?!\d)", "C208"),   # DOC: 208 Caravan (208/208B)
    ("CESSNA", r"^R172", "C172"),        # DOC: 172 (R172K Hawk XP -> 172 family)
    ("CESSNA", r"^408", "C408"),         # DOC: 408 SkyCourier
    ("CESSNA", r"^T240", "COL4"),        # DOC: TTx (T240 -> Cessna 400/TTx)
    # Textron Aviation now owns Beechcraft; these distinctively-Beech models are
    # registered under the "TEXTRON AVIATION" make (which canon folds to the
    # Cessna key), so map them here under CESSNA. Each is unambiguously Beech.
    ("CESSNA", r"^B300C?(?!\d)", "B350"),  # DOC: 350 Super King Air (B300/B300C)
    ("CESSNA", r"^B200", "BE20"),          # DOC: 200 Super King Air (B200GT/B200CGT)
    ("CESSNA", r"^C90", "BE9L"),           # DOC: 90 King Air (C90GTI)
    ("CESSNA", r"^G36(?!\d)", "BE36"),     # DOC: 36 Bonanza (G36)
    ("CESSNA", r"^G58(?!\d)", "BE58"),     # DOC: 58 Baron (G58)
    ("CESSNA", r"^F33", "BE33"),           # DOC: 33 Bonanza (F33C aerobatic)
    # --- Bombardier CL-600 / BD-700 program codes (grounded in FAA strings) ---
    # FAA labels by certificate program number; these map to marketing types:
    ("BOMBARDIER", r"^CL[\s-]*600[\s-]*2B19", "CRJ2"),  # CL-600-2B19 = CRJ100/200
    ("BOMBARDIER", r"^CL[\s-]*600[\s-]*2C10", "CRJ7"),  # CL-600-2C10 = CRJ700
    ("BOMBARDIER", r"^CL[\s-]*600[\s-]*2C11", "CRJ7"),  # CL-600-2C11 = CRJ705 (CRJ700 fam)
    ("BOMBARDIER", r"^CL[\s-]*600[\s-]*2D24", "CRJ9"),  # CL-600-2D24 = CRJ900
    ("BOMBARDIER", r"^CL[\s-]*600[\s-]*2E25", "CRJX"),  # CL-600-2E25 = CRJ1000
    ("BOMBARDIER", r"^CL[\s-]*600[\s-]*2B16", "CL60"),  # CL-600-2B16 = Challenger 601/604/605
    ("BOMBARDIER", r"^CL[\s-]*600[\s-]*1A11", "CL60"),  # CL-600-1A11 = Challenger 600
    ("BOMBARDIER", r"^BD[\s-]*700[\s-]*1A10", "GLEX"),  # BD-700-1A10 = Global Express/6000
    ("BOMBARDIER", r"^BD[\s-]*700[\s-]*1A11", "GL5T"),  # BD-700-1A11 = Global 5000
    ("BOMBARDIER", r"^BD[\s-]*700[\s-]*2A12", "GL7T"),  # BD-700-2A12 = Global 7500
    ("BOMBARDIER", r"^BD[\s-]*100", "CL30"),            # BD-100 = Challenger 300/350
    # --- Gulfstream large-cabin (grounded in FAA GV-SP / GVII strings) --------
    ("GULFSTREAM", r"^GVIII[\s-]*G700", "GA7C"),  # GVIII-G700 -> G700
    ("GULFSTREAM", r"^GVIII[\s-]*G800", "GA8C"),  # GVIII-G800 -> G800
    ("GULFSTREAM", r"^GVII[\s-]*G500", "GA5C"),   # GVII-G500 -> G500
    ("GULFSTREAM", r"^GVII[\s-]*G600", "GA6C"),   # GVII-G600 -> G600
    ("GULFSTREAM", r"^GVI(?!I)", "GLF6"),         # GVI (G650/G650ER) -> GLF6
    ("GULFSTREAM", r"^GV[\s-]*SP", "GLF5"),       # GV-SP (G550) -> GLF5
    ("GULFSTREAM", r"^G[\s-]*V(?![I])", "GLF5"),  # G-V -> GLF5
    ("GULFSTREAM", r"^GIV[\s-]*X", "GLF4"),       # GIV-X (G450) -> GLF4
    ("GULFSTREAM", r"^G[\s-]*IV", "GLF4"),        # G-IV -> GLF4
    ("GULFSTREAM", r"^G[\s-]*III", "GLF3"),       # G-III -> GLF3
    ("GULFSTREAM", r"^G[\s-]*II", "GLF2"),        # G-II -> GLF2
    ("GULFSTREAM", r"^G150(?!\d)", "G150"),       # G150
    ("GULFSTREAM", r"^G200(?!\d)", "GALX"),       # G200 (Galaxy)
    ("GULFSTREAM", r"^G280(?!\d)", "G280"),       # G280
    # Grumman-American light singles sold under the Gulfstream American name:
    ("GULFSTREAM", r"^AA[\s-]*1", "AA1"),         # AA-1
    ("GULFSTREAM", r"^AA[\s-]*5", "AA5"),         # AA-5 Tiger/Cheetah
    # --- Air Tractor ag planes (AT-NNN program -> turbine/piston designator) --
    ("AIR TRACTOR", r"^AT[\s-]*802", "AT8T"),  # DOC: AT-802
    ("AIR TRACTOR", r"^AT[\s-]*602", "AT6T"),  # DOC: AT-602
    ("AIR TRACTOR", r"^AT[\s-]*502", "AT5T"),  # DOC: AT-502
    ("AIR TRACTOR", r"^AT[\s-]*3", "AT3T"),    # DOC: AT-301/302 Air Tractor
    # --- Hawker (800XP and the BAe 125 lineage) ------------------------------
    ("BEECH", r"^HAWKER[\s-]*800", "H25B"),  # DOC: Hawker 800XP (Raytheon/Hawker Beech)
    # --- Stinson 108 ---------------------------------------------------------
    ("STINSON", r"^108", "S108"),  # DOC: Stinson 108 Voyager (108-1/2/3)
    # --- Cirrus jet handled above; Pilatus/Socata turboprops -----------------
    ("SOCATA", r"^TBM[\s-]*9", "TBM9"),  # DOC: TBM-910/940
    ("SOCATA", r"^TBM[\s-]*8", "TBM8"),  # DOC: TBM-850
    ("SOCATA", r"^TBM[\s-]*7", "TBM7"),  # DOC: TBM-700A
    # --- Vans RV homebuilts (model number -> RVn designator) -----------------
    ("VANS", r"^RV[\s-]*14", "RV14"),  # DOC: Van's RV-14
    ("VANS", r"^RV[\s-]*12", "RV12"),  # DOC: Van's RV-12
    ("VANS", r"^RV[\s-]*10", "RV10"),  # DOC: Van's RV-10
    ("VANS", r"^RV[\s-]*9", "RV9"),    # DOC: Van's RV-9
    ("VANS", r"^RV[\s-]*8", "RV8"),    # DOC: Van's RV-8
    ("VANS", r"^RV[\s-]*7", "RV7"),    # DOC: Van's RV-7
    ("VANS", r"^RV[\s-]*6", "RV6"),    # DOC: RV6 (Van's RV-6)
    ("VANS", r"^RV[\s-]*4", "RV4"),    # DOC: Van's RV-4
    ("VANS", r"^RV[\s-]*3", "RV3"),    # DOC: Van's RV-3
    # --- Aviat / CubCrafters -------------------------------------------------
    ("AVIAT", r"^A[\s-]*1", "HUSK"),       # DOC: Aviat A-1 Husky
    ("CUB CRAFTERS", r"^CC11", "CC11"),    # DOC: Cub Crafters CC11 Carbon Cub
    ("CUB CRAFTERS", r"^CC19", "CC19"),    # DOC: Cub Crafters CC-19 XCub
    # --- Honda / Eclipse very-light jets -------------------------------------
    ("HONDA", r"^HA[\s-]*420", "HDJT"),  # DOC: Honda HA-420 HondaJet
    ("ECLIPSE", r"^EA[\s-]*50", "EA50"),  # DOC: Eclipse 500
    ("ECLIPSE", r"^500", "EA50"),         # DOC: Eclipse 500
    # --- Dassault Falcon (FAA "FALCON 2000EX" / "MYSTERE FALCON 50") ---------
    ("DASSAULT", r"^FALCON[\s-]*7X", "FA7X"),    # DOC: Falcon 7X
    ("DASSAULT", r"^FALCON[\s-]*8X", "FA8X"),    # DOC: Falcon 8X
    ("DASSAULT", r"^FALCON[\s-]*900", "F900"),   # DOC: Falcon 900
    ("DASSAULT", r"^FALCON[\s-]*2000", "F2TH"),  # DOC: Falcon 2000 (incl 2000EX)
    ("DASSAULT", r"^FALCON[\s-]*50", "FA50"),    # DOC: Falcon 50
    ("DASSAULT", r"^FALCON[\s-]*20", "FA20"),    # DOC: Falcon 20
    ("DASSAULT", r"^MYSTERE[\s-]*FALCON[\s-]*50", "FA50"),
    ("DASSAULT", r"^MYSTERE[\s-]*FALCON[\s-]*20", "FA20"),
    ("DASSAULT", r"^MYSTERE[\s-]*FALCON[\s-]*900", "F900"),
    # --- Airbus Helicopters / Eurocopter (AS350/EC130/EC135/EC145/H-series) --
    ("AIRBUS HELICOPTERS", r"^AS[\s-]*350", "AS50"),  # DOC: H-125 (AS350)
    ("AIRBUS HELICOPTERS", r"^AS[\s-]*355", "AS55"),  # DOC: AS-555 (AS355)
    ("AIRBUS HELICOPTERS", r"^H125", "AS50"),
    ("AIRBUS HELICOPTERS", r"^H130", "EC30"),
    ("AIRBUS HELICOPTERS", r"^H135", "EC35"),
    ("AIRBUS HELICOPTERS", r"^H145", "EC45"),
    ("AIRBUS HELICOPTERS", r"^EC[\s-]*130", "EC30"),  # DOC: H-130 (EC130)
    ("AIRBUS HELICOPTERS", r"^EC[\s-]*135", "EC35"),  # DOC: H-135 (EC135)
    ("AIRBUS HELICOPTERS", r"^EC[\s-]*145", "EC45"),  # DOC: H-145 (EC145)
    # Eurocopter is Airbus Helicopters' former brand; canon collapses below.
    # --- Sikorsky -----------------------------------------------------------
    ("SIKORSKY", r"^(UH[\s-]*60|S[\s-]*70)", "H60"),  # DOC: S-70 (UH-60 Black Hawk)
    ("SIKORSKY", r"^S[\s-]*76", "S76"),  # DOC: Sikorsky S-76
    ("SIKORSKY", r"^S[\s-]*92", "S92"),  # DOC: Sikorsky S-92
    # --- Singles / utility ---------------------------------------------------
    ("CESSNA", r"^A?188", "C188"),  # DOC: 188 AgWagon (A188B)
    ("CESSNA", r"^162", "C162"),    # DOC: 162 Skycatcher
    ("CESSNA", r"^T?337", "C337"),  # DOC: 337 Super Skymaster (337/T337)
    ("CESSNA", r"^O[\s-]*2", "C337"),  # DOC: 337 (military O-2 Skymaster)
    ("CESSNA", r"^305", "O1"),      # DOC: Cessna OE/O-1 Bird Dog (305A)
    ("MITSUBISHI", r"^MU[\s-]*2", "MU2"),  # DOC: Mitsubishi MU-2
    # --- Bell helicopters (206 JetRanger / 407 / 505 / UH-1 / OH-58) ---------
    # Note: B06 is the canonical ICAO 8643 designator for the Bell 206 JetRanger
    # family (the bundled AircraftTypes.json model string "406" is an upstream
    # naming quirk; the designator key itself is correct and valid).
    ("BELL", r"^(206|OH[\s-]*58)", "B06"),  # DOC key B06: Bell 206 JetRanger (OH-58 is the military 206)
    ("BELL", r"^407", "B407"),   # DOC: Bell 407
    ("BELL", r"^429", "B429"),   # DOC: Bell 429 GlobalRanger
    ("BELL", r"^505", "B505"),   # DOC: Bell 505 Jet Ranger X
    ("BELL", r"^(UH[\s-]*1|205|212)", "UH1"),  # DOC key UH1: Bell 204/205/UH-1 Huey
    # --- Erco / Globe / Rockwell / Navion / Republic / Grumman Ag-Cat --------
    ("ERCOUPE", r"^415", "ERCO"),  # DOC: Erco 415 Ercoupe
    # FAA make "ENGINEERING & RESEARCH" normalizes (& -> space) to this key:
    ("ENGINEERING RESEARCH", r"^(415|ERCOUPE)", "ERCO"),
    ("ALON", r"^A2", "ERCO"),      # Alon A-2 Aircoupe is the Ercoupe continuation
    ("GLOBE", r"^GC[\s-]*1", "GC1"),  # DOC: Globe GC-1 Swift
    ("TEMCO", r"^GC[\s-]*1", "GC1"),  # Temco built the GC-1 Swift too
    ("ROCKWELL", r"^112", "AC11"),    # DOC: Rockwell Commander 112
    ("ROCKWELL", r"^114", "AC11"),    # DOC: AC11 covers the 112/114 Commander
    ("NORTH AMERICAN", r"^NAVION", "NAVI"),  # DOC: North American Navion
    ("RYAN", r"^NAVION", "NAVI"),            # Ryan Navion
    ("REPUBLIC", r"^RC[\s-]*3", "RC3"),      # DOC: Republic RC-3 Seabee
    ("GRUMMAN", r"^G[\s-]*164", "G164"),     # DOC: Grumman G-164 Ag-Cat
    # --- ICON ----------------------------------------------------------------
    ("ICON", r"^A[\s-]*5", "A5"),  # DOC: Icon A-5
    # --- Hawker / Premier (Raytheon/Hawker Beechcraft) -----------------------
    ("BEECH", r"^HAWKER[\s-]*900", "H25B"),  # DOC: Hawker 900XP (800-series airframe)
    ("BEECH", r"^390", "PRM1"),              # DOC: 390 Premier 1
    # Canadair CL-600 strings are handled by the BOMBARDIER rules above —
    # canon_make folds "CANADAIR"/"CANADAIR LTD" into BOMBARDIER.
    # --- IAI (G280 built by Israel Aerospace) --------------------------------
    ("IAI", r"^GULFSTREAM[\s-]*G280", "G280"),  # DOC: Gulfstream G280 (IAI-built)
    ("IAI", r"^G280", "G280"),
    ("IAI", r"^1125", "ASTR"),  # IAI 1125 Astra
    # --- Lake amphibians -----------------------------------------------------
    ("LAKE", r"^LA[\s-]*4", "LA4"),  # DOC: Lake LA-4
    ("CONSOLIDATED AERONAUTICS", r"LA[\s-]*4", "LA4"),  # FAA model "LAKE LA-4-200"
    # --- AgustaWestland / Leonardo helicopters -------------------------------
    ("AGUSTAWESTLAND", r"(AW)?119", "A119"),  # DOC: A-119 Koala
    ("AGUSTAWESTLAND", r"(AW)?109", "A109"),  # DOC: A-109
    ("AGUSTAWESTLAND", r"(AW)?139", "A139"),  # DOC: AW-139
    ("AGUSTAWESTLAND", r"(AW)?169", "A169"),  # DOC: AW-169
    ("AGUSTAWESTLAND", r"(AW)?189", "A189"),  # DOC: AW-189
    ("LEONARDO", r"(AW)?139", "A139"),
    ("LEONARDO", r"(AW)?169", "A169"),
    ("LEONARDO", r"(AW)?109", "A109"),
    ("AGUSTA", r"(A|AW)?109", "A109"),        # DOC: A-109
    ("AGUSTA", r"(A|AW)?119", "A119"),        # DOC: A-119 Koala
    # --- Maule / American Champion / Aeronca high-wing taildraggers ----------
    ("MAULE", r"^M[\s-]*(4|5|6|7|8|9|X)", "M7"),  # DOC: Maule M-7 (the catchable family)
    ("AMERICAN CHAMPION", r"^7", "CH7B"),  # DOC: 7GCBC Citabria family
    ("AMERICAN CHAMPION", r"^8", "BL8"),   # DOC: 8 Scout / 8KCAB Decathlon
    ("AERONCA", r"^7", "CH7A"),            # DOC: Aeronca 7BCM Champion
    ("AERONCA", r"^11", "AR11"),           # DOC: Aeronca 11 Chief
    ("AERONCA", r"^15", "AR15"),           # DOC: Aeronca 15 Sedan (15AC)
    ("AERONCA", r"^65", "AR65"),           # DOC: Aeronca 65 (65-CA/65-C Super Chief lineage)
    # Bellanca built the Champion/Citabria/Decathlon line under license:
    ("BELLANCA", r"^7", "CH7B"),           # DOC: 7GCBC/7ECA Citabria family
    ("BELLANCA", r"^8", "BL8"),            # DOC: 8 Scout / 8KCAB Decathlon
    ("BELLANCA", r"^17", "BL17"),          # DOC: 17 Viking
    ("BELLANCA", r"^14", "B14C"),          # DOC: 14 Bellanca 260A (Cruisair/Cruisemaster)
    # --- North American warbirds (T-6/SNJ Texan, T-28, P-51) -----------------
    ("NORTH AMERICAN", r"^(AT[\s-]*6|T[\s-]*6|SNJ|BC[\s-]*1)", "T6"),  # DOC key T6: Texan/Harvard
    ("NORTH AMERICAN", r"^T[\s-]*28", "T28"),  # DOC: T-28 Trojan
    ("NORTH AMERICAN", r"^(P[\s-]*51|F[\s-]*51|A[\s-]*36)", "P51"),  # DOC key P51: Mustang
    # --- Taylorcraft (BC-12 / BC-65 / DCO-65 / BL-65 / F19) ------------------
    ("TAYLORCRAFT", r"^(BC|DC|DCO|BL)", "TAYB"),  # DOC: Taylorcraft BC (pre-war B-series)
    ("TAYLORCRAFT", r"^F?19", "TF19"),            # DOC: 19 Sportsman (F19/19)
    ("TAYLORCRAFT", r"^F[\s-]*22", "TF22"),       # DOC: F-22 Ranger
    # --- De Havilland Canada / De Havilland --------------------------------
    ("DE HAVILLAND", r"DHC[\s-]*2", "DHC2"),    # DOC: DHC-2 Beaver
    ("DE HAVILLAND", r"DHC[\s-]*3", "DHC3"),    # DOC: DHC-3 Otter
    ("DE HAVILLAND", r"DHC[\s-]*6", "DHC6"),    # DOC: DHC-6 Twin Otter
    ("DE HAVILLAND", r"DH[\s-]*82", "DH82"),    # DOC: DH-82 Tiger Moth
    # --- Luscombe 8 / 11 -----------------------------------------------------
    ("LUSCOMBE", r"^T?[\s-]*8", "L8"),    # DOC: Luscombe 8 (8A-8F, T-8F)
    ("LUSCOMBE", r"^11", "L11"),          # DOC: Luscombe 11A Sedan
    # --- Aero Commander piston twins / Thrush ag ----------------------------
    ("AERO COMMANDER", r"^S[\s-]*2R", "SS2P"),  # DOC: S-2R-600 Thrush (piston, Rockwell/Aero Commander)
    ("AERO COMMANDER", r"^500", "AC50"),  # DOC: Aero Commander 500
    ("AERO COMMANDER", r"^680", "AC68"),  # DOC: Aero Commander 680
    ("AERO COMMANDER", r"^112", "AC11"),  # DOC: Commander 112 (Aero Commander-built)
    ("AERO COMMANDER", r"^114", "AC11"),  # DOC: AC11 covers 112/114
    # --- Lancair / Columbia (Cessna 350/400 lineage) ------------------------
    ("LANCAIR", r"^LC[\s-]*4?0?[\s-]*550", "COL4"),  # DOC: Cessna 400 (Columbia 400/LC41-550)
    ("LANCAIR", r"^LC4", "COL4"),                    # Lancair LC40/41/42 -> Columbia/Cessna 400
    ("LANCAIR", r"^IV", "LNC4"),                     # DOC: Lancair 4 (Legacy)
    ("COLUMBIA AIRCRAFT", r"^LC4", "COL4"),          # DOC: Cessna 400 (Columbia-built)
    ("CESSNA", r"^LC4", "COL4"),                     # Cessna-badged Columbia 400
    # --- Grumman American light singles & Cougar twin -----------------------
    ("GRUMMAN AMERICAN", r"^GA[\s-]*7", "GA7"),  # DOC: GA-7 Cougar
    ("AMERICAN", r"^AA[\s-]*1", "AA1"),  # DOC: AA-1 (American-built)
    ("AMERICAN", r"^AA[\s-]*5", "AA5"),  # DOC: AA-5
    ("AMERICAN", r"^GA[\s-]*7", "GA7"),  # DOC: GA-7 Cougar
    # --- Quest Kodiak turboprop ----------------------------------------------
    ("QUEST AIRCRAFT", r"^KODIAK", "K100"),  # DOC: Kodiak 100
    # --- McDonnell Douglas MD-11 / MD-90 -------------------------------------
    ("MCDONNELL DOUGLAS", r"^MD[\s-]*11", "MD11"),  # DOC: MD-11
    ("MCDONNELL DOUGLAS", r"^MD[\s-]*90", "MD90"),  # DOC: MD-90
    ("BOEING", r"^MD[\s-]*11", "MD11"),             # MD-11 sometimes under Boeing
    # --- Piper / Ted Smith Aerostar twin -------------------------------------
    # NB: the "AEROSTAR" make is a BALLOON manufacturer; the Ted Smith Aerostar
    # twin registers under PIPER (model "AEROSTAR 601P") — match only there.
    ("PIPER", r"^AEROSTAR[\s-]*6", "AEST"),  # DOC: Aerostar 600/601/602
    # --- Vintage trainers / warbirds (Yak-52 / CJ-6 / L-39 / Navion / N3N) ---
    ("YAKOVLEV", r"^YAK[\s-]*52", "YK52"),     # DOC: Yak-52
    ("NANCHANG", r"^CJ[\s-]*6", "CJ6"),        # DOC: Nanchang CJ-6
    ("AERO VODOCHODY", r"^L[\s-]*39", "L39"),  # DOC: Aero L-39 Albatros
    ("NORTH AMERICAN", r"^NAVION", "NAVI"),    # NAA-built Navion
    ("NAVION", r"^NAVION", "NAVI"),            # DOC: Navion (post-NAA Navion Co.)
    ("NAVAL AIRCRAFT FACTORY", r"^N3N", "N3N"),  # DOC: N3N
    # --- Boeing Stearman (FAA "A75N1(PT17)" / "E75") -------------------------
    ("BOEING", r"^A75", "ST75"),  # DOC: Boeing 75 Kaydet (Stearman A75N1)
    ("BOEING", r"^B75", "ST75"),  # DOC: Boeing 75 Kaydet (Stearman B75)
    ("BOEING", r"^D75", "ST75"),  # DOC: Boeing 75 Kaydet (Stearman D75)
    ("BOEING", r"^E75", "ST75"),  # DOC: Boeing 75 Kaydet (Stearman E75)
    ("BOEING", r"^N2S", "ST75"),  # DOC: Boeing 75 Kaydet (Navy N2S Stearman)
    ("BOEING", r"^PT[\s-]*13", "ST75"),  # DOC: Boeing 75 Kaydet (Army PT-13)
    ("BOEING", r"^PT[\s-]*17", "ST75"),  # DOC: Boeing 75 Kaydet (Army PT-17)
]


def compile_family_rules():
    return [(mk, re.compile(rx), tc) for (mk, rx, tc) in FAMILY_RULES]


# ---------------------------------------------------------------------------
# Pass 4: per-code overrides. mfrMdlCode -> designator. Grounded in the actual
# ACFTREF (mfr, model) for that code AND the DOC 8643 ModelFullName. Populated
# from the tail-weighted miss list this script prints — never from memory.
# Keep small; prefer fixing/adding a FAMILY rule if a whole family is affected.
# ---------------------------------------------------------------------------
OVERRIDES = {
    # (code) : (designator)   # ACFTREF mfr/model  ->  DOC ModelFullName
    "8850316": "TAYB",  # TAYLORCRAFT BC12-D  -> DOC: Taylorcraft BC
    "8190104": "L8",    # LUSCOMBE 8A         -> DOC: Luscombe 8 (L8)
    "1390044": "CL30",  # BOMBARDIER BD-100-1A10 -> DOC: BD-100 Challenger 300
    "7090553": "PC12",  # PILATUS PC-12/47E   -> DOC: Pilatus PC-12
}


# ---------------------------------------------------------------------------
# Loaders
# ---------------------------------------------------------------------------


def clean_hdr(cells):
    return [c.replace("﻿", "").replace("ï»¿", "").strip() for c in cells]


def load_acftref(path: Path):
    """code -> (mfr, model). Latin-1; BOM on first header cell."""
    out = {}
    with open(path, encoding="latin1", newline="") as f:
        r = csv.reader(f)
        ix = {h: i for i, h in enumerate(clean_hdr(next(r)))}
        cc, mc, dc = ix["CODE"], ix["MFR"], ix["MODEL"]
        for row in r:
            if len(row) <= dc:
                continue
            code = row[cc].strip()
            if not code:
                continue
            out[code] = (row[mc].strip(), row[dc].strip())
    return out


def load_tail_counts(path: Path):
    """MFR MDL CODE -> count of valid-hex US tails referencing it (MASTER)."""
    counts = Counter()
    with open(path, encoding="latin1", newline="") as f:
        r = csv.reader(f)
        ix = {h: i for i, h in enumerate(clean_hdr(next(r)))}
        mc, hc = ix["MFR MDL CODE"], ix["MODE S CODE HEX"]
        for row in r:
            if len(row) <= max(mc, hc):
                continue
            hexc = row[hc].strip().lower()
            if len(hexc) != 6 or any(c not in "0123456789abcdef" for c in hexc):
                continue
            counts[row[mc].strip()] += 1
    return counts


def load_types(path: Path):
    return json.loads(Path(path).read_text())


def load_xlsx(path: Path, valid: set):
    """Return list of (icao, mfr, model) for rows whose ICAO is a valid designator."""
    ns = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    with zipfile.ZipFile(path) as z:
        ss = ET.fromstring(z.read("xl/sharedStrings.xml"))
        shared = [
            "".join(t.text or "" for t in si.findall(".//x:t", ns))
            for si in ss.findall("x:si", ns)
        ]
        sheet = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
        rows = []
        for row in sheet.findall(".//x:row", ns):
            rd = {}
            for cell in row.findall("x:c", ns):
                ref, t, v = cell.get("r"), cell.get("t"), cell.find("x:v", ns)
                col = "".join(c for c in ref if c.isalpha())
                if v is not None:
                    rd[col] = shared[int(v.text)] if t == "s" else v.text
            rows.append(rd)
    out = []
    for rd in rows[1:]:
        icao = (rd.get("A") or "").strip().upper()
        if not icao or icao not in valid:
            continue
        out.append((icao, (rd.get("C") or "").strip(), (rd.get("D") or "").strip()))
    return out


# ---------------------------------------------------------------------------
# Index builders + the per-code mapper
# ---------------------------------------------------------------------------


def build_model_index(pairs, valid):
    """pairs: iterable of (icao, make, model). -> canon_make -> {modelkey: icao}.
    Indexes both the tight model and the make-stripped tight model."""
    idx = defaultdict(dict)
    for icao, make, model in pairs:
        if icao not in valid:
            continue
        cm = canon_make(make)
        mt = norm_tight(model)
        idx[cm].setdefault(mt, icao)
        ms = norm_tight(strip_leading_make(cm, norm(model)))
        idx[cm].setdefault(ms, icao)
    return idx


def map_one(mfr, model, fam_rules, xlsx_idx, doc_idx):
    """Return (designator, pass_label) or (None, None)."""
    cm = canon_make(mfr)
    mn = norm(model)
    # Pass 1: family rules
    for rmk, rx, tc in fam_rules:
        if rmk == cm and rx.search(mn):
            return tc, "family"
    # Pass 2: xlsx exact/normalized join
    for v in model_variants(model):
        if cm in xlsx_idx and v in xlsx_idx[cm]:
            return xlsx_idx[cm][v], "xlsx"
    # Pass 3: DOC 8643 exact/normalized join
    for v in model_variants(model):
        if cm in doc_idx and v in doc_idx[cm]:
            return doc_idx[cm][v], "doc8643"
    return None, None


# ---------------------------------------------------------------------------
# Spot-check pairs (make, model) -> expected designator. >= 20 required.
# Each is a real ACFTREF-style (mfr, model). Build fails loudly on a mismatch.
# ---------------------------------------------------------------------------
SPOT_CHECKS = [
    ("CIRRUS DESIGN CORP", "SR20", "SR20"),
    ("CIRRUS DESIGN CORP", "SR22", "SR22"),
    ("CIRRUS DESIGN CORP", "SR22T", "S22T"),
    ("CESSNA", "172S", "C172"),
    ("CESSNA", "172N", "C172"),
    ("CESSNA", "182P", "C182"),
    ("CESSNA", "150M", "C150"),
    ("CESSNA", "152", "C152"),
    ("CESSNA", "206H", "C206"),
    ("CESSNA", "310R", "C310"),
    ("PIPER", "PA-28-181", "P28A"),
    ("PIPER", "PA-28-140", "P28A"),
    ("PIPER", "PA-28R-200", "P28R"),
    ("PIPER", "PA-18-150", "PA18"),
    ("PIPER", "PA-32-300", "PA32"),
    ("PIPER", "PA-46-350P", "PA46"),
    ("BEECH", "A36", "BE36"),
    ("BEECH", "V35B", "BE35"),
    ("BEECH", "F33A", "BE33"),
    ("BEECH", "B200", "BE20"),
    ("MOONEY", "M20J", "M20P"),
    ("MOONEY", "M20K", "M20T"),
    ("ROBINSON HELICOPTER COMPANY", "R44 II", "R44"),
    ("BOEING", "737-8H4", "B738"),
    ("BOEING", "777-300ER", "B77W"),
    ("EMBRAER S A", "ERJ 170-200 LR", "E75L"),
    ("PILATUS AIRCRAFT LTD", "PC-12/47E", "PC12"),
    ("DIAMOND AIRCRAFT IND INC", "DA 40", "DA40"),
]


def run_spot_checks(fam_rules, xlsx_idx, doc_idx) -> int:
    failures = []
    for mfr, model, expected in SPOT_CHECKS:
        got, _ = map_one(mfr, model, fam_rules, xlsx_idx, doc_idx)
        if got != expected:
            failures.append((mfr, model, expected, got))
    if failures:
        print("SPOT-CHECK FAILURES:", file=sys.stderr)
        for mfr, model, exp, got in failures:
            print(f"  {mfr} / {model}: expected {exp}, got {got}", file=sys.stderr)
        raise SystemExit(f"build aborted: {len(failures)} spot-check failure(s)")
    print(f"spot-checks: {len(SPOT_CHECKS)}/{len(SPOT_CHECKS)} passed")
    return len(SPOT_CHECKS)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--acftref", required=True, type=Path)
    ap.add_argument("--master", type=Path, default=None, help="optional; enables tail-weighted coverage")
    ap.add_argument(
        "--types",
        type=Path,
        default=REPO_ROOT / "ios/Tailspot/Tailspot/AircraftTypes.json",
    )
    ap.add_argument(
        "--xlsx",
        type=Path,
        default=REPO_ROOT / "tools/data/faa_aircraft_characteristics.xlsx",
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=REPO_ROOT / "backend/data/faa-typecode-map.json",
    )
    args = ap.parse_args()

    types = load_types(args.types)
    valid = set(types.keys())
    acftref = load_acftref(args.acftref)
    xlsx = load_xlsx(args.xlsx, valid) if args.xlsx.exists() else []

    fam_rules = compile_family_rules()
    xlsx_idx = build_model_index(xlsx, valid)
    # DOC index: (icao, make, model) from AircraftTypes.json
    doc_pairs = [
        (k, v.get("make", ""), v.get("model", ""))
        for k, v in types.items()
        if isinstance(v, dict)
    ]
    doc_idx = build_model_index(doc_pairs, valid)

    # --- validate FAMILY_RULES + OVERRIDES targets are valid designators -----
    bad_targets = sorted(
        {tc for _, _, tc in FAMILY_RULES if tc not in valid}
        | {tc for tc in OVERRIDES.values() if tc not in valid}
    )
    if bad_targets:
        raise SystemExit(
            f"build aborted: rule/override targets not in AircraftTypes.json: {bad_targets}"
        )

    # --- spot-checks before emitting -----------------------------------------
    run_spot_checks(fam_rules, xlsx_idx, doc_idx)

    # --- map every ACFTREF code ----------------------------------------------
    result = {}
    pass_counts = Counter()
    for code, (mfr, model) in acftref.items():
        if code in OVERRIDES:
            result[code] = OVERRIDES[code]
            pass_counts["override"] += 1
            continue
        tc, label = map_one(mfr, model, fam_rules, xlsx_idx, doc_idx)
        if tc:
            result[code] = tc
            pass_counts[label] += 1

    # --- final validation: every emitted designator is valid -----------------
    emitted_bad = sorted({tc for tc in result.values() if tc not in valid})
    if emitted_bad:
        raise SystemExit(f"build aborted: emitted designators not valid: {emitted_bad}")

    # --- coverage report ------------------------------------------------------
    total_codes = len(acftref)
    mapped_codes = len(result)
    print()
    print("=== Coverage ===")
    print(f"ACFTREF codes total:   {total_codes}")
    print(f"mapped codes:          {mapped_codes} ({100 * mapped_codes / total_codes:.1f}%)")
    print(f"pass breakdown:        {dict(pass_counts)}")

    if args.master and args.master.exists():
        tail = load_tail_counts(args.master)
        total_tails = sum(tail.values())
        mapped_tails = sum(tail.get(c, 0) for c in result)
        ref_codes = set(tail.keys())
        ref_mapped = sum(1 for c in ref_codes if c in result)
        print(f"MASTER tails (valid):  {total_tails}")
        print(
            f"MASTER-referenced codes mapped: {ref_mapped}/{len(ref_codes)} "
            f"({100 * ref_mapped / len(ref_codes):.1f}%)"
        )
        print(
            f"TAIL-WEIGHTED coverage: {mapped_tails}/{total_tails} = "
            f"{100 * mapped_tails / total_tails:.1f}%"
        )
        unmapped = sorted(
            ((c, n) for c, n in tail.items() if c not in result), key=lambda x: -x[1]
        )
        print()
        print("=== Top 15 UNMAPPED model codes by tail count ===")
        for c, n in unmapped[:15]:
            mfr, model = acftref.get(c, ("?", "?"))
            print(f"  {n:5d}  {c:9s}  {mfr[:28]:29s} {model}")

    # --- write the committed map (sorted keys for a stable diff) -------------
    args.out.parent.mkdir(parents=True, exist_ok=True)
    ordered = {k: result[k] for k in sorted(result)}
    args.out.write_text(json.dumps(ordered, indent=2, sort_keys=True) + "\n")
    size = args.out.stat().st_size
    print()
    print(f"wrote {args.out}  ({mapped_codes} entries, {size} bytes)")


if __name__ == "__main__":
    main()
