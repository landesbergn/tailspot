//
//  TypeInfo.swift
//  Tailspot
//
//  Bundled "about this plane" facts for the back of a catch card: the
//  English Wikipedia article, Wikidata specs (first flight, number built,
//  wingspan, length) and a freely licensed Wikimedia Commons photo, one
//  record per family-set variant (`CardSetEntry.id`).
//
//  TypeInfo.json is generated at BUILD time by tools/generate-type-info.py
//  (re-run it when families are added to Sets.swift) — nothing here talks
//  to the network. Facts Wikidata lacks are simply absent; wingspan and
//  length then fall back to the FAA numbers in AircraftTypes.json. Nothing
//  is ever guessed.
//
//  `nonisolated` per repo convention: pure value logic callable from any
//  actor (the card back builds its model off these).
//

import Foundation
import os

/// A Wikimedia Commons photo of the aircraft type, with what its licence
/// requires us to show: the author and the licence short name, linking to
/// the Commons file page.
nonisolated struct TypePhoto: Equatable, Sendable, Decodable {
    /// https Commons thumbnail, ~800–960 px wide.
    let imageURL: URL
    /// https commons.wikimedia.org/wiki/File:… page (the credit link).
    let pageURL: URL
    /// Plain-text author (HTML stripped by the generator).
    let artist: String
    /// Licence short name: "CC BY-SA 4.0", "CC BY 2.0", "CC0", "Public domain".
    let license: String
}

/// Bundled facts for one family-set variant. Every fact is optional: the
/// card back omits what's missing rather than guessing.
nonisolated struct TypeInfo: Equatable, Sendable, Decodable {
    /// CardSetEntry.id (Sets.swift), e.g. "f737-800". "" for a dims-only
    /// record built for a catch that fills no family slot.
    let entryId: String
    /// English Wikipedia article title after redirects. Several variants
    /// can share their family's article ("Boeing 737 Next Generation").
    let wikipediaTitle: String?
    /// Wikidata item, e.g. "Q1084919".
    let wikidataId: String?
    let firstFlightYear: Int?
    let numberBuilt: Int?
    let wingspanMeters: Double?
    let lengthMeters: Double?
    let photo: TypePhoto?
}

nonisolated enum TypeInfoStore {

    /// Lazy one-time decode of the bundled TypeInfo.json.
    static func info(forEntryId id: String) -> TypeInfo? {
        bundled[id]
    }

    /// The family set + variant entry this catch fills, using the SAME
    /// matcher as the Hangar's Sets screen (`CardSets.matches(key:entry:)`).
    /// Skips "fam-unidentified" (it has no facts to show). nil when nothing
    /// matches.
    ///
    /// Two passes over `CardSets.families` in declaration order:
    ///  1. the first entry whose own ICAO typecode equals the catch's
    ///     (the precise identity — a B38M catch whose raw model reads
    ///     "737-8" would otherwise also token-match the 737-800 slot), then
    ///  2. the first entry that matches at all (token path, no typecode).
    static func entry(for c: Catch) -> (family: CardSet, entry: CardSetEntry)? {
        let key = CardSets.matchKey(for: c)
        let families = CardSets.families.filter { $0.id != unidentifiedFamilyId }
        if let tc = c.typecode?.trimmingCharacters(in: .whitespacesAndNewlines), !tc.isEmpty {
            for family in families {
                for entry in family.entries
                where hasOwnTypecode(entry, tc) && CardSets.matches(key: key, entry: entry) {
                    return (family, entry)
                }
            }
        }
        for family in families {
            for entry in family.entries where CardSets.matches(key: key, entry: entry) {
                return (family, entry)
            }
        }
        return nil
    }

    /// `info(forEntryId:)` for `entry(for:)`, with wingspan/length filled
    /// from AircraftTypes.json (feet → metres) when the bundled value is
    /// nil. When no entry matches but the typecode has dimensions, returns a
    /// TypeInfo carrying only those (entryId = ""). nil when there's nothing.
    static func info(for c: Catch) -> TypeInfo? {
        let match = entry(for: c)
        // The catch's own typecode first; a token-matched catch with no
        // typecode borrows its slot's representative one (unless that code
        // is shared by unrelated airframes — RV6).
        let typecode = c.typecode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? match.flatMap { $0.entry.ambiguousTypecode ? nil : $0.entry.representativeTypecode }
        let dims = AircraftNaming.dimensionsFeet(forTypecode: typecode)

        guard let match else {
            guard let dims, dims.wingspan != nil || dims.length != nil else { return nil }
            return TypeInfo(entryId: "", wikipediaTitle: nil, wikidataId: nil,
                            firstFlightYear: nil, numberBuilt: nil,
                            wingspanMeters: dims.wingspan.map(metres),
                            lengthMeters: dims.length.map(metres),
                            photo: nil)
        }
        let base = info(forEntryId: match.entry.id)
        guard base != nil || dims != nil else { return nil }
        return TypeInfo(
            entryId: match.entry.id,
            wikipediaTitle: base?.wikipediaTitle,
            wikidataId: base?.wikidataId,
            firstFlightYear: base?.firstFlightYear,
            numberBuilt: base?.numberBuilt,
            wingspanMeters: base?.wingspanMeters ?? dims?.wingspan.map(metres),
            lengthMeters: base?.lengthMeters ?? dims?.length.map(metres),
            photo: base?.photo
        )
    }

    // MARK: - Internals

    private static let unidentifiedFamilyId = "fam-unidentified"

    /// Feet → metres, rounded to the centimetre (the source is 0.1 ft).
    static func metres(_ feet: Double) -> Double {
        (feet * 0.3048 * 100).rounded() / 100
    }

    private static func hasOwnTypecode(_ entry: CardSetEntry, _ tc: String) -> Bool {
        if !entry.ambiguousTypecode,
           let rep = entry.representativeTypecode,
           rep.caseInsensitiveCompare(tc) == .orderedSame {
            return true
        }
        return entry.exactTypecodes.contains { $0.caseInsensitiveCompare(tc) == .orderedSame }
    }

    private struct File: Decodable {
        let version: Int
        let entries: [String: TypeInfo]
    }

    /// entryId → facts. Decoded once on first touch; a missing or corrupt
    /// resource degrades to an empty table (the back just shows less).
    private static let bundled: [String: TypeInfo] = {
        guard let url = Bundle.main.url(forResource: "TypeInfo", withExtension: "json") else {
            Log.ui.error("TypeInfo.json missing from bundle")
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(File.self, from: data).entries
        } catch {
            Log.ui.error("TypeInfo.json decode failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }()
}

private nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
