#!/usr/bin/env python3
"""
generate-type-info.py — build ios/Tailspot/Tailspot/TypeInfo.json, the bundled
"about this plane" facts shown on the back of a catch card.

What it does
------------
1. Parses every CardSetEntry in `CardSets.families` out of
   ios/Tailspot/Tailspot/Sets.swift (entry id, canonicalName,
   representativeTypecode and the family title). "fam-unidentified" is skipped.
2. Builds a candidate English Wikipedia title per entry (the canonical name when
   it already names the maker, else family maker + canonical name, e.g.
   "Boeing 737" + "737-800" -> "Boeing 737-800"; for "A / B" names the first
   half is tried). `OVERRIDES` below wins over the heuristic.
3. Resolves the titles in batches of 50 through the MediaWiki API (redirects
   followed) to the final article title + Wikidata QID.
4. Fetches the Wikidata entities in batches for first flight (P606, year),
   number built (P1092), wingspan (P2050) and length (P2043), both converted
   to metres, and the image (P18).
5. Fetches Commons imageinfo for those images and keeps a photo ONLY when its
   licence is public domain, CC0, CC BY x.x or CC BY-SA x.x (GFDL-only and
   anything else is dropped). The artist is stored as plain text, with
   Commons boilerplate trimmed (`clean_artist`: "self", bot-assumed authors,
   "X.jpg: A derivative work: B", "Original uploader was X at en.wikipedia");
   a CC BY/BY-SA photo with no real author falls back to the uploader, else
   is dropped. A public-domain photo with no author stores artist "".
   When the P18 image is missing or fails that check, the article's lead
   image is tried, then the other photos in the article (`article_photos`:
   file names that mention the type, never cockpits, logos or diagrams),
   all through the same licence check.
6. Typecode pass: every AircraftTypes.json typecode that is not a family
   entry's representative typecode gets its own record under "typecodes",
   so rare types outside the sets still have a description. "make model" is
   tried as an exact title, then the top 3 search hits; a hit is kept only
   when its short description names an aircraft type, it is no
   disambiguation page, and its designators/numbers agree with the model
   (`typecode_article_ok`). Missing beats wrong. Same specs and photo rules.
7. Writes TypeInfo.json (sorted, pretty-printed) and prints a report.

Missing facts are omitted, never guessed: a field Wikidata lacks is simply
absent, and the app falls back to AircraftTypes.json for wingspan/length.

Re-running
----------
    python3 -I tools/generate-type-info.py            # fetch + write JSON
    python3 -I tools/generate-type-info.py --dry-run  # fetch + report only
    TYPEINFO_CACHE_DIR=/tmp/ti-cache python3 -I tools/generate-type-info.py
        # cache responses (the typecode pass is ~35 min uncached). The
        # cache never expires: use a fresh directory for a real refresh.
    ... --typecode-limit 150  # first N typecodes only; implies --dry-run

Stdlib only; needs network. It is polite: batched requests, ~1 s apart, with an
identifying User-Agent. Re-run whenever families are added to Sets.swift, then
read the report: an entry with no article, or one flagged "looks wrong", gets a
hand-picked title in OVERRIDES (map a variant to its family article when the
variant has none — e.g. "737-800" -> "Boeing 737 Next Generation"). Map an entry
to None to deliberately leave it without an article (no facts, no photo).
"""

import datetime
import hashlib
import html
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SETS_SWIFT = ROOT / "ios/Tailspot/Tailspot/Sets.swift"
OUT_JSON = ROOT / "ios/Tailspot/Tailspot/TypeInfo.json"
AIRCRAFT_TYPES = ROOT / "ios/Tailspot/Tailspot/AircraftTypes.json"

USER_AGENT = "Tailspot/1.0 (+https://tailspot.app) generate-type-info"
WIKI_API = "https://en.wikipedia.org/w/api.php"
WIKIDATA_API = "https://www.wikidata.org/w/api.php"
COMMONS_API = "https://commons.wikimedia.org/w/api.php"
REQUEST_GAP_S = 1.0

# Family id -> the maker prefix its (maker-less) canonical names need.
# Families not listed have canonical names that already name the maker
# ("Cessna 172", "Robinson R44"), so the canonical name is used as-is.
FAMILY_MAKER = {
    "fam-737": "Boeing",
    "fam-777": "Boeing",
    "fam-787": "Boeing",
    "fam-747": "Boeing",
    "fam-767": "Boeing",
    "fam-757": "Boeing",
    "fam-a320": "Airbus",
    "fam-a330": "Airbus",
    "fam-a350": "Airbus",
    "fam-a340": "Airbus",
    "fam-a220": "Airbus",
    "fam-a380": "Airbus",
    "fam-a300": "Airbus",
    "fam-ejet": "Embraer",
    "fam-erj": "Embraer",
    "fam-crj": "Bombardier",
    "fam-citation": "Cessna",
    "fam-gulfstream": "Gulfstream",
    "fam-md": "McDonnell Douglas",
    "fam-md-heavies": "McDonnell Douglas",
    "fam-comac": "Comac",
    "fam-dash8": "De Havilland Canada",
    "fam-bombardier-biz": "Bombardier",
    "fam-falcon": "Dassault",
    "fam-embraer-exec": "Embraer",
}

