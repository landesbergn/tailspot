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
    /// Curated fallback tier — used only for entries with no resolvable
    /// typecode. Typecoded entries derive rarity from the activity table
    /// (see `rarity`), so a re-tier in generate-aircraft-types.py can
    /// never drift from Sets.swift.
    let curatedRarity: Rarity
    let modelTokens: [String]       // case-insensitive substring match
    let summary: String             // tap-to-reveal blurb
    /// Opt-in fallback for catches with no usable typecode or model identity.
    /// Kept explicit so an unknown catch cannot accidentally fill a real model.
    let matchesUnidentified: Bool
    /// A representative ICAO typecode for this entry — the one used
    /// when cross-referencing the activity-rarity table in tests
    /// (divergence-b fix, 2026-06-11). Optional for entries with no
    /// resolvable typecode (homebuilts, retired types not in DOC 8643).
    let representativeTypecode: String?

    /// Tier that colors the locked silhouette. Derives from the single
    /// source of truth (the activity table) when a typecode resolves;
    /// falls back to the curated tier only for typecode-less entries.
    var rarity: Rarity {
        if let tc = representativeTypecode,
           let derived = AircraftNaming.rarity(forTypecode: tc) {
            return derived
        }
        return curatedRarity
    }

    init(id: String, canonicalName: String, rarity: Rarity,
         modelTokens: [String], summary: String,
         representativeTypecode: String? = nil,
         matchesUnidentified: Bool = false) {
        self.id = id
        self.canonicalName = canonicalName
        self.curatedRarity = rarity
        self.modelTokens = modelTokens
        self.summary = summary
        self.representativeTypecode = representativeTypecode
        self.matchesUnidentified = matchesUnidentified
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
                      modelTokens: ["e175", "e170", "embraer 175"],
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
                // Rarity: uncommon (H25B) — mid-size fleet still large in the US.
                .init(id: "b-hawker",   canonicalName: "Hawker 800",       rarity: .uncommon,
                      modelTokens: ["hawker 800", "hawker 750", "hawker 900", "800xp"],
                      summary: "Midsize British-born twin. Hundreds still working.",
                      representativeTypecode: "H25B"),
                // One slot for the whole marque — any Learjet fills it.
                .init(id: "b-learjet",  canonicalName: "Learjet",          rarity: .uncommon,
                      modelTokens: ["learjet"],
                      summary: "The name that meant bizjet. 35s and 60s still fly hard.",
                      representativeTypecode: "LJ60"),
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
                // Rarity: uncommon (PC12) — turboprop single; 16 catches in prod
                // with no slot before this (2026-08-12 histogram audit).
                .init(id: "ga-pc12", canonicalName: "Pilatus PC-12", rarity: .uncommon,
                      modelTokens: ["pc-12", "pc12"],
                      summary: "Single-engine turboprop workhorse. Freight, medevac, charter.",
                      representativeTypecode: "PC12"),
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
    private static let familiesCore: [CardSet] = [
        .init(id: "fam-737", type: .narrow, title: "Boeing 737", entries: [
            // One slot for the -300/-400/-500 generation — mostly freighters
            // now, so variant-level slots would be near-impossible quests.
            .init(id: "f737-classic", canonicalName: "737 Classic", rarity: .common,
                  modelTokens: ["737-300", "737-400", "737-500", "737-3", "737-4", "737-5"],
                  summary: "The -300/-400/-500 generation. Mostly night freight now.",
                  representativeTypecode: "B734"),
            .init(id: "f737-600", canonicalName: "737-600", rarity: .common,
                  modelTokens: ["737-6", "737-600"],
                  summary: "The rarest NG. Barely anyone ordered it.",
                  representativeTypecode: "B736"),
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
        .init(id: "fam-a320", type: .narrow, title: "Airbus A320", entries: [
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
        .init(id: "fam-787", type: .wide, title: "Boeing 787", entries: [
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
        // Rare-hunt quest: the last quads in scheduled service, retiring fast.
        .init(id: "fam-a340", type: .wide, title: "Airbus A340", entries: [
            .init(id: "fa340-300", canonicalName: "A340-300", rarity: .rare,
                  modelTokens: ["a340-300", "a340-3"], summary: "Four engines, CFM56s. The common A340 — for now.",
                  representativeTypecode: "A343"),
            .init(id: "fa340-600", canonicalName: "A340-600", rarity: .rare,
                  modelTokens: ["a340-600", "a340-6"], summary: "Stretched quad on RR Trents. Once the longest airliner.",
                  representativeTypecode: "A346"),
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
            // "embraer 175": the short-winglet E75S resolves to canonical
            // "Embraer 175", which no e175/e-175 token substring-matches —
            // 2 prod catches fell through (2026-08-12 histogram audit).
            .init(id: "fe175", canonicalName: "E175", rarity: .common,
                  modelTokens: ["e175", "e-175", "erj 175", "embraer 175"], summary: "The US regional-jet standard.",
                  representativeTypecode: "E75L"),
            .init(id: "fe190", canonicalName: "E190", rarity: .uncommon,
                  modelTokens: ["erj 190"], summary: "Larger E-Jet. Mainline-feel regional.",
                  representativeTypecode: "E190"),
            .init(id: "fe195", canonicalName: "E195", rarity: .uncommon,
                  modelTokens: ["erj 195"], summary: "Longest classic E-Jet.",
                  representativeTypecode: "E195"),
            .init(id: "fe190-e2", canonicalName: "E190-E2", rarity: .uncommon,
                  modelTokens: ["e190-e2", "e-190-e2"], summary: "New wing and geared turbofans. The shorter E2.",
                  representativeTypecode: "E290"),
            .init(id: "fe195-e2", canonicalName: "E195-E2", rarity: .uncommon,
                  modelTokens: ["e195-e2", "e-195-e2"], summary: "The largest E-Jet. Up to 146 seats.",
                  representativeTypecode: "E295"),
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
        // Citation is the messiest family (16 typecodes). Slots are grouped by
        // variant series with broad numeric/name tokens (avoiding ambiguous
        // Roman-numeral substrings like "citation v" ⊂ "citation vii") so any
        // Citation lands somewhere — all variants are .uncommon in the catalog.
        .init(id: "fam-citation", type: .biz, title: "Cessna Citation", entries: [
            .init(id: "fc-cj", canonicalName: "CitationJet / CJ", rarity: .uncommon,
                  modelTokens: ["citationjet", "citation cj", "cj1", "cj2", "cj3", "cj4",
                                "525 citation", "525a", "525b", "525c"],
                  summary: "The 525 light-jet line — CitationJet through CJ4.",
                  representativeTypecode: "C525"),
            .init(id: "fc-classic", canonicalName: "Citation II / V", rarity: .uncommon,
                  modelTokens: ["500 citation", "501 citation", "550 citation", "551 citation",
                                "560 citation", "citation bravo", "citation ultra", "citation encore"],
                  summary: "The classic straight-wing Citations (500/550/560).",
                  representativeTypecode: "C560"),
            .init(id: "fc-xls", canonicalName: "Citation Excel / XLS", rarity: .uncommon,
                  modelTokens: ["xls", "560xl", "excel"], summary: "Best-selling midsize Citation.",
                  representativeTypecode: "C56X"),
            .init(id: "fc-sovereign", canonicalName: "Citation Sovereign / Latitude", rarity: .uncommon,
                  modelTokens: ["sovereign", "latitude", "680 citation"], summary: "Midsize, transcontinental range.",
                  representativeTypecode: "C680"),
            .init(id: "fc-longitude", canonicalName: "Citation X / Longitude", rarity: .uncommon,
                  modelTokens: ["longitude", "cessna citation x", "citation 10", "650 citation", "700 citation", "750 citation"],
                  summary: "The fast, long-range top of the line.",
                  representativeTypecode: "C700"),
            // "citation mustang", not bare "mustang" — a P-51 resolves to
            // canonical "A-36 Mustang" and would bleed into this slot.
            .init(id: "fc-mustang", canonicalName: "Citation Mustang", rarity: .uncommon,
                  modelTokens: ["citation mustang", "510 citation"], summary: "Entry-level very-light Citation.",
                  representativeTypecode: "C510"),
        ]),
        .init(id: "fam-gulfstream", type: .biz, title: "Gulfstream", entries: [
            .init(id: "fg-iv", canonicalName: "Gulfstream IV", rarity: .uncommon,
                  modelTokens: ["gulfstream iv", "g-iv", "giv"], summary: "Classic large-cabin Gulfstream.",
                  representativeTypecode: "GLF4"),
            // G200 folded in (2026-08-24 coverage audit: a GALX catch had no
            // slot) — same Israeli super-midsize line, predecessor to the G280.
            .init(id: "fg-280", canonicalName: "G200 / G280", rarity: .uncommon,
                  modelTokens: ["g280", "g-280", "g200", "g-200", "galaxy g200"], summary: "Super-midsize. Israeli-built.",
                  representativeTypecode: "G280"),
            .init(id: "fg-550", canonicalName: "Gulfstream G550", rarity: .uncommon,
                  modelTokens: ["g550", "g-550"], summary: "Long-range large cabin. Ubiquitous at the top.",
                  representativeTypecode: "GLF5"),
            .init(id: "fg-600", canonicalName: "G500 / G600", rarity: .rare,
                  modelTokens: ["g500", "g-500", "g600", "g-600"], summary: "New-generation large cabin. Fly-by-wire.",
                  representativeTypecode: "GA6C"),
            .init(id: "fg-650", canonicalName: "Gulfstream G650", rarity: .rare,
                  modelTokens: ["g650", "g-650"], summary: "Flagship ultra-long-range. The status jet.",
                  representativeTypecode: "GLF6"),
            .init(id: "fg-700", canonicalName: "G700 / G800", rarity: .rare,
                  modelTokens: ["g700", "g-700", "g800", "g-800"], summary: "The new flagships. Longest cabins flying.",
                  representativeTypecode: "GA7C"),
        ]),
    ]

    // Gap-filling families so common catches (GA pistons, turboprops, other
    // jet makers) have a home — broadly MECE for what you'll realistically
    // catch. As of the 2026-08-24 coverage audit (gap chunk C), every type
    // observed in prod lands in at least one family. Split into chunks so
    // the Swift type-checker handles each literal quickly.
    private static let familiesGapA: [CardSet] = [
        .init(id: "fam-a220", type: .narrow, title: "Airbus A220", entries: [
            .init(id: "fa220-100", canonicalName: "A220-100", rarity: .uncommon,
                  modelTokens: ["a220-100", "bcs1", "cs100"], summary: "Shorter A220 (ex-Bombardier CS100).",
                  representativeTypecode: "BCS1"),
            .init(id: "fa220-300", canonicalName: "A220-300", rarity: .uncommon,
                  modelTokens: ["a220-300", "a220", "bcs3", "cs300"], summary: "The common A220. Quiet, efficient.",
                  representativeTypecode: "BCS3"),
        ]),
        .init(id: "fam-a380", type: .wide, title: "Airbus A380", entries: [
            .init(id: "fa380", canonicalName: "A380-800", rarity: .epic,
                  modelTokens: ["a380"], summary: "Full double-decker. The largest airliner flying.",
                  representativeTypecode: "A388"),
        ]),
        .init(id: "fam-a300", type: .wide, title: "Airbus A300", entries: [
            .init(id: "fa300", canonicalName: "A300", rarity: .epic,
                  modelTokens: ["a300"], summary: "The first twin-engine widebody. Cargo keeps it flying.",
                  representativeTypecode: "A306"),
        ]),
        .init(id: "fam-757", type: .narrow, title: "Boeing 757", entries: [
            .init(id: "f757-200", canonicalName: "757-200", rarity: .common,
                  modelTokens: ["757-200", "757-2"], summary: "The common 757. Tall gear, long fuselage.",
                  representativeTypecode: "B752"),
            .init(id: "f757-300", canonicalName: "757-300", rarity: .common,
                  modelTokens: ["757-300", "757-3"], summary: "Stretched 757. Rare; mostly charter.",
                  representativeTypecode: "B753"),
        ]),
        // The Long Beach narrow-body family tree, one slot per generation:
        // DC-9 → MD-80 → MD-90 → 717 (né MD-95, the only one delivered as
        // a Boeing). The MD-80 slot spans all five variants (81/82/83/87/88)
        // — MD-83s fly cargo today and used to fall through the old
        // per-variant tokens. The MD-11/DC-10 wide-bodies live next door in
        // fam-md-heavies.
        .init(id: "fam-md", type: .narrow, title: "McDonnell Douglas", entries: [
            .init(id: "fdc9", canonicalName: "DC-9", rarity: .epic,
                  modelTokens: ["dc-9", "dc9"], summary: "Where the line began. A handful still fly.",
                  representativeTypecode: "DC93"),
            .init(id: "fmd80", canonicalName: "MD-80 series", rarity: .rare,
                  modelTokens: ["md-81", "md-82", "md-83", "md-87", "md-88",
                                "md81", "md82", "md83", "md87", "md88"],
                  summary: "The Mad Dog. Any MD-81 through MD-88 counts.",
                  representativeTypecode: "MD82"),
            .init(id: "fmd90", canonicalName: "MD-90", rarity: .epic,
                  modelTokens: ["md-90", "md90"], summary: "Re-engined MD-80 stretch. Very scarce.",
                  representativeTypecode: "MD90"),
            .init(id: "f717", canonicalName: "Boeing 717", rarity: .rare,
                  modelTokens: ["717"], summary: "The final MD-95, sold as the 717.",
                  representativeTypecode: "B712"),
        ]),
        .init(id: "fam-md-heavies", type: .wide, title: "McDonnell Douglas Heavies", entries: [
            .init(id: "fdc10", canonicalName: "DC-10", rarity: .epic,
                  modelTokens: ["dc-10", "dc10"], summary: "First Long Beach tri-jet. Fire bombers now.",
                  representativeTypecode: "DC10"),
            .init(id: "fmd11", canonicalName: "MD-11", rarity: .epic,
                  modelTokens: ["md-11", "md11"], summary: "Tri-jet widebody. Night freighters now.",
                  representativeTypecode: "MD11"),
        ]),
        .init(id: "fam-comac", type: .narrow, title: "Comac", entries: [
            .init(id: "fc919", canonicalName: "C919", rarity: .common,
                  modelTokens: ["c919", "c-919"], summary: "China's narrow-body answer to the 737/A320.",
                  representativeTypecode: "C919"),
            .init(id: "farj21", canonicalName: "ARJ21 / C909", rarity: .common,
                  modelTokens: ["c909", "c-909", "arj21", "arj-21"], summary: "Comac's regional jet.",
                  representativeTypecode: "AJ27"),
        ]),
        .init(id: "fam-erj", type: .regional, title: "Embraer ERJ", entries: [
            .init(id: "ferj135", canonicalName: "ERJ-135", rarity: .common,
                  modelTokens: ["erj-135", "erj135", "emb-135"], summary: "37-seat original ERJ.",
                  representativeTypecode: "E135"),
            .init(id: "ferj145", canonicalName: "ERJ-145", rarity: .common,
                  modelTokens: ["erj-145", "erj145", "emb-145"], summary: "Stretched ERJ. Pre-E-Jet regional.",
                  representativeTypecode: "E145"),
        ]),
        .init(id: "fam-atr", type: .regional, title: "ATR", entries: [
            .init(id: "fatr42", canonicalName: "ATR 42", rarity: .common,
                  modelTokens: ["atr 42", "atr-42", "atr42"], summary: "Short twin turboprop.",
                  representativeTypecode: "AT45"),
            .init(id: "fatr72", canonicalName: "ATR 72", rarity: .common,
                  modelTokens: ["atr 72", "atr-72", "atr72"], summary: "Stretched ATR. The common one.",
                  representativeTypecode: "AT76"),
        ]),
        .init(id: "fam-dash8", type: .regional, title: "Bombardier Dash 8", entries: [
            .init(id: "fdash8-100", canonicalName: "Dash 8-100", rarity: .common,
                  modelTokens: ["dash 8-100", "dhc-8-100", "dh8a"], summary: "Original 37-seat Dash 8.",
                  representativeTypecode: "DH8A"),
            .init(id: "fdash8-300", canonicalName: "Dash 8-300", rarity: .common,
                  modelTokens: ["dash 8-300", "dhc-8-300", "dh8c"], summary: "Stretched 50-seat Dash 8.",
                  representativeTypecode: "DH8C"),
            .init(id: "fdash8-400", canonicalName: "Dash 8-400 (Q400)", rarity: .common,
                  modelTokens: ["dash 8-400", "q400", "dhc-8-400", "dh8d"], summary: "Fast 78-seat Q400.",
                  representativeTypecode: "DH8D"),
        ]),
    ]

    private static let familiesGapB: [CardSet] = [
        .init(id: "fam-cessna", type: .ga, title: "Cessna", entries: [
            .init(id: "fc152", canonicalName: "Cessna 150 / 152", rarity: .common,
                  modelTokens: ["cessna 152", "c152", "152", "cessna 150"], summary: "Two-seat trainer.",
                  representativeTypecode: "C152"),
            .init(id: "fc170", canonicalName: "Cessna 170", rarity: .common,
                  modelTokens: ["cessna 170", "c170"],
                  summary: "Postwar four-seat taildragger. The 172's immediate predecessor.",
                  representativeTypecode: "C170"),
            .init(id: "fc172", canonicalName: "Cessna 172", rarity: .common,
                  modelTokens: ["cessna 172", "c172", "172", "skyhawk"], summary: "Most-built aircraft ever.",
                  representativeTypecode: "C172"),
            .init(id: "fc177", canonicalName: "Cessna 177 Cardinal", rarity: .common,
                  modelTokens: ["cardinal", "177"], summary: "The strutless, sleeker 172 sibling.",
                  representativeTypecode: "C77R"),
            .init(id: "fc182", canonicalName: "Cessna 182", rarity: .common,
                  modelTokens: ["cessna 182", "c182", "182", "skylane"], summary: "Higher-power four-seater.",
                  representativeTypecode: "C182"),
            .init(id: "fc185", canonicalName: "Cessna 180 / 185", rarity: .common,
                  modelTokens: ["skywagon", "cessna 180", "cessna 185"], summary: "Taildragger workhorse. Bush and floats.",
                  representativeTypecode: "C185"),
            .init(id: "fc206", canonicalName: "Cessna 206 / 207", rarity: .common,
                  modelTokens: ["cessna 206", "c206", "206", "stationair", "cessna 207"], summary: "Hauler / floatplane single.",
                  representativeTypecode: "C206"),
            .init(id: "fc208", canonicalName: "Cessna 208 Caravan", rarity: .common,
                  modelTokens: ["caravan", "c208", "208"], summary: "Single turboprop utility hauler.",
                  representativeTypecode: "C208"),
            .init(id: "fc210", canonicalName: "Cessna 210 Centurion", rarity: .common,
                  modelTokens: ["cessna 210", "c210", "centurion"], summary: "Fast retractable-gear six-seat single.",
                  representativeTypecode: "C210"),
            // The twin the singles-only lineup skipped (field report 2026-08-12:
            // a Cape Air 402 catch had no slot to fill).
            .init(id: "fc402", canonicalName: "Cessna 402", rarity: .common,
                  modelTokens: ["cessna 402", "c402", "402"], summary: "Twin-piston commuter. Cape Air's workhorse.",
                  representativeTypecode: "C402"),
            // "cessna 310" (canonical-only), never bare "310" — an Airbus
            // A310's canonical name contains "310" and would bleed in.
            .init(id: "fc310", canonicalName: "Cessna 310", rarity: .common,
                  modelTokens: ["cessna 310", "c310"], summary: "Sleek tip-tank twin. Sky King's ride.",
                  representativeTypecode: "C310"),
        ]),
        .init(id: "fam-cirrus", type: .ga, title: "Cirrus", entries: [
            .init(id: "fsr20", canonicalName: "Cirrus SR20", rarity: .common,
                  modelTokens: ["sr20", "sr-20"], summary: "Composite single. Whole-plane parachute.",
                  representativeTypecode: "SR20"),
            .init(id: "fsr22", canonicalName: "Cirrus SR22", rarity: .common,
                  modelTokens: ["sr22", "sr-22"], summary: "The best-selling GA single.",
                  representativeTypecode: "SR22"),
            .init(id: "fsf50", canonicalName: "Cirrus Vision Jet", rarity: .uncommon,
                  modelTokens: ["sf50", "vision jet"], summary: "Single-engine personal jet.",
                  representativeTypecode: "SF50"),
        ]),
        .init(id: "fam-piper", type: .ga, title: "Piper", entries: [
            .init(id: "fpa28", canonicalName: "Piper PA-28 Cherokee", rarity: .common,
                  modelTokens: ["pa-28", "cherokee", "p28a"], summary: "Low-wing trainer staple.",
                  representativeTypecode: "P28A"),
            .init(id: "fpa32", canonicalName: "Piper PA-32", rarity: .common,
                  modelTokens: ["pa-32", "p32", "saratoga", "cherokee six"], summary: "Six-seat single.",
                  representativeTypecode: "PA32"),
            .init(id: "fpa44", canonicalName: "Piper PA-44 Seminole", rarity: .common,
                  modelTokens: ["pa-44", "seminole"], summary: "Light twin trainer.",
                  representativeTypecode: "PA44"),
            .init(id: "fpa34", canonicalName: "Piper PA-34 Seneca", rarity: .common,
                  modelTokens: ["pa-34", "seneca"], summary: "Six-seat twin. Trainer and light hauler.",
                  representativeTypecode: "PA34"),
            .init(id: "fpa46", canonicalName: "PA-46 / M-Class", rarity: .common,
                  modelTokens: ["pa-46", "malibu", "m350", "m500", "m600", "meridian"],
                  summary: "Pressurized single — Malibu through M600.",
                  representativeTypecode: "PA46"),
            .init(id: "fpa23", canonicalName: "Apache / Aztec / Pawnee", rarity: .common,
                  modelTokens: ["pa-23", "apache", "aztec", "pa-25", "pawnee"],
                  summary: "Vintage Pipers — 50s twins and the cropduster.",
                  representativeTypecode: "PA23"),
            .init(id: "fpa12", canonicalName: "Piper PA-12 Super Cruiser", rarity: .common,
                  modelTokens: ["pa-12 super cruiser", "piper pa-12"],
                  summary: "Postwar cabin descendant of the Cub line.",
                  representativeTypecode: "PA12"),
            .init(id: "fpay2", canonicalName: "Piper Cheyenne II", rarity: .common,
                  modelTokens: ["pa-31t-620 cheyenne", "cheyenne 2", "cheyenne ii"],
                  summary: "Twin-turboprop development of the PA-31 family.",
                  representativeTypecode: "PAY2"),
        ]),
        .init(id: "fam-beech", type: .ga, title: "Beechcraft", entries: [
            .init(id: "fbe36", canonicalName: "Beechcraft Bonanza", rarity: .common,
                  modelTokens: ["bonanza", "be36", "be-36", "be35"], summary: "Iconic single — in production since 1947.",
                  representativeTypecode: "BE36"),
            .init(id: "fbe58", canonicalName: "Beechcraft Baron", rarity: .common,
                  modelTokens: ["baron", "be58", "be-58"], summary: "Cabin-class light twin.",
                  representativeTypecode: "BE58"),
            .init(id: "fbe20", canonicalName: "King Air 200", rarity: .uncommon,
                  modelTokens: ["king air 200", "super king air", "be20", "b200"], summary: "The ubiquitous business turboprop.",
                  representativeTypecode: "BE20"),
            .init(id: "fb350", canonicalName: "King Air 350", rarity: .uncommon,
                  modelTokens: ["king air 350", "b350"], summary: "Stretched King Air.",
                  representativeTypecode: "B350"),
            // DOC 8643 word order is "90/100 King Air" — tokens match that,
            // not the colloquial "King Air 90".
            .init(id: "fbe10", canonicalName: "King Air 90 / 100", rarity: .common,
                  modelTokens: ["90 king air", "100 king air", "king air 90", "king air 100", "be9l"],
                  summary: "The original small King Airs.",
                  representativeTypecode: "BE10"),
            .init(id: "fbe76", canonicalName: "Travel Air / Duchess", rarity: .common,
                  modelTokens: ["travel air", "duchess"],
                  summary: "Beech's classic light twins.",
                  representativeTypecode: "BE76"),
            .init(id: "fbt34", canonicalName: "Beechcraft T-34 Mentor", rarity: .common,
                  modelTokens: ["t-34 mentor", "45 mentor", "beechcraft mentor"],
                  summary: "Military trainer derived from the Bonanza.",
                  representativeTypecode: "T34P"),
        ]),
        .init(id: "fam-diamond", type: .ga, title: "Diamond", entries: [
            .init(id: "fda40", canonicalName: "Diamond DA40", rarity: .common,
                  modelTokens: ["da40", "da-40", "diamond star"], summary: "Composite low-wing trainer.",
                  representativeTypecode: "DA40"),
            .init(id: "fda42", canonicalName: "Diamond DA42", rarity: .common,
                  modelTokens: ["da42", "da-42", "twin star"], summary: "Diesel light twin trainer.",
                  representativeTypecode: "DA42"),
            .init(id: "fda62", canonicalName: "Diamond DA62", rarity: .common,
                  modelTokens: ["da62", "da-62"], summary: "Larger seven-seat twin.",
                  representativeTypecode: "DA62"),
        ]),
        // Rotorcraft finally get a home: 33 heli catches in prod had zero
        // set slots before this (2026-08-12 histogram audit — B407 alone
        // was the single most-caught uncovered typecode at 17).
        .init(id: "fam-heli", type: .ga, title: "Helicopters", entries: [
            .init(id: "fh-r44", canonicalName: "Robinson R44", rarity: .uncommon,
                  modelTokens: ["r44", "robinson"], summary: "Light piston heli. The rotorcraft trainer.",
                  representativeTypecode: "R44"),
            // DOC 8643 names the 206 series "406", so token matching can't
            // key on the model string (bare "406" would also catch a Cessna
            // 406) — the B06 typecode is the reliable identity here.
            .init(id: "fh-b206", canonicalName: "Bell 206", rarity: .uncommon,
                  modelTokens: ["bell 206", "jetranger", "longranger"],
                  summary: "JetRanger / LongRanger. Tours and TV news.",
                  representativeTypecode: "B06"),
            .init(id: "fh-b505", canonicalName: "Bell 505", rarity: .uncommon,
                  modelTokens: ["bell 505", "505 jet ranger x", "jet ranger x"],
                  summary: "Modern light single. Utility, training, and tours.",
                  representativeTypecode: "B505"),
            .init(id: "fh-b407", canonicalName: "Bell 407", rarity: .uncommon,
                  modelTokens: ["bell 407", "b407"], summary: "News, EMS, charter — the utility standard.",
                  representativeTypecode: "B407"),
            .init(id: "fh-b429", canonicalName: "Bell 429", rarity: .uncommon,
                  modelTokens: ["bell 429", "b429", "globalranger"],
                  summary: "Modern light twin. EMS and police.",
                  representativeTypecode: "B429"),
            .init(id: "fh-h500", canonicalName: "MD 500 / 530", rarity: .uncommon,
                  modelTokens: ["md 500", "md500", "md 530", "md530", "hughes 369"],
                  summary: "Compact turbine workhorse. Scout, utility, and film ship.",
                  representativeTypecode: "H500"),
            .init(id: "fh-h125", canonicalName: "Airbus H125", rarity: .uncommon,
                  modelTokens: ["h-125", "h125", "as350", "as 350", "as-350"],
                  summary: "The AStar. Tour and utility single.",
                  representativeTypecode: "AS50"),
            // No "ec-130" token here or on H130 below: Lockheed's EC-130
            // Hercules variant canonicalizes to "EC-130 …" and would bleed in.
            .init(id: "fh-h130", canonicalName: "Airbus H130", rarity: .uncommon,
                  modelTokens: ["h-130", "h130"],
                  summary: "Wide-cabin tour single. Quiet fenestron tail.",
                  representativeTypecode: "EC30"),
            .init(id: "fh-h135", canonicalName: "Airbus H135", rarity: .uncommon,
                  modelTokens: ["h-135", "h135", "ec135", "ec 135", "ec-135"],
                  summary: "Twin-engine EMS staple.",
                  representativeTypecode: "EC35"),
            .init(id: "fh-h145", canonicalName: "Airbus H145", rarity: .uncommon,
                  modelTokens: ["h-145", "h145", "ec145", "ec 145", "ec-145", "bk117", "bk 117"],
                  summary: "Police and rescue twin. Five-blade rotor on the D3.",
                  representativeTypecode: "EC45"),
            .init(id: "fh-s76", canonicalName: "Sikorsky S-76", rarity: .uncommon,
                  modelTokens: ["s-76", "s76"], summary: "Executive and offshore twin.",
                  representativeTypecode: "S76"),
            .init(id: "fh-aw139", canonicalName: "Leonardo AW139", rarity: .uncommon,
                  modelTokens: ["aw139", "aw-139", "aw 139"], summary: "Medium twin. SAR, offshore, VIP.",
                  representativeTypecode: "A139"),
            .init(id: "fh-a109", canonicalName: "Leonardo AW109", rarity: .uncommon,
                  modelTokens: ["a109", "a-109", "aw109", "aw-109"], summary: "Sleek light twin. EMS and VIP.",
                  representativeTypecode: "A109"),
            .init(id: "fh-h160", canonicalName: "Airbus H160", rarity: .uncommon,
                  modelTokens: ["h-160", "h160"], summary: "The newest Airbus medium. Biplane stabilizer.",
                  representativeTypecode: "H160"),
            .init(id: "fh-g2ca", canonicalName: "Guimbal Cabri G2", rarity: .uncommon,
                  modelTokens: ["guimbal cabri", "g-2 cabri", "cabri g2"],
                  summary: "Compact two-seat piston trainer with a fenestron tail.",
                  representativeTypecode: "G2CA"),
        ]),
        .init(id: "fam-bombardier-biz", type: .biz, title: "Bombardier Business Jets", entries: [
            .init(id: "fcl35", canonicalName: "Challenger 350", rarity: .uncommon,
                  modelTokens: ["challenger 3", "cl35", "cl30"], summary: "Super-midsize Challenger.",
                  representativeTypecode: "CL35"),
            .init(id: "fcl60", canonicalName: "Challenger 650", rarity: .uncommon,
                  modelTokens: ["challenger 6", "cl60", "challenger 604", "challenger 650"], summary: "Large-cabin Challenger.",
                  representativeTypecode: "CL60"),
            .init(id: "fglex", canonicalName: "Global 6000", rarity: .rare,
                  modelTokens: ["global 6000", "global express", "glex"], summary: "Long-range Global.",
                  representativeTypecode: "GLEX"),
            .init(id: "fgl5t", canonicalName: "Global 5000", rarity: .rare,
                  modelTokens: ["global 5000", "gl5t"], summary: "Long-range Global with a shorter cabin.",
                  representativeTypecode: "GL5T"),
            .init(id: "fgl7t", canonicalName: "Global 7500", rarity: .rare,
                  modelTokens: ["global 7500", "global 7000", "gl7t"], summary: "Ultra-long-range flagship.",
                  representativeTypecode: "GL7T"),
        ]),
        .init(id: "fam-falcon", type: .biz, title: "Dassault Falcon", entries: [
            .init(id: "ffa50", canonicalName: "Falcon 50", rarity: .uncommon,
                  modelTokens: ["falcon 50", "fa50"], summary: "The first transoceanic Falcon tri-jet.",
                  representativeTypecode: "FA50"),
            .init(id: "ff2th", canonicalName: "Falcon 2000", rarity: .uncommon,
                  modelTokens: ["falcon 2000", "f2th"], summary: "Twin-engine large-cabin Falcon.",
                  representativeTypecode: "F2TH"),
            .init(id: "ff900", canonicalName: "Falcon 900", rarity: .uncommon,
                  modelTokens: ["falcon 900", "f900"], summary: "Three-engine widebody-cabin Falcon.",
                  representativeTypecode: "F900"),
            .init(id: "ffa7x", canonicalName: "Falcon 7X", rarity: .uncommon,
                  modelTokens: ["falcon 7x", "fa7x"], summary: "Tri-jet, fly-by-wire flagship.",
                  representativeTypecode: "FA7X"),
            .init(id: "ffa8x", canonicalName: "Falcon 8X", rarity: .uncommon,
                  modelTokens: ["falcon 8x", "fa8x"], summary: "Longest-range Falcon tri-jet.",
                  representativeTypecode: "FA8X"),
        ]),
        .init(id: "fam-embraer-exec", type: .biz, title: "Embraer Executive", entries: [
            .init(id: "fe50p", canonicalName: "Phenom 100", rarity: .uncommon,
                  modelTokens: ["phenom 100", "e50p"], summary: "Entry-level very-light jet.",
                  representativeTypecode: "E50P"),
            .init(id: "fe55p", canonicalName: "Phenom 300", rarity: .uncommon,
                  modelTokens: ["phenom 300", "e55p"], summary: "Best-selling light jet.",
                  representativeTypecode: "E55P"),
            // "legacy 450"/"e545": the EMB-545 (Legacy 450 → Praetor 500)
            // resolves to canonical "EMB-545 Legacy 450", which none of the
            // old tokens matched — 3 prod catches fell through (2026-08-12).
            .init(id: "fe550", canonicalName: "Praetor 500", rarity: .uncommon,
                  modelTokens: ["praetor", "legacy 500", "legacy 450", "e550", "e545"], summary: "Midsize Embraer business jet.",
                  representativeTypecode: "E550"),
            .init(id: "fe35l", canonicalName: "Legacy 600", rarity: .uncommon,
                  modelTokens: ["legacy 600", "legacy 650", "e35l"], summary: "ERJ-derived large-cabin jet.",
                  representativeTypecode: "E35L"),
        ]),
    ]

    // Third gap chunk (2026-08-24 coverage audit vs. the full prod catch
    // census): turboprops, commuters, military, light/classic bizjets,
    // vintage, and sport types — 49 typecodes (~6% of catches) previously
    // matched NO family set. With these, every type observed in prod lands
    // somewhere; `SetsCoverageTests` pins that against a census snapshot.
    private static let familiesGapC: [CardSet] = [
        .init(id: "fam-turboprop-singles", type: .ga, title: "Turboprop singles", entries: [
            .init(id: "ftp-epic", canonicalName: "Epic LT / E1000", rarity: .rare,
                  modelTokens: ["epic lt", "e1000", "e-1000"],
                  summary: "Carbon-composite speedster. Kit-built LT to certified E1000.",
                  representativeTypecode: "EPIC"),
            .init(id: "ftp-pc12", canonicalName: "Pilatus PC-12", rarity: .uncommon,
                  modelTokens: ["pc-12", "pc12"], summary: "The Swiss do-everything single. Charter king.",
                  representativeTypecode: "PC12"),
            .init(id: "ftp-tbm", canonicalName: "Daher TBM", rarity: .uncommon,
                  modelTokens: ["tbm"], summary: "Fast personal turboprop — 700 through 960.",
                  representativeTypecode: "TBM9"),
            .init(id: "ftp-kodiak", canonicalName: "Kodiak 100", rarity: .common,
                  modelTokens: ["kodiak"], summary: "Short-field utility single. Floats optional.",
                  representativeTypecode: "K100"),
            .init(id: "ftp-beaver", canonicalName: "DHC-2 Beaver", rarity: .common,
                  modelTokens: ["dhc-2", "beaver"], summary: "The classic bush plane. Often on floats.",
                  representativeTypecode: "DHC2"),
        ]),
        .init(id: "fam-commuter-props", type: .regional, title: "Commuter props", entries: [
            .init(id: "fcp-islander", canonicalName: "BN-2 Islander", rarity: .uncommon,
                  modelTokens: ["bn-2", "islander"], summary: "Boxy island-hopper. Ten seats, two pistons.",
                  representativeTypecode: "BN2P"),
            .init(id: "fcp-twinotter", canonicalName: "DHC-6 Twin Otter", rarity: .uncommon,
                  modelTokens: ["dhc-6", "twin otter"], summary: "STOL twin. Skis, floats, gravel bars.",
                  representativeTypecode: "DHC6"),
            .init(id: "fcp-saab340", canonicalName: "Saab 340", rarity: .common,
                  modelTokens: ["saab 340", "sf34"], summary: "Swedish 30-seater. Freight and regionals now.",
                  representativeTypecode: "SF34"),
            .init(id: "fcp-l410", canonicalName: "L-410 Turbolet", rarity: .uncommon,
                  modelTokens: ["l-410", "turbolet"], summary: "Czech 19-seat commuter twin.",
                  representativeTypecode: "L410"),
            .init(id: "fcp-be99", canonicalName: "Beech 99", rarity: .rare,
                  modelTokens: ["99 airliner", "be99"], summary: "Small feeder liner. Cargo runs today.",
                  representativeTypecode: "BE99"),
            .init(id: "fcp-p2012", canonicalName: "Tecnam P-2012 Traveller", rarity: .rare,
                  modelTokens: ["p-2012", "p2012"], summary: "Modern 11-seat commuter twin. A small but growing fleet.",
                  representativeTypecode: "P212"),
        ]),
        .init(id: "fam-military", type: .mil, title: "Military", entries: [
            .init(id: "fm-c130", canonicalName: "C-130 Hercules", rarity: .epic,
                  modelTokens: ["c-130", "hercules"], summary: "Four-turboprop airlifter. Sixty years of Herc.",
                  representativeTypecode: "C130"),
            .init(id: "fm-c17", canonicalName: "C-17 Globemaster", rarity: .epic,
                  modelTokens: ["c-17", "globemaster"], summary: "Heavy airlifter. T-tail, four huge turbofans.",
                  representativeTypecode: "C17"),
            .init(id: "fm-kc135", canonicalName: "KC-135 Stratotanker", rarity: .epic,
                  modelTokens: ["kc-135", "stratotanker", "c-135"], summary: "The 707's tanker sibling. Still everywhere.",
                  representativeTypecode: "K35R"),
            .init(id: "fm-c5", canonicalName: "C-5 Galaxy", rarity: .epic,
                  modelTokens: ["c-5m", "super galaxy"], summary: "The biggest airlifter in the US fleet.",
                  representativeTypecode: "C5M"),
            .init(id: "fm-uh60", canonicalName: "UH-60 Black Hawk", rarity: .epic,
                  modelTokens: ["uh-60", "black hawk", "s-70", "h-60"], summary: "The military utility helicopter.",
                  representativeTypecode: "H60"),
            .init(id: "fm-ch47", canonicalName: "CH-47 Chinook", rarity: .epic,
                  modelTokens: ["ch-47", "chinook", "vertol"], summary: "Tandem-rotor heavy lifter.",
                  representativeTypecode: "H47"),
            .init(id: "fm-hh65", canonicalName: "HH-65 Dolphin", rarity: .uncommon,
                  modelTokens: ["hh-65", "dauphin", "dolphin"], summary: "Coast Guard orange. Fenestron tail.",
                  representativeTypecode: "AS65"),
        ]),
        .init(id: "fam-classic-biz", type: .biz, title: "Classic bizjets", entries: [
            .init(id: "fcb-learjet", canonicalName: "Learjet", rarity: .uncommon,
                  modelTokens: ["learjet"], summary: "THE bizjet name. 35 through 75, all slim and fast.",
                  representativeTypecode: "LJ60"),
            .init(id: "fcb-hawker", canonicalName: "Hawker 800", rarity: .uncommon,
                  modelTokens: ["hawker 8", "800xp", "hs-125", "bae 125"], summary: "British midsize. Decades of the same good shape.",
                  representativeTypecode: "H25B"),
            .init(id: "fcb-beechjet", canonicalName: "Beechjet 400", rarity: .uncommon,
                  modelTokens: ["beechjet", "hawker 400"], summary: "Light twin jet — Mitsubishi design, Wichita badge.",
                  representativeTypecode: "BE40"),
        ]),
        .init(id: "fam-light-jets", type: .biz, title: "Light jets", entries: [
            .init(id: "flj-hondajet", canonicalName: "HondaJet", rarity: .uncommon,
                  modelTokens: ["hondajet", "ha-420"], summary: "Engines over the wing. Yes, that Honda.",
                  representativeTypecode: "HDJT"),
            .init(id: "flj-pc24", canonicalName: "Pilatus PC-24", rarity: .uncommon,
                  modelTokens: ["pc-24", "pc24"], summary: "A jet that lands on grass. Swiss practicality.",
                  representativeTypecode: "PC24"),
            .init(id: "flj-eclipse", canonicalName: "Eclipse 500", rarity: .uncommon,
                  modelTokens: ["eclipse"], summary: "The very-light-jet dream, tiny and efficient.",
                  representativeTypecode: "EA50"),
        ]),
        .init(id: "fam-vintage", type: .heritage, title: "Vintage & warbirds", entries: [
            .init(id: "fv-safir", canonicalName: "Saab 91 Safir", rarity: .rare,
                  modelTokens: ["saab 91", "91 safir"], summary: "Swedish four-seat trainer from the 1940s.",
                  representativeTypecode: "SB91"),
            .init(id: "fv-stearman", canonicalName: "Stearman Kaydet", rarity: .common,
                  modelTokens: ["stearman", "kaydet"], summary: "Open-cockpit biplane trainer. Barnstormer look.",
                  representativeTypecode: "ST75"),
            .init(id: "fv-cub", canonicalName: "Piper Cub", rarity: .common,
                  modelTokens: ["super cub", "j-3 cub", "carbon cub"], summary: "Yellow, slow, beloved. The original trainer.",
                  representativeTypecode: "PA18"),
            .init(id: "fv-dc3", canonicalName: "Douglas DC-3", rarity: .rare,
                  modelTokens: ["dc-3"], summary: "The airliner that made airlines. Still working.",
                  representativeTypecode: "DC3"),
            .init(id: "fv-t6", canonicalName: "T-6 Texan", rarity: .rare,
                  modelTokens: ["texan", "harvard", "at-6"], summary: "WWII advanced trainer. The airshow growl.",
                  representativeTypecode: "T6"),
            // "p-51" only, never "mustang" — the Citation Mustang would
            // bleed into this slot (and vice versa; see fc-mustang).
            .init(id: "fv-p51", canonicalName: "P-51 Mustang", rarity: .rare,
                  modelTokens: ["p-51", "tf-51"], summary: "The WWII fighter. Merlin sound included.",
                  representativeTypecode: "P51"),
        ]),
        .init(id: "fam-sport-classics", type: .ga, title: "Sport & classics", entries: [
            .init(id: "fsc-mooney", canonicalName: "Mooney M20", rarity: .common,
                  modelTokens: ["mooney"], summary: "Backwards tail, forward speed.",
                  representativeTypecode: "M20P"),
            .init(id: "fsc-aa5", canonicalName: "Grumman AA-5", rarity: .common,
                  modelTokens: ["aa-5", "aa-1"], summary: "Sliding-canopy sport tourer.",
                  representativeTypecode: "AA5"),
            .init(id: "fsc-sierra", canonicalName: "Musketeer / Sierra", rarity: .common,
                  modelTokens: ["musketeer", "sierra", "sundowner"], summary: "Beech's friendly low-wing singles.",
                  representativeTypecode: "BE24"),
            .init(id: "fsc-rv", canonicalName: "Van's RV", rarity: .common,
                  modelTokens: ["van's", "rv-"], summary: "The homebuilt that outsold the factories.",
                  representativeTypecode: "RV8"),
            .init(id: "fsc-icon", canonicalName: "Icon A5", rarity: .common,
                  modelTokens: ["icon a-5", "icon a5"], summary: "Folding-wing amphibian jet-ski of the sky.",
                  representativeTypecode: "A5"),
            .init(id: "fsc-tecnam", canonicalName: "Tecnam light aircraft", rarity: .common,
                  modelTokens: ["astore", "p-92", "p-96", "p-2002", "p-2004", "p-2006", "p-2008", "p-2010"],
                  summary: "Italian light singles and twins — trainers, tourers, and sport aircraft.",
                  representativeTypecode: "SIRA"),
            .init(id: "fsc-bristell", canonicalName: "BRM Aero Bristell", rarity: .common,
                  modelTokens: ["brm aero bristell", "ng-5 bristell", "bristell hd"],
                  summary: "Czech all-metal low-wing sport aircraft.",
                  representativeTypecode: "NG5"),
            .init(id: "fsc-cavalon", canonicalName: "AutoGyro Cavalon", rarity: .uncommon,
                  modelTokens: ["autogyro cavalon", "rotorsport cavalon"],
                  summary: "Enclosed side-by-side touring gyroplane.",
                  representativeTypecode: "CLON"),
        ]),
        .init(id: "fam-unidentified", type: .ga, title: "Unidentified aircraft", entries: [
            .init(id: "fu-unidentified", canonicalName: "Unidentified transponder", rarity: .common,
                  modelTokens: [],
                  summary: "A real catch whose transponder identity is privacy-blocked, stale, or not yet present in the aircraft registry.",
                  matchesUnidentified: true),
        ]),
    ]

    /// All make/model family sets — the Sets collection (the only lens).
    static let families: [CardSet] = familiesCore + familiesGapA + familiesGapB + familiesGapC

    /// Slot status for a single entry against a catch list.
    enum SlotStatus: Equatable {
        case locked
        case caught(catchedExample: Catch)
    }

    /// A catch with its three match-relevant strings derived ONCE, up front.
    ///
    /// Why this exists (perf): matching is called for EVERY (catch, entry)
    /// pair — ~60 families × ~5 entries × N catches — and most entries are
    /// locked forever, so each one used to rescan the whole catch list. The
    /// old per-pair `matches(catch:entry:)` re-derived the same per-catch
    /// strings on every one of those scans: an `AircraftNaming.canonical()`
    /// lookup plus a few `.lowercased()` allocations, all of which depend
    /// only on the catch, not the entry. Precomputing them once per catch
    /// (see `matchKeys(for:)`) and reusing the key across every family/entry
    /// collapses tens of thousands of `canonical()` calls into N.
    ///
    /// Holds the `Catch` so `status` can still hand back the filling example.
    /// Deliberately NOT `Sendable` — it wraps a MainActor-bound `Catch`, same
    /// as `SlotStatus.caught` above; it's a within-actor scratch value, never
    /// crosses an actor boundary.
    struct CatchMatchKey {
        /// The catch this key was derived from — returned as the filling
        /// example when a slot matches.
        let source: Catch
        /// Raw `c.typecode`, UNMODIFIED. The precise path compares it with
        /// `caseInsensitiveCompare`, so we keep the original casing and let
        /// the comparison normalize — bit-for-bit as the per-pair path did.
        let typecode: String?
        /// `c.model?.lowercased() ?? ""` — the lowercased raw model string.
        let rawModelLowercased: String
        /// `AircraftNaming.canonical(...).displayName?.lowercased() ?? ""`.
        let canonicalLowercased: String
    }

    /// Derive a `CatchMatchKey` for one catch — the single place the per-catch
    /// strings are computed. `matches(catch:entry:)` and `matchKeys(for:)` both
    /// route through this, so there's exactly one copy of the derivation.
    nonisolated static func matchKey(for c: Catch) -> CatchMatchKey {
        CatchMatchKey(
            source: c,
            typecode: c.typecode,
            rawModelLowercased: c.model?.lowercased() ?? "",
            canonicalLowercased: AircraftNaming.canonical(
                typecode: c.typecode,
                manufacturer: c.manufacturer,
                model: c.model
            ).displayName?.lowercased() ?? ""
        )
    }

    /// Derive the match keys for a whole catch list in ONE pass. Order is
    /// preserved (a plain `map`), so the keyed `status` below reproduces the
    /// same first-match-wins result as scanning `catches` directly.
    nonisolated static func matchKeys(for catches: [Catch]) -> [CatchMatchKey] {
        catches.map(matchKey(for:))
    }

    /// Keyed twin of `matches(catch:entry:)` — the actual decision, reading
    /// the precomputed strings instead of re-deriving them per pair. Semantics
    /// are bit-for-bit identical to the legacy `[Catch]` path.
    ///
    /// Precise path (added for family sets, 2026-06-15): exact ICAO typecode
    /// equality. Family lenses distinguish variants the model string can't
    /// (A320 vs A320neo, 777-300 vs 777-300ER) — the typecode is the
    /// unambiguous variant identity, and the backend resolves it for virtually
    /// every airliner. This is a UNION with the token path below (membership
    /// can only gain), so existing type-set behavior is unchanged for
    /// token-matched catches.
    nonisolated static func matches(key: CatchMatchKey, entry: CardSetEntry) -> Bool {
        if entry.matchesUnidentified {
            return (key.typecode?.isEmpty ?? true)
                && key.rawModelLowercased.isEmpty
                && key.canonicalLowercased.isEmpty
        }
        if let tc = entry.representativeTypecode,
           let ctc = key.typecode,
           !ctc.isEmpty,
           tc.caseInsensitiveCompare(ctc) == .orderedSame {
            return true
        }
        guard !key.rawModelLowercased.isEmpty || !key.canonicalLowercased.isEmpty else { return false }
        return entry.modelTokens.contains { token in
            let t = token.lowercased()
            return key.rawModelLowercased.contains(t) || key.canonicalLowercased.contains(t)
        }
    }

    /// True when the catch's model matches any of the entry's `modelTokens` —
    /// checked against BOTH the raw OpenSky model string AND the canonical name
    /// (typecode-resolved). Union, not replacement: membership can only gain
    /// from canonicalization, never lose. Single source of truth for Catch →
    /// CardSetEntry. Thin wrapper: builds a one-catch key, then delegates to
    /// `matches(key:entry:)` (the decision lives there).
    nonisolated static func matches(catch c: Catch, entry: CardSetEntry) -> Bool {
        matches(key: matchKey(for: c), entry: entry)
    }

    /// Walk a single set's entries against precomputed keys. First matching
    /// key (in key order) fills the slot — same first-match-wins rule as the
    /// `[Catch]` overload, since `matchKeys(for:)` preserves order.
    static func status(of set: CardSet, againstKeys keys: [CatchMatchKey]) -> [(CardSetEntry, SlotStatus)] {
        set.entries.map { entry in
            let hit = keys.first { matches(key: $0, entry: entry) }
            return (entry, hit.map { SlotStatus.caught(catchedExample: $0.source) } ?? .locked)
        }
    }

    /// "N caught out of M" from precomputed keys.
    static func progress(of set: CardSet, againstKeys keys: [CatchMatchKey]) -> (caught: Int, total: Int) {
        let s = status(of: set, againstKeys: keys)
        return (s.filter { if case .caught = $0.1 { return true } else { return false } }.count, s.count)
    }

    /// Walk a single set's entries and resolve each against the caught planes.
    /// First matching catch (by `modelTokens` substring on `c.model`) fills the
    /// slot. Thin wrapper over the keyed overload — fine for one-off callers;
    /// callers that evaluate MANY sets against the SAME catches should build
    /// `matchKeys(for:)` once and use `status(of:againstKeys:)` to avoid
    /// rederiving per-catch strings for each set.
    static func status(of set: CardSet, against catches: [Catch]) -> [(CardSetEntry, SlotStatus)] {
        status(of: set, againstKeys: matchKeys(for: catches))
    }

    /// "N caught out of M" for the set browser tile. Thin wrapper — see the
    /// note on `status(of:against:)` about batching many sets via keys.
    static func progress(of set: CardSet, against catches: [Catch]) -> (caught: Int, total: Int) {
        progress(of: set, againstKeys: matchKeys(for: catches))
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
