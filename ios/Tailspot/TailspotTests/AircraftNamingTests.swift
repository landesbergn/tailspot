//
//  AircraftNamingTests.swift
//  TailspotTests
//
//  Canonical-name resolution: bundled DOC 8643 table (structural
//  checks across ALL ~2,600 entries, not just spot values) + the
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
    /// NOTE: "K & S" is an initialism (Kit & Scale); it appears as all-caps
    /// in the ICAO table and has no lower-case form — included in exempt.
    @Test func makesAreNotShoutyUnlessExempt() {
        let exempt: Set<String> = ["ATR", "PZL", "CASA", "MBB", "NAMC", "BAE Systems", "K & S"]
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
        #expect(AircraftNaming.canonical(typecode: "CRJ7", manufacturer: nil, model: nil).displayName == "Bombardier CRJ-700")
        #expect(AircraftNaming.canonical(typecode: "C172", manufacturer: nil, model: nil).displayName == "Cessna 172")
        #expect(AircraftNaming.canonical(typecode: "B38M", manufacturer: nil, model: nil).displayName == "Boeing 737 MAX 8")
    }

    @Test func typecodeIsCaseAndWhitespaceInsensitive() {
        #expect(AircraftNaming.canonical(typecode: " b738 ", manufacturer: nil, model: nil).displayName == "Boeing 737-800")
    }

    @Test func typecodeWinsOverRawStrings() {
        let n = AircraftNaming.canonical(typecode: "B77W", manufacturer: "BOEING", model: "777-3F2ER")
        #expect(n.displayName == "Boeing 777-300ER")
    }

    /// H25B is the ICAO designator for the civil Hawker 800 family
    /// (800/800XP/850XP/900XP) AND its US military C-29A variant. The
    /// generator's shortest-model-wins heuristic picked the short
    /// military "C-29" name; OVERRIDES pins it to the plane-spotter-
    /// familiar "Hawker 800XP". Reported in the field: a civil N-reg
    /// airframe (N667WJ) surfaced as "British Aerospace C-29".
    @Test func hawker800xpResolvesFromTypecode() {
        #expect(AircraftNaming.canonical(typecode: "H25B", manufacturer: nil, model: nil).displayName == "Hawker 800XP")
    }

    /// 2026-06-08 audit batch: typecodes whose DOC 8643 reduction picked
    /// a poor representative (military designation / foreign-licensee make /
    /// converter or doubled string) instead of the recognizable civil name.
    /// Pinned via the generator's OVERRIDES; values are grounded in actual
    /// DOC 8643 / FAA rows. Regression-locks the fix — if a regeneration
    /// ever drops an override, the displayName reverts and this fails.
    @Test(arguments: [
        ("H25B", "Hawker 800XP"),
        ("BE40", "Beechcraft 400A Beechjet"),
        ("FA20", "Dassault Falcon 20"),
        ("LJ23", "Learjet 23"),
        ("LJ24", "Learjet 24"),
        ("LJ25", "Learjet 25"),
        ("LJ31", "Learjet 31"),
        ("LJ35", "Learjet 35"),
        ("HA4T", "Hawker 4000"),
        ("B350", "Beechcraft 350 Super King Air"),
        ("BE10", "Beechcraft 100 King Air"),
        ("PAY1", "Piper PA-31T1-500 Cheyenne 1"),
        ("PAY3", "Piper PA-42-720 Cheyenne 3"),
        ("BE33", "Beechcraft 33 Bonanza"),
        ("BE50", "Beechcraft 50 Twin Bonanza"),
        ("B36T", "Beechcraft 36 Turbine Bonanza"),
        ("B18T", "Beechcraft 18 Turbo"),
        ("C340", "Cessna 340"),
        ("P210", "Cessna P210 Centurion"),
        ("C185", "Cessna 185 Skywagon"),
        ("C303", "Cessna T303 Crusader"),
        ("C72R", "Cessna 172RG Cutlass"),
        ("C77R", "Cessna 177RG Cardinal"),
        ("C82R", "Cessna R182 Skylane RG"),
        ("P28B", "Piper PA-28-236 Dakota"),
        ("P28T", "Piper PA-28RT-201 Arrow 4"),
        ("P32T", "Piper PA-32RT-300T Turbo Lance 2"),
        ("PA25", "Piper PA-25 Pawnee"),
        ("PA36", "Piper PA-36 Pawnee Brave"),
        ("PA12", "Piper PA-12 Super Cruiser"),
        ("S108", "Stinson 108 Voyager"),
        ("ERCO", "Erco 415 Ercoupe"),
        ("AC50", "Aero Commander 500"),
        ("AC6L", "Aero Commander 685"),
        ("B703", "Boeing 707-300"),
        ("DC93", "McDonnell Douglas DC-9-30"),
        ("CN35", "CASA CN-235"),
        ("E45X", "Embraer ERJ-145XR"),
        ("DHC2", "De Havilland Canada DHC-2 Beaver"),
        ("DHC7", "De Havilland Canada DHC-7 Dash 7"),
        ("DHC4", "De Havilland Canada DHC-4 Caribou"),
        ("DHC5", "De Havilland Canada DHC-5 Buffalo"),
        ("GLF2", "Gulfstream II"),
        ("GLF3", "Gulfstream III"),
        ("GLF4", "Gulfstream IV"),
        ("GLF6", "Gulfstream G650"),
        ("E35L", "Embraer Legacy 600"),
        ("E121", "Embraer EMB-121 Xingu"),
        ("PA34", "Piper PA-34 Seneca"),
        ("PA27", "Piper PA-23-250 Aztec"),
        ("PA18", "Piper PA-18 Super Cub"),
        ("PA11", "Piper PA-11 Cub Special"),
        ("GA4C", "Gulfstream G400"),
        ("GA5C", "Gulfstream G500"),
        ("GA6C", "Gulfstream G600"),
        ("GA7C", "Gulfstream G700"),
        ("GA8C", "Gulfstream G800"),
    ])
    func auditBatchNamesResolveFromTypecode(typecode: String, expected: String) {
        #expect(AircraftNaming.canonical(typecode: typecode, manufacturer: nil, model: nil).displayName == expected)
    }

    // MARK: - Fallback: Boeing customer-code collapse
    // Dirty inputs collapse; clean inputs MUST pass through unchanged
    // (idempotence) — OpenSky has both since Boeing dropped customer
    // codes ~2016.

    @Test(arguments: [
        ("737-8H4", "737-800"),        // letter+digit code (Southwest)
        ("737-8h4", "737-800"),        // lowercase input
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
        // space-to-dash join: Boeing family (spaces before digits)
        ("777 300ER", "777-300ER"),
        ("747 400", "747-400"),
    ])
    func customerCodeCollapse(input: String, expected: String) {
        let n = AircraftNaming.canonical(typecode: nil, manufacturer: "BOEING", model: input)
        #expect(n.model == expected)
        #expect(n.make == "Boeing")
    }

    // MARK: - Fallback: Airbus engine-variant collapse

    @Test(arguments: [
        // variant collapse: engine-code digits → series-hundred
        ("A380-842", "A380-800"),
        ("A320-214", "A320-200"),
        // space-to-dash join then variant collapse
        ("A380 861", "A380-800"),
        // neo variants
        ("A321-271NX", "A321neo"),
        // freighter
        ("A330-243F", "A330-200F"),
        // A350 four-digit variant — must NOT be touched by the 3-digit pattern
        ("A350-941", "A350-900"),
        // idempotence: already clean strings pass through unchanged
        ("A380-800", "A380-800"),
        ("A320neo", "A320neo"),
        // A220 is NOT in the A3xx pattern — must not match
        ("A220-300", "A220-300"),
        // A350-1000 has FOUR variant digits — pattern requires exactly 3
        ("A350-1000", "A350-1000"),
        // A330-900 is already series-hundred style — stays as-is (idempotent)
        ("A330-900", "A330-900"),
    ])
    func airbusVariantCollapse(input: String, expected: String) {
        let n = AircraftNaming.canonical(typecode: nil, manufacturer: "AIRBUS", model: input)
        #expect(n.make == "Airbus")
        #expect(n.model == expected, "Input '\(input)' expected '\(expected)' got '\(n.model ?? "nil")'")
    }

    // MARK: - Fallback: Boeing 737 MAX short codes
    // A bare "737-N" (single digit) is the MAX; the previous-gen NG is
    // always 3-digit "737-N00". The MAX short code must converge with
    // the typecode table ("737 MAX N"); the NG must NOT become a MAX.

    @Test(arguments: [
        ("737-8", "737 MAX 8"),    // MAX 8 short code
        ("737-9", "737 MAX 9"),    // MAX 9
        ("737-7", "737 MAX 7"),    // MAX 7
        ("737-10", "737 MAX 10"),  // MAX 10
        ("B737-8", "737 MAX 8"),   // leading-B variant
        ("737-800", "737-800"),    // NG — three digits, NOT a MAX
        ("737-900", "737-900"),    // NG
        ("737-8H4", "737-800"),    // NG customer code, not MAX
        ("737 MAX 8", "737 MAX 8"),// already clean, idempotent
    ])
    func boeing737MaxShortCode(input: String, expected: String) {
        let n = AircraftNaming.canonical(typecode: nil, manufacturer: "BOEING", model: input)
        #expect(n.model == expected, "Input '\(input)' expected '\(expected)' got '\(n.model ?? "nil")'")
    }

    /// The user's report: a MAX 8 caught WITH a typecode (B38M) and one
    /// caught WITHOUT (raw "737-8") must land in the SAME group. Same
    /// for the MAX 9. And the NG -800/-900 must NOT collapse into the MAX.
    @Test func boeing737MaxConvergesWithTypecode() {
        let max8Table    = AircraftNaming.canonical(typecode: "B38M", manufacturer: nil, model: nil).displayName
        let max8Fallback = AircraftNaming.canonical(typecode: nil, manufacturer: "Boeing", model: "737-8").displayName
        #expect(max8Table == max8Fallback)
        #expect(max8Table == "Boeing 737 MAX 8")

        let max9Table    = AircraftNaming.canonical(typecode: "B39M", manufacturer: nil, model: nil).displayName
        let max9Fallback = AircraftNaming.canonical(typecode: nil, manufacturer: "Boeing", model: "737-9").displayName
        #expect(max9Table == max9Fallback)

        // NG stays distinct from the MAX.
        let ng800 = AircraftNaming.canonical(typecode: nil, manufacturer: "Boeing", model: "737-800").displayName
        #expect(ng800 == "Boeing 737-800")
        #expect(ng800 != max8Table)
    }

    // MARK: - Convergence invariant

    /// Pins that the string-cleanup fallback and the DOC 8643 table
    /// produce identical displayNames for the same airframe. Breaks if
    /// the Airbus variant-collapse rule drifts or a table value gains
    /// marketing suffixes (e.g. "XWB").
    @Test func fallbackConvergesWithTable() {
        let pairs: [(typecode: String, manufacturer: String, rawModel: String)] = [
            ("A388", "AIRBUS",  "A380 842"),
            ("A346", "AIRBUS",  "A340 642"),
            ("B77W", "BOEING",  "777-3F2ER"),
            ("A359", "AIRBUS",  "A350-941"),  // requires Fix 2's XWB drop
        ]
        for (tc, mfr, raw) in pairs {
            let fromTable    = AircraftNaming.canonical(typecode: tc,  manufacturer: nil,  model: nil).displayName
            let fromFallback = AircraftNaming.canonical(typecode: nil, manufacturer: mfr,  model: raw).displayName
            #expect(fromTable == fromFallback,
                    "Convergence failure for typecode \(tc): table='\(fromTable ?? "nil")' fallback='\(fromFallback ?? "nil")'")
        }
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
        #expect(n.make == nil)
    }

    @Test func multiWordSpecialMakeResolves() {
        #expect(AircraftNaming.canonical(typecode: nil, manufacturer: "BAE SYSTEMS", model: "Jetstream 41").make == "BAE Systems")
    }
}
