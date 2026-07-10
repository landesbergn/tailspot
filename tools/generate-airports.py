#!/usr/bin/env python3
"""
Generate ios/Tailspot/Tailspot/airports.json — the curated airport pool
behind the route-guess bonus round's option chips (game-layer PR2).

Source: OurAirports (https://ourairports.com/data/), released into the
PUBLIC DOMAIN by its maintainers — no licensing pass needed. We join a
hand-curated list of ~250 IATA codes (the world's major passenger
airports, spread across every continent) against the OurAirports CSV so
the coordinates / ICAO idents / city names are authoritative rather
than from-memory.

Why curated instead of "all large airports": OurAirports marks ~1,150
airports "large"; bundling them all would make distractor chips drift
toward airports nobody has heard of ("plausibly wrong" beats "obscurely
wrong" for a guessing game). ~250 keeps every option recognizable and
the asset ~30 KB.

Output shape (consumed by GuessOptions.swift):
  [ { "icao": "VHHH", "iata": "HKG", "city": "Hong Kong",
      "lat": 22.3089, "lon": 113.9146, "continent": "AS" }, … ]

`continent` is OurAirports' two-letter code (AF AN AS EU NA OC SA) and
is the "same broad region" bucket for distractor sampling.

Usage:
  python3 tools/generate-airports.py                    # fetch + write
  python3 tools/generate-airports.py --input airports.csv   # offline

The checked-in JSON diff is the verification surface: review it after
every regeneration.
"""

import argparse
import csv
import io
import json
import sys
import urllib.request
from pathlib import Path

CSV_URL = "https://davidmegginson.github.io/ourairports-data/airports.csv"
OUT_PATH = Path(__file__).resolve().parent.parent / "ios/Tailspot/Tailspot/airports.json"

# Hand-curated major-airport IATA codes, grouped for reviewability.
# Criteria: passenger volume + regional significance + recognizability,
# with deliberate worldwide spread (route guesses happen wherever Noah
# and testers travel — Berkeley to Bali).
CURATED_IATA = [
    # ── North America — US ──
    "ATL", "LAX", "ORD", "DFW", "DEN", "JFK", "SFO", "SEA", "LAS", "MCO",
    "EWR", "MIA", "PHX", "IAH", "BOS", "MSP", "DTW", "FLL", "LGA", "CLT",
    "SLC", "DCA", "IAD", "SAN", "TPA", "BWI", "AUS", "MDW", "HNL", "PDX",
    "STL", "RDU", "SMF", "SJC", "MCI", "OAK", "MSY", "SAT", "RSW", "IND",
    "CLE", "PIT", "CVG", "CMH", "ANC", "ABQ", "OGG", "BNA", "PHL", "MEM",
    # ── North America — Canada ──
    "YYZ", "YVR", "YUL", "YYC", "YEG", "YOW", "YWG", "YHZ",
    # ── North America — Mexico / Central America / Caribbean ──
    "MEX", "CUN", "GDL", "MTY", "TIJ", "SJD", "PVR",
    "PTY", "SJO", "SAL", "GUA", "SJU", "MBJ", "NAS", "PUJ", "HAV",
    # ── South America ──
    "GRU", "GIG", "BSB", "CGH", "VCP", "SSA", "REC", "FOR", "POA", "CWB",
    "EZE", "AEP", "SCL", "LIM", "BOG", "MDE", "UIO", "GYE", "CCS", "ASU",
    "MVD", "VVI",
    # ── Europe — UK / Ireland ──
    "LHR", "LGW", "STN", "LTN", "MAN", "EDI", "BHX", "GLA", "DUB",
    # ── Europe — France / Benelux ──
    "CDG", "ORY", "NCE", "LYS", "MRS", "TLS", "AMS", "BRU",
    # ── Europe — Germany / Alpine ──
    "FRA", "MUC", "BER", "DUS", "HAM", "STR", "CGN", "ZRH", "GVA", "VIE",
    # ── Europe — Italy ──
    "MXP", "LIN", "FCO", "VCE", "NAP", "BLQ", "CTA",
    # ── Europe — Iberia ──
    "MAD", "BCN", "PMI", "AGP", "VLC", "SVQ", "LIS", "OPO",
    # ── Europe — Greece / Turkey ──
    "ATH", "SKG", "IST", "SAW", "ADB", "AYT", "ESB",
    # ── Europe — Nordics / Baltics ──
    "CPH", "OSL", "ARN", "GOT", "HEL", "KEF", "RIX", "TLL", "VNO",
    # ── Europe — Central / Eastern ──
    "WAW", "KRK", "PRG", "BUD", "OTP", "SOF", "BEG", "ZAG", "LJU", "LCA",
    "MLA",
    # ── Middle East ──
    "DXB", "AUH", "DOH", "RUH", "JED", "DMM", "KWI", "BAH", "MCT", "AMM",
    "BEY", "TLV",
    # ── South Asia ──
    "DEL", "BOM", "BLR", "MAA", "HYD", "CCU", "COK", "AMD", "GOI",
    "MLE", "CMB", "KTM", "DAC", "KHI", "LHE", "ISB",
    # ── Southeast Asia ──
    "SIN", "KUL", "PEN", "BKK", "DMK", "HKT", "CNX", "SGN", "HAN", "DAD",
    "CGK", "DPS", "SUB", "KNO", "MNL", "CEB", "RGN", "PNH",
    # ── East Asia — Greater China ──
    "HKG", "MFM", "TPE", "KHH", "PEK", "PKX", "PVG", "SHA", "CAN", "SZX",
    "CTU", "CKG", "KMG", "XIY", "HGH", "WUH", "NKG", "TAO", "URC",
    # ── East Asia — Japan / Korea ──
    "HND", "NRT", "KIX", "ITM", "NGO", "FUK", "CTS", "OKA",
    "ICN", "GMP", "PUS", "CJU",
    # ── Central Asia / Caucasus ──
    "TAS", "ALA", "NQZ", "TBS", "EVN", "GYD",
    # ── Oceania ──
    "SYD", "MEL", "BNE", "PER", "ADL", "OOL", "CNS",
    "AKL", "WLG", "CHC", "NAN", "PPT", "GUM", "POM",
    # ── Africa ──
    "JNB", "CPT", "DUR", "CAI", "HRG", "SSH", "CMN", "RAK", "ALG", "TUN",
    "LOS", "ABV", "ACC", "ABJ", "DKR", "NBO", "MBA", "ADD", "DAR", "JRO",
    "EBB", "KGL", "LAD", "FIH", "MRU", "SEZ", "WDH", "GBE", "HRE", "LUN",
    "TNR", "RUN",
]


