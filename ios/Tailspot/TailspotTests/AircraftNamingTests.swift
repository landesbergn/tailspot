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
