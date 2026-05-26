//
//  Sets.swift
//  Tailspot
//
//  Pokédex-style sets. Each set is a curated list of airframes
//  identified by a model substring + a "canonical model name" the
//  set page displays. Sets are organized by `AircraftType` so the
//  Hangar can show "Wide-body 4 / 14", "Narrow-body 2 / 12", etc.
//
//  Curation philosophy: a set is a complete-able quest, not a tier
//  list. Common types still belong (a 737-800 should appear in the
//  Narrow set) because filling a set IS the achievement. Tier
//  affects scoring, not membership.
//

import Foundation

/// One slot in a set — a specific airframe the user can fill by
/// catching anything whose model matches `modelTokens`.
nonisolated struct PokeSetEntry: Identifiable, Hashable, Sendable {
    let id: String                  // dedupe key
    let canonicalName: String       // how the slot reads in the grid
    let rarity: Rarity              // colors the locked silhouette
    let modelTokens: [String]       // case-insensitive substring match
    let summary: String             // tap-to-reveal blurb
}

nonisolated struct PokeSet: Identifiable, Hashable, Sendable {
    let id: String
    let type: AircraftType
    let title: String
    let entries: [PokeSetEntry]
}

nonisolated enum PokeSets {

    /// Concrete sets per type. Hand-curated, not exhaustive — the
    /// goal is "ladder of recognizable airframes" not "every model
    /// ever produced." Add to this over time.
    static let all: [PokeSet] = [
        .init(
            id: "narrow", type: .narrow, title: "Narrow-body",
            entries: [
                .init(id: "n-737-800",  canonicalName: "Boeing 737-800",    rarity: .common,
                      modelTokens: ["737-8", "737-800"],
                      summary: "Most-built airliner variant. Workhorse of every major US carrier."),
                .init(id: "n-737-max",  canonicalName: "Boeing 737 MAX",    rarity: .uncommon,
                      modelTokens: ["max"],
                      summary: "Re-engined 737 family. MAX 8/9 are the common spots."),
                .init(id: "n-a320neo", canonicalName: "Airbus A320neo",     rarity: .common,
                      modelTokens: ["a320", "a319", "a321"],
                      summary: "European narrow-body counterpart to the 737 NG."),
                .init(id: "n-a220",    canonicalName: "Airbus A220",        rarity: .uncommon,
                      modelTokens: ["a220"],
                      summary: "Formerly Bombardier C-series. Quiet, fuel-efficient."),
                .init(id: "n-757",     canonicalName: "Boeing 757",         rarity: .rare,
                      modelTokens: ["757"],
                      summary: "Increasingly retired. Distinctive long fuselage + tall gear."),
                .init(id: "n-e190",    canonicalName: "Embraer E190",       rarity: .common,
                      modelTokens: ["e190", "e195"],
                      summary: "Larger Embraer family. Often regional + low-cost duties."),
            ]
        ),
        .init(
            id: "wide", type: .wide, title: "Wide-body",
            entries: [
                .init(id: "w-777",     canonicalName: "Boeing 777",        rarity: .rare,
                      modelTokens: ["777"],
                      summary: "Long-haul workhorse. Twin GE90s — biggest jet engines flying."),
                .init(id: "w-787",     canonicalName: "Boeing 787",        rarity: .rare,
                      modelTokens: ["787"],
                      summary: "Composite fuselage. Distinctive raked wingtips."),
                .init(id: "w-a350",    canonicalName: "Airbus A350",       rarity: .rare,
                      modelTokens: ["a350"],
                      summary: "Curved cockpit window mask. Newer than the 787."),
                .init(id: "w-a330",    canonicalName: "Airbus A330",       rarity: .uncommon,
                      modelTokens: ["a330"],
                      summary: "Mid-life refresh keeps it competitive vs the 787."),
                .init(id: "w-767",     canonicalName: "Boeing 767",        rarity: .uncommon,
                      modelTokens: ["767"],
                      summary: "Twin-aisle, mostly cargo / military tanker now."),
                .init(id: "w-747",     canonicalName: "Boeing 747",        rarity: .rare,
                      modelTokens: ["747"],
                      summary: "The Queen of the Skies. Passenger 747s are nearly extinct."),
                .init(id: "w-a380",    canonicalName: "Airbus A380",       rarity: .epic,
                      modelTokens: ["a380"],
                      summary: "Largest passenger airliner. Full double-decker."),
                .init(id: "w-747-8",   canonicalName: "Boeing 747-8",      rarity: .epic,
                      modelTokens: ["747-8"],
                      summary: "Stretched 747 with all-new engines. Rare in passenger service."),
            ]
        ),
        .init(
            id: "regional", type: .regional, title: "Regional jets & turboprops",
            entries: [
                .init(id: "r-e175",    canonicalName: "Embraer E175",      rarity: .common,
                      modelTokens: ["e175", "e170"],
                      summary: "Sole feeder jet for most US legacy carriers."),
                .init(id: "r-crj-700", canonicalName: "Bombardier CRJ-700",rarity: .common,
                      modelTokens: ["crj-7", "crj7"],
                      summary: "Stretched CRJ family. T-tail, two rear engines."),
                .init(id: "r-dash-8",  canonicalName: "De Havilland Dash 8",rarity: .uncommon,
                      modelTokens: ["dash 8"],
                      summary: "Twin turboprop. Tall stilted gear. Common in PNW."),
                .init(id: "r-atr",     canonicalName: "ATR 72",            rarity: .uncommon,
                      modelTokens: ["atr"],
                      summary: "European twin turboprop. Rare west of the Mississippi."),
            ]
        ),
        .init(
            id: "biz", type: .biz, title: "Business jets",
            entries: [
                .init(id: "b-citation", canonicalName: "Cessna Citation",  rarity: .common,
                      modelTokens: ["citation"],
                      summary: "Best-selling biz-jet family. Many variants."),
                .init(id: "b-phenom",   canonicalName: "Embraer Phenom",   rarity: .common,
                      modelTokens: ["phenom"],
                      summary: "Entry-level biz jets. Often charter."),
                .init(id: "b-falcon",   canonicalName: "Dassault Falcon",  rarity: .common,
                      modelTokens: ["falcon"],
                      summary: "Tri-jets and twins. French heritage."),
                .init(id: "b-g650",     canonicalName: "Gulfstream G650",  rarity: .uncommon,
                      modelTokens: ["g650"],
                      summary: "Long-range top tier. Distinctive winglet."),
                .init(id: "b-global",   canonicalName: "Bombardier Global",rarity: .uncommon,
                      modelTokens: ["global 7500", "global 6500"],
                      summary: "Largest of the Globals. Three-zone cabin."),
            ]
        ),
        .init(
            id: "mil", type: .mil, title: "Military",
            entries: [
                .init(id: "m-c130",  canonicalName: "Lockheed C-130 Hercules", rarity: .rare,
                      modelTokens: ["c-130"],
                      summary: "Four-engine turboprop. Tactical airlift workhorse."),
                .init(id: "m-c17",   canonicalName: "Boeing C-17 Globemaster",  rarity: .rare,
                      modelTokens: ["c-17"],
                      summary: "Strategic airlift. Distinctive winglets + T-tail."),
                .init(id: "m-kc135", canonicalName: "Boeing KC-135 Stratotanker",rarity: .rare,
                      modelTokens: ["kc-135"],
                      summary: "Aerial refueling tanker. Based on the 707."),
                .init(id: "m-kc46",  canonicalName: "Boeing KC-46 Pegasus",      rarity: .rare,
                      modelTokens: ["kc-46"],
                      summary: "Newer tanker, 767-based. Replacing the KC-135 slowly."),
                .init(id: "m-b52",   canonicalName: "Boeing B-52 Stratofortress",rarity: .rare,
                      modelTokens: ["b-52"],
                      summary: "Long-serving strategic bomber. Eight engines."),
                .init(id: "m-vc25",  canonicalName: "Boeing VC-25 (Air Force One)",rarity: .legendary,
                      modelTokens: ["vc-25"],
                      summary: "747-200 in white & blue. Three of them; one is always Air Force One."),
            ]
        ),
        .init(
            id: "ga", type: .ga, title: "General aviation",
            entries: [
                .init(id: "ga-c172", canonicalName: "Cessna 172", rarity: .common,
                      modelTokens: ["172", "skyhawk"],
                      summary: "Most-built aircraft ever. Universal training plane."),
                .init(id: "ga-c182", canonicalName: "Cessna 182", rarity: .common,
                      modelTokens: ["182", "skylane"],
                      summary: "Higher-power four-seater. Bigger sibling of the 172."),
                .init(id: "ga-c152", canonicalName: "Cessna 152", rarity: .uncommon,
                      modelTokens: ["152", "cessna 150"],
                      summary: "Two-seat trainer. Older, smaller cousin of the 172."),
                .init(id: "ga-pa28", canonicalName: "Piper PA-28", rarity: .common,
                      modelTokens: ["pa-28", "piper cherokee", "cherokee"],
                      summary: "Low-wing trainer alternative to the 172."),
                .init(id: "ga-piper-cub", canonicalName: "Piper Cub", rarity: .uncommon,
                      modelTokens: ["j-3", "piper cub", "super cub"],
                      summary: "Yellow taildragger. Classic American light aircraft."),
                .init(id: "ga-sr22", canonicalName: "Cirrus SR22", rarity: .common,
                      modelTokens: ["sr22"],
                      summary: "Composite single. Whole-aircraft parachute system."),
                .init(id: "ga-sr20", canonicalName: "Cirrus SR20", rarity: .uncommon,
                      modelTokens: ["sr20"],
                      summary: "Lower-powered Cirrus. Same airframe as the SR22, smaller engine."),
                .init(id: "ga-bonanza", canonicalName: "Beechcraft Bonanza", rarity: .uncommon,
                      modelTokens: ["bonanza", "be-36", "be-35", "v-tail"],
                      summary: "V-tail or straight-tail single. In production since 1947."),
                .init(id: "ga-mooney", canonicalName: "Mooney M20", rarity: .rare,
                      modelTokens: ["m20", "mooney"],
                      summary: "Distinctive forward-canted tail. Fast for a piston single."),
                .init(id: "ga-da40", canonicalName: "Diamond DA40", rarity: .uncommon,
                      modelTokens: ["da40", "da 40", "diamond star"],
                      summary: "Composite low-wing. Common modern trainer."),
                .init(id: "ga-da42", canonicalName: "Diamond DA42", rarity: .rare,
                      modelTokens: ["da42", "da 42", "twin star"],
                      summary: "Twin-engine diesel. Multi-engine trainer."),
                .init(id: "ga-rv", canonicalName: "Van's RV-series", rarity: .uncommon,
                      modelTokens: ["van's rv", "vans rv", "rv-7", "rv-8", "rv-9", "rv-10", "rv-12", "rv-14"],
                      summary: "Homebuilt kit aircraft. Often aerobatic-capable."),
                .init(id: "ga-r44", canonicalName: "Robinson R44", rarity: .rare,
                      modelTokens: ["r44", "robinson"],
                      summary: "Light piston helicopter. Very common trainer rotorcraft."),
            ]
        ),
        .init(
            id: "heritage", type: .heritage, title: "Heritage & special-mission",
            entries: [
                .init(id: "h-dc3",       canonicalName: "Douglas DC-3",         rarity: .legendary,
                      modelTokens: ["dc-3", "c-47"],
                      summary: "1930s twin-radial. A few still flying."),
                .init(id: "h-connie",    canonicalName: "Lockheed Constellation",rarity: .legendary,
                      modelTokens: ["constellation", "l-1049"],
                      summary: "Distinctive triple-tail. Pre-jet flagship."),
                .init(id: "h-sofia",     canonicalName: "NASA SOFIA (747SP)",   rarity: .legendary,
                      modelTokens: ["747sp"],
                      summary: "Stratospheric Observatory. Decommissioned 2022."),
                .init(id: "h-concorde",  canonicalName: "Concorde",             rarity: .legendary,
                      modelTokens: ["concorde"],
                      summary: "Retired 2003. For the wishful thinker."),
            ]
        ),
    ]

    /// Slot status for a single entry against a catch list.
    enum SlotStatus: Equatable {
        case locked
        case caught(catchedExample: Catch)
    }

    /// True when the given catch's model matches any of the entry's
    /// `modelTokens` (case-insensitive substring on `c.model`). The
    /// single source of truth for Catch → PokeSetEntry membership;
    /// `status(of:against:)`, `progress(of:against:)`, and
    /// `HangarGrouping.resolveSlots(for:in:)` all pivot on this so a
    /// future tweak to the matching rule lands in every caller at
    /// once.
    nonisolated static func matches(catch c: Catch, entry: PokeSetEntry) -> Bool {
        guard let model = c.model?.lowercased(), !model.isEmpty else { return false }
        return entry.modelTokens.contains { token in
            model.contains(token.lowercased())
        }
    }

    /// Walk a single set's entries and resolve each against the
    /// caught planes. First matching catch (by `modelTokens`
    /// substring on `c.model`) fills the slot.
    static func status(of set: PokeSet, against catches: [Catch]) -> [(PokeSetEntry, SlotStatus)] {
        set.entries.map { entry in
            let hit = catches.first { matches(catch: $0, entry: entry) }
            return (entry, hit.map(SlotStatus.caught) ?? .locked)
        }
    }

    /// "N caught out of M" for the set browser tile.
    static func progress(of set: PokeSet, against catches: [Catch]) -> (caught: Int, total: Int) {
        let s = status(of: set, against: catches)
        return (s.filter { if case .caught = $0.1 { return true } else { return false } }.count, s.count)
    }
}