# OurAirports `municipality` is sometimes the airport's literal suburb or a
# parenthesised admin string ("Kuta, Badung", "Sydney (Mascot)", "Ferno (VA)").
# Option chips read "IATA · City", so pin the traveler-recognizable city name
# where the raw value would look wrong. Populated from human review of the
# generated output, never from memory of the CSV.
CITY_OVERRIDES = {
    "BHX": "Birmingham", "CAN": "Guangzhou", "CDG": "Paris", "CEB": "Cebu",
    "CGN": "Cologne", "CTU": "Chengdu", "CVG": "Cincinnati",
    "DFW": "Dallas-Fort Worth", "DPS": "Denpasar (Bali)", "EZE": "Buenos Aires",
    "HAN": "Hanoi", "HEL": "Helsinki", "HNL": "Honolulu", "KHH": "Kaohsiung",
    "LIN": "Milan", "LTN": "Luton", "LYS": "Lyon", "MAN": "Manchester",
    "MFM": "Macau", "MNL": "Manila", "MRS": "Marseille", "MVD": "Montevideo",
    "MXP": "Milan", "NCE": "Nice", "ORY": "Paris", "OSL": "Oslo",
    "PNH": "Phnom Penh", "PVG": "Shanghai", "SAL": "San Salvador",
    "SAW": "Istanbul", "SHA": "Shanghai", "SJO": "San José", "STN": "London",
    "SYD": "Sydney", "TAO": "Qingdao", "VCE": "Venice", "WUH": "Wuhan",
}


def load_rows(path: str | None) -> list[dict]:
    if path:
        text = Path(path).read_text(encoding="utf-8")
    else:
        print(f"fetching {CSV_URL} …", file=sys.stderr)
        with urllib.request.urlopen(CSV_URL, timeout=60) as resp:
            text = resp.read().decode("utf-8")
    return list(csv.DictReader(io.StringIO(text)))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", help="local OurAirports airports.csv (skip fetch)")
    args = ap.parse_args()

    rows = load_rows(args.input)
    by_iata: dict[str, dict] = {}
    for r in rows:
        iata = (r.get("iata_code") or "").strip().upper()
        # Prefer real airports over closed/heliport rows sharing an IATA code.
        if iata and r["type"] in ("large_airport", "medium_airport"):
            existing = by_iata.get(iata)
            if existing is None or (
                existing["type"] != "large_airport" and r["type"] == "large_airport"
            ):
                by_iata[iata] = r

    wanted = set(CURATED_IATA)
    assert len(wanted) == len(CURATED_IATA), "duplicate IATA in curated list"
    out, missing = [], []
    for iata in CURATED_IATA:
        r = by_iata.get(iata)
        icao = (r.get("icao_code") or "").strip().upper() if r else ""
        if not r or not icao:
            missing.append(iata)
            continue
        out.append(
            {
                "icao": icao,
                "iata": iata,
                "city": CITY_OVERRIDES.get(
                    iata, (r.get("municipality") or r["name"]).strip()
                ),
                "lat": round(float(r["latitude_deg"]), 4),
                "lon": round(float(r["longitude_deg"]), 4),
                "continent": r["continent"].strip(),
            }
        )

    if missing:
        print(f"WARNING: no OurAirports match for: {', '.join(missing)}", file=sys.stderr)

    out.sort(key=lambda a: a["icao"])
    OUT_PATH.write_text(
        json.dumps(out, indent=1, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"wrote {len(out)} airports → {OUT_PATH}", file=sys.stderr)


if __name__ == "__main__":
    main()
