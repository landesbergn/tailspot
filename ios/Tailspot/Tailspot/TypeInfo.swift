//
//  TypeInfo.swift
//  Tailspot
//
//  Bundled "about this plane" facts for the back of a catch card: the
//  English Wikipedia article, Wikidata specs (first flight, number built,
//  wingspan, length) and a freely licensed Wikimedia Commons photo, one
//  record per family-set variant (`CardSetEntry.id`), plus one record per
//  ICAO typecode for every other type in AircraftTypes.json (the rare tail:
//  most GA, military and oddball types), so their card backs get the
//  Wikipedia description too. A family record always wins over a typecode
//  record; the typecode record only fills in when the family has no article
//  or the catch fills no family slot.
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
    /// CardSetEntry.id (Sets.swift), e.g. "f737-800". "" for a per-typecode
    /// record, or a dims-only record built for a catch that fills no family
    /// slot.
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
        bundled.entries[id]
    }

    /// Lazy one-time lookup of a per-typecode record (case-insensitive).
    static func info(forTypecode tc: String) -> TypeInfo? {
        bundled.typecodes[tc.uppercased()]
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
    /// nil. When the family record has no article (or no family slot
    /// matches), the per-typecode record supplies the article, specs and
    /// photo instead. With neither, a typecode that has dimensions still
    /// gets a TypeInfo carrying only those (entryId = ""). nil when there's
    /// nothing.
    static func info(for c: Catch) -> TypeInfo? {
        let match = entry(for: c)
        // The catch's own typecode first; a token-matched catch with no
        // typecode borrows its slot's representative one (unless that code
        // is shared by unrelated airframes — RV6).
        let typecode = c.typecode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? match.flatMap { $0.entry.ambiguousTypecode ? nil : $0.entry.representativeTypecode }
        let dims = AircraftNaming.dimensionsFeet(forTypecode: typecode)

        // The family record when it names an article; otherwise the
        // typecode's own record (the catch's real typecode only — never a
        // borrowed representative one, which the family already covers).
        let family = match.flatMap { info(forEntryId: $0.entry.id) }
        let own = c.typecode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            .flatMap { info(forTypecode: $0) }
        let base = family?.wikipediaTitle != nil ? family : (own ?? family)

        guard let match else {
            if base == nil {
                guard let dims, dims.wingspan != nil || dims.length != nil else { return nil }
            }
            return TypeInfo(entryId: "", wikipediaTitle: base?.wikipediaTitle,
                            wikidataId: base?.wikidataId,
                            firstFlightYear: base?.firstFlightYear,
                            numberBuilt: base?.numberBuilt,
                            wingspanMeters: base?.wingspanMeters ?? dims?.wingspan.map(metres),
                            lengthMeters: base?.lengthMeters ?? dims?.length.map(metres),
                            photo: base?.photo)
        }
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
        /// ICAO typecode (uppercase) → facts. Optional so an older file
        /// without the typecode pass still decodes.
        let typecodes: [String: TypeInfo]?
    }

    private struct Tables {
        var entries: [String: TypeInfo] = [:]
        var typecodes: [String: TypeInfo] = [:]
    }

    /// entryId → facts and typecode → facts. Decoded once on first touch; a
    /// missing or corrupt resource degrades to empty tables (the back just
    /// shows less).
    private static let bundled: Tables = {
        guard let url = Bundle.main.url(forResource: "TypeInfo", withExtension: "json") else {
            Log.ui.error("TypeInfo.json missing from bundle")
            return Tables()
        }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(File.self, from: data)
            return Tables(entries: file.entries, typecodes: file.typecodes ?? [:])
        } catch {
            Log.ui.error("TypeInfo.json decode failed: \(error.localizedDescription, privacy: .public)")
            return Tables()
        }
    }()
}

private nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
