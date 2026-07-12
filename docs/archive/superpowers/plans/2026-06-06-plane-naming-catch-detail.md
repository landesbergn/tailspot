# Plane Naming Standardization + Catch Detail Upgrades — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Official ICAO-derived aircraft names everywhere, airline-agnostic set grouping with Unknown last, and a catch detail view that shows ALT/SPD, city/state location, tail number, and supports confirmed deletion — with one-time backfill for pre-existing rows.

**Architecture:** A checked-in python generator converts ICAO DOC 8643 (official endpoint, verified fetchable) into a bundled JSON table; a new pure `AircraftNaming` enum resolves typecode→official name with a string-cleanup fallback (Boeing customer-code stripping) applied at READ time — raw OpenSky strings stay stored. Five additive optional fields land on `Catch` (lightweight migration). `CatchDetailView` gains an airframe panel, place-name line, delete flow, and a fill-only-if-nil backfill.

**Tech Stack:** Swift/SwiftUI, SwiftData, Swift Testing (`@Test`/`#expect`), python3 stdlib (generator), CoreLocation reverse geocoding.

**Spec:** `docs/superpowers/specs/2026-06-06-plane-naming-catch-detail-design.md` — read it first.

**Branch:** all work happens on `feature/naming-catch-detail` (already created; the spec commits live on it).

---

## Repo facts you need (read once)

- **Synchronized folders:** any file dropped into `ios/Tailspot/Tailspot/` is auto-added to the Xcode target — `.swift` as source, `.json`/`.ttf` as bundled resources (the B612 fonts prove this). No "Add Files" step ever.
- **MainActor default isolation (Xcode 26):** every new type is implicitly `@MainActor`. Pure value types/helpers that must work anywhere get explicit `nonisolated` — and so do their extensions (extensions do NOT inherit it).
- **Test command** (run from repo root; first run ~3 min cold, then ~30–60 s):
  ```bash
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests
  ```
  Single suite: append e.g. `-only-testing:TailspotTests/AircraftNamingTests`.
- **Tests run hosted in the app**, so `Bundle.main` inside tests IS the Tailspot app bundle — bundled-resource tests just work.
- **Suite baseline: 213 tests pass** before this plan.
- **Do not run `bin/deploy`** until the final task; tests gate deploys.
- **Commit after every task** (steps below include the commands). Never `git add ios/` blindly — name files explicitly; never commit if the diff contains `OPENSKY`, `client_secret`, or `EnvironmentVariable`.

---

### Task 1: DOC 8643 generator tool + bundled table

**Files:**
- Create: `tools/generate-aircraft-types.py`
- Create (generated): `ios/Tailspot/Tailspot/AircraftTypes.json`

- [ ] **Step 1: Write the generator script**

Create `tools/generate-aircraft-types.py` with exactly this content:

```python
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
# styling). Default rule below title-cases every word.
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
}

# designator: (make, model) — pins designators where the deterministic
# reduction picks a poor representative. POPULATED FROM POST-GENERATION
# REVIEW (--sample), never from memory.
OVERRIDES = {}


def polish_make(raw):
    raw = " ".join(raw.split())
    upper = raw.upper()
    if upper in SPECIAL_MAKES:
        return SPECIAL_MAKES[upper]
    if raw != upper:
        return raw  # already mixed-case in the source
    return " ".join(w.capitalize() for w in raw.split())


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
        rows = json.load(open(args.input))
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
```

- [ ] **Step 2: Run it and check the stats line**

```bash
python3 tools/generate-aircraft-types.py
```
Expected output shape: `rows in: 7260  designators out: <N>  -> .../AircraftTypes.json` with N in the 2,500–3,000 band. If the fetch fails (network), STOP and report — don't hand-build the file.

- [ ] **Step 3: Human review — the random sample**

```bash
python3 tools/generate-aircraft-types.py --sample 25
```
Read all 25 names. Each should read like a plane-spotter wrote it ("Cessna 172", "Boeing 777-300ER"), NOT like a database dump (truncated model, ALL-CAPS make not on the exceptions list, cryptic codes). Also check these eight known designators directly in the generated JSON:

```bash
python3 -c "
import json
t = json.load(open('ios/Tailspot/Tailspot/AircraftTypes.json'))
for d in ['B738','B77W','A20N','BCS3','A320','CRJ7','AT76','C172']:
    print(d, t.get(d))"
```
Required: `B738` → Boeing 737-800, `B77W` → Boeing 777-300ER, `A20N` → Airbus A320neo, `BCS3` → Airbus A220-300 (these four were verified against the live endpoint during design). For `A320`/`CRJ7`/`AT76`/`C172`: if any reads poorly (e.g. CRJ7 comes out "Bombardier Regional Jet CRJ-700"), add an `OVERRIDES` entry (e.g. `"CRJ7": ("Bombardier", "CRJ-700")`), re-run, re-review. Record what the final values are — Task 2's spot-check tests pin them.

- [ ] **Step 4: Commit**

```bash
git add tools/generate-aircraft-types.py ios/Tailspot/Tailspot/AircraftTypes.json
git commit -m "Add DOC 8643 aircraft-type table + generator

tools/generate-aircraft-types.py fetches ICAO's official designator
data (~7,260 rows), reduces to one canonical (make, model) per
designator (~2,700), and writes the bundled AircraftTypes.json the
naming layer reads at runtime. Overrides are populated from human
review of the generated output, never from memory."
```

---

### Task 2: `AircraftNaming` — canonical name resolution (TDD)

**Files:**
- Create: `ios/Tailspot/Tailspot/AircraftNaming.swift`
- Create: `ios/Tailspot/TailspotTests/AircraftNamingTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/Tailspot/TailspotTests/AircraftNamingTests.swift`:

```swift
//
//  AircraftNamingTests.swift
//  TailspotTests
//
//  Canonical-name resolution: bundled DOC 8643 table (structural
//  checks across ALL ~2,700 entries, not just spot values) + the
//  string-cleanup fallback (Boeing customer codes, casing).
//
//  The python generator is not tested here — its checked-in OUTPUT is.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("AircraftNaming")
struct AircraftNamingTests {

    // MARK: - Bundled table, structural

    @Test func tableLoadsWithFullDoc8643Coverage() {
        let count = AircraftNaming.table.count
        #expect(count >= 2_500)
        #expect(count <= 3_000)
    }

    @Test func everyEntryIsCleanAndNonEmpty() {
        for (code, name) in AircraftNaming.table {
            #expect(name.make?.isEmpty == false, "\(code): empty make")
            #expect(name.model?.isEmpty == false, "\(code): empty model")
            let display = name.displayName ?? ""
            #expect(!display.contains("  "), "\(code): double space in \(display)")
            #expect(display == display.trimmingCharacters(in: .whitespacesAndNewlines),
                    "\(code): untrimmed \(display)")
        }
    }

    @Test func airbusEntriesUseMarketingHyphenStyle() {
        for (code, name) in AircraftNaming.table where name.make == "Airbus" {
            #expect(name.model?.hasPrefix("A-") != true,
                    "\(code): raw ICAO hyphen style survived: \(name.model ?? "")")
        }
    }

    /// All-caps makes only exist when the generator's SPECIAL_MAKES
    /// map keeps them caps deliberately. This set must mirror that
    /// map's deliberately-caps values — a new raw-caps make appearing
    /// here means the generator ran without polish.
    @Test func makesAreNotShoutyUnlessExempt() {
        let exempt: Set<String> = ["ATR", "PZL", "CASA", "MBB", "NAMC", "BAE Systems"]
        for (code, name) in AircraftNaming.table {
            guard let make = name.make, make.count >= 4, !exempt.contains(make) else { continue }
            #expect(make != make.uppercased(), "\(code): make looks raw: \(make)")
        }
    }

    // MARK: - Bundled table, spot checks (values verified against the
    // live ICAO endpoint during design, 2026-06-06)

    @Test func officialNamesResolveFromTypecode() {
        #expect(AircraftNaming.canonical(typecode: "B738", manufacturer: nil, model: nil).displayName == "Boeing 737-800")
        #expect(AircraftNaming.canonical(typecode: "B77W", manufacturer: nil, model: nil).displayName == "Boeing 777-300ER")
        #expect(AircraftNaming.canonical(typecode: "A20N", manufacturer: nil, model: nil).displayName == "Airbus A320neo")
        #expect(AircraftNaming.canonical(typecode: "BCS3", manufacturer: nil, model: nil).displayName == "Airbus A220-300")
    }

    @Test func typecodeIsCaseAndWhitespaceInsensitive() {
        #expect(AircraftNaming.canonical(typecode: " b738 ", manufacturer: nil, model: nil).displayName == "Boeing 737-800")
    }

    @Test func typecodeWinsOverRawStrings() {
        let n = AircraftNaming.canonical(typecode: "B77W", manufacturer: "BOEING", model: "777-3F2ER")
        #expect(n.displayName == "Boeing 777-300ER")
    }

    // MARK: - Fallback: Boeing customer-code collapse
    // Dirty inputs collapse; clean inputs MUST pass through unchanged
    // (idempotence) — OpenSky has both since Boeing dropped customer
    // codes ~2016.

    @Test(arguments: [
        ("737-8H4", "737-800"),        // letter+digit code (Southwest)
        ("777-322", "777-300"),        // all-digit code (United)
        ("777-3F2ER", "777-300ER"),    // suffix survives
        ("767-332(ER)", "767-300ER"),  // parenthesised suffix
        ("B737-8AS", "737-800"),       // leading B variant
        ("757-2Q8", "757-200"),
        ("737-800", "737-800"),        // — idempotence below —
        ("777-300ER", "777-300ER"),
        ("787-9", "787-9"),
        ("737 MAX 8", "737 MAX 8"),
        ("747-8", "747-8"),
        ("747-400F", "747-400F"),
    ])
    func customerCodeCollapse(input: String, expected: String) {
        let n = AircraftNaming.canonical(typecode: nil, manufacturer: "BOEING", model: input)
        #expect(n.model == expected)
        #expect(n.make == "Boeing")
    }

    // MARK: - Fallback: make casing + dedupe

    @Test func upperCaseMakeGetsTitleCased() {
        #expect(AircraftNaming.canonical(typecode: nil, manufacturer: "AIRBUS", model: "A320-200").make == "Airbus")
    }

    @Test func exceptionMakesStayCapitalized() {
        #expect(AircraftNaming.canonical(typecode: nil, manufacturer: "ATR", model: "ATR 72-600").make == "ATR")
    }

    @Test func mixedCaseMakePassesThrough() {
        #expect(AircraftNaming.canonical(typecode: nil, manufacturer: "Cessna", model: "172").make == "Cessna")
    }

    @Test func makeRepeatedInModelIsDeduped() {
        let n = AircraftNaming.canonical(typecode: nil, manufacturer: "BOEING", model: "BOEING 737-800")
        #expect(n.displayName == "Boeing 737-800")
    }

    // MARK: - Fallback: degenerate inputs

    @Test func allNilGivesNilDisplayName() {
        let n = AircraftNaming.canonical(typecode: nil, manufacturer: nil, model: nil)
        #expect(n.displayName == nil)
    }

    @Test func emptyAndWhitespaceFoldToNil() {
        let n = AircraftNaming.canonical(typecode: "", manufacturer: "  ", model: "")
        #expect(n.displayName == nil)
    }

    @Test func unknownTypecodeFallsThroughToStrings() {
        let n = AircraftNaming.canonical(typecode: "ZZ99", manufacturer: "BOEING", model: "737-8H4")
        #expect(n.displayName == "Boeing 737-800")
    }

    @Test func modelOnlyStillCleans() {
        let n = AircraftNaming.canonical(typecode: nil, manufacturer: nil, model: "737-8H4")
        #expect(n.displayName == "737-800")
    }
}
```

Note: if Task 1 Step 3's review changed `CRJ7`/`AT76`/`A320`/`C172` via overrides, add spot-check expectations for the final values to `officialNamesResolveFromTypecode` — pin what the table ACTUALLY contains, read from the JSON, not from memory.

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests/AircraftNamingTests
```
Expected: BUILD FAILURE — `cannot find 'AircraftNaming' in scope`. (Compile error, not test failure — that's the red step for a new type.)

- [ ] **Step 3: Implement `AircraftNaming`**

Create `ios/Tailspot/Tailspot/AircraftNaming.swift`:

```swift
//
//  AircraftNaming.swift
//  Tailspot
//
//  Canonical aircraft names. OpenSky's metadata DB carries raw,
//  inconsistent strings — "BOEING" / "737-8H4" (the H4 is a Boeing
//  CUSTOMER code: it encodes the airline, not the model — Southwest
//  in this case). We resolve to official names at READ time; the raw
//  strings stay stored on Catch untouched, so rule improvements are
//  retroactive and nothing needs a migration.
//
//  Resolution order:
//   1. ICAO type designator (B738, B77W…) against the bundled DOC 8643
//      table (AircraftTypes.json, generated by
//      tools/generate-aircraft-types.py — full ~2,700-designator set).
//   2. String cleanup fallback for rows without a typecode: Boeing
//      customer-code collapse, make title-casing, make/model dedupe.
//
//  `nonisolated` per repo convention: pure value logic that must be
//  callable from any actor.
//

import Foundation