# Hand fixes: entry id -> exact English Wikipedia title (redirects are still
# followed), or None to leave the entry without an article on purpose.
# Add to this after reading the report.
OVERRIDES = {
    # Boeing 737: variants live in generation articles.
    "f737-classic": "Boeing 737 Classic",
    "f737-600": "Boeing 737 Next Generation",
    "f737-700": "Boeing 737 Next Generation",
    "f737-800": "Boeing 737 Next Generation",
    "f737-900": "Boeing 737 Next Generation",
    "f737-max8": "Boeing 737 MAX",
    "f737-max9": "Boeing 737 MAX",
    "f737-max10": "Boeing 737 MAX",
    # Airbus A320 family.
    "fa319": "Airbus A319",
    "fa320": "Airbus A320 family",
    "fa321": "Airbus A321",
    "fa319neo": "Airbus A320neo family",
    "fa320neo": "Airbus A320neo family",
    "fa321neo": "Airbus A321neo",
    # Widebodies.
    "f777-200": "Boeing 777",
    "f777-200lr": "Boeing 777",
    "f777-300": "Boeing 777",
    "f777-300er": "Boeing 777",
    "f777-9": "Boeing 777X",
    "f787-8": "Boeing 787 Dreamliner",
    "f787-9": "Boeing 787 Dreamliner",
    "f787-10": "Boeing 787 Dreamliner",
    "fa330-200": "Airbus A330",
    "fa330-300": "Airbus A330",
    "fa330-beluga-xl": "Airbus BelugaXL",
    "fa330-800": "Airbus A330neo",
    "fa330-900": "Airbus A330neo",
    "fa350-900": "Airbus A350",
    "fa350-1000": "Airbus A350",
    "fa340-200": "Airbus A340",
    "fa340-300": "Airbus A340",
    "fa340-600": "Airbus A340",
    "f747-400": "Boeing 747-400",
    "f747-8": "Boeing 747-8",
    "f747-sp": "Boeing 747SP",
    "f767-200": "Boeing 767",
    "f767-300": "Boeing 767",
    "f767-400": "Boeing 767",
    "fa380": "Airbus A380",
    "fa300": "Airbus A300",
    "f757-200": "Boeing 757",
    "f757-300": "Boeing 757",
    "fa220-100": "Airbus A220",
    "fa220-300": "Airbus A220",
    # Regional.
    "fe170": "Embraer E-Jet family",
    "fe175": "Embraer E-Jet family",
    "fe190": "Embraer E-Jet family",
    "fe195": "Embraer E-Jet family",
    "fe190-e2": "Embraer E-Jet E2 family",
    "fe195-e2": "Embraer E-Jet E2 family",
    "fcrj100": "Bombardier CRJ100/200",
    "fcrj200": "Bombardier CRJ100/200",
    "fcrj700": "Bombardier CRJ700 series",
    "fcrj900": "Bombardier CRJ700 series",
    "fcrj1000": "Bombardier CRJ700 series",
    "ferj135": "Embraer ERJ family",
    "ferj145": "Embraer ERJ family",
    "fatr42": "ATR 42",
    "fatr72": "ATR 72",
    "fdash8-100": "De Havilland Canada Dash 8",
    "fdash8-200": "De Havilland Canada Dash 8",
    "fdash8-300": "De Havilland Canada Dash 8",
    "fdash8-400": "De Havilland Canada Dash 8",
    "fd328-jet": "Fairchild Dornier 328JET",
    "farj85": "British Aerospace 146",
    "fdc9": "McDonnell Douglas DC-9",
    "fmd80": "McDonnell Douglas MD-80",
    "fmd90": "McDonnell Douglas MD-90",
    "f717": "Boeing 717",
    "fdc10": "McDonnell Douglas DC-10",
    "fmd11": "McDonnell Douglas MD-11",
    "fc919": "Comac C919",
    "farj21": "Comac ARJ21",
    # Business jets.
    "fc-cj": "Cessna CitationJet/M2",
    "fc-classic": "Cessna Citation V",
    "fc-xls": "Cessna Citation Excel",
    "fc-sovereign": "Cessna Citation Sovereign",
    "fc-longitude": "Cessna Citation Longitude",
    "fc-mustang": "Cessna Citation Mustang",
    "fg-astra": "IAI Astra",
    "fg-150": "Gulfstream G150",
    "fg-iv": "Gulfstream IV",
    "fg-280": "Gulfstream G280",
    "fg-550": "Gulfstream G550",
    "fg-600": "Gulfstream G500/G600",
    "fg-650": "Gulfstream G650",
    "fg-700": "Gulfstream G700",
    "fcl35": "Bombardier Challenger 300",
    "fcl60": "Bombardier Challenger 600 series",
    "fglex": "Bombardier Global 6000",
    "fgl5t": "Bombardier Global 5000",
    "fgl7t": "Bombardier Global 7500",
    "ffa20": "Dassault Falcon 20",
    "ffa50": "Dassault Falcon 50",
    "ff2th": "Dassault Falcon 2000",
    "ff900": "Dassault Falcon 900",
    "ffa6x": "Dassault Falcon 6X",
    "ffa7x": "Dassault Falcon 7X",
    "ffa8x": "Dassault Falcon 8X",
    "fe50p": "Embraer Phenom 100",
    "fe55p": "Embraer Phenom 300",
    "fe550": "Embraer Legacy 450/500 and Praetor 500/600",
    "fe35l": "Embraer Legacy 600",
    "fcb-sabreliner": "North American Sabreliner",
    "fcb-learjet": "Learjet",
    "fcb-hawker": "Hawker 800",
    "fcb-beechjet": "Beechcraft Beechjet",
    "flj-hondajet": "Honda HA-420 HondaJet",
    "flj-pc24": "Pilatus PC-24",
    "flj-eclipse": "Eclipse 500",
    "flj-premier": "Beechcraft Premier I",
    # GA.
    # The card and its representative typecode are the 152, which has its
    # own article (and a freely licensed photo; the 150's has neither).
    "fc152": "Cessna 152",
    "fc185": "Cessna 185 Skywagon",
    "fc206": "Cessna 206",
    "fc400": "Cessna 400",
    "fc402": "Cessna 402",
    "fpa28": "Piper PA-28 Cherokee",
    "fpa32": "Piper PA-32",
    "fpa46": "Piper PA-46",
    "fpa23": "Piper PA-23",
    "fpa60": "Piper PA-60 Aerostar",
    "fpay2": "Piper PA-31T Cheyenne",
    "fbe36": "Beechcraft Bonanza",
    "fbe58": "Beechcraft Baron",
    "fbe20": "Beechcraft Super King Air",
    "fb350": "Beechcraft Super King Air",
    "fbe10": "Beechcraft King Air",
    "fbe76": "Beechcraft Duchess",
    "fbt34": "Beechcraft T-34 Mentor",
    "fda20": "Diamond DA20",
    "fda40": "Diamond DA40 Diamond Star",
    "fda42": "Diamond DA42 Twin Star",
    "fda62": "Diamond DA62",
    # Helicopters.
    "fh-b206": "Bell 206",
    "fh-h500": "MD Helicopters MD 500",
    "fh-h125": "Eurocopter AS350 Écureuil",
    "fh-as355": "Eurocopter AS355 Écureuil 2",
    "fh-h120": "Eurocopter EC120 Colibri",
    "fh-gazelle": "Aérospatiale Gazelle",
    "fh-h130": "Eurocopter EC130",
    "fh-h135": "Eurocopter EC135",
    "fh-h145": "Airbus Helicopters H145",
    "fh-s64": "Sikorsky S-64 Skycrane",
    "fh-aw139": "AgustaWestland AW139",
    "fh-a109": "Agusta A109",
    "fh-a119": "AgustaWestland AW119 Koala",
    "fh-a169": "AgustaWestland AW169",
    "fh-exec": "RotorWay Exec",
    "fh-h160": "Airbus Helicopters H160",
    "fh-g2ca": "Guimbal Cabri G2",
    # Turboprops / commuters.
    "ftp-epic": "Epic LT",
    "ftp-tbm": "Socata TBM",
    "ftp-kodiak": "Quest Kodiak",
    "ftp-beaver": "de Havilland Canada DHC-2 Beaver",
    "fav-p180": "Piaggio P.180 Avanti",
    "ftc-690": "Aero Commander 500 family",
    "fcp-islander": "Britten-Norman BN-2 Islander",
    "fcp-twinotter": "de Havilland Canada DHC-6 Twin Otter",
    "fcp-l410": "Let L-410 Turbolet",
    "fcp-be99": "Beechcraft Model 99",
    "fcp-b190": "Beechcraft 1900",
    "fcp-p2012": "Tecnam P2012 Traveller",
    "fcp-js32": "British Aerospace Jetstream",
    "fcp-metro": "Fairchild Swearingen Metroliner",
    # Military.
    "fm-hornet": "McDonnell Douglas F/A-18 Hornet",
    "fm-texan2": "Beechcraft T-6 Texan II",
    "fm-c130": "Lockheed C-130 Hercules",
    "fm-c17": "Boeing C-17 Globemaster III",
    "fm-c27j": "Alenia C-27J Spartan",
    "fm-cn235": "CASA/IPTN CN-235",
    "fm-kc135": "Boeing KC-135 Stratotanker",
    "fm-c5": "Lockheed C-5 Galaxy",
    "fm-uh60": "Sikorsky UH-60 Black Hawk",
    "fm-uh1": "Bell UH-1 Iroquois",
    "fm-ch47": "Boeing CH-47 Chinook",
    "fm-hh65": "Eurocopter HH-65 Dolphin",
    "fm-hawk": "BAE Systems Hawk",
    "fm-u2": "Lockheed U-2",
    "fm-f5": "Northrop F-5",
    # Vintage.
    "fv-dh82": "de Havilland Tiger Moth",
    "fv-stearman": "Boeing-Stearman Model 75",
    "fv-cub": "Piper J-3 Cub",
    "fv-luscombe8": "Luscombe 8",
    "fv-t6": "North American T-6 Texan",
    "fv-p149": "Piaggio P.149",
    "fv-p51": "North American P-51 Mustang",
    "fv-tbm": "Grumman TBF Avenger",
    # Sport & classics.
    "fsc-alarus": "Zenith CH 2000",
    "fsc-mt03": "AutoGyro MTOsport",
    "fsc-mooney": "Mooney M20",
    "fsc-maule-m7": "Maule M-7",
    "fsc-scout": "American Champion Scout",
    "fsc-sonaca200": "Sonaca 200",
    "fsc-flight-design-ct": "Flight Design CT",
    "fsc-aa5": "Grumman American AA-5",
    "fsc-commander112": "Rockwell Commander 112",
    "fsc-ercoupe": "ERCO Ercoupe",
    "fsc-dimona": "Diamond HK36 Super Dimona",
    "fsc-s18": "Thorp T-18",
    "fsc-sierra": "Beechcraft Musketeer",
    "fsc-rv": "Van's Aircraft RV-8",
    "fsc-pitts-s2": "Pitts Special",
    "fsc-velocity": "Velocity SE",
    "fsc-longez": "Rutan Long-EZ",
    "fsc-air-beetle": "AIEP Air Beetle",
    "fsc-searey": "Progressive Aerodyne SeaRey",
    "fsc-lake-la4": "Lake LA-4",
    "fsc-dr400": "Robin DR400",
    "fsc-harmony": "Evektor Harmony",
    "fsc-husky": "Aviat Husky",
    "fsc-icon": "Icon A5",
    "fsc-citabria": "American Champion Citabria",
    "fsc-tecnam": "Tecnam P2002 Sierra",
    "fsc-bristell": "BRM Aero Bristell",
    "fsc-cavalon": "AutoGyro Cavalon",
    "fsc-glider": "Glider (sailplane)",
    "fsc-ultralight": "Ultralight aviation",
    "fsc-glastar": "Glasair GlaStar",
    "fsc-minicab": "Gardan GY-20 Minicab",
    "fsc-p68": "Partenavia P.68",
    "fsc-viking": "Bellanca Viking",
    "fsc-evolution": "Lancair Evolution",
    "fsc-evolution-piston": "Lancair Evolution",
    "fsc-airvan": "GippsAero GA8 Airvan",
    # No English article for the Harmon Rocket (a Van's RV-4 derivative).
    "fsc-harmon-rocket": None,
    "fc414": "Cessna 414",
    "fc425": "Cessna 425",
    "fcp-e120": "Embraer EMB 120 Brasilia",
    "fv-great-lakes": "Great Lakes Sport Trainer",
    "fsc-fk9": "B&F Fk9",
    "fsc-risen": "Swiss Excellence Risen",
    "fsc-aurora": "Sunward SA 60L Aurora",
    "fsc-sport-cub": "CubCrafters CC11-100 Sport Cub S2",
    "fsc-tampico": "SOCATA TB family",
    "fsc-faeta": "ATEC 321 Faeta",
    "fsc-remos-g3": "Remos GX",          # article covers the G3 Mirage too
    "fsc-cozy": "Cozy MK IV",
    "fsc-skyfox": "Skyfox Aviation Skyfox",
    "fsc-gamebird": "Game Composites GB1 GameBird",
    "fsc-mx2": "MX Aircraft MX2",
    "fsc-sling4": "Sling Aircraft Sling 4",
    "fsc-sling-high-wing": "Sling Aircraft Sling HW",
    "fsc-c42": "Ikarus C42",
    "fsc-zodiac": "AMD Zodiac",
    "fsc-bushcat": "SkyReach BushCat",
}

