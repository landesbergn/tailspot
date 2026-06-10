#!/usr/bin/env python3
"""
download.py — fetch the spike's CC/PD test images from Wikimedia Commons.

Pulls each file through the Commons thumbnail endpoint at a capped width so the
committed set stays small (<5 MB total). Sources + licenses are recorded in
SOURCES.md (kept in sync by hand from the IMAGES table below).

Run:  python3 download.py
(Plain system python3 is fine — no venv deps; uses only urllib.)
"""
from __future__ import annotations

import sys
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
UA = "TailspotSpike/0.1 (https://github.com/landesbergn/tailspot; noah.landesberg@gmail.com)"
THUMB_WIDTH = 800  # cap longest-fit width; keeps files small + plane suitably distant

# (output_name, commons_file_title) — license/source documented in SOURCES.md
IMAGES = [
    ("01_airliner_overhead.jpg",
     "2011.10.15.184427 LH6802 Airplane crossing Switzerland.jpg"),
    ("02_airliner_approach.jpg",
     "Boeing 737-700 C-GYWJ WestJet 0886.jpg"),
    ("03_plane_in_clouds.jpg",
     "Sukhoi SuperJet 100 (5114478300).jpg"),
    ("04_helicopter.jpg",
     "Helicopter on the sky in 2021.01.jpg"),
    ("05_empty_sky.jpg",
     "Awesome beauty of the Sky.jpg"),
    ("06_cessna_ga.jpg",
     "Cessna 172 N4811V (2700356170).jpg"),
    ("07_airliner_distant.jpg",
     "American Eagle over Southeast Farm.jpg"),
]


def thumb_url(title: str, width: int) -> str:
    # Special:FilePath supports a width= param that returns a scaled thumbnail.
    fname = urllib.parse.quote(title.replace(" ", "_"))
    return f"https://commons.wikimedia.org/wiki/Special:FilePath/{fname}?width={width}"


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def main() -> int:
    total = 0
    for out_name, title in IMAGES:
        out = HERE / out_name
        url = thumb_url(title, THUMB_WIDTH)
        print(f"[dl] {out_name}  <- {title}")
        data = fetch(url)
        out.write_bytes(data)
        total += len(data)
        print(f"     {len(data)/1e3:.0f} KB")
    print(f"[dl] total: {total/1e6:.2f} MB across {len(IMAGES)} images")
    return 0


if __name__ == "__main__":
    sys.exit(main())
