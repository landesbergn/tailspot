#!/usr/bin/env python3
"""
Generate ios/Tailspot/Tailspot/airports.json — the airport table behind
the route-guess bonus round (game-layer PR2).

Source: OurAirports (https://ourairports.com/data/), released into the
PUBLIC DOMAIN by its maintainers — no licensing pass needed.

TWO ROLES, ONE TABLE (the `major` flag splits them):
  The table plays two distinct roles for GuessOptions.swift, and a row's
  `major` flag says which it may serve:
    (a) RESOLUTION — an endpoint must resolve here for a round to fire
        (`routeAvailable`) and to render the correct chip. This wants
        COMPREHENSIVE coverage: every airport that can realistically be a
        route endpoint. ALL rows (major and not) serve this role.
    (b) DISTRACTORS — the wrong-answer chips are sampled from the table.
        This wants RECOGNIZABLE airports only ("plausibly wrong" beats
        "obscurely wrong"). ONLY `major` rows serve this role.

  So we bundle two overlapping sets:
    • a hand-curated worldwide IATA list (~250 major passenger airports,
      spread across every continent — route guesses happen wherever Noah
      and testers travel, Berkeley to Bali) — all `major: true`; and
    • EVERY US airport (iso_country == "US") that can plausibly be a route
      endpoint: type large/medium, or a small field with scheduled
      service or an IATA code. This closes the "route round never fires
      on a US regional field" gap. US large airports (recognizable hubs)
      are `major: true`; US medium/small resolution-only fields are
      `major: false` so they never surface as distractors.

  The ~13k US heliports / closed / tiny private strips that never appear
  in route data are excluded so the asset stays a few hundred KB.

US ICAO idents: OurAirports leaves `icao_code` blank for most US rows but
carries the K/P-prefixed ident in the `ident` column, so US rows key on
`ident` (the curated worldwide pass keys on `icao_code`, unchanged). We do
NOT filter on the K/P prefix — `iso_country == "US"` is the selector.

Output shape (consumed by GuessOptions.swift):
  [ { "icao": "VHHH", "iata": "HKG", "city": "Hong Kong",
      "lat": 22.3089, "lon": 113.9146, "continent": "AS",
      "major": true }, … ]

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


def _city(r: dict, iata: str) -> str:
    """Traveler-recognizable city: pinned override → municipality → name."""
    return CITY_OVERRIDES.get(iata, (r.get("municipality") or r["name"]).strip())


def _valid_latlon(r: dict) -> bool:
    try:
        float(r["latitude_deg"])
        float(r["longitude_deg"])
        return True
    except (TypeError, ValueError, KeyError):
        return False


def _row(icao: str, iata: str, r: dict, major: bool) -> dict:
    return {
        "icao": icao,
        "iata": iata,
        "city": _city(r, iata),
        "lat": round(float(r["latitude_deg"]), 4),
        "lon": round(float(r["longitude_deg"]), 4),
        "continent": r["continent"].strip(),
        "major": major,
    }


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

    # Keyed by emitted ICAO so the two passes dedupe: a US airport already
    # covered by the curated list keeps its curated (major=true) row.
    out: dict[str, dict] = {}

    # ── Pass 1: curated worldwide (keys on icao_code, always major) ──
    missing = []
    for iata in CURATED_IATA:
        r = by_iata.get(iata)
        icao = (r.get("icao_code") or "").strip().upper() if r else ""
        if not r or not icao:
            missing.append(iata)
            continue
        out[icao] = _row(icao, iata, r, major=True)

    if missing:
        print(f"WARNING: no OurAirports match for: {', '.join(missing)}", file=sys.stderr)

    # ── Pass 2: comprehensive US coverage (keys on `ident`) ──
    # Every US airport that can realistically be a route endpoint: large or
    # medium, or a small field with scheduled service or an IATA code. Skips
    # the ~13k US heliports / closed / tiny private strips absent from route
    # data. Curated rows already present win the dedupe (their major=true
    # stands). `major` for a fresh US row: large hub, or a curated IATA that
    # somehow only resolved here → true; medium/small resolution-only → false.
    us_added = 0
    for r in rows:
        if r.get("iso_country") != "US":
            continue
        icao = (r.get("ident") or "").strip().upper()
        if not icao or not _valid_latlon(r):
            continue
        t = r["type"]
        iata = (r.get("iata_code") or "").strip().upper()
        eligible = t in ("large_airport", "medium_airport") or (
            t == "small_airport" and (r["scheduled_service"] == "yes" or iata)
        )
        if not eligible or icao in out:
            continue
        major = t == "large_airport" or iata in wanted
        out[icao] = _row(icao, iata, r, major=major)
        us_added += 1

    airports = sorted(out.values(), key=lambda a: a["icao"])
    OUT_PATH.write_text(
        json.dumps(airports, indent=1, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    major_count = sum(1 for a in airports if a["major"])
    print(
        f"wrote {len(airports)} airports → {OUT_PATH}\n"
        f"  major: {major_count}  non-major: {len(airports) - major_count}\n"
        f"  (curated worldwide + {us_added} US resolution-only rows)",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
