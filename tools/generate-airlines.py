#!/usr/bin/env python3
"""Regenerate the bundled ICAO airline-designator table (airlines.json).

Source: the VRS standing-data project (CC0 / public domain),
https://github.com/vradarserver/standing-data — airlines/schema-01/airlines.csv.
Rows without a 3-letter ICAO designator (IATA-only sales codes) are dropped;
what remains is {ICAO designator: airline name} for every designator the
dataset knows (~5,900), defunct carriers included — old catches should keep
resolving.

The curated table in Airlines.swift stays as a display-name OVERRIDE layer
(e.g. "FedEx Express" over the dataset's legal name "Federal Express");
this snapshot is the comprehensive fallback beneath it.

Usage:  python3 tools/generate-airlines.py
Writes: ios/Tailspot/Tailspot/airlines.json (sorted keys, stable diffs)
"""

import csv
import io
import json
import pathlib
import re
import urllib.request

SOURCE = (
    "https://raw.githubusercontent.com/vradarserver/standing-data/"
    "main/airlines/schema-01/airlines.csv"
)
OUT = pathlib.Path(__file__).resolve().parent.parent / "ios/Tailspot/Tailspot/airlines.json"
ICAO = re.compile(r"^[A-Z]{3}$")


def main() -> None:
    raw = urllib.request.urlopen(SOURCE, timeout=60).read().decode("utf-8-sig")
    table: dict[str, str] = {}
    for row in csv.DictReader(io.StringIO(raw)):
        code = (row["ICAO"] or "").strip()
        name = (row["Name"] or "").strip()
        if ICAO.fullmatch(code) and name:
            table[code] = name
    OUT.write_text(
        json.dumps(table, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n",
        encoding="utf-8",
    )
    print(f"{len(table)} designators -> {OUT}")


if __name__ == "__main__":
    main()
