//
//  Trophies.swift
//  Tailspot
//
//  Achievement / trophy system. Each achievement is a multi-tier
//  ladder (bronze / silver / gold / platinum) climbed by hitting
//  threshold values derived from the user's caught planes. The
//  current tier is the highest threshold whose `at` value the
//  user's progress equals or exceeds; the next tier is the lowest
//  threshold strictly above progress.
//
//  Trophy progression is a *derived* state — computed from the
//  Hangar contents, not persisted separately. That keeps the spec
//  simple (no out-of-sync drift between "you have X trophies" and
//  "you have N catches") and makes the implementation testable as
//  a pure function.
//

import Foundation

// MARK: - Tiers

/// Trophy tier (the "metal" of the trophy). Bronze → Silver → Gold
/// → Platinum, in ascending order of unlock difficulty.
nonisolated enum TrophyTier: String, CaseIterable, Equatable, Sendable {
    case bronze
    case silver
    case gold
    case platinum

    /// Display label rendered under or beside the trophy.
    var label: String {
        switch self {
        case .bronze:   return "BRONZE"
        case .silver:   return "SILVER"
        case .gold:     return "GOLD"
        case .platinum: return "PLATINUM"
        }
    }

    /// Outer-ring color (the metal itself).
    var outerHex: UInt32 {
        switch self {
        case .bronze:   return 0xC26B3F
        case .silver:   return 0xC5D0DA
        case .gold:     return 0xFFC74A
        case .platinum: return 0xA9F4FF
        }
    }

    /// Inner well color (dark metal, paired with the outer ring).
    var innerHex: UInt32 {
        switch self {
        case .bronze:   return 0x7D3F1F
        case .silver:   return 0x6C7986
        case .gold:     return 0x9C6E00
        case .platinum: return 0x005A73
        }
    }

    /// Rank index, ascending: bronze=0 … platinum=3. Used by the unlock
    /// ledger to compare "tier you've been shown" against current tier.
    var ordinal: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

// MARK: - Achievement definitions

/// One step on a multi-tier achievement ladder.
nonisolated struct AchievementTier: Equatable, Sendable {
    let tier: TrophyTier
    /// Threshold value: progress must equal or exceed this to unlock.
    let at: Int
}

/// A single achievement family. Most have multiple tiers; some are
/// one-shots that only unlock at a single threshold + tier.
nonisolated struct Achievement: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let summary: String
    /// Maps to a SwiftUI icon shape in `TrophyIcon`.
    let iconName: String
    /// Tiers in ascending order of `at`.
    let tiers: [AchievementTier]

    /// Secret achievements show as a locked `???` placeholder (no name or
    /// details) until earned, then reveal with a moment. Non-secret
    /// achievements show their real identity. Defaults to false (visible).
    let secret: Bool

    /// For milestone chains (Catcher → Centurion → Sky Veteran): the id of the
    /// achievement that must be earned before this one appears in the list, so
    /// later milestones stay hidden until the prior is complete. nil = no
    /// prerequisite (always visible). Ignored for secret achievements.
    let prerequisite: String?

    /// The progress metric this achievement tracks. Resolved against
    /// a `TrophyProgressInputs` value (totals derived from the Hangar
    /// contents) at evaluation time. Marked `@Sendable` because
    /// `Achievement` claims Sendable conformance; the closures in
    /// `Trophies.all` only read fields off the passed-in inputs (no
    /// captured state), so they're trivially Sendable in practice.
    let progress: @Sendable (TrophyProgressInputs) -> Int

    /// Explicit init so `secret` can default — and sits *before* the trailing
    /// `progress` closure, keeping `Achievement(... progress: { ... })` call
    /// sites tidy.
    init(
        id: String,
        title: String,
        summary: String,
        iconName: String,
        tiers: [AchievementTier],
        secret: Bool = false,
        prerequisite: String? = nil,
        progress: @escaping @Sendable (TrophyProgressInputs) -> Int
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.iconName = iconName
        self.tiers = tiers
        self.secret = secret
        self.prerequisite = prerequisite
        self.progress = progress
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// All the totals an achievement might want to read, pre-computed
/// once over the Hangar so each per-achievement evaluation is O(1).
nonisolated struct TrophyProgressInputs: Sendable {
    let totalCatches: Int
    let uniqueAirframes: Int
    let wideBodyCatches: Int
    let regionalCatches: Int
    let heritageCatches: Int
    let rareTierCatches: Int        // strictly .rare
    let epicTierCatches: Int        // strictly .epic
    let legendaryTierCatches: Int   // strictly .legendary
    let rarePlusUnique: Int         // unique icao24 at .rare or higher
    let longestSlantKm: Double
    /// Captured-N-planes-in-one-frame moments. v1 has no multi-catch
    /// mechanic yet; this is 0 until that ships.
    let bestMultiCatchCount: Int
    /// Caught between civil dusk and civil dawn (placeholder — v1
    /// approximates by "caughtAt local hour 20–6"; refine later with
    /// proper solar-position calc).
    let nightCatches: Int
    // Metrics added with the trophy-roster expansion (2026-06-16). Defaulted
    // in the initializer so the existing call sites (tests, `.zero`) compile
    // unchanged.
    let narrowBodyCatches: Int      // resolved type == .narrow
    let uniqueOperators: Int        // distinct non-empty operator names
    let uniquePlaces: Int           // distinct non-empty catch locations
    let completedSets: Int          // fully-collected make/model families
    let distinctDays: Int           // distinct calendar days with a catch
    // Metrics added with the trophies/unlock-moments round (2026-06-20).
    // Defaulted in the initializer so existing call sites compile unchanged.
    let distinctCountries: Int      // distinct non-empty observer countries
    let farCatchCount: Int          // catches at slant distance >= 25 km
    let redEyeCatches: Int          // caughtAt hour in [2, 5)
    let bestBurstWithinTenMin: Int  // max catches inside any 10-min window
    let hasRepeatAirframeAcrossDays: Bool  // an icao24 caught on >= 2 days
    let longestDayStreak: Int       // longest run of consecutive catch-days
    // Metrics added with the 2026-06-21 trophy expansion.
    let caughtTags: Set<String>     // aircraft tags (heavymetal, freighter, …)
    let highestAltitudeM: Double    // max recorded catch altitude (m)
    let fastestVelocityMps: Double  // max recorded catch ground speed (m/s)
    let bestCatchesInOneDay: Int    // most catches in any single day
    let dayPartsCovered: Int        // distinct of {night, morning, afternoon, evening}
    // Metrics added with the 2026-06-21 second trophy batch.
    let lowestAltitudeM: Double     // min recorded catch altitude (m); .greatestFiniteMagnitude if none
    let maxCatchesAtOnePlace: Int   // most catches at any single place
    let distinctTypes: Int          // distinct resolved aircraft types
    let weekendDaysHit: Int         // distinct weekend days caught on (0–2)
    let hadDawnCatch: Bool          // a catch in the 4–7 AM window
    let hadConsecutiveSameOperator: Bool  // two time-adjacent catches, same airline

    init(
        totalCatches: Int,
        uniqueAirframes: Int,
        wideBodyCatches: Int,
        regionalCatches: Int,
        heritageCatches: Int,
        rareTierCatches: Int,
        epicTierCatches: Int,
        legendaryTierCatches: Int,
        rarePlusUnique: Int,
        longestSlantKm: Double,
        bestMultiCatchCount: Int,
        nightCatches: Int,
        narrowBodyCatches: Int = 0,
        uniqueOperators: Int = 0,
        uniquePlaces: Int = 0,
        completedSets: Int = 0,
        distinctDays: Int = 0,
        distinctCountries: Int = 0,
        farCatchCount: Int = 0,
        redEyeCatches: Int = 0,
        bestBurstWithinTenMin: Int = 0,
        hasRepeatAirframeAcrossDays: Bool = false,
        longestDayStreak: Int = 0,
        caughtTags: Set<String> = [],
        highestAltitudeM: Double = 0,
        fastestVelocityMps: Double = 0,
        bestCatchesInOneDay: Int = 0,
        dayPartsCovered: Int = 0,
        lowestAltitudeM: Double = .greatestFiniteMagnitude,
        maxCatchesAtOnePlace: Int = 0,
        distinctTypes: Int = 0,
        weekendDaysHit: Int = 0,
        hadDawnCatch: Bool = false,
        hadConsecutiveSameOperator: Bool = false
    ) {
        self.totalCatches = totalCatches
        self.uniqueAirframes = uniqueAirframes
        self.wideBodyCatches = wideBodyCatches
        self.regionalCatches = regionalCatches
        self.heritageCatches = heritageCatches
        self.rareTierCatches = rareTierCatches
        self.epicTierCatches = epicTierCatches
        self.legendaryTierCatches = legendaryTierCatches
        self.rarePlusUnique = rarePlusUnique
        self.longestSlantKm = longestSlantKm
        self.bestMultiCatchCount = bestMultiCatchCount
        self.nightCatches = nightCatches
        self.narrowBodyCatches = narrowBodyCatches
        self.uniqueOperators = uniqueOperators
        self.uniquePlaces = uniquePlaces
        self.completedSets = completedSets
        self.distinctDays = distinctDays
        self.distinctCountries = distinctCountries
        self.farCatchCount = farCatchCount
        self.redEyeCatches = redEyeCatches
        self.bestBurstWithinTenMin = bestBurstWithinTenMin
        self.hasRepeatAirframeAcrossDays = hasRepeatAirframeAcrossDays
        self.longestDayStreak = longestDayStreak
        self.caughtTags = caughtTags
        self.highestAltitudeM = highestAltitudeM
        self.fastestVelocityMps = fastestVelocityMps
        self.bestCatchesInOneDay = bestCatchesInOneDay
        self.dayPartsCovered = dayPartsCovered
        self.lowestAltitudeM = lowestAltitudeM
        self.maxCatchesAtOnePlace = maxCatchesAtOnePlace
        self.distinctTypes = distinctTypes
        self.weekendDaysHit = weekendDaysHit
        self.hadDawnCatch = hadDawnCatch
        self.hadConsecutiveSameOperator = hadConsecutiveSameOperator
    }

    static let zero = TrophyProgressInputs(
        totalCatches: 0, uniqueAirframes: 0,
        wideBodyCatches: 0, regionalCatches: 0, heritageCatches: 0,
        rareTierCatches: 0, epicTierCatches: 0, legendaryTierCatches: 0,
        rarePlusUnique: 0, longestSlantKm: 0,
        bestMultiCatchCount: 0, nightCatches: 0
    )
}

// MARK: - The roster

nonisolated enum Trophies {

    /// Full achievement roster. Every achievement is BINARY — earned or not,
    /// no tier ramp (the single `.gold` tier only drives the uniform hex
    /// color). Count families are split into separate milestone achievements
    /// (Noah, 2026-06-20). `secret: true` ones are absent from the list until
    /// earned; the rest are always visible so the user can chase them.
    static let roster: [Achievement] = [
        // ── Catch count ──
        Achievement(id: "firstcatch", title: "First Catch", summary: "Catch your first plane",
                    iconName: "catcher", tiers: [.init(tier: .gold, at: 1)],
                    progress: { $0.totalCatches }),
        Achievement(id: "spotter", title: "Plane Spotter", summary: "Reach 5 catches",
                    iconName: "catcher", tiers: [.init(tier: .gold, at: 5)],
                    prerequisite: "firstcatch", progress: { $0.totalCatches }),
        Achievement(id: "catcher", title: "Catcher", summary: "Reach 25 catches",
                    iconName: "catcher", tiers: [.init(tier: .gold, at: 25)],
                    prerequisite: "spotter", progress: { $0.totalCatches }),
        Achievement(id: "centurion", title: "Centurion", summary: "Reach 100 catches",
                    iconName: "centurion", tiers: [.init(tier: .gold, at: 100)],
                    prerequisite: "catcher", progress: { $0.totalCatches }),
        Achievement(id: "veteran", title: "Sky Veteran", summary: "Reach 500 catches",
                    iconName: "catcher", tiers: [.init(tier: .gold, at: 500)],
                    prerequisite: "centurion", progress: { $0.totalCatches }),

        // ── Wide-body ──
        Achievement(id: "heavy", title: "Wide Awake", summary: "Catch 10 wide-bodies",
                    iconName: "widebody", tiers: [.init(tier: .gold, at: 10)],
                    progress: { $0.wideBodyCatches }),
        Achievement(id: "heavy2", title: "Heavy Hitter", summary: "Catch 50 wide-bodies",
                    iconName: "widebody", tiers: [.init(tier: .gold, at: 50)],
                    prerequisite: "heavy", progress: { $0.wideBodyCatches }),

        // ── Narrow-body ──
        Achievement(id: "narrow", title: "Single Aisle", summary: "Catch 25 narrow-bodies",
                    iconName: "narrowbody", tiers: [.init(tier: .gold, at: 25)],
                    progress: { $0.narrowBodyCatches }),
        Achievement(id: "narrow2", title: "Workhorse", summary: "Catch 120 narrow-bodies",
                    iconName: "narrowbody", tiers: [.init(tier: .gold, at: 120)],
                    prerequisite: "narrow", progress: { $0.narrowBodyCatches }),

        // ── Regional ──
        Achievement(id: "regional", title: "Regional Pilot", summary: "Catch 15 regional jets",
                    iconName: "regional", tiers: [.init(tier: .gold, at: 15)],
                    progress: { $0.regionalCatches }),
        Achievement(id: "regional2", title: "Puddle Jumper", summary: "Catch 60 regional jets",
                    iconName: "regional", tiers: [.init(tier: .gold, at: 60)],
                    prerequisite: "regional", progress: { $0.regionalCatches }),

        // ── Unique airframes ──
        Achievement(id: "world", title: "Collector", summary: "Catalogue 25 unique airframes",
                    iconName: "world", tiers: [.init(tier: .gold, at: 25)],
                    progress: { $0.uniqueAirframes }),
        Achievement(id: "world2", title: "World Tour", summary: "Catalogue 100 unique airframes",
                    iconName: "world", tiers: [.init(tier: .gold, at: 100)],
                    prerequisite: "world", progress: { $0.uniqueAirframes }),

        // ── Airlines ──
        Achievement(id: "airlines", title: "Frequent Flyer", summary: "Collect 10 airlines",
                    iconName: "ticket", tiers: [.init(tier: .gold, at: 10)],
                    progress: { $0.uniqueOperators }),
        Achievement(id: "airlines2", title: "Airline Buff", summary: "Collect 30 airlines",
                    iconName: "ticket", tiers: [.init(tier: .gold, at: 30)],
                    prerequisite: "airlines", progress: { $0.uniqueOperators }),

        // ── Places ──
        Achievement(id: "places", title: "Globetrotter", summary: "Spot from 10 locations",
                    iconName: "coast", tiers: [.init(tier: .gold, at: 10)],
                    progress: { $0.uniquePlaces }),
        Achievement(id: "places2", title: "Wanderer", summary: "Spot from 25 locations",
                    iconName: "coast", tiers: [.init(tier: .gold, at: 25)],
                    prerequisite: "places", progress: { $0.uniquePlaces }),

        // ── Sets ──
        Achievement(id: "setcollector", title: "Set Collector", summary: "Complete 3 sets",
                    iconName: "setmaster", tiers: [.init(tier: .gold, at: 3)],
                    progress: { $0.completedSets }),
        Achievement(id: "setmaster", title: "Set Master", summary: "Complete 8 sets",
                    iconName: "setmaster", tiers: [.init(tier: .gold, at: 8)],
                    prerequisite: "setcollector", progress: { $0.completedSets }),

        // ── Rare-or-better airframes ──
        Achievement(id: "rarehunter", title: "Rare Hunter", summary: "Find 5 rare-or-better airframes",
                    iconName: "gems", tiers: [.init(tier: .gold, at: 5)],
                    progress: { $0.rarePlusUnique }),
        Achievement(id: "rarehunter2", title: "Treasure Hunter", summary: "Find 25 rare-or-better airframes",
                    iconName: "gems", tiers: [.init(tier: .gold, at: 25)],
                    prerequisite: "rarehunter", progress: { $0.rarePlusUnique }),

        // ── Days out ──
        Achievement(id: "regular", title: "Regular", summary: "Catch on 10 different days",
                    iconName: "calendar", tiers: [.init(tier: .gold, at: 10)],
                    progress: { $0.distinctDays }),
        Achievement(id: "devotee", title: "Devotee", summary: "Catch on 40 different days",
                    iconName: "calendar", tiers: [.init(tier: .gold, at: 40)],
                    prerequisite: "regular", progress: { $0.distinctDays }),

        // ── Night ──
        Achievement(id: "night", title: "Night Owl", summary: "Catch 5 after sundown",
                    iconName: "night", tiers: [.init(tier: .gold, at: 5)],
                    progress: { $0.nightCatches }),
        Achievement(id: "night2", title: "Nocturnal", summary: "Catch 25 after sundown",
                    iconName: "night", tiers: [.init(tier: .gold, at: 25)],
                    prerequisite: "night", progress: { $0.nightCatches }),

        // ── Heritage ──
        Achievement(id: "heritage", title: "Heritage", summary: "Catch a heritage aircraft",
                    iconName: "heritage", tiers: [.init(tier: .gold, at: 1)],
                    progress: { $0.heritageCatches }),
        Achievement(id: "heritage2", title: "Living History", summary: "Catch 5 heritage aircraft",
                    iconName: "heritage", tiers: [.init(tier: .gold, at: 5)],
                    prerequisite: "heritage", progress: { $0.heritageCatches }),

        // ── Rarity one-shots ──
        Achievement(id: "firstrare", title: "First Rare", summary: "Catch a rare-tier plane",
                    iconName: "diamond", tiers: [.init(tier: .gold, at: 1)],
                    progress: { min(1, $0.rareTierCatches) }),
        Achievement(id: "epic", title: "Epic Encounter", summary: "Catch an epic-tier plane",
                    iconName: "sparkle", tiers: [.init(tier: .gold, at: 1)],
                    progress: { min(1, $0.epicTierCatches) }),
        Achievement(id: "legendary", title: "Legendary", summary: "Catch a legendary plane",
                    iconName: "crown", tiers: [.init(tier: .gold, at: 1)],
                    progress: { min(1, $0.legendaryTierCatches) }),

        // ── Catch-a-kind (visible goals) ──
        Achievement(id: "heavymetal", title: "Heavy Metal", summary: "Catch a 747 or A380",
                    iconName: "jumbo", tiers: [.init(tier: .gold, at: 1)],
                    progress: { $0.caughtTags.contains("heavymetal") ? 1 : 0 }),
        Achievement(id: "freighter", title: "Heavy Hauler", summary: "Catch a freighter",
                    iconName: "cargo", tiers: [.init(tier: .gold, at: 1)],
                    progress: { $0.caughtTags.contains("freighter") ? 1 : 0 }),
        Achievement(id: "bizjet", title: "Business Class", summary: "Catch a business jet",
                    iconName: "bizjet", tiers: [.init(tier: .gold, at: 1)],
                    progress: { $0.caughtTags.contains("bizjet") ? 1 : 0 }),
        Achievement(id: "turboprop", title: "Spinning Props", summary: "Catch a turboprop",
                    iconName: "prop", tiers: [.init(tier: .gold, at: 1)],
                    progress: { $0.caughtTags.contains("turboprop") ? 1 : 0 }),

        // ── Collection / habit (visible) ──
        Achievement(id: "varietypack", title: "Variety Pack", summary: "Catch 5 different aircraft types",
                    iconName: "grid", tiers: [.init(tier: .gold, at: 5)],
                    progress: { $0.distinctTypes }),
        Achievement(id: "fulldeck", title: "Full Deck", summary: "Catch all 7 aircraft types",
                    iconName: "grid", tiers: [.init(tier: .gold, at: 7)],
                    prerequisite: "varietypack", progress: { $0.distinctTypes }),
        Achievement(id: "homebody", title: "Homebody", summary: "10 catches from one spot",
                    iconName: "home", tiers: [.init(tier: .gold, at: 10)],
                    progress: { $0.maxCatchesAtOnePlace }),

        // ── Secret — absent from the list until earned, then they appear. ──
        Achievement(id: "mrworldwide", title: "Mr. Worldwide", summary: "Caught planes in 2+ countries",
                    iconName: "worldwide", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.distinctCountries >= 2 ? 1 : 0 }),
        Achievement(id: "hattrick", title: "Hat Trick", summary: "Three catches within ten minutes",
                    iconName: "hattrick", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.bestBurstWithinTenMin >= 3 ? 1 : 0 }),
        Achievement(id: "redeye", title: "Red Eye", summary: "A catch between 2 and 5 AM",
                    iconName: "eye", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { min(1, $0.redEyeCatches) }),
        Achievement(id: "repeat", title: "Repeat Customer", summary: "Caught the same airframe on two days",
                    iconName: "repeat", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.hasRepeatAirframeAcrossDays ? 1 : 0 }),
        Achievement(id: "streak", title: "Streak", summary: "Caught planes seven days in a row",
                    iconName: "streak", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.longestDayStreak >= 7 ? 1 : 0 }),
        Achievement(id: "longshot", title: "Long Lens", summary: "Five catches past 25 km",
                    iconName: "longlens", tiers: [.init(tier: .gold, at: 5)], secret: true,
                    progress: { $0.farCatchCount }),
        Achievement(id: "multi", title: "Constellation", summary: "Catch 2+ planes in one frame",
                    iconName: "constellation", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.bestMultiCatchCount >= 2 ? 1 : 0 }),
        Achievement(id: "quintet", title: "Quintet", summary: "Catch 5 planes in one frame",
                    iconName: "quintet", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.bestMultiCatchCount >= 5 ? 1 : 0 }),
        Achievement(id: "military", title: "Brass Hat", summary: "Catch a military aircraft",
                    iconName: "star", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.caughtTags.contains("military") ? 1 : 0 }),
        Achievement(id: "helicopter", title: "Whirlybird", summary: "Catch a helicopter",
                    iconName: "heli", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.caughtTags.contains("helicopter") ? 1 : 0 }),
        Achievement(id: "milehigh", title: "Mile High", summary: "Catch one above 40,000 ft",
                    iconName: "altitude", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.highestAltitudeM >= 12_000 ? 1 : 0 }),
        Achievement(id: "speeddemon", title: "Speed Demon", summary: "Catch one doing 600+ mph",
                    iconName: "speed", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.fastestVelocityMps >= 268 ? 1 : 0 }),
        Achievement(id: "marathon", title: "Marathon", summary: "Catch 10 planes in one day",
                    iconName: "stack", tiers: [.init(tier: .gold, at: 10)], secret: true,
                    progress: { $0.bestCatchesInOneDay }),
        Achievement(id: "aroundclock", title: "Around the Clock", summary: "Catch in all four parts of the day",
                    iconName: "clock", tiers: [.init(tier: .gold, at: 4)], secret: true,
                    progress: { $0.dayPartsCovered }),
        Achievement(id: "ondeck", title: "On the Deck", summary: "Catch one below 3,000 ft",
                    iconName: "approach", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.lowestAltitudeM <= 1000 ? 1 : 0 }),
        Achievement(id: "weekend", title: "Weekend Warrior", summary: "Catch on a Saturday and a Sunday",
                    iconName: "weekend", tiers: [.init(tier: .gold, at: 2)], secret: true,
                    progress: { $0.weekendDaysHit }),
        Achievement(id: "dawn", title: "Dawn Patrol", summary: "A catch between 4 and 7 AM",
                    iconName: "sunrise", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.hadDawnCatch ? 1 : 0 }),
        Achievement(id: "doubleheader", title: "Doubleheader", summary: "Two of the same airline in a row",
                    iconName: "twin", tiers: [.init(tier: .gold, at: 1)], secret: true,
                    progress: { $0.hadConsecutiveSameOperator ? 1 : 0 }),
    ]

    // MARK: - Evaluation

    /// Compute the input totals from a flat list of catches.
    static func inputs(from catches: [Catch]) -> TrophyProgressInputs {
        var unique = Set<String>()
        var rarePlusUnique = Set<String>()
        var operators = Set<String>()
        var places = Set<String>()
        var days = Set<Date>()
        var countries = Set<String>()
        var wide = 0, narrow = 0, regional = 0, heritage = 0
        var rare = 0, epic = 0, legendary = 0
        var longest: Double = 0
        var night = 0, far = 0, redEye = 0
        var tags = Set<String>()
        var highestAlt: Double = 0, fastestVel: Double = 0
        var lowestAlt = Double.greatestFiniteMagnitude
        var dayCounts: [Date: Int] = [:]   // catches per day → best-in-day
        var dayParts = Set<String>()       // distinct {night, morning, afternoon, evening}
        var placeCounts: [String: Int] = [:]  // catches per place → best-at-one-place
        var types = Set<String>()          // distinct resolved aircraft types
        var weekendDays = Set<Int>()       // distinct weekend weekdays caught on
        var hadDawn = false
        var opTimeline: [(Date, String)] = []  // (time, operator) → consecutive check
        // Per-airframe day set (repeat-customer) and all catch timestamps
        // (burst) — derived after the loop.
        var icaoDays: [String: Set<Date>] = [:]
        var timestamps: [Date] = []
        let calendar = Calendar(identifier: .gregorian)

        for c in catches {
            unique.insert(c.icao24)
            let r = c.resolvedRarity
            let t = c.resolvedType
            switch r {
            case .rare:      rare += 1; rarePlusUnique.insert(c.icao24)
            case .epic:      epic += 1; rarePlusUnique.insert(c.icao24)
            case .legendary: legendary += 1; rarePlusUnique.insert(c.icao24)
            default: break
            }
            switch t {
            case .narrow:   narrow += 1
            case .wide:     wide += 1
            case .regional: regional += 1
            case .heritage: heritage += 1
            default: break
            }
            if let op = c.operatorName?.trimmingCharacters(in: .whitespacesAndNewlines), !op.isEmpty {
                operators.insert(op)
                opTimeline.append((c.caughtAt, op.lowercased()))
            }
            if let place = c.placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
                places.insert(place)
                placeCounts[place, default: 0] += 1
            }
            if let country = c.country?.trimmingCharacters(in: .whitespacesAndNewlines), !country.isEmpty {
                countries.insert(country)
            }
            let day = calendar.startOfDay(for: c.caughtAt)
            days.insert(day)
            dayCounts[day, default: 0] += 1
            icaoDays[c.icao24, default: []].insert(day)
            timestamps.append(c.caughtAt)
            let km = c.slantDistanceMeters / 1000
            if km > longest { longest = km }
            if km >= 25 { far += 1 }
            let hour = calendar.component(.hour, from: c.caughtAt)
            if hour >= 20 || hour < 6 { night += 1 }
            if hour >= 2 && hour < 5 { redEye += 1 }
            dayParts.insert(dayPart(forHour: hour))
            if hour >= 4 && hour < 7 { hadDawn = true }
            tags.formUnion(aircraftTags(model: c.model, manufacturer: c.manufacturer,
                                        typecode: c.typecode, operatorName: c.operatorName, type: t))
            types.insert(t.rawValue)
            if let alt = c.altitudeMeters {
                if alt > highestAlt { highestAlt = alt }
                if alt > 0 && alt < lowestAlt { lowestAlt = alt }  // skip ground/bad zeros
            }
            if let vel = c.velocityMps, vel > fastestVel { fastestVel = vel }
            let weekday = calendar.component(.weekday, from: c.caughtAt)
            if weekday == 1 || weekday == 7 { weekendDays.insert(weekday) }
        }

        // Repeat customer: any airframe caught on two or more distinct days.
        let hasRepeat = icaoDays.values.contains { $0.count >= 2 }
        // Hat Trick: most catches inside any 10-minute (600 s) sliding window.
        let bestBurst = maxCountWithinWindow(timestamps, seconds: 600)
        // Streak: longest run of consecutive calendar days with a catch.
        let longestStreak = longestConsecutiveDayRun(days, calendar: calendar)
        // Doubleheader: two time-adjacent catches share an operator.
        let consecutiveOp = hasConsecutiveSameOperator(opTimeline)

        // Fully-collected make/model families — drives the Set Master trophy.
        let completedSets = CardSets.families.reduce(into: 0) { acc, set in
            let p = CardSets.progress(of: set, against: catches)
            if p.total > 0 && p.caught == p.total { acc += 1 }
        }

        return TrophyProgressInputs(
            totalCatches: catches.count,
            uniqueAirframes: unique.count,
            wideBodyCatches: wide,
            regionalCatches: regional,
            heritageCatches: heritage,
            rareTierCatches: rare,
            epicTierCatches: epic,
            legendaryTierCatches: legendary,
            rarePlusUnique: rarePlusUnique.count,
            longestSlantKm: longest,
            bestMultiCatchCount: 0,
            nightCatches: night,
            narrowBodyCatches: narrow,
            uniqueOperators: operators.count,
            uniquePlaces: places.count,
            completedSets: completedSets,
            distinctDays: days.count,
            distinctCountries: countries.count,
            farCatchCount: far,
            redEyeCatches: redEye,
            bestBurstWithinTenMin: bestBurst,
            hasRepeatAirframeAcrossDays: hasRepeat,
            longestDayStreak: longestStreak,
            caughtTags: tags,
            highestAltitudeM: highestAlt,
            fastestVelocityMps: fastestVel,
            bestCatchesInOneDay: dayCounts.values.max() ?? 0,
            dayPartsCovered: dayParts.count,
            lowestAltitudeM: lowestAlt,
            maxCatchesAtOnePlace: placeCounts.values.max() ?? 0,
            distinctTypes: types.count,
            weekendDaysHit: weekendDays.count,
            hadDawnCatch: hadDawn,
            hadConsecutiveSameOperator: consecutiveOp
        )
    }

    /// True if any two time-adjacent catches share the same operator
    /// (Doubleheader). Sorts the (time, operator) timeline and scans neighbors.
    static func hasConsecutiveSameOperator(_ timeline: [(Date, String)]) -> Bool {
        let sorted = timeline.sorted { $0.0 < $1.0 }
        for i in 1..<max(1, sorted.count) where i < sorted.count {
            if sorted[i].1 == sorted[i - 1].1 { return true }
        }
        return false
    }

    /// Which part of the day an hour falls in (for the Around the Clock trophy).
    static func dayPart(forHour hour: Int) -> String {
        switch hour {
        case 5..<12:  return "morning"
        case 12..<17: return "afternoon"
        case 17..<21: return "evening"
        default:      return "night"
        }
    }

    /// Heuristic aircraft tags derived from a catch's metadata — drives the
    /// "catch a <kind>" trophies. Tags are coarse and intentionally generous
    /// (a catch can carry several).
    static func aircraftTags(
        model: String?, manufacturer: String?, typecode: String?,
        operatorName: String?, type: AircraftType
    ) -> Set<String> {
        var tags = Set<String>()
        let hay = "\(model ?? "") \(manufacturer ?? "") \(typecode ?? "")".lowercased()
        let op = (operatorName ?? "").lowercased()

        // Iconic four-engine giants.
        if hay.contains("747") || hay.contains("a380") || hay.contains("a340") {
            tags.insert("heavymetal")
        }
        // Freighters — cargo operator, or an explicit freighter model.
        let cargoOps = ["fedex", "ups", "atlas", "cargolux", "dhl", "cargo",
                        "kalitta", "abx", "amerijet", "western global", "polar air", "national air"]
        if cargoOps.contains(where: { op.contains($0) })
            || hay.contains("freighter") || hay.contains("-f ") || hay.hasSuffix("f")
            || hay.contains("bcf") || hay.contains("scf") {
            tags.insert("freighter")
        }
        // Turboprops.
        let props = ["dash 8", "dhc-8", "q400", "atr ", "atr-", "king air", "pc-12", "pc12",
                     "caravan", "c208", "saab 340", "saab 2000", "do 228", "twin otter", "metroliner"]
        if props.contains(where: { hay.contains($0) }) { tags.insert("turboprop") }
        // Helicopters.
        let heli = ["helicopter", "robinson", "sikorsky", "eurocopter", "airbus helicopters",
                    "bell ", "agusta", "leonardo heli", "md helicopter", "enstrom",
                    "r44", "r66", "ec1", "as35", "h125", "h135", "h145", "uh-", "ah-", "ch-"]
        if heli.contains(where: { hay.contains($0) }) { tags.insert("helicopter") }
        // Type-derived.
        if type == .mil { tags.insert("military") }
        if type == .biz { tags.insert("bizjet") }
        return tags
    }

    /// Max number of timestamps inside any sliding window of `seconds`.
    /// Two-pointer over the sorted sequence: each timestamp is a candidate
    /// window start, so a burst spanning a fixed-bucket boundary still
    /// counts. O(n log n) sort + O(n) sweep — cheap enough for the per-render
    /// `inputs(from:)` even at hundreds of catches.
    static func maxCountWithinWindow(_ times: [Date], seconds: TimeInterval) -> Int {
        guard !times.isEmpty else { return 0 }
        let sorted = times.sorted()
        var best = 1
        var i = 0
        for j in sorted.indices {
            while sorted[j].timeIntervalSince(sorted[i]) > seconds { i += 1 }
            best = max(best, j - i + 1)
        }
        return best
    }

    /// Longest run of consecutive calendar days present in `days` (a set of
    /// start-of-day dates), using the SAME calendar as the day-bucketing so
    /// boundaries don't disagree across metrics.
    static func longestConsecutiveDayRun(_ days: Set<Date>, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var best = 1
        var run = 1
        for k in 1..<sorted.count {
            if let next = calendar.date(byAdding: .day, value: 1, to: sorted[k - 1]),
               calendar.isDate(next, inSameDayAs: sorted[k]) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
        }
        return best
    }
}