nonisolated enum AircraftNaming {

    /// Resolved official (or best-effort cleaned) name.
    struct CanonicalName: Equatable, Sendable {
        let make: String?
        let model: String?

        /// "Boeing 777-300ER" — the string display surfaces show and
        /// the Hangar groups by. nil only when both halves are nil.
        var displayName: String? {
            switch (make, model) {
            case let (m?, d?): return "\(m) \(d)"
            case let (m?, nil): return m
            case let (nil, d?): return d
            case (nil, nil): return nil
            }
        }
    }

    // MARK: - Entry point

    static func canonical(
        typecode: String?,
        manufacturer: String?,
        model: String?
    ) -> CanonicalName {
        if let code = typecode?.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased().nonEmpty,
           let hit = table[code] {
            return hit
        }
        let make = cleanedMake(manufacturer)
        return CanonicalName(make: make, model: cleanedModel(model, make: make))
    }

    // MARK: - Bundled DOC 8643 table

    /// designator → canonical name. Decoded once on first touch.
    /// Missing/corrupt resource degrades to an empty table — every
    /// lookup falls through to the string path; never crashes.
    static let table: [String: CanonicalName] = {
        guard let url = Bundle.main.url(forResource: "AircraftTypes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return raw.mapValues { CanonicalName(make: $0.make, model: $0.model) }
    }()

    private struct Entry: Decodable {
        let make: String
        let model: String
    }

    // MARK: - Fallback: make

    /// Deliberately-capitalized makes (acronyms). Mirrors the
    /// generator's SPECIAL_MAKES; only matters for the string path.
    private static let makeExceptions: Set<String> = ["ATR", "PZL", "CASA", "MBB", "NAMC", "BAE"]
    private static let makeSpecials: [String: String] = [
        "MCDONNELL DOUGLAS": "McDonnell Douglas",
        "DE HAVILLAND": "De Havilland",
        "DE HAVILLAND CANADA": "De Havilland Canada",
        "SAAB": "Saab",
    ]

    static func cleanedMake(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        else { return nil }
        let collapsed = trimmed.split(separator: " ").joined(separator: " ")
        let upper = collapsed.uppercased()
        if let special = makeSpecials[upper] { return special }
        // Already mixed-case → trust the source.
        guard collapsed == upper else { return collapsed }
        return collapsed.split(separator: " ")
            .map { word in
                let w = String(word)
                return makeExceptions.contains(w) ? w : w.capitalized
            }
            .joined(separator: " ")
    }

    // MARK: - Fallback: model

    /// Boeing customer-code shape: optional leading "B", 7x7 family,
    /// dash, variant digit, 2-char customer code, optional
    /// (possibly parenthesised) suffix. "737-8H4" → 737-800;
    /// "777-322" → 777-300 (all-digit codes exist — 22 is United);
    /// "767-332(ER)" → 767-300ER. Idempotent on clean strings by
    /// construction: "737-800" parses as variant 8 + code "00" and
    /// rebuilds identically. Extended `#/…/#` delimiters so the
    /// literal doesn't depend on the bare-slash-regex feature flag.
    private static let customerCode =
        #/^B?(7[0-9]7)-([0-9])([A-Z0-9]{2})\(?([A-Z]{1,3})?\)?$/#

    static func cleanedModel(_ raw: String?, make: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        else { return nil }
        var model = trimmed.split(separator: " ").joined(separator: " ")
        // Manufacturer repeated inside the model ("BOEING 737-800"
        // with make Boeing) reads twice once joined — drop it.
        if let make, model.lowercased().hasPrefix(make.lowercased() + " ") {
            model = String(model.dropFirst(make.count + 1))
        }
        if let m = model.uppercased().wholeMatch(of: customerCode) {
            let suffix = m.4.map(String.init) ?? ""
            model = "\(m.1)-\(m.2)00\(suffix)"
        }
        return model
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
```

- [ ] **Step 4: Run the suite to verify green**

```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests/AircraftNamingTests
```
Expected: PASS (all AircraftNamingTests). If a STRUCTURAL test fails, the fix is in the GENERATOR (add SPECIAL_MAKES/OVERRIDES entries, re-run Task 1 Steps 2–3), not in test relaxation — unless the entry is legitimately fine and the structural rule was too strict (e.g. a genuinely all-caps brand: add it to BOTH the generator map and the test's exempt set).

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/AircraftNaming.swift ios/Tailspot/TailspotTests/AircraftNamingTests.swift
git commit -m "Add AircraftNaming: typecode->official names + cleanup fallback

Resolution: ICAO designator against the bundled DOC 8643 table first,
then string cleanup (Boeing customer-code collapse — idempotent on
already-clean strings — make title-casing, dedupe). Read-time and
pure, so stored raw strings are untouched and old catches re-bucket
automatically. Structural tests sweep the whole bundled table."
```

---

### Task 3: `Catch` schema additions

**Files:**
- Modify: `ios/Tailspot/Tailspot/Catch.swift` (fields + init params)
- Test: `ios/Tailspot/TailspotTests/CatchTests.swift` (add tests)

- [ ] **Step 1: Write the failing test**

Add to `CatchTests` (inside the existing `@Suite struct`):

```swift
    @Test func newSnapshotFieldsRoundTrip() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let c = Catch(
            icao24: "a1b2c3",
            callsign: "UAL248",
            model: "777-322ER",
            manufacturer: "BOEING",
            operatorName: "United Airlines",
            caughtAt: Date(timeIntervalSince1970: 1_750_000_000),
            observerLat: 37.87,
            observerLon: -122.27,
            slantDistanceMeters: 8_300,
            registration: "N779UA",
            typecode: "B77W",
            altitudeMeters: 11_277.6,
            velocityMps: 245.0,
            placeName: "Berkeley, CA"
        )
        context.insert(c)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Catch>()).first
        #expect(fetched?.registration == "N779UA")
        #expect(fetched?.typecode == "B77W")
        #expect(fetched?.altitudeMeters == 11_277.6)
        #expect(fetched?.velocityMps == 245.0)
        #expect(fetched?.placeName == "Berkeley, CA")
    }

    @Test func newSnapshotFieldsDefaultToNil() throws {
        // Pre-existing call sites omit the new params; lightweight
        // migration gives old rows nil. Pin the defaults.
        let container = try makeContainer()
        let context = ModelContext(container)

        let c = Catch(
            icao24: "a1b2c3",
            callsign: nil, model: nil, manufacturer: nil,
            caughtAt: Date(),
            observerLat: 0, observerLon: 0, slantDistanceMeters: 0
        )
        context.insert(c)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Catch>()).first
        #expect(fetched?.registration == nil)
        #expect(fetched?.typecode == nil)
        #expect(fetched?.altitudeMeters == nil)
        #expect(fetched?.velocityMps == nil)
        #expect(fetched?.placeName == nil)
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests/CatchTests
```
Expected: BUILD FAILURE — `extra arguments at positions … in call` (init doesn't take the new params yet).

- [ ] **Step 3: Add the fields**

In `Catch.swift`, after the `aircraftType` property declaration (line ~62), add:

```swift
    /// Tail number (registration) from OpenSky metadata at catch time —
    /// or recovered later by the detail view's backfill (registration
    /// is a property of the airframe, not the moment). Added 2026-06,
    /// optional + nil-default for lightweight migration.
    var registration: String?
    /// ICAO type designator ("B77W") — the key into AircraftNaming's
    /// DOC 8643 table. Same migration strategy as `registration`.
    var typecode: String?
    /// Aircraft altitude (m MSL) at the catch moment. NEVER backfilled
    /// — the moment is unrecoverable; old rows render "—".
    var altitudeMeters: Double?
    /// Aircraft ground speed (m/s) at the catch moment. Same rules as
    /// `altitudeMeters`.
    var velocityMps: Double?
    /// Reverse-geocoded observer place, e.g. "Berkeley, CA". Filled
    /// post-save at catch time (never blocks the catch) or by the
    /// detail-view backfill.
    var placeName: String?
```

In the `init`, add parameters between `slantDistanceMeters:` and `rarity:` (labeled args must keep declaration order at call sites):

```swift
        slantDistanceMeters: Double,
        registration: String? = nil,
        typecode: String? = nil,
        altitudeMeters: Double? = nil,
        velocityMps: Double? = nil,
        placeName: String? = nil,
        rarity: Rarity? = nil,
        aircraftType: AircraftType? = nil
```

and the assignments after `self.slantDistanceMeters = slantDistanceMeters`:

```swift
        self.registration = registration
        self.typecode = typecode
        self.altitudeMeters = altitudeMeters
        self.velocityMps = velocityMps
        self.placeName = placeName
```

- [ ] **Step 4: Run CatchTests — expect PASS**

Same command as Step 2. Expected: PASS, including the pre-existing tests (defaults keep old call sites compiling).

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/Catch.swift ios/Tailspot/TailspotTests/CatchTests.swift
git commit -m "Catch: add registration/typecode/alt/speed/place fields

All optional with nil defaults — SwiftData lightweight migration;
tester rows survive. alt/speed snapshot the catch moment (never
backfilled); registration/typecode/placeName are recoverable facts
the detail-view backfill may fill later."
```

---

### Task 4: `PokePlane` — canonical names + persisted ALT/SPD

**Files:**
- Modify: `ios/Tailspot/Tailspot/PokeCardView.swift` (builder + new formatting helpers, lines ~373–392)
- Modify: `ios/Tailspot/Tailspot/ContentView.swift` (`pokePlane(from:observed:)`, lines ~1035–1054)
- Test: `ios/Tailspot/TailspotTests/CatchTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `CatchTests`:

```swift
    // MARK: - PokePlane from a stored Catch

    @Test func pokePlaneFormatsStoredAltAndSpeed() {
        let c = Catch(
            icao24: "a1b2c3", callsign: "UAL248",
            model: "777-322ER", manufacturer: "BOEING",
            caughtAt: Date(), observerLat: 0, observerLon: 0,
            slantDistanceMeters: 8_300,
            altitudeMeters: 152.4,   // exactly 500 ft
            velocityMps: 102.889     // exactly 200 kt
        )
        let plane = PokePlane(catchRecord: c)
        #expect(plane.altText == "500 ft")
        #expect(plane.speedText == "200 kt")
    }

    @Test func pokePlaneShowsNilStatsForLegacyRows() {
        let c = Catch(
            icao24: "a1b2c3", callsign: nil, model: nil, manufacturer: nil,
            caughtAt: Date(), observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0
        )
        let plane = PokePlane(catchRecord: c)
        #expect(plane.altText == nil)   // card renders "—"
        #expect(plane.speedText == nil)
    }

    @Test func pokePlaneUsesCanonicalModelName() {
        let c = Catch(
            icao24: "a1b2c3", callsign: "UAL248",
            model: "777-322ER", manufacturer: "BOEING",
            caughtAt: Date(), observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0,
            typecode: "B77W"
        )
        #expect(PokePlane(catchRecord: c).model == "Boeing 777-300ER")
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests/CatchTests
```
Expected: FAIL — `plane.altText` is nil (builder hardcodes nil today) and `model` is the raw string.

- [ ] **Step 3: Implement**

In `PokeCardView.swift`, replace the whole `// MARK: - PokePlane builders` extension (lines ~375–392) with:

```swift
// MARK: - PokePlane builders

extension PokePlane {
    /// "500 ft" from meters MSL. Shared by the live catch reveal and
    /// the stored-catch builder so the two can't drift apart.
    static func altText(fromMeters m: Double?) -> String? {
        m.map { "\(Int(($0 * 3.28084).rounded()).formatted(.number)) ft" }
    }

    /// "200 kt" from m/s ground speed.
    static func speedText(fromMps v: Double?) -> String? {
        v.map { "\(Int(($0 * 1.94384).rounded())) kt" }
    }

    /// Build a card from a persisted Catch. Reads the snapshotted
    /// rarity/type (or backfills via classifier when nil), resolves
    /// the model line to its canonical official name, and formats the
    /// alt/speed snapshotted at the catch moment (nil for rows from
    /// before those fields shipped → the card renders "—").
    init(catchRecord c: Catch) {
        let canonical = AircraftNaming.canonical(
            typecode: c.typecode,
            manufacturer: c.manufacturer,
            model: c.model
        )
        self.init(
            callsign: c.callsign,
            model: canonical.displayName ?? c.model,
            carrier: c.operatorName,
            rarity: c.resolvedRarity,
            type: c.resolvedType,
            altText: Self.altText(fromMeters: c.altitudeMeters),
            speedText: Self.speedText(fromMps: c.velocityMps),
            distText: String(format: "%.1f km", c.slantDistanceMeters / 1000),
            photoURL: c.photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) }
        )
    }
}
```

In `ContentView.swift`, replace the body of `pokePlane(from:observed:)` (lines ~1039–1054) with:

```swift
    private func pokePlane(from row: Catch, observed: ObservedAircraft?) -> PokePlane {
        let canonical = AircraftNaming.canonical(
            typecode: row.typecode,
            manufacturer: row.manufacturer,
            model: row.model
        )
        let distMeters = observed?.slantDistanceMeters ?? row.slantDistanceMeters
        return PokePlane(
            callsign: row.callsign,
            model: canonical.displayName ?? row.model,
            carrier: row.operatorName,
            rarity: row.resolvedRarity,
            type: row.resolvedType,
            altText: PokePlane.altText(fromMeters: observed?.aircraft.altitudeMeters ?? row.altitudeMeters),
            speedText: PokePlane.speedText(fromMps: observed?.aircraft.velocityMps ?? row.velocityMps),
            distText: String(format: "%.1f km", distMeters / 1000),
            photoURL: row.photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) }
        )
    }
```
(Keep the doc comment above it; it still applies — live values win, stored values now back-fill when the plane has left view.)

- [ ] **Step 4: Run CatchTests — expect PASS**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/PokeCardView.swift ios/Tailspot/Tailspot/ContentView.swift ios/Tailspot/TailspotTests/CatchTests.swift
git commit -m "PokePlane: canonical model names + persisted ALT/SPD

The detail view's ALT/SPD chips were always em-dashes: the reveal
borrowed live observed values but nothing persisted them. The builder
now reads the Catch's snapshotted altitudeMeters/velocityMps via
shared formatting helpers (single source for ft/kt conversion), and
the model line resolves through AircraftNaming."
```

---

### Task 5: Grouping + Sets — canonical keys, Unknown last, matcher union

**Files:**
- Modify: `ios/Tailspot/Tailspot/HangarGrouping.swift` (`key(for:mode:)` lines ~143–164, `modelGroups` sort lines ~217–226)
- Modify: `ios/Tailspot/Tailspot/Sets.swift` (`matches(catch:entry:)` lines ~229–234)
- Modify: `ios/Tailspot/Tailspot/SetDetailView.swift` (`displayModel` lines ~146–153)
- Modify: `ios/Tailspot/Tailspot/ModelSlotDetailView.swift` (`displayModel` lines ~74–82)
- Test: `ios/Tailspot/TailspotTests/HangarGroupingTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `HangarGroupingTests` (note the factory already exists; extend it first — add `typecode: String? = nil` parameter and pass it through to `Catch(... typecode: typecode ...)`):

```swift
    // MARK: - Canonical naming integration

    @Test func customerCodeVariantsCollapseIntoOneGroup() {
        // Same airframe model, two airlines, two customer codes —
        // must be ONE group keyed by the canonical name.
        let groups = HangarGrouping.group([
            makeCatch(icao: "s1", manufacturer: "BOEING", model: "737-8H4"),
            makeCatch(icao: "u1", manufacturer: "BOEING", model: "737-824"),
        ], by: .aircraftType)

        #expect(groups.count == 1)
        #expect(groups[0].title == "Boeing 737-800")
        #expect(groups[0].rows.count == 2)
    }

    @Test func typecodeDrivesGroupTitleWhenPresent() {
        let groups = HangarGrouping.group([
            makeCatch(icao: "w1", manufacturer: "BOEING", model: "777-322ER", typecode: "B77W"),
        ], by: .aircraftType)
        #expect(groups[0].title == "Boeing 777-300ER")
    }

    @Test func unknownModelGroupSortsLastInModelGroups() {
        // Unknown has MORE tails than the named group — under the old
        // count-desc-first sort it landed on top. It must pin to the end.
        let catches = [
            makeCatch(icao: "x1"), makeCatch(icao: "x2"), makeCatch(icao: "x3"),
            makeCatch(icao: "b1", manufacturer: "BOEING", model: "737-800"),
        ]
        let rows = HangarGrouping.group(catches, by: .recent).first?.rows ?? []
        // All four default-classify to the same AircraftType via the
        // classifier's fallback, so one type bucket holds them all.
        let type = rows.first!.aircraftType
        let groups = HangarGrouping.modelGroups(in: rows, type: type)

        #expect(groups.last?.model == HangarGrouping.unknownTitle)
    }
```

Then update the TWO existing expectations that pin raw-caps titles (the canonical key changes presentation):

- In `groupsByManufacturerAndModel`: `"AIRBUS A320"` → `"Airbus A320"` and `"BOEING 737-800"` → `"Boeing 737-800"`.
- In `aircraftTypeFallsBackToManufacturerOrModelOrUnknown` (and any other test in the file asserting a `.aircraftType` title): apply the same casing change — run the suite and fix every title assertion the canonical key breaks. Mechanical; the test INTENT is unchanged.

Add to a new or existing Sets-related suite in `GameSystemTests.swift` (it already imports the module; add this test to the file's existing suite):

```swift
    @Test func setMatcherSeesCanonicalAndRawNames() {
        // Raw-only: model string carries the token (pre-typecode row).
        let raw = Catch(
            icao24: "r1", callsign: nil, model: "737-8H4", manufacturer: "BOEING",
            caughtAt: Date(), observerLat: 0, observerLon: 0, slantDistanceMeters: 0
        )
        // Canonical-only: nil model, typecode resolves to "Boeing 737 MAX 8".
        let canon = Catch(
            icao24: "c1", callsign: nil, model: nil, manufacturer: nil,
            caughtAt: Date(), observerLat: 0, observerLon: 0, slantDistanceMeters: 0,
            typecode: "B38M"
        )
        let narrow = PokeSets.all.first { $0.id == "narrow" }!
        let entry737 = narrow.entries.first { $0.id == "n-737-800" }!
        let entryMax = narrow.entries.first { $0.id == "n-737-max" }!

        #expect(PokeSets.matches(catch: raw, entry: entry737))   // union keeps raw matching
        #expect(PokeSets.matches(catch: canon, entry: entryMax)) // union adds canonical matching
    }
```
(Verify `B38M` exists in the generated JSON first: `python3 -c "import json; print(json.load(open('ios/Tailspot/Tailspot/AircraftTypes.json'))['B38M'])"` — expect a 737 MAX 8 name containing "MAX". If ICAO styles it without "MAX", add an OVERRIDES entry in the generator (`"B38M": ("Boeing", "737 MAX 8")`), regenerate, and re-run Task 2's suite.)

- [ ] **Step 2: Run to verify failures**

```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests/HangarGroupingTests -only-testing:TailspotTests/GameSystemTests
```
Expected: FAIL — new tests fail on raw-caps keys / count-first sort / matcher misses.

- [ ] **Step 3: Implement the four changes**

**(a)** `HangarGrouping.swift` — replace the `.aircraftType` case in `key(for:mode:)`:

```swift
        case .aircraftType:
            // Canonical official name (DOC 8643 typecode first, string
            // cleanup fallback) so Boeing customer-code variants of
            // the same model land in one bucket regardless of airline.
            return AircraftNaming.canonical(
                typecode: c.typecode,
                manufacturer: c.manufacturer,
                model: c.model
            ).displayName ?? unknownTitle
```

**(b)** `HangarGrouping.swift` — replace the `.sorted` closure at the end of `modelGroups(in:type:)`:

```swift
            .sorted { lhs, rhs in
                // Unknown pins to the END regardless of tail count —
                // it's a junk drawer, not a headline.
                let lUnknown = lhs.model == unknownTitle
                let rUnknown = rhs.model == unknownTitle
                if lUnknown != rUnknown { return rUnknown }
                if lhs.tails.count != rhs.tails.count {
                    return lhs.tails.count > rhs.tails.count
                }
                return lhs.model.localizedCaseInsensitiveCompare(rhs.model)
                    == .orderedAscending
            }
```

**(c)** `Sets.swift` — replace `matches(catch:entry:)`:

```swift
    /// True when the catch's model matches any of the entry's
    /// `modelTokens` — checked against BOTH the raw OpenSky model
    /// string AND the canonical name (typecode-resolved). Union, not
    /// replacement: membership can only gain from canonicalization,
    /// never lose. Single source of truth for Catch → PokeSetEntry.
    nonisolated static func matches(catch c: Catch, entry: PokeSetEntry) -> Bool {
        let raw = c.model?.lowercased() ?? ""
        let canonical = AircraftNaming.canonical(
            typecode: c.typecode,
            manufacturer: c.manufacturer,
            model: c.model
        ).displayName?.lowercased() ?? ""
        guard !raw.isEmpty || !canonical.isEmpty else { return false }
        return entry.modelTokens.contains { token in
            let t = token.lowercased()
            return raw.contains(t) || canonical.contains(t)
        }
    }
```

**(d)** `SetDetailView.swift` — the group key is now display-ready; shrink `displayModel` to:

```swift
    /// The group key is already the canonical display name; only the
    /// Unknown sentinel needs a friendlier label.
    private func displayModel(_ raw: String) -> String {
        raw == HangarGrouping.unknownTitle ? "Unknown model" : raw
    }
```

**(e)** `ModelSlotDetailView.swift` — same shrink for its `displayModel` computed property:

```swift
    /// The group key is already the canonical display name; only the
    /// Unknown sentinel needs a friendlier label.
    private var displayModel: String {
        group.model == HangarGrouping.unknownTitle ? "Unknown model" : group.model
    }
```

- [ ] **Step 4: Run the FULL suite**

```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests
```
Expected: PASS. The canonical key may break title assertions in OTHER suites too (search test sources for `"BOEING` / `"AIRBUS` if anything fails) — update casings, intent unchanged.

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/HangarGrouping.swift ios/Tailspot/Tailspot/Sets.swift \
  ios/Tailspot/Tailspot/SetDetailView.swift ios/Tailspot/Tailspot/ModelSlotDetailView.swift \
  ios/Tailspot/TailspotTests/HangarGroupingTests.swift ios/Tailspot/TailspotTests/GameSystemTests.swift
git commit -m "Sets: airline-agnostic model groups, Unknown last, matcher union

.aircraftType grouping keys on AircraftNaming's canonical name, so
737-8H4 and 737-824 collapse into one Boeing 737-800 group. Unknown
pins to the end of modelGroups regardless of tail count. PokeSets
membership checks tokens against raw AND canonical strings (union —
can only gain). Set surfaces drop their re-casing hacks."
```

---

### Task 6: `ReverseGeocode` helper

**Files:**
- Create: `ios/Tailspot/Tailspot/ReverseGeocode.swift`
- Create: `ios/Tailspot/TailspotTests/ReverseGeocodeTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/Tailspot/TailspotTests/ReverseGeocodeTests.swift`:

```swift
//
//  ReverseGeocodeTests.swift
//  TailspotTests
//
//  The formatting half is pure and pinned here for every placemark
//  shape; the network half (Apple geocoder) is a thin untested
//  wrapper by design.
//

import Testing
@testable import Tailspot

@Suite("Reverse geocode formatting")
struct ReverseGeocodeTests {

    @Test func usStyleCityState() {
        // CLPlacemark gives "CA" as administrativeArea in the US.
        #expect(ReverseGeocode.format(locality: "Berkeley", adminArea: "CA", country: "United States") == "Berkeley, CA")
    }

    @Test func internationalCityRegion() {
        // Non-US placemarks carry full region names — used as-is, no
        // US-style abbreviation assumed.
        #expect(ReverseGeocode.format(locality: "Toulouse", adminArea: "Occitanie", country: "France") == "Toulouse, Occitanie")
    }

    @Test func cityCountryWhenNoRegion() {
        #expect(ReverseGeocode.format(locality: "Reykjavík", adminArea: nil, country: "Iceland") == "Reykjavík, Iceland")
    }

    @Test func regionCountryWhenNoCity() {
        #expect(ReverseGeocode.format(locality: nil, adminArea: "Scotland", country: "United Kingdom") == "Scotland, United Kingdom")
    }

    @Test func countryAloneAsLastResort() {
        #expect(ReverseGeocode.format(locality: nil, adminArea: nil, country: "Japan") == "Japan")
    }

    @Test func cityAloneWhenThatIsAllThereIs() {
        #expect(ReverseGeocode.format(locality: "Singapore", adminArea: nil, country: nil) == "Singapore")
    }

    @Test func nothingGivesNil() {
        #expect(ReverseGeocode.format(locality: nil, adminArea: nil, country: nil) == nil)
        #expect(ReverseGeocode.format(locality: "", adminArea: "  ", country: "") == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests/ReverseGeocodeTests
```
Expected: BUILD FAILURE — `cannot find 'ReverseGeocode' in scope`.

- [ ] **Step 3: Implement**

Create `ios/Tailspot/Tailspot/ReverseGeocode.swift`:

```swift
//
//  ReverseGeocode.swift
//  Tailspot
//
//  Observer coordinates → human place name ("Berkeley, CA"). One
//  thin async wrapper around Apple's geocoder + a pure formatting
//  function the tests pin. Callers treat nil as "try again later"
//  (offline, rate-limited, mid-ocean) — never as an error.
//
//  Implicitly MainActor (repo default isolation) — all callers are
//  views/managers on main. `format` is nonisolated so tests and any
//  future background caller can use it freely.
//

import Foundation
import CoreLocation

enum ReverseGeocode {

    /// Reverse-geocode to a display string. nil on any failure —
    /// callers persist nil and retry on a later view-open.
    static func placeName(lat: Double, lon: Double) async -> String? {
        guard lat != 0 || lon != 0 else { return nil }
        let location = CLLocation(latitude: lat, longitude: lon)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        else { return nil }
        return format(
            locality: mark.locality,
            adminArea: mark.administrativeArea,
            country: mark.country
        )
    }

    /// Locale-aware assembly, deliberately NOT US-hardcoded:
    /// US placemarks carry abbreviated admin areas ("CA") → "Berkeley, CA";
    /// elsewhere the region is a full name → "Toulouse, Occitanie";
    /// no region → "Reykjavík, Iceland"; degrade through region/
    /// country alone; nil when the placemark is empty.
    nonisolated static func format(
        locality: String?,
        adminArea: String?,
        country: String?
    ) -> String? {
        let city = locality?.trimmedNonEmpty
        let region = adminArea?.trimmedNonEmpty
        let nation = country?.trimmedNonEmpty
        switch (city, region, nation) {
        case let (c?, r?, _):     return "\(c), \(r)"
        case let (c?, nil, n?):   return "\(c), \(n)"
        case let (c?, nil, nil):  return c
        case let (nil, r?, n?):   return "\(r), \(n)"
        case let (nil, r?, nil):  return r
        case let (nil, nil, n?):  return n
        case (nil, nil, nil):     return nil
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
```

**Build-time API decision (spec § C):** if this build emits a `CLGeocoder`/`reverseGeocodeLocation` deprecation warning on the iOS 26.2 target, replace ONLY the body of `placeName` with the MapKit replacement Apple's docs point to (look up `MKReverseGeocodingRequest` in the Xcode 26 documentation viewer — do not guess its API from memory), keeping the signature and `format` untouched. If no warning: CLGeocoder stands.

- [ ] **Step 4: Run — expect PASS, check warnings**

Same command as Step 2. Expected: PASS. Then check the build log for deprecation warnings on the geocode call (`grep -i "deprecat" <build output>`); act per the note above.

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/ReverseGeocode.swift ios/Tailspot/TailspotTests/ReverseGeocodeTests.swift
git commit -m "Add ReverseGeocode: coords -> locale-aware place names

Thin async wrapper around Apple's geocoder plus a pure, fully-tested
formatting function: 'Berkeley, CA' / 'Toulouse, Occitanie' /
'Reykjavík, Iceland' — degrades through region/country, nil when
empty. nil from the network half means 'retry on a later open'."
```

---

### Task 7: `performCatch` wiring — populate the new fields

**Files:**
- Modify: `ios/Tailspot/Tailspot/ContentView.swift` (`performCatch`, lines ~823–942)

- [ ] **Step 1: Thread the new fields into the `Catch` initializer**

In `performCatch`, the `Catch(` call (~line 909) gains four arguments after `slantDistanceMeters:`:

```swift
                let row = Catch(
                    icao24: icao,
                    callsign: observed?.aircraft.callsign,
                    model: metadata?.model,
                    manufacturer: metadata?.manufacturerName,
                    operatorName: metadata?.operatorName,
                    photoFilename: photoFilename,
                    caughtAt: now,
                    observerLat: observerLat,
                    observerLon: observerLon,
                    slantDistanceMeters: observed?.slantDistanceMeters ?? 0,
                    registration: metadata?.registration,
                    typecode: metadata?.typecode,
                    altitudeMeters: observed?.aircraft.altitudeMeters,
                    velocityMps: observed?.aircraft.velocityMps
                )
```
(`placeName` is deliberately NOT passed here — see Step 2.)

- [ ] **Step 2: Post-save reverse geocode**

Inside the `if !newCatches.isEmpty` block, immediately after the `Log.adsb.notice("Caught …")` line, add:

```swift
                // Reverse-geocode the observer position ONCE for the
                // batch (every row shares it) and stamp the new rows.
                // Post-save and fire-and-forget: a catch never waits
                // on — or fails because of — the geocoder. Offline →
                // placeName stays nil; CatchDetailView's backfill
                // retries on a later open.
                Task { @MainActor in
                    guard let place = await ReverseGeocode.placeName(
                        lat: observerLat, lon: observerLon
                    ) else { return }
                    for row in newCatches where row.placeName == nil {
                        row.placeName = place
                    }
                    try? modelContext.save()
                }
```

- [ ] **Step 3: Run the full suite + build**

```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests
```
Expected: PASS (no behavioral tests target performCatch directly; this verifies compilation + no regressions).

- [ ] **Step 4: Commit**

```bash
git add ios/Tailspot/Tailspot/ContentView.swift
git commit -m "performCatch: snapshot registration/typecode/alt/speed + place

New Catch rows are born with the tail number and ICAO designator from
metadata and the alt/speed the plane actually had at the catch moment
(the ALT/SPD fix at the source). The observer position reverse-
geocodes once per batch, post-save, fire-and-forget."
```

---

### Task 8: `CatchDetailView` — place line, airframe panel, delete, backfill (+ row/photo fixes)

**Files:**
- Modify: `ios/Tailspot/Tailspot/CatchDetailView.swift`
- Modify: `ios/Tailspot/Tailspot/ModelSlotDetailView.swift` (tail row, lines ~84–109)
- Modify: `ios/Tailspot/Tailspot/HangarRecentView.swift` (`performDelete`, lines ~87–95)

This task is UI + IO glue — no new unit tests (SwiftUI bodies and network/geocoder calls); the full suite still gates the commit, and Task 9 field-verifies.

- [ ] **Step 1: CatchDetailView state + imports**

Top of `CatchDetailView.swift`: add `import SwiftData` and `import os` below `import SwiftUI`. Inside the struct, after the `@Environment(\.openURL)` line, add:

```swift
    @Environment(\.modelContext) private var modelContext

    /// One shared client for the airframe-fact backfill. Deliberately
    /// NOT ADSBManager's MetadataCache — the manager isn't reachable
    /// from the Hangar sheet without threading it through every layer,
    /// and this is a one-shot recovery path. The metadata endpoint
    /// works anonymously; creds come from the bundle when present.
    private static let backfillClient = OpenSkyClient()

    @State private var showDeleteConfirm = false
```

- [ ] **Step 2: Place-name line**

In `firstCaughtPanel`, replace `Text(observerCoordText)` with:

```swift
            Text(first.placeName ?? observerCoordText)
```
(`observerCoordText` stays — it's the fallback while the geocoder hasn't succeeded yet.)

- [ ] **Step 3: AIRFRAME panel**

In `body`'s `VStack`, insert `airframePanel` between `firstCaughtPanel` and the attribution `if`. Then add below the `firstCaughtPanel` section:

```swift
    // MARK: - Airframe panel

    /// Registration (tail number) + ICAO hex + type designator. These
    /// are airframe facts, not moment facts — recoverable by the
    /// backfill for rows that predate the fields. "—" when OpenSky
    /// simply doesn't know.
    private var airframePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AIRFRAME")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            HStack(spacing: 0) {
                airframeField("REG", first.registration?.trimmedNonEmpty ?? "—")
                airframeField("ICAO", first.icao24.uppercased())
                airframeField("TYPE", first.typecode?.trimmedNonEmpty ?? "—")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 10))
    }

    private func airframeField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Brand.Font.mono(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Brand.Color.textTertiary)
            Text(value)
                .font(Brand.Font.mono(size: 13, weight: .bold))
                .foregroundStyle(Brand.Color.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
```

- [ ] **Step 4: Delete flow**

Replace `chromeBar` with (trash pill between back and share; `chromePillBody` gains a tint):

```swift
    private var chromeBar: some View {
        HStack {
            chromePill(icon: "chevron.left") { dismiss() }
            Spacer()
            Button {
                showDeleteConfirm = true
            } label: {
                chromePillBody(icon: "trash", tint: Brand.Color.alertWarning)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            ShareLink(item: shareText) {
                chromePillBody(icon: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }
```

and update `chromePillBody`:

```swift
    private func chromePillBody(icon: String, tint: Color = Brand.Color.textPrimary) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
```

Attach the alert to the outer `ZStack` (after `.toolbar(.hidden, for: .navigationBar)`):

```swift
        .alert(deleteTitle, isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
```

and add the helpers (same copy pattern as HangarRecentView):

```swift
    // MARK: - Delete

    private var deleteTitle: String {
        let cs = first.callsign?.trimmedNonEmpty ?? first.icao24.uppercased()
        if row.count == 1 { return "Delete catch of \(cs)?" }
        return "Delete all \(row.count) catches of \(cs)?"
    }

    /// Drops every catch in the row AND each catch's photo file —
    /// rows referencing dead files would render placeholder stripes
    /// and the orphaned JPEGs would pile up in Documents/catches.
    private func performDelete() {
        for c in row.allCatches {
            CatchPhotoStore.delete(filename: c.photoFilename)
            modelContext.delete(c)
        }
        do { try modelContext.save() } catch {
            Log.adsb.error("Detail delete failed for \(row.icao24, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        dismiss()
    }
```

- [ ] **Step 5: Backfill**

Replace the existing `.task { … }` modifier with:

```swift
        .task {
            await backfillIfNeeded()
            // Skip the net call when the user has a catch photo —
            // the card already paints that JPEG and attribution is
            // suppressed.
            guard !didFetchPhoto, !hasCatchPhoto else {
                didFetchPhoto = true
                return
            }
            didFetchPhoto = true
            let fetched = await PlanespottersClient.shared.photo(for: first.icao24)
            withAnimation(.easeInOut(duration: 0.25)) {
                planespottersPhoto = fetched
            }
        }
```

and add:

```swift
    // MARK: - Backfill

    /// One-time recovery of airframe-static facts for rows written
    /// before these fields existed. AMENDS the "read-only snapshot"
    /// rule deliberately (spec 2026-06-06 § E): fill-only-if-nil, so
    /// recorded values are never overwritten, and moment-data
    /// (alt/speed) is never touched. operatorName is the documented
    /// exception — what we recover is the CURRENT operator, not
    /// as-flown; better than a permanent blank for pre-field rows.
    /// Persisted on success, so each row backfills at most once;
    /// offline → still-nil fields retry on the next open.
    private func backfillIfNeeded() async {
        var dirty = false

        if first.registration == nil || first.typecode == nil {
            if let meta = (try? await Self.backfillClient.aircraftMetadata(icao24: first.icao24)) ?? nil {
                for c in row.allCatches {
                    if c.registration == nil { c.registration = meta.registration?.trimmedNonEmpty }
                    if c.typecode == nil { c.typecode = meta.typecode?.trimmedNonEmpty }
                    if c.manufacturer == nil { c.manufacturer = meta.manufacturerName?.trimmedNonEmpty }
                    if c.model == nil { c.model = meta.model?.trimmedNonEmpty }
                    if c.operatorName == nil { c.operatorName = meta.operatorName?.trimmedNonEmpty }
                }
                dirty = true
            }
        }

        if first.placeName == nil, first.observerLat != 0 || first.observerLon != 0 {
            if let place = await ReverseGeocode.placeName(
                lat: first.observerLat, lon: first.observerLon
            ) {
                first.placeName = place
                dirty = true
            }
        }

        if dirty { try? modelContext.save() }
    }
```

- [ ] **Step 6: ModelSlotDetailView — registration in tail rows**

In `tailRow(_:)`, replace the icao24 line:

```swift
            Text("\(row.icao24) · \(row.mostRecent.operatorName ?? "—")")
```
with:

```swift
            Text("\(tailIdentifier(row)) · \(row.mostRecent.operatorName ?? "—")")
```
and add the helper to the struct:

```swift
    /// Tail number when we have it ("N779UA"), raw hex as fallback —
    /// the registration is what a spotter actually reads off the plane.
    private func tailIdentifier(_ row: HangarRow) -> String {
        row.mostRecent.registration?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? row.icao24
    }
```

- [ ] **Step 7: HangarRecentView — stop orphaning photo files**

In `performDelete(row:)`, replace the loop:

```swift
        for c in row.allCatches {
            modelContext.delete(c)
        }
```
with:

```swift
        for c in row.allCatches {
            // Drop the photo file with the row — deleting only the
            // model row orphaned JPEGs in Documents/catches forever.
            CatchPhotoStore.delete(filename: c.photoFilename)
            modelContext.delete(c)
        }
```

- [ ] **Step 8: Full suite + build**

```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests
```
Expected: PASS (~235+ tests).

- [ ] **Step 9: Commit**

```bash
git add ios/Tailspot/Tailspot/CatchDetailView.swift ios/Tailspot/Tailspot/ModelSlotDetailView.swift ios/Tailspot/Tailspot/HangarRecentView.swift
git commit -m "CatchDetailView: place line, airframe panel, delete, backfill

FIRST CAUGHT shows the geocoded 'Berkeley, CA' (coords fallback).
New AIRFRAME panel: registration + hex + type designator. Trash
chrome pill -> confirmation alert -> deletes the row's catches AND
photo files (HangarRecentView's delete now also drops files — was
orphaning JPEGs). One-time fill-only-if-nil backfill recovers
airframe facts + place for pre-field rows; alt/speed never touched."
```

---

### Task 9: Full verification + device deploy

- [ ] **Step 1: Full suite, final count**

```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests
```
Expected: PASS. Record the final test count for the docs task (baseline was 213).

- [ ] **Step 2: Deploy to Noah's iPhone**

```bash
bin/deploy
```
If install/launch fails with a pairing/lock error, surface it and ask Noah to unlock/re-pair — do NOT silently retry.

- [ ] **Step 3: Hand Noah the field checklist**

Ask Noah to verify (mock mode works on the couch for most of it):
1. Hangar → Sets → a type → model names read officially ("Boeing 737-800"), no airline-suffixed duplicates, Unknown at the BOTTOM.
2. Open an OLD catch → tail number + place name appear after a moment (backfill), ALT/SPD show "—".
3. Catch a NEW plane (mock or live) → detail shows ALT/SPD values, place name, REG/ICAO/TYPE.
4. Delete from the detail view → confirmation alert → row gone from Hangar.

---

### Task 10: Docs + branch finish

**Files:**
- Modify: `CLAUDE.md` (read-only-snapshot note + Current state + test count)
- Modify: `PLAN.md` (§ 9)

- [ ] **Step 1: Amend the invariant CLAUDE.md documents**

In CLAUDE.md's "Hangar collection" section, replace the sentence beginning `CatchDetailView` is a **read-only snapshot** with:

```markdown
`CatchDetailView` is a **frozen-moment view with a narrow backfill
exception** (spec 2026-06-06): on open it may fill **nil-only** fields
that are properties of the airframe, not the moment — registration,
typecode, manufacturer, model, placeName, and operatorName (the last
is best-effort *current* operator, not as-flown; documented in code).
Recorded values are never overwritten, and moment-data (altitude,
speed, distance, date) is never backfilled. A catch's recorded facts
still must not be retroactively rewritten.
```

Also update the stale test-count references (the "Tests: 213 pass" line in the newest Current state entry stays as history; update the `**193 tests**` line in the Tests section to the Task 9 count, and note `AircraftNamingTests` / `ReverseGeocodeTests` in the suite list).

- [ ] **Step 2: Add a Current state entry**

Add a new dated `## Current state` section at the top of CLAUDE.md (above the 2026-06-06 AR-tracking entry) summarizing this round in the established style: naming standardization (DOC 8643 table + generator + read-time canonicalization), sets fixes (airline-agnostic, Unknown last), catch detail upgrades (ALT/SPD persisted, place names, airframe panel, delete, backfill), new files, final test count, and the MARKETING_VERSION decision (bump to 0.1.4 — user-visible feature drop per the workflow rules; two configs in `project.pbxproj`).

- [ ] **Step 3: Update PLAN.md § 9**

Mark the corresponding backlog reality: naming/sets/catch-detail round landed; note the pre-release ICAO-licensing checklist item from the spec.

- [ ] **Step 4: Bump MARKETING_VERSION**

In `ios/Tailspot/Tailspot.xcodeproj/project.pbxproj`, change BOTH `MARKETING_VERSION = 0.1.3;` occurrences to `0.1.4`. Do NOT touch `CURRENT_PROJECT_VERSION`.

- [ ] **Step 5: Commit docs + version**

```bash
git add CLAUDE.md PLAN.md ios/Tailspot/Tailspot.xcodeproj/project.pbxproj
git commit -m "Docs: naming + catch-detail round; bump to 0.1.4

CLAUDE.md: amend the read-only-snapshot invariant (fill-only-if-nil
airframe backfill), refresh Current state + test counts. PLAN.md §9
updated; ICAO-terms pass added to the pre-release checklist."
```

- [ ] **Step 6: Finish the branch**

Use the superpowers:finishing-a-development-branch skill — the merge target is `main` (tester-facing: merging + pushing kicks an Xcode Cloud TestFlight build). Before the merge commit reaches `main`, run `git diff main...feature/naming-catch-detail | grep -iE "OPENSKY|client_secret|EnvironmentVariable"` and expect NO matches (the secret-leak gate).

---

## Self-review notes (already applied)

- **Spec coverage:** § A → Tasks 1–2; § B → Task 5; § C → Tasks 3, 6, 7; § D → Tasks 4, 8; § E → Task 8 Step 5; § F → Tasks 2/3/4/5/6; § G → Task 10. The seven user asks all map: official names (1–2), airline-agnostic sets (5), Unknown last (5), ALT/SPD (3/4/7), city/state (6/7/8), delete (8), tail number (3/7/8).
- **Type consistency:** `AircraftNaming.canonical(typecode:manufacturer:model:)` and `CanonicalName.displayName` are used identically in Tasks 4, 5; `PokePlane.altText(fromMeters:)`/`speedText(fromMps:)` defined in Task 4, reused in Task 4's ContentView change only. `ReverseGeocode.placeName(lat:lon:)`/`format(locality:adminArea:country:)` defined in Task 6, called in Tasks 7–8.
- **Known judgment calls:** `makesAreNotShoutyUnlessExempt` may surface legitimately-all-caps obscure makes on first run — the fix loop is generator-side (Task 2 Step 4 note). `B38M` spot-verify before writing Task 5's matcher test.