ALLOWED_LICENSE = re.compile(
    # Optional jurisdiction port suffix ("CC BY-SA 3.0 de") is the same licence.
    r"^(public domain|pd|cc0( 1\.0)?|cc by(-sa)? \d\.\d( [a-z]{2})?)$",
    re.IGNORECASE,
)

UNIT_TO_METRES = {
    "Q11573": 1.0,       # metre
    "Q3710": 0.3048,     # foot
    "Q174728": 0.01,     # centimetre
    "Q218593": 0.0254,   # inch
    "Q174789": 0.001,    # millimetre
}


# MARK: - HTTP

_last_request = 0.0


def get_json(base, params):
    """GET base?params as JSON, ~1 s after the previous request. With
    TYPEINFO_CACHE_DIR set, responses are cached there by URL so a re-run
    (e.g. after tuning OVERRIDES or the matcher) costs no requests."""
    global _last_request
    cache_dir = os.environ.get("TYPEINFO_CACHE_DIR")
    cache_file = None
    if cache_dir:
        key = hashlib.sha256((base + json.dumps(params, sort_keys=True)).encode()).hexdigest()
        cache_file = Path(cache_dir) / f"{key}.json"
        if cache_file.exists():
            return json.loads(cache_file.read_text())
    wait = REQUEST_GAP_S - (time.monotonic() - _last_request)
    if wait > 0:
        time.sleep(wait)
    query = dict(params)
    query.setdefault("format", "json")
    query.setdefault("formatversion", "2")
    url = base + "?" + urllib.parse.urlencode(query)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                _last_request = time.monotonic()
                data = json.load(resp)
                if cache_file:
                    cache_file.parent.mkdir(parents=True, exist_ok=True)
                    cache_file.write_text(json.dumps(data))
                return data
        except Exception as exc:  # noqa: BLE001 — retry any transient failure
            _last_request = time.monotonic()
            if attempt == 3:
                raise
            print(f"  retry after error: {exc}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))


def chunks(seq, n):
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


# MARK: - Sets.swift parsing

# Every typecode a family entry claims through `exactTypecodes:`, filled by
# parse_families(). The typecode pass skips these (the family article wins).
EXACT_TYPECODES = set()

def parse_families():
    """[(family_id, family_title, entry_id, canonical_name, typecode)]."""
    src = SETS_SWIFT.read_text()
    start = src.index("private static let familiesCore")
    end = src.index("static let families: [CardSet]")
    body = src[start:end]
    out = []
    family = None
    pattern = re.compile(
        r'\.init\(id:\s*"([^"]+)",\s*'
        r'(?:type:\s*\.\w+,\s*title:\s*"([^"]+)"|canonicalName:\s*"([^"]+)")'
    )
    for m in pattern.finditer(body):
        if m.group(2) is not None:
            family = (m.group(1), m.group(2))
            continue
        rest = body[m.end():]
        nxt = rest.find(".init(")
        segment = rest if nxt < 0 else rest[:nxt]
        tc = re.search(r'representativeTypecode:\s*"([^"]+)"', segment)
        exact = re.search(r'exactTypecodes:\s*\[([^\]]*)\]', segment)
        if exact:
            EXACT_TYPECODES.update(re.findall(r'"([^"]+)"', exact.group(1)))
        out.append((family[0], family[1], m.group(1), m.group(3),
                    tc.group(1) if tc else None))
    return [e for e in out if e[0] != "fam-unidentified"]


def candidate_title(family_id, canonical):
    name = canonical.split(" / ")[0].strip()
    maker = FAMILY_MAKER.get(family_id)
    if maker and not name.lower().startswith(maker.lower()) \
            and not name.lower().startswith(maker.split()[0].lower()):
        return f"{maker} {name}"
    return name


# MARK: - Wikipedia

def resolve_titles(titles):
    """title -> (final_title, qid, is_disambiguation, short_description) or
    None if missing."""
    result = {}
    for batch in chunks(sorted(set(titles)), 50):
        data = get_json(WIKI_API, {
            "action": "query",
            "titles": "|".join(batch),
            "redirects": "1",
            "prop": "pageprops",
            "ppprop": "wikibase_item|disambiguation|wikibase-shortdesc",
        })
        q = data.get("query", {})
        mapping = {t: t for t in batch}
        for norm in q.get("normalized", []):
            for k, v in mapping.items():
                if v == norm["from"]:
                    mapping[k] = norm["to"]
        for red in q.get("redirects", []):
            for k, v in mapping.items():
                if v == red["from"]:
                    mapping[k] = red["to"]
        pages = {p["title"]: p for p in q.get("pages", [])}
        for original, final in mapping.items():
            page = pages.get(final)
            if not page or page.get("missing") or page.get("invalid"):
                result[original] = None
                continue
            props = page.get("pageprops", {})
            result[original] = (final, props.get("wikibase_item"),
                                "disambiguation" in props,
                                props.get("wikibase-shortdesc", ""))
    return result


# MARK: - Wikidata

def best_claims(entity, prop):
    claims = entity.get("claims", {}).get(prop, [])
    claims = [c for c in claims if c.get("rank") != "deprecated"
              and c.get("mainsnak", {}).get("snaktype") == "value"]
    preferred = [c for c in claims if c.get("rank") == "preferred"]
    return preferred or claims


def first_flight_year(entity):
    years = []
    for c in best_claims(entity, "P606"):
        t = c["mainsnak"]["datavalue"]["value"].get("time", "")
        m = re.match(r"^\+?(\d{4})-", t)
        if m:
            years.append(int(m.group(1)))
    return min(years) if years else None


def quantity(claim):
    v = claim["mainsnak"]["datavalue"]["value"]
    unit = v.get("unit", "1").rsplit("/", 1)[-1]
    return float(v["amount"]), unit


def number_built(entity):
    values = []
    for c in best_claims(entity, "P1092"):
        amount, _ = quantity(c)
        if amount > 0:
            values.append(int(round(amount)))
    # Multiple statements are usually counts at different dates; the
    # largest is the most recent cumulative total.
    return max(values) if values else None


def length_metres(entity, prop, unknown_units):
    for c in best_claims(entity, prop):
        amount, unit = quantity(c)
        factor = UNIT_TO_METRES.get(unit)
        if factor is None:
            unknown_units.add(unit)
            continue
        if amount > 0:
            return round(amount * factor, 2)
    return None


RASTER = re.compile(r"\.(jpe?g|png|webp)$", re.IGNORECASE)


def image_file(entity):
    for c in best_claims(entity, "P18"):
        name = c["mainsnak"]["datavalue"]["value"]
        if RASTER.search(name):  # photos only, never SVG drawings
            return name
    return None


def fetch_entities(qids):
    out = {}
    for batch in chunks(sorted(set(qids)), 50):
        data = get_json(WIKIDATA_API, {
            "action": "wbgetentities",
            "ids": "|".join(batch),
            "props": "claims",
        })
        out.update(data.get("entities", {}))
    return out


def lead_images(titles):
    """article title -> its lead image file name (Wikipedia pageimages).

    Second source for entries whose Wikidata P18 is missing or not freely
    licensed. A non-Commons (fair-use) lead image simply fails the Commons
    licence check later, so it can never slip through.
    """
    out = {}
    for batch in chunks(sorted(set(titles)), 50):
        data = get_json(WIKI_API, {
            "action": "query",
            "titles": "|".join(batch),
            "prop": "pageimages",
            "piprop": "name",
        })
        for page in data.get("query", {}).get("pages", []):
            name = page.get("pageimage")
            if name and RASTER.search(name):
                out[page["title"]] = name.replace("_", " ")
    return out


# Words in a file name that mean it is not a photo of the whole aircraft.
NOT_THE_AIRCRAFT = re.compile(
    r"cockpit|panel|interior|cabin|engine|logo|flag|map|diagram|drawing|"
    r"3view|3-view|schematic|seat|wreck|crash|accident|propeller|wheel|mockup|mock-up",
    re.IGNORECASE)


def _squash(text):
    return re.sub(r"[^a-z0-9]", "", text.lower())


def article_photos(titles):
    """article title -> candidate photo file names, best first.

    Third source, for articles where neither P18 nor the lead image is a
    freely licensed photo. Only files whose name mentions the type (a word of
    the title after the maker, e.g. "SR22", "PC-12", "King Air") count, so a
    stray photo of some other aircraft in the article is never picked. Every
    candidate still goes through the Commons licence check.
    """
    out = {}
    for title in sorted(set(titles)):
        data = get_json(WIKI_API, {
            "action": "query",
            "titles": title,
            "prop": "images",
            "imlimit": "max",
        })
        names = []
        for page in data.get("query", {}).get("pages", []):
            for im in page.get("images", []):
                n = im.get("title", "")
                n = n.split(":", 1)[1] if ":" in n else n
                if RASTER.search(n) and not NOT_THE_AIRCRAFT.search(n):
                    names.append(n.replace("_", " "))
        words = [_squash(w) for w in title.split()[1:]]
        words = [w for w in words if len(w) >= 2]
        joined = _squash("".join(title.split()[1:]))

        def score(name):
            sq = _squash(name)
            return (joined in sq) * 10 + sum(w in sq for w in words)

        ranked = sorted((n for n in names if score(n) > 0),
                        key=lambda n: (-score(n), n))
        if ranked:
            out[title] = ranked[:8]
    return out


# MARK: - Commons

def strip_html(text):
    text = re.sub(r"<[^>]+>", "", text or "")
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


# Commons "Artist" fields are free text, and some are not an author at all.
# clean_artist() turns the recurring boilerplate into the name the licence
# wants credited, or "" when there is no real author in the field.
_NO_AUTHOR = {"self", "unknown", "own work", "anonymous"}


def clean_artist(text):
    a = strip_html(text)
    # "No machine-readable author provided. X assumed (based on copyright
    # claims)." -> X (the uploader), unless X is a bot.
    m = re.match(r"^No machine-readable author provided\.\s*(.+?)\s+assumed\b", a)
    if m:
        a = m.group(1).replace("~commonswiki", "").strip()
        if re.search(r"\bbot$", a, re.IGNORECASE):
            return ""
    # "Orig.jpg: A derivative work: B (talk)" -> "A / B".
    m = re.match(r"^\S+\.(?:jpe?g|png|tiff?|gif):\s*(.+?)\s+derivative work:\s*(.+)$", a,
                 re.IGNORECASE)
    if m:
        a = f"{m.group(1)} / {m.group(2)}"
    # "(The) original uploader was X at en.wikipedia. Later version(s) ..." -> X.
    m = re.match(r"^(?:The )?original uploader was (.+?) at "
                 r"(?:en\.wikipedia|English Wikipedia)\b", a, re.IGNORECASE)
    if m:
        a = m.group(1)
    # "Myself (Adrian Pingstone)." -> "Adrian Pingstone".
    m = re.match(r"^Myself \((.+)\)\.?$", a)
    if m:
        a = m.group(1)
    a = re.sub(r"\s*\(talk\)", "", a)
    a = re.sub(r"\s*\(There are \d+ Pictures in my Category\)", "", a)
    a = re.sub(r"\s*See also Toolserver\b", "", a)
    a = re.sub(r"\s+", " ", a).strip(" .")
    return "" if a.lower() in _NO_AUTHOR else a


def fetch_photos(files):
    """file name -> (photo dict | None, licence short name)."""
    out = {}
    for batch in chunks(sorted(set(files)), 50):
        titles = ["File:" + f for f in batch]
        data = get_json(COMMONS_API, {
            "action": "query",
            "titles": "|".join(titles),
            "prop": "imageinfo",
            "iiprop": "url|extmetadata|user",
            "iiurlwidth": "800",
        })
        q = data.get("query", {})
        norm = {n["to"]: n["from"] for n in q.get("normalized", [])}
        for page in q.get("pages", []):
            title = page.get("title", "")
            original = norm.get(title, title)
            name = original[len("File:"):] if original.startswith("File:") else original
            infos = page.get("imageinfo") or []
            if not infos:
                out[name] = (None, "missing")
                continue
            info = infos[0]
            meta = info.get("extmetadata", {})
            lic = strip_html(meta.get("LicenseShortName", {}).get("value", ""))
            artist = clean_artist(meta.get("Artist", {}).get("value", "")) \
                or clean_artist(meta.get("Credit", {}).get("value", ""))
            thumb = info.get("thumburl") or info.get("url")
            page_url = info.get("descriptionurl")
            # Commons appends utm_* tracking params to thumb URLs; drop them.
            thumb = thumb.split("?", 1)[0] if thumb else thumb
            page_url = page_url.split("?", 1)[0] if page_url else page_url
            if not ALLOWED_LICENSE.match(lic):
                out[name] = (None, lic or "unknown")
                continue
            if not (thumb and page_url and thumb.startswith("https://")
                    and page_url.startswith("https://")):
                out[name] = (None, "non-https url")
                continue
            if lic.lower() in ("pd", "public domain"):
                lic = "Public domain"
            if not artist and lic not in ("Public domain", "CC0"):
                # No author in the metadata: credit the uploader, who is
                # the author Commons assumes for an own-work upload.
                artist = clean_artist(info.get("user", ""))
            if not artist and lic not in ("Public domain", "CC0"):
                # CC BY/BY-SA require attribution; no author, no photo.
                out[name] = (None, lic + " without author")
                continue
            out[name] = ({
                "imageURL": thumb,
                "pageURL": page_url,
                # "" for a public-domain photo with no known author: the
                # app then credits just the licence and Commons.
                "artist": artist,
                "license": lic,
            }, lic)
    return out


# MARK: - Sanity heuristics

def looks_wrong(canonical, final_title, is_disambig):
    if is_disambig:
        return "disambiguation page"
    title = final_title.lower()
    # Some distinctive token of the canonical name should appear in the
    # article title (a digit-bearing designator or a brand word).
    tokens = re.findall(r"[a-z0-9]+", canonical.lower().split(" / ")[0])
    tokens = [t for t in tokens if len(t) >= 2 and t not in {"series", "family"}]
    if not tokens:
        return None
    hits = [t for t in tokens if t in title]
    if not hits:
        return "no shared token with canonical name"
    return None


# MARK: - Typecode pass

# A typecode's article must describe an aircraft TYPE, not a maker, airline
# or anything else the name search turns up.
AIRCRAFT_DESC = re.compile(
    r"aircraft|airplane|aeroplane|helicopter|airliner|glider|gyro|autogiro|"
    r"airship|seaplane|flying boat|biplane|monoplane|ultralight|microlight|"
    r"fighter|bomber|trainer|airlifter|tiltrotor|rotorcraft|jet\b|"
    r"business jet|light-sport|amphibian|unmanned aerial|uav|drone|"
    r"transport plane|cargo plane",
    re.IGNORECASE)
NOT_A_TYPE_DESC = re.compile(
    r"manufacturer|\bcompany\b|corporation|\bairlines?\b|\bairports?\b|"
    r"air force|squadron|aircraft engine|piston engine|turbofan|turbojet engine|"
    r"turboprop engine|turboshaft|\bperson\b|family of|list of|disambiguation|"
    r"\baccident\b|\bcrash\b|\bincident\b|\bmissile\b|"
    r"\bengines?\b(?! aircraft| airplane| light| plane| monoplane| biplane)|"
    r"^turbojet$|^turbofan$",
    re.IGNORECASE)

ROMAN = {"i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6",
         "vii": "7", "viii": "8", "x": "10"}


def _alnum(text):
    return re.sub(r"[^a-z0-9]", "", text.lower())


def designator_tokens(text):
    """Digit-bearing designators, alnum-squashed, at word level: "M-3 Falcon
    Major" -> {"m", "3", "m3"} minus non-designators = {"m3"}; "727-200RE
    Super 27" -> {"727", "200re", "727200re"}. Pure numbers under 3 digits
    are dropped ("27" would match almost anything). Compared by EQUALITY
    against the title's own tokens, so "AC-4" never matches "AC-47"."""
    out = set()
    for word in re.split(r"[\s/,()]+", text.lower()):
        parts = [x for x in re.split(r"[-.]", word) if x]
        for tok in parts + ["".join(parts)]:
            tok = _alnum(tok)
            if not re.search(r"\d", tok):
                continue
            if tok.isdigit() and len(tok) < 3:
                continue
            out.add(tok)
    return out


def numbers(text):
    """Every number in a name, with standalone roman numerals (I-VIII, X)
    read as digits, so "Citation X" differs from "Citation VII"."""
    words = re.findall(r"[a-z]+", text.lower())
    return set(re.findall(r"\d+", text)) | {ROMAN[w] for w in words if w in ROMAN}


def word_tokens(text):
    return {t for t in re.findall(r"[a-z]{4,}", text.lower())
            if t not in {"aviation", "aircraft", "aerospace", "industries",
                         "company", "corporation", "series", "family",
                         "international", "super", "light", "sport", "aero"}}


def typecode_article_ok(make, model, hit):
    """Whether a resolved article plausibly IS this make+model. Strict on
    purpose: a missing description is fine, a wrong one is not."""
    if not hit:
        return False
    final, _qid, disambig, desc = hit
    if disambig or not desc:
        return False
    # "Yakovlev Yak-30 (1948)": a dated disambiguator means two aircraft
    # share the name; we can't tell which one the typecode is.
    if re.search(r"\(.*\d.*\)", final):
        return False
    # "Twin engine light aircraft" is a plane; "Jet engine" is not. Count
    # engines only when not part of "<n>-engine"/"<n> engine".
    plain = re.sub(r"[\w-]+-engined?\b|\b(single|twin|two|three|four|multi) engined?\b",
                   "", desc, flags=re.IGNORECASE)
    if not AIRCRAFT_DESC.search(desc) or NOT_A_TYPE_DESC.search(plain):
        return False
    # Different numbers = a different type or variant ("Acro-Sport 1" vs
    # "Acro Sport II", "APM-21" vs "APM 30"); a number only the title has is
    # a variant too ("Anka" vs "TAI Anka-3").
    m_nums = numbers(f"{make} {model}")
    t_nums = numbers(final)
    if t_nums and not (m_nums & t_nums):
        return False
    # A variant article for a base model ("Airbus A310 MRTT"): an all-caps
    # word in the title, past the maker position, that the model lacks.
    own = {w.lower() for w in re.findall(r"[A-Za-z]+", f"{make} {model}")}
    later_caps = re.findall(r"\b[A-Z]{3,}\b", final.split(" ", 1)[1]) \
        if " " in final else []
    if any(w.lower() not in own for w in later_caps):
        return False
    title_designators = designator_tokens(final)
    if designator_tokens(model) & title_designators:
        return True
    title = _alnum(final)
    make_words = word_tokens(make) or {_alnum(make)}
    return bool(word_tokens(model) & word_tokens(final)) and \
        any(m and m in title for m in make_words)


def names_the_variant(model, final):
    """Whether the article title carries the model's FULL designator, i.e.
    is about this variant and not its base model or family ("Antonov An-124
    Ruslan" for An-124: yes; "Airbus A340" for A340-500: no). Models with no
    designator ("Aircruiser") count as named. Only then are the article's
    Wikidata specs the variant's own."""
    full = {_alnum(w) for w in re.split(r"[\s/,()]+", model)
            if re.search(r"\d", w) and not (w.isdigit() and len(w) < 3)}
    if not full:
        return True
    return bool(full & designator_tokens(final))


def pick_typecode_articles(types, exclude, limit=None):
    """typecode -> resolved hit, for AircraftTypes.json typecodes not already
    a family entry's representative typecode. "make model" as an exact title
    first, then the top 3 search results, each through typecode_article_ok."""
    queries = {}
    for tc in sorted(types):
        rec = types[tc]
        if tc.upper() in exclude or not rec.get("make") or not rec.get("model"):
            continue
        queries[tc] = (rec["make"], rec["model"],
                       f"{rec['make']} {rec['model']}".strip())
    if limit:
        queries = dict(list(queries.items())[:limit])
    print(f"Typecode pass: {len(queries)} typecodes")

    exact = resolve_titles([q[2] for q in queries.values()])
    picks, pending = {}, {}
    for tc, (make, model, q) in queries.items():
        hit = exact.get(q)
        if typecode_article_ok(make, model, hit):
            picks[tc] = hit
        else:
            pending[tc] = (make, model, q)
    print(f"  exact-title hits: {len(picks)}; searching {len(pending)}")

    candidates = {}
    for i, (tc, (_make, _model, q)) in enumerate(pending.items()):
        data = get_json(WIKI_API, {
            "action": "query", "list": "search", "srsearch": q,
            "srlimit": "3", "srnamespace": "0", "srprop": "",
        })
        candidates[tc] = [r["title"] for r in data.get("query", {}).get("search", [])]
        if (i + 1) % 100 == 0:
            print(f"  searched {i + 1}/{len(pending)}", flush=True)
    found = resolve_titles([t for ts in candidates.values() for t in ts]) \
        if candidates else {}
    for tc, titles in candidates.items():
        make, model, _q = pending[tc]
        for t in titles:
            if typecode_article_ok(make, model, found.get(t)):
                picks[tc] = found[t]
                break
    print(f"  typecodes with an article: {len(picks)}/{len(queries)}")
    return picks


# MARK: - Main

def main():
    dry_run = "--dry-run" in sys.argv
    limit = None
    if "--typecode-limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--typecode-limit") + 1])
        # A partial typecode pass must never overwrite the shipped file.
        dry_run = True
    entries = parse_families()
    print(f"Parsed {len(entries)} family entries from Sets.swift")

    wanted = {}
    for fam_id, _title, entry_id, canonical, _tc in entries:
        if entry_id in OVERRIDES:
            wanted[entry_id] = OVERRIDES[entry_id]
        else:
            wanted[entry_id] = candidate_title(fam_id, canonical)

    resolved = resolve_titles([t for t in wanted.values() if t])

    # Every other typecode in AircraftTypes.json gets its own record, keyed
    # by typecode, so the rare tail (most GA, military and odd types) has a
    # description too. Stored in `resolved` under "tc:<CODE>" so the photo
    # and Wikidata passes below cover them.
    types = json.loads(AIRCRAFT_TYPES.read_text())
    family_tcs = {tc.upper() for *_rest, tc in entries if tc} \
        | {tc.upper() for tc in EXACT_TYPECODES}
    tc_hits = pick_typecode_articles(types, family_tcs, limit)
    for tc, hit in tc_hits.items():
        resolved[f"tc:{tc}"] = hit

    qids = [r[1] for r in resolved.values() if r and r[1]]
    entities = fetch_entities(qids) if qids else {}

    unknown_units = set()
    facts = {}
    for qid, entity in entities.items():
        facts[qid] = {
            "firstFlightYear": first_flight_year(entity),
            "numberBuilt": number_built(entity),
            "wingspanMeters": length_metres(entity, "P2050", unknown_units),
            "lengthMeters": length_metres(entity, "P2043", unknown_units),
            "image": image_file(entity),
        }

    files = [f["image"] for f in facts.values() if f["image"]]
    photos = fetch_photos(files) if files else {}

    # Fallback photo source: the article's lead image, for every article
    # whose P18 is absent or was dropped for its licence.
    def has_photo(final_qid):
        f = facts.get(final_qid or "", {})
        return bool(f.get("image")) and bool(photos.get(f["image"], (None,))[0])
    needs_lead = sorted({r[0] for r in resolved.values()
                         if r and not has_photo(r[1])})
    leads = lead_images(needs_lead) if needs_lead else {}
    new_files = [f for f in leads.values() if f not in photos]
    if new_files:
        photos.update(fetch_photos(new_files))

    # An article shared by several entries is a FAMILY article (737-800 and
    # 737-700 both -> "Boeing 737 Next Generation"). Its Wikidata specs
    # describe the family, not the variant on the card (the Dash 8 item's
    # length is the -100's, wrong for a Q400), so shared-article entries get
    # no Wikidata specs; the app falls back to the per-typecode wingspan and
    # length in AircraftTypes.json. The article, summary and photo still apply.
    article_users = {}
    for _f, _t, eid, _c, _tc in entries:
        hit = resolved.get(wanted[eid]) if wanted[eid] else None
        if hit:
            article_users[hit[0]] = article_users.get(hit[0], 0) + 1
    # Typecode records count sharing separately: a typecode on its family's
    # article must not strip the FAMILY entry's specs, but a typecode whose
    # article a family entry or another typecode also uses gets none itself.
    tc_article_users = dict(article_users)
    for hit in tc_hits.values():
        tc_article_users[hit[0]] = tc_article_users.get(hit[0], 0) + 1

    # Third source: other photos in the article, for articles still without
    # a usable P18 or lead image.
    def lead_ok(title):
        return bool(photos.get(leads.get(title, ""), (None,))[0])
    needs_any = sorted({r[0] for r in resolved.values()
                        if r and not has_photo(r[1]) and not lead_ok(r[0])})
    extras = article_photos(needs_any) if needs_any else {}
    extra_files = [f for fs in extras.values() for f in fs if f not in photos]
    if extra_files:
        photos.update(fetch_photos(extra_files))

    out = {}
    no_article, suspicious, dropped = [], [], []
    from_lead = 0
    from_article = 0
    shared_article = 0
    implausible = []
    def build(entry_id, report_id, final, qid, users, specs_ok=True):
        nonlocal shared_article, from_lead, from_article
        info = {"entryId": entry_id, "wikipediaTitle": final}
        if qid:
            info["wikidataId"] = qid
            f = facts.get(qid, {})
            if users.get(final, 0) > 1 or not specs_ok:
                shared_article += 1
            else:
                for key in ("firstFlightYear", "numberBuilt",
                            "wingspanMeters", "lengthMeters"):
                    if f.get(key) is not None:
                        info[key] = f[key]
                # Wikidata occasionally carries a unit slip (Falcon 900:
                # "119 m" long on a 19 m span). Aircraft are never 3x longer
                # than wide or vice versa, so drop both rather than guess
                # which one is wrong; AircraftTypes.json fills in.
                w, l = info.get("wingspanMeters"), info.get("lengthMeters")
                if w and l and not (1 / 3 <= l / w <= 3):
                    implausible.append((report_id, w, l))
                    del info["wingspanMeters"], info["lengthMeters"]
            image = f.get("image")
            if image:
                photo, lic = photos.get(image, (None, "missing"))
                if photo:
                    info["photo"] = photo
                else:
                    dropped.append((report_id, image, lic))
        if "photo" not in info and final in leads:
            photo, lic = photos.get(leads[final], (None, "missing"))
            if photo:
                info["photo"] = photo
                from_lead += 1
            else:
                dropped.append((report_id, leads[final] + " (lead image)", lic))
        if "photo" not in info:
            for name in extras.get(final, []):
                photo, _lic = photos.get(name, (None, "missing"))
                if photo:
                    info["photo"] = photo
                    from_article += 1
                    break
        return info

    for fam_id, fam_title, entry_id, canonical, _tc in entries:
        title = wanted[entry_id]
        hit = resolved.get(title) if title else None
        if not hit:
            no_article.append((entry_id, canonical, title))
            continue
        final, qid, disambig, _desc = hit
        reason = looks_wrong(canonical, final, disambig)
        if reason:
            suspicious.append((entry_id, canonical, final, reason))
        out[entry_id] = build(entry_id, entry_id, final, qid, article_users)

    by_typecode = {}
    for tc, hit in sorted(tc_hits.items()):
        rec = types.get(tc, {})
        by_typecode[tc] = build("", tc, hit[0], hit[1], tc_article_users,
                                specs_ok=names_the_variant(rec.get("model", ""), hit[0]))

    doc = {
        "version": 1,
        "generated": datetime.date.today().isoformat(),
        "entries": out,
        "typecodes": by_typecode,
    }

    print()
    print("=== Report ===")
    print(f"entries: {len(entries)}  resolved: {len(out)}  "
          f"no article: {len(no_article)}  looks wrong: {len(suspicious)}")
    with_photo = sum(1 for v in out.values() if "photo" in v)
    print(f"with photo: {with_photo} ({from_lead} from article lead images, "
          f"{from_article} from other article photos)  "
          f"photo candidates dropped for licence: {len(dropped)}")
    for eid, v in sorted(out.items()):
        if "photo" not in v:
            print(f"  no photo: {eid} ({v['wikipediaTitle']})")
    print(f"entries on a shared family article (Wikidata specs omitted): {shared_article}")
    for key in ("firstFlightYear", "numberBuilt", "wingspanMeters", "lengthMeters"):
        print(f"  {key}: {sum(1 for v in out.values() if key in v)}")
    if implausible:
        print(f"implausible dims dropped (span, length m): {implausible}")
    if unknown_units:
        print(f"unknown length units (skipped): {sorted(unknown_units)}")
    if no_article:
        print("\n-- No article:")
        for e in no_article:
            print(f"  {e[0]:28} {e[1]!r} tried {e[2]!r}")
    if suspicious:
        print("\n-- Looks wrong:")
        for e in suspicious:
            print(f"  {e[0]:28} {e[1]!r} -> {e[2]!r} ({e[3]})")
    if dropped:
        print("\n-- Photos dropped:")
        for e in dropped:
            print(f"  {e[0]:28} {e[1]} [{e[2]}]")
    print("\n-- Mapping:")
    for fam_id, fam_title, entry_id, canonical, _tc in entries:
        info = out.get(entry_id)
        print(f"  {entry_id:28} {canonical!r:40} -> "
              f"{info['wikipediaTitle'] if info else '-'}")

    print(f"\n-- Typecodes ({len(by_typecode)} with an article, "
          f"{sum(1 for v in by_typecode.values() if 'photo' in v)} with a photo):")
    for tc, info in sorted(by_typecode.items()):
        rec = types.get(tc, {})
        print(f"  {tc:6} {rec.get('make', '')} {rec.get('model', '')!r:40} -> "
              f"{info['wikipediaTitle']}")

    if dry_run:
        print("\n(dry run: TypeInfo.json not written)")
        return
    OUT_JSON.write_text(json.dumps(doc, indent=2, sort_keys=True,
                                   ensure_ascii=False) + "\n")
    print(f"\nWrote {OUT_JSON.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
