//
//  Sets.swift
//  Tailspot
//
//  Collectible card sets. Each set is a curated list of airframes
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
nonisolated struct CardSetEntry: Identifiable, Hashable, Sendable {
    let id: String                  // dedupe key
    let canonicalName: String       // how the slot reads in the grid
    let rarity: Rarity              // colors the locked silhouette
    let modelTokens: [String]       // case-insensitive substring match
    let summary: String             // tap-to-reveal blurb
    /// A representative ICAO typecode for this entry — the one used
    /// when cross-referencing the activity-rarity table in tests
    /// (divergence-b fix, 2026-06-11). Optional for entries with no
    /// resolvable typecode (homebuilts, retired types not in DOC 8643).
    let representativeTypecode: String?

    init(id: String, canonicalName: String, rarity: Rarity,
         modelTokens: [String], summary: String,
         representativeTypecode: String? = nil) {
        self.id = id
        self.canonicalName = canonicalName
        self.rarity = rarity
        self.modelTokens = modelTokens
        self.summary = summary
        self.representativeTypecode = representativeTypecode
    }
}

nonisolated struct CardSet: Identifiable, Hashable, Sendable {
    let id: String
    let type: AircraftType
    let title: String
    let entries: [CardSetEntry]
}

nonisolated enum CardSets {

    /// Concrete sets per type. Hand-curated, not exhaustive — the
    /// goal is "ladder of recognizable airframes" not "every model
    /// ever produced." Add to this over time.
    static let all: [CardSet] = [
        .init(
            id: "narrow", type: .narrow, title: "Narrow-body",
            entries: [
                .init(id: "n-737-800",  canonicalName: "Boeing 737-800",    rarity: .common,
                      modelTokens: ["737-8", "737-800"],
                      summary: "Most-built airliner variant. Workhorse of every major US carrier.",
                      representativeTypecode: "B738"),
                // "max" token: union matching also scans canonical names —
                // K-Max/SeaMax could theoretically match, but need a typecode'd
                // catch of those airframes; acceptable.
                // Rarity: common (B38M) — one of the most-seen jets despite being "new".
                .init(id: "n-737-max",  canonicalName: "Boeing 737 MAX",    rarity: .common,
                      modelTokens: ["max"],
                      summary: "Re-engined 737 family. MAX 8/9 are the common spots.",
                      representativeTypecode: "B38M"),
                .init(id: "n-a320neo", canonicalName: "Airbus A320neo",     rarity: .common,
                      modelTokens: ["a320", "a319", "a321"],
                      summary: "European narrow-body counterpart to the 737 NG.",
                      representativeTypecode: "A20N"),
                .init(id: "n-a220",    canonicalName: "Airbus A220",        rarity: .uncommon,
                      modelTokens: ["a220"],
                      summary: "Formerly Bombardier C-series. Quiet, fuel-efficient.",
                      representativeTypecode: "BCS3"),
                // Rarity: common (B752) — still flying daily on cargo/charter routes.
                .init(id: "n-757",     canonicalName: "Boeing 757",         rarity: .common,
                      modelTokens: ["757"],
                      summary: "Increasingly retired. Distinctive long fuselage + tall gear.",
                      representativeTypecode: "B752"),
                // Rarity: uncommon (E190/E195) — narrowbody but smaller presence than 737/A320.
                .init(id: "n-e190",    canonicalName: "Embraer E190",       rarity: .uncommon,
                      modelTokens: ["e190", "e195"],
                      summary: "Larger Embraer family. Often regional + low-cost duties.",
                      representativeTypecode: "E190"),
            ]
        ),
        .init(
            id: "wide", type: .wide, title: "Wide-body",
            entries: [
                // Rarity: uncommon (B77W) — workhorse widebody per activity model.
                .init(id: "w-777",     canonicalName: "Boeing 777",        rarity: .uncommon,
                      modelTokens: ["777"],
                      summary: "Long-haul workhorse. Twin GE90s — biggest jet engines flying.",
                      representativeTypecode: "B77W"),
                // Rarity: uncommon (B788) — workhorse widebody per activity model.
                .init(id: "w-787",     canonicalName: "Boeing 787",        rarity: .uncommon,
                      modelTokens: ["787"],
                      summary: "Composite fuselage. Distinctive raked wingtips.",
                      representativeTypecode: "B788"),
                // Rarity: uncommon (A35K) — workhorse widebody per activity model.
                .init(id: "w-a350",    canonicalName: "Airbus A350",       rarity: .uncommon,
                      modelTokens: ["a350"],
                      summary: "Curved cockpit window mask. Newer than the 787.",
                      representativeTypecode: "A35K"),
                .init(id: "w-a330",    canonicalName: "Airbus A330",       rarity: .uncommon,
                      modelTokens: ["a330"],
                      summary: "Mid-life refresh keeps it competitive vs the 787.",
                      representativeTypecode: "A332"),
                .init(id: "w-767",     canonicalName: "Boeing 767",        rarity: .uncommon,
                      modelTokens: ["767"],
                      summary: "Twin-aisle, mostly cargo / military tanker now.",
                      representativeTypecode: "B763"),
                .init(id: "w-747",     canonicalName: "Boeing 747",        rarity: .rare,
                      modelTokens: ["747"],
                      summary: "The Queen of the Skies. Passenger 747s are nearly extinct.",
                      representativeTypecode: "B744"),
                .init(id: "w-a380",    canonicalName: "Airbus A380",       rarity: .epic,
                      modelTokens: ["a380"],
                      summary: "Largest passenger airliner. Full double-decker.",
                      representativeTypecode: "A388"),
                .init(id: "w-747-8",   canonicalName: "Boeing 747-8",      rarity: .epic,
                      modelTokens: ["747-8"],
                      summary: "Stretched 747 with all-new engines. Rare in passenger service.",
                      representativeTypecode: "B748"),
            ]
        ),
        .init(
            id: "regional", type: .regional, title: "Regional jets & turboprops",
            entries: [
                .init(id: "r-e175",    canonicalName: "Embraer E175",      rarity: .common,
                      modelTokens: ["e175", "e170"],
                      summary: "Sole feeder jet for most US legacy carriers.",
                      representativeTypecode: "E75L"),
                .init(id: "r-crj-700", canonicalName: "Bombardier CRJ-700",rarity: .common,
                      modelTokens: ["crj-7", "crj7"],
                      summary: "Stretched CRJ family. T-tail, two rear engines.",
                      representativeTypecode: "CRJ7"),
                // Rarity: common (DH8D) — turboprop but high daily volume in PNW/Canada.
                .init(id: "r-dash-8",  canonicalName: "De Havilland Dash 8",rarity: .common,
                      modelTokens: ["dash 8"],
                      summary: "Twin turboprop. Tall stilted gear. Common in PNW.",
                      representativeTypecode: "DH8D"),
                // Rarity: common (AT72) — active in regional ops.
                .init(id: "r-atr",     canonicalName: "ATR 72",            rarity: .common,
                      modelTokens: ["atr"],
                      summary: "European twin turboprop. Rare west of the Mississippi.",
                      representativeTypecode: "AT72"),
            ]
        ),
        .init(
            id: "biz", type: .biz, title: "Business jets",
            entries: [
                // Rarity: uncommon (C525) — bizjets rarely airborne vs. narrowbodies.
                .init(id: "b-citation", canonicalName: "Cessna Citation",  rarity: .uncommon,
                      modelTokens: ["citation"],
                      summary: "Best-selling biz-jet family. Many variants.",
                      representativeTypecode: "C525"),
                // Rarity: uncommon (E55P) — bizjet default per activity model.
                .init(id: "b-phenom",   canonicalName: "Embraer Phenom",   rarity: .uncommon,
                      modelTokens: ["phenom"],
                      summary: "Entry-level biz jets. Often charter.",
                      representativeTypecode: "E55P"),
                // Rarity: uncommon (F2TH) — bizjet default per activity model.
                .init(id: "b-falcon",   canonicalName: "Dassault Falcon",  rarity: .uncommon,
                      modelTokens: ["falcon"],
                      summary: "Tri-jets and twins. French heritage.",
                      representativeTypecode: "F2TH"),
                // Rarity: rare (GLF6) — heavy bizjet, scarce in the air.
                .init(id: "b-g650",     canonicalName: "Gulfstream G650",  rarity: .rare,
                      modelTokens: ["g650"],
                      summary: "Long-range top tier. Distinctive winglet.",
                      representativeTypecode: "GLF6"),
                // Rarity: rare (GL7T) — heavy bizjet, scarce in the air.
                .init(id: "b-global",   canonicalName: "Bombardier Global",rarity: .rare,
                      modelTokens: ["global 7500", "global 6500"],
                      summary: "Largest of the Globals. Three-zone cabin.",
                      representativeTypecode: "GL7T"),
            ]
        ),
        .init(
            id: "mil", type: .mil, title: "Military",
            entries: [
                .init(id: "m-c130",  canonicalName: "Lockheed C-130 Hercules", rarity: .rare,
                      modelTokens: ["c-130"],
                      summary: "Four-engine turboprop. Tactical airlift workhorse.",
                      representativeTypecode: "C130"),
                .init(id: "m-c17",   canonicalName: "Boeing C-17 Globemaster",  rarity: .rare,
                      modelTokens: ["c-17"],
                      summary: "Strategic airlift. Distinctive winglets + T-tail.",
                      representativeTypecode: "C17"),
                // Rarity: uncommon (K35E) — tanker fleet is large; many are airborne daily.
                .init(id: "m-kc135", canonicalName: "Boeing KC-135 Stratotanker",rarity: .uncommon,
                      modelTokens: ["kc-135"],
                      summary: "Aerial refueling tanker. Based on the 707.",
                      representativeTypecode: "K35E"),
                // No typecode in DOC 8643 table — KC-46 is recent / sparsely catalogued.
                .init(id: "m-kc46",  canonicalName: "Boeing KC-46 Pegasus",      rarity: .rare,
                      modelTokens: ["kc-46"],
                      summary: "Newer tanker, 767-based. Replacing the KC-135 slowly.",
                      representativeTypecode: nil),
                // Rarity: epic (B52) — 8-engine strategic bomber, one of the rarest active types.
                .init(id: "m-b52",   canonicalName: "Boeing B-52 Stratofortress",rarity: .epic,
                      modelTokens: ["b-52"],
                      summary: "Long-serving strategic bomber. Eight engines.",
                      representativeTypecode: "B52"),
                // No typecode in DOC 8643 table — AircraftClassifier .legendary gate
                // (operator-gated USAF/Air Force rule) handles the post-catch path.
                .init(id: "m-vc25",  canonicalName: "Boeing VC-25 (Air Force One)",rarity: .legendary,
                      modelTokens: ["vc-25"],
                      summary: "747-200 in white & blue. Three of them; one is always Air Force One.",
                      representativeTypecode: nil),
            ]
        ),
        .init(
            id: "ga", type: .ga, title: "General aviation",
            entries: [
                .init(id: "ga-c172", canonicalName: "Cessna 172", rarity: .common,
                      modelTokens: ["172", "skyhawk"],
                      summary: "Most-built aircraft ever. Universal training plane.",
                      representativeTypecode: "C172"),
                .init(id: "ga-c182", canonicalName: "Cessna 182", rarity: .common,
                      modelTokens: ["182", "skylane"],
                      summary: "Higher-power four-seater. Bigger sibling of the 172.",
                      representativeTypecode: "C182"),
                // Rarity: common (C152) — GA piston, still widely owned.
                .init(id: "ga-c152", canonicalName: "Cessna 152", rarity: .common,
                      modelTokens: ["152", "cessna 150"],
                      summary: "Two-seat trainer. Older, smaller cousin of the 172.",
                      representativeTypecode: "C152"),
                .init(id: "ga-pa28", canonicalName: "Piper PA-28", rarity: .common,
                      modelTokens: ["pa-28", "piper cherokee", "cherokee"],
                      summary: "Low-wing trainer alternative to the 172.",
                      representativeTypecode: "P28A"),
                // No typecode in DOC 8643 table (Piper J-3 / L-4 are homebuilt-era).
                .init(id: "ga-piper-cub", canonicalName: "Piper Cub", rarity: .uncommon,
                      modelTokens: ["j-3", "piper cub", "super cub"],
                      summary: "Yellow taildragger. Classic American light aircraft.",
                      representativeTypecode: nil),
                .init(id: "ga-sr22", canonicalName: "Cirrus SR22", rarity: .common,
                      modelTokens: ["sr22"],
                      summary: "Composite single. Whole-aircraft parachute system.",
                      representativeTypecode: "SR22"),
                // Rarity: common (SR20) — GA piston, widely flown.
                .init(id: "ga-sr20", canonicalName: "Cirrus SR20", rarity: .common,
                      modelTokens: ["sr20"],
                      summary: "Lower-powered Cirrus. Same airframe as the SR22, smaller engine.",
                      representativeTypecode: "SR20"),
                // Rarity: common (BE35) — GA piston long-tail.
                .init(id: "ga-bonanza", canonicalName: "Beechcraft Bonanza", rarity: .common,
                      modelTokens: ["bonanza", "be-36", "be-35", "v-tail"],
                      summary: "V-tail or straight-tail single. In production since 1947.",
                      representativeTypecode: "BE35"),
                // Rarity: common (M20P) — niche but not scarce; GA piston default.
                .init(id: "ga-mooney", canonicalName: "Mooney M20", rarity: .common,
                      modelTokens: ["m20", "mooney"],
                      summary: "Distinctive forward-canted tail. Fast for a piston single.",
                      representativeTypecode: "M20P"),
                // Rarity: common (DA40) — composite trainer, common at flight schools.
                .init(id: "ga-da40", canonicalName: "Diamond DA40", rarity: .common,
                      modelTokens: ["da40", "da 40", "diamond star"],
                      summary: "Composite low-wing. Common modern trainer.",
                      representativeTypecode: "DA40"),
                // Rarity: common (DA42) — multi-engine trainer, common at ATP schools.
                .init(id: "ga-da42", canonicalName: "Diamond DA42", rarity: .common,
                      modelTokens: ["da42", "da 42", "twin star"],
                      summary: "Twin-engine diesel. Multi-engine trainer.",
                      representativeTypecode: "DA42"),
                // No typecode in DOC 8643 table (homebuilt / experimental category).
                .init(id: "ga-rv", canonicalName: "Van's RV-series", rarity: .uncommon,
                      modelTokens: ["van's rv", "vans rv", "rv-7", "rv-8", "rv-9", "rv-10", "rv-12", "rv-14"],
                      summary: "Homebuilt kit aircraft. Often aerobatic-capable.",
                      representativeTypecode: nil),
                // Rarity: uncommon (R44) — rotorcraft default.
                .init(id: "ga-r44", canonicalName: "Robinson R44", rarity: .uncommon,
                      modelTokens: ["r44", "robinson"],
                      summary: "Light piston helicopter. Very common trainer rotorcraft.",
                      representativeTypecode: "R44"),
            ]
        ),
        .init(
            id: "heritage", type: .heritage, title: "Heritage & special-mission",
            entries: [
                // Rarity: common (DC3) — DOC 8643 classifies it as common; a handful
                // are still airborne worldwide. The "legendary" collector feel stays in
                // the set's summary / editorial copy.
                .init(id: "h-dc3",       canonicalName: "Douglas DC-3",         rarity: .common,
                      modelTokens: ["dc-3", "c-47"],
                      summary: "1930s twin-radial. A few still flying.",
                      representativeTypecode: "DC3"),
                // No typecode in DOC 8643 table (Constellation is museum-only).
                .init(id: "h-connie",    canonicalName: "Lockheed Constellation",rarity: .legendary,
                      modelTokens: ["constellation", "l-1049"],
                      summary: "Distinctive triple-tail. Pre-jet flagship.",
                      representativeTypecode: nil),
                // Rarity: rare (B74S = 747SP) — decommissioned, essentially uncatchable.
                .init(id: "h-sofia",     canonicalName: "NASA SOFIA (747SP)",   rarity: .rare,
                      modelTokens: ["747sp"],
                      summary: "Stratospheric Observatory. Decommissioned 2022.",
                      representativeTypecode: "B74S"),
                // No typecode in DOC 8643 table (Concorde is retired/museum).
                .init(id: "h-concorde",  canonicalName: "Concorde",             rarity: .legendary,
                      modelTokens: ["concorde"],
                      summary: "Retired 2003. For the wishful thinker.",
                      representativeTypecode: nil),
            ]
        ),
    ]

    /// Make/model FAMILY sets — the second collection lens. Where `all`
    /// groups by broad type (every narrow-body together), `families` groups
    /// by airframe lineage: every 737 variant, every A320 variant, etc. A
    /// family is the most natural "complete the collection" unit — a bounded,
    /// recognizable set of variants you can realistically fill.
    ///
    /// Each entry carries its real ICAO `representativeTypecode`, so matching
    /// is precise (B738 → 737-800, A20N → A320neo) via the typecode path in
    /// `matches`. Rarity mirrors `AircraftTypes.json` for that typecode
    /// (pinned by FamilySetsTests, same contract as the type sets). The
    /// `type` field drives the family's tint/glyph in the browser.
    static let families: [CardSet] = [
        .init(id: "fam-737", type: .narrow, title: "Boeing 737", entries: [
            .init(id: "f737-700", canonicalName: "737-700", rarity: .common,
                  modelTokens: ["737-7", "737-700"],
                  summary: "Shortest current-gen 737. Southwest's backbone.",
                  representativeTypecode: "B737"),
            .init(id: "f737-800", canonicalName: "737-800", rarity: .common,
                  modelTokens: ["737-8", "737-800"],
                  summary: "The definitive 737. Most-built variant of the family.",
                  representativeTypecode: "B738"),
            .init(id: "f737-900", canonicalName: "737-900", rarity: .common,
                  modelTokens: ["737-9", "737-900"],
                  summary: "Stretched NG. Common on US legacy carriers.",
                  representativeTypecode: "B739"),
            .init(id: "f737-max8", canonicalName: "737 MAX 8", rarity: .common,
                  modelTokens: ["max 8", "737 max 8", "737-8 max"],
                  summary: "Re-engined NG. Split-tip winglets are the tell.",
                  representativeTypecode: "B38M"),
            .init(id: "f737-max9", canonicalName: "737 MAX 9", rarity: .common,
                  modelTokens: ["max 9", "737 max 9", "737-9 max"],
                  summary: "Stretched MAX. United and Alaska fly the most.",
                  representativeTypecode: "B39M"),
        ]),
        .init(id: "fam-a320", type: .narrow, title: "Airbus A320 Family", entries: [
            // Classic ceo variants are TYPECODE-ONLY (empty tokens): the neo
            // canonical names contain "a320" etc., so a token would let a neo
            // catch bleed into the classic slot. The typecode (A320 vs A20N)
            // is the unambiguous variant identity.
            .init(id: "fa319", canonicalName: "A319", rarity: .common,
                  modelTokens: [], summary: "Shortened A320. Same cockpit, fewer rows.",
                  representativeTypecode: "A319"),
            .init(id: "fa320", canonicalName: "A320", rarity: .common,
                  modelTokens: [], summary: "The baseline of Airbus's narrow-body family.",
                  representativeTypecode: "A320"),
            .init(id: "fa321", canonicalName: "A321", rarity: .common,
                  modelTokens: [], summary: "Stretched A320. Longest of the ceo family.",
                  representativeTypecode: "A321"),
            .init(id: "fa319neo", canonicalName: "A319neo", rarity: .common,
                  modelTokens: ["a319neo"], summary: "New-engine A319. Rare — most orders went larger.",
                  representativeTypecode: "A19N"),
            .init(id: "fa320neo", canonicalName: "A320neo", rarity: .common,
                  modelTokens: ["a320neo"], summary: "New-engine option. Bigger fan, sharklets.",
                  representativeTypecode: "A20N"),
            .init(id: "fa321neo", canonicalName: "A321neo", rarity: .common,
                  modelTokens: ["a321neo"], summary: "Longest, longest-range narrow-body Airbus.",
                  representativeTypecode: "A21N"),
        ]),
        .init(id: "fam-777", type: .wide, title: "Boeing 777", entries: [
            .init(id: "f777-200", canonicalName: "777-200", rarity: .uncommon,
                  modelTokens: ["777-200", "777-2"], summary: "Original 777. Twin GE90s.",
                  representativeTypecode: "B772"),
            .init(id: "f777-200lr", canonicalName: "777-200LR", rarity: .uncommon,
                  modelTokens: ["777-200lr", "777lr"], summary: "Ultra-long-range. 'Worldliner'.",
                  representativeTypecode: "B77L"),
            // Typecode-only: "777-300" is a substring of "777-300ER", so a
            // token would let a -300ER catch bleed into the -300 slot.
            .init(id: "f777-300", canonicalName: "777-300", rarity: .uncommon,
                  modelTokens: [], summary: "Stretched 777, original engines.",
                  representativeTypecode: "B773"),
            .init(id: "f777-300er", canonicalName: "777-300ER", rarity: .uncommon,
                  modelTokens: ["777-300er", "777er"], summary: "The workhorse long-hauler. Raked wingtips.",
                  representativeTypecode: "B77W"),
        ]),
        .init(id: "fam-787", type: .wide, title: "Boeing 787 Dreamliner", entries: [
            .init(id: "f787-8", canonicalName: "787-8", rarity: .uncommon,
                  modelTokens: ["787-8"], summary: "First Dreamliner. Composite fuselage.",
                  representativeTypecode: "B788"),
            .init(id: "f787-9", canonicalName: "787-9", rarity: .uncommon,
                  modelTokens: ["787-9"], summary: "Stretched, longer-range. The common 787.",
                  representativeTypecode: "B789"),
            .init(id: "f787-10", canonicalName: "787-10", rarity: .uncommon,
                  modelTokens: ["787-10"], summary: "Longest Dreamliner. Regional long-haul.",
                  representativeTypecode: "B78X"),
        ]),
        .init(id: "fam-a330", type: .wide, title: "Airbus A330", entries: [
            .init(id: "fa330-200", canonicalName: "A330-200", rarity: .uncommon,
                  modelTokens: ["a330-2", "a330-200"], summary: "Shorter, longer-range A330.",
                  representativeTypecode: "A332"),
            .init(id: "fa330-300", canonicalName: "A330-300", rarity: .uncommon,
                  modelTokens: ["a330-3", "a330-300"], summary: "Original stretched A330.",
                  representativeTypecode: "A333"),
            .init(id: "fa330-800", canonicalName: "A330-800neo", rarity: .uncommon,
                  modelTokens: ["a330-800"], summary: "Re-engined neo, shorter. Rare.",
                  representativeTypecode: "A338"),
            .init(id: "fa330-900", canonicalName: "A330-900neo", rarity: .uncommon,
                  modelTokens: ["a330-900"], summary: "Re-engined neo, the common one.",
                  representativeTypecode: "A339"),
        ]),
        .init(id: "fam-a350", type: .wide, title: "Airbus A350", entries: [
            .init(id: "fa350-900", canonicalName: "A350-900", rarity: .uncommon,
                  modelTokens: ["a350-900", "a350-9"], summary: "Curved cockpit mask. Carbon long-hauler.",
                  representativeTypecode: "A359"),
            .init(id: "fa350-1000", canonicalName: "A350-1000", rarity: .uncommon,
                  modelTokens: ["a350-1000", "a350-10"], summary: "Stretched A350. Six-wheel main gear.",
                  representativeTypecode: "A35K"),
        ]),
        .init(id: "fam-747", type: .wide, title: "Boeing 747", entries: [
            .init(id: "f747-400", canonicalName: "747-400", rarity: .rare,
                  modelTokens: ["747-400", "747-4"], summary: "The classic Queen. Mostly cargo now.",
                  representativeTypecode: "B744"),
            .init(id: "f747-8", canonicalName: "747-8", rarity: .epic,
                  modelTokens: ["747-8"], summary: "Final, stretched 747. New engines + wing.",
                  representativeTypecode: "B748"),
            .init(id: "f747-sp", canonicalName: "747SP", rarity: .rare,
                  modelTokens: ["747sp"], summary: "Stubby long-range special. Vanishingly rare.",
                  representativeTypecode: "B74S"),
        ]),
        .init(id: "fam-767", type: .wide, title: "Boeing 767", entries: [
            .init(id: "f767-200", canonicalName: "767-200", rarity: .uncommon,
                  modelTokens: ["767-200", "767-2"], summary: "Original twin-aisle 767.",
                  representativeTypecode: "B762"),
            .init(id: "f767-300", canonicalName: "767-300", rarity: .uncommon,
                  modelTokens: ["767-300", "767-3"], summary: "Stretched 767. Heavy on cargo routes.",
                  representativeTypecode: "B763"),
            .init(id: "f767-400", canonicalName: "767-400", rarity: .uncommon,
                  modelTokens: ["767-400", "767-4"], summary: "Longest 767. Delta + United only.",
                  representativeTypecode: "B764"),
        ]),
        .init(id: "fam-ejet", type: .regional, title: "Embraer E-Jet", entries: [
            .init(id: "fe170", canonicalName: "E170", rarity: .common,
                  modelTokens: ["e170", "e-170", "erj 170"], summary: "Smallest E-Jet. Four-abreast regional.",
                  representativeTypecode: "E170"),
            .init(id: "fe175", canonicalName: "E175", rarity: .common,
                  modelTokens: ["e175", "e-175", "erj 175"], summary: "The US regional-jet standard.",
                  representativeTypecode: "E75L"),
            .init(id: "fe190", canonicalName: "E190", rarity: .uncommon,
                  modelTokens: ["e190", "e-190", "erj 190"], summary: "Larger E-Jet. Mainline-feel regional.",
                  representativeTypecode: "E190"),
            .init(id: "fe195", canonicalName: "E195", rarity: .uncommon,
                  modelTokens: ["e195", "e-195", "erj 195"], summary: "Longest classic E-Jet.",
                  representativeTypecode: "E195"),
        ]),
        .init(id: "fam-crj", type: .regional, title: "Bombardier CRJ", entries: [
            .init(id: "fcrj200", canonicalName: "CRJ-200", rarity: .common,
                  modelTokens: ["crj-2", "crj200", "crj 200"], summary: "The original 50-seat regional jet.",
                  representativeTypecode: "CRJ2"),
            .init(id: "fcrj700", canonicalName: "CRJ-700", rarity: .common,
                  modelTokens: ["crj-7", "crj700", "crj 700"], summary: "Stretched CRJ. 70 seats.",
                  representativeTypecode: "CRJ7"),
            .init(id: "fcrj900", canonicalName: "CRJ-900", rarity: .common,
                  modelTokens: ["crj-9", "crj900", "crj 900"], summary: "90-seat CRJ. US regional staple.",
                  representativeTypecode: "CRJ9"),
            .init(id: "fcrj1000", canonicalName: "CRJ-1000", rarity: .common,
                  modelTokens: ["crj-1000", "crj1000", "crj 1000"], summary: "Longest CRJ. Rare in the US.",
                  representativeTypecode: "CRJX"),
        ]),
        .init(id: "fam-citation", type: .biz, title: "Cessna Citation", entries: [
            .init(id: "fc-cj", canonicalName: "CitationJet / CJ", rarity: .uncommon,
                  modelTokens: ["citationjet", "525 citation", "cj1"], summary: "Entry CitationJet. The 525 line.",
                  representativeTypecode: "C525"),
            .init(id: "fc-cj4", canonicalName: "Citation CJ4", rarity: .uncommon,
                  modelTokens: ["cj4", "525c"], summary: "Largest single-pilot CJ.",
                  representativeTypecode: "C25C"),
            .init(id: "fc-xls", canonicalName: "Citation XLS", rarity: .uncommon,
                  modelTokens: ["xls", "560xl", "excel"], summary: "Best-selling midsize Citation.",
                  representativeTypecode: "C56X"),
            .init(id: "fc-sovereign", canonicalName: "Citation Sovereign", rarity: .uncommon,
                  modelTokens: ["sovereign", "680 citation"], summary: "Midsize, transcontinental range.",
                  representativeTypecode: "C680"),
            .init(id: "fc-longitude", canonicalName: "Citation Longitude", rarity: .uncommon,
                  modelTokens: ["longitude", "700 citation"], summary: "Top of the Citation line.",
                  representativeTypecode: "C700"),
        ]),
        .init(id: "fam-gulfstream", type: .biz, title: "Gulfstream", entries: [
            .init(id: "fg-iv", canonicalName: "Gulfstream IV", rarity: .uncommon,
                  modelTokens: ["gulfstream iv", "g-iv", "giv"], summary: "Classic large-cabin Gulfstream.",
                  representativeTypecode: "GLF4"),
            .init(id: "fg-280", canonicalName: "Gulfstream G280", rarity: .uncommon,
                  modelTokens: ["g280", "g-280"], summary: "Super-midsize. Israeli-built.",
                  representativeTypecode: "G280"),
            .init(id: "fg-550", canonicalName: "Gulfstream G550", rarity: .uncommon,
                  modelTokens: ["g550", "g-550"], summary: "Long-range large cabin. Ubiquitous at the top.",
                  representativeTypecode: "GLF5"),
            .init(id: "fg-650", canonicalName: "Gulfstream G650", rarity: .rare,
                  modelTokens: ["g650", "g-650"], summary: "Flagship ultra-long-range. The status jet.",
                  representativeTypecode: "GLF6"),
        ]),
    ]

    /// Slot status for a single entry against a catch list.
    enum SlotStatus: Equatable {
        case locked
        case caught(catchedExample: Catch)
    }

    /// True when the catch's model matches any of the entry's
    /// `modelTokens` — checked against BOTH the raw OpenSky model
    /// string AND the canonical name (typecode-resolved). Union, not
    /// replacement: membership can only gain from canonicalization,
    /// never lose. Single source of truth for Catch → CardSetEntry.
    nonisolated static func matches(catch c: Catch, entry: CardSetEntry) -> Bool {
        // Precise path (added for family sets, 2026-06-15): exact ICAO
        // typecode equality. Family lenses distinguish variants the model
        // string can't (A320 vs A320neo, 777-300 vs 777-300ER) — the typecode
        // is the unambiguous variant identity, and the backend resolves it for
        // virtually every airliner. This is a UNION with the token path below
        // (membership can only gain), so existing type-set behavior is
        // unchanged for token-matched catches.
        if let tc = entry.representativeTypecode,
           let ctc = c.typecode,
           !ctc.isEmpty,
           tc.caseInsensitiveCompare(ctc) == .orderedSame {
            return true
        }
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

    /// Walk a single set's entries and resolve each against the
    /// caught planes. First matching catch (by `modelTokens`
    /// substring on `c.model`) fills the slot.
    static func status(of set: CardSet, against catches: [Catch]) -> [(CardSetEntry, SlotStatus)] {
        set.entries.map { entry in
            let hit = catches.first { matches(catch: $0, entry: entry) }
            return (entry, hit.map(SlotStatus.caught) ?? .locked)
        }
    }

    /// "N caught out of M" for the set browser tile.
    static func progress(of set: CardSet, against catches: [Catch]) -> (caught: Int, total: Int) {
        let s = status(of: set, against: catches)
        return (s.filter { if case .caught = $0.1 { return true } else { return false } }.count, s.count)
    }

    /// The set list for a given browser lens.
    static func sets(for lens: SetLens) -> [CardSet] {
        switch lens {
        case .type:   return all
        case .family: return families
        }
    }
}

/// The two ways to slice the collection in the Sets browser.
///   .type   — broad category (every narrow-body together)   → `CardSets.all`
///   .family — airframe lineage (every 737 variant together) → `CardSets.families`
nonisolated enum SetLens: String, CaseIterable, Identifiable, Sendable {
    case type, family
    var id: String { rawValue }
    var title: String {
        switch self {
        case .type:   return "By Type"
        case .family: return "By Family"
        }
    }
}