// MARK: - Per-achievement evaluation

extension Achievement {

    /// The single threshold this binary achievement is earned at.
    var threshold: Int { tiers.first?.at ?? 1 }

    /// Earned once progress reaches the threshold. Every achievement is a
    /// single binary bar now (no tier ramp).
    func isEarned(inputs: TrophyProgressInputs) -> Bool {
        currentProgress(inputs: inputs) >= threshold
    }

    /// A one-shot milestone with no meaningful count to display (threshold 1).
    var isOneShot: Bool { tiers.count == 1 }

    /// Current value of the progress metric.
    func currentProgress(inputs: TrophyProgressInputs) -> Int {
        progress(inputs)
    }

    /// Highest tier whose threshold the user has met, or nil if
    /// none have been reached yet.
    func currentTier(inputs: TrophyProgressInputs) -> TrophyTier? {
        let p = currentProgress(inputs: inputs)
        var unlocked: TrophyTier?
        for step in tiers where p >= step.at {
            unlocked = step.tier
        }
        return unlocked
    }

    /// Next tier still to reach, or nil when all tiers are unlocked.
    func nextTier(inputs: TrophyProgressInputs) -> AchievementTier? {
        let p = currentProgress(inputs: inputs)
        return tiers.first { p < $0.at }
    }

    /// True when no tier has been unlocked yet.
    func isLocked(inputs: TrophyProgressInputs) -> Bool {
        currentTier(inputs: inputs) == nil
    }
}
