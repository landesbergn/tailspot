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

    /// The progress metric this achievement tracks. Resolved against
    /// a `TrophyProgressInputs` value (totals derived from the Hangar
    /// contents) at evaluation time. Marked `@Sendable` because
    /// `Achievement` claims Sendable conformance; the closures in
    /// `Trophies.all` only read fields off the passed-in inputs (no
    /// captured state), so they're trivially Sendable in practice.
    let progress: @Sendable (TrophyProgressInputs) -> Int

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
        distinctDays: Int = 0
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

    /// Full achievement roster. Mirrors the design canvas's
    /// `ACHIEVEMENTS` array; thresholds match.
    static let roster: [Achievement] = [
        Achievement(
            id: "catcher", title: "Catcher",
            summary: "Catches accumulated",
            iconName: "catcher",
            tiers: [
                .init(tier: .bronze,   at: 10),
                .init(tier: .silver,   at: 50),
                .init(tier: .gold,     at: 250),
                .init(tier: .platinum, at: 1000),
            ],
            progress: { $0.totalCatches }
        ),
        Achievement(
            id: "heavy", title: "Wide Awake",
            summary: "Wide-body airframes caught",
            iconName: "widebody",
            tiers: [
                .init(tier: .bronze, at: 5),
                .init(tier: .silver, at: 20),
                .init(tier: .gold,   at: 50),
            ],
            progress: { $0.wideBodyCatches }
        ),
        Achievement(
            id: "regional", title: "Regional Pilot",
            summary: "Regional jets caught",
            iconName: "regional",
            tiers: [
                .init(tier: .bronze, at: 10),
                .init(tier: .silver, at: 30),
                .init(tier: .gold,   at: 75),
            ],
            progress: { $0.regionalCatches }
        ),
        Achievement(
            id: "longshot", title: "Long Lens",
            summary: "Catches farther than 30 km",
            iconName: "longlens",
            tiers: [
                .init(tier: .bronze, at: 1),
                .init(tier: .silver, at: 5),
                .init(tier: .gold,   at: 15),
            ],
            progress: { Int($0.longestSlantKm >= 30 ? 1 : 0) }
        ),
        Achievement(
            id: "world", title: "World Tour",
            summary: "Unique airframes catalogued",
            iconName: "world",
            tiers: [
                .init(tier: .bronze, at: 5),
                .init(tier: .silver, at: 25),
                .init(tier: .gold,   at: 100),
            ],
            progress: { $0.uniqueAirframes }
        ),
        Achievement(
            id: "multi", title: "Constellation",
            summary: "Multi-catches (2+ in frame)",
            iconName: "constellation",
            tiers: [
                .init(tier: .bronze, at: 1),
                .init(tier: .silver, at: 5),
                .init(tier: .gold,   at: 20),
            ],
            progress: { max(0, $0.bestMultiCatchCount >= 2 ? 1 : 0) }
        ),
        Achievement(
            id: "quintet", title: "Quintet",
            summary: "Five planes in a single frame",
            iconName: "quintet",
            tiers: [.init(tier: .gold, at: 1)],
            progress: { $0.bestMultiCatchCount >= 5 ? 1 : 0 }
        ),
        Achievement(
            id: "firstrare", title: "First Rare",
            summary: "Catch any rare-tier plane",
            iconName: "diamond",
            tiers: [.init(tier: .silver, at: 1)],
            progress: { min(1, $0.rareTierCatches) }
        ),
        Achievement(
            id: "epic", title: "Epic Encounter",
            summary: "Catch an epic-tier plane",
            iconName: "sparkle",
            tiers: [.init(tier: .gold, at: 1)],
            progress: { min(1, $0.epicTierCatches) }
        ),
        Achievement(
            id: "legendary", title: "Legendary",
            summary: "Catch a legendary plane",
            iconName: "crown",
            tiers: [.init(tier: .platinum, at: 1)],
            progress: { min(1, $0.legendaryTierCatches) }
        ),
        Achievement(
            id: "centurion", title: "Centurion",
            summary: "Reach 100 catches",
            iconName: "centurion",
            tiers: [.init(tier: .gold, at: 100)],
            progress: { $0.totalCatches }
        ),
        Achievement(
            id: "heritage", title: "Heritage",
            summary: "Catch a heritage / special-mission aircraft",
            iconName: "heritage",
            tiers: [
                .init(tier: .bronze, at: 1),
                .init(tier: .gold,   at: 5),
            ],
            progress: { $0.heritageCatches }
        ),
        Achievement(
            id: "night", title: "Night Owl",
            summary: "Catches after sundown",
            iconName: "night",
            tiers: [
                .init(tier: .bronze, at: 3),
                .init(tier: .silver, at: 15),
            ],
            progress: { $0.nightCatches }
        ),
        Achievement(
            id: "narrow", title: "Single Aisle",
            summary: "Narrow-body airframes caught",
            iconName: "narrowbody",
            tiers: [
                .init(tier: .bronze, at: 10),
                .init(tier: .silver, at: 40),
                .init(tier: .gold,   at: 120),
            ],
            progress: { $0.narrowBodyCatches }
        ),
        Achievement(
            id: "airlines", title: "Frequent Flyer",
            summary: "Different airlines collected",
            iconName: "ticket",
            tiers: [
                .init(tier: .bronze, at: 5),
                .init(tier: .silver, at: 15),
                .init(tier: .gold,   at: 30),
            ],
            progress: { $0.uniqueOperators }
        ),
        Achievement(
            id: "places", title: "Globetrotter",
            summary: "Spotting locations visited",
            iconName: "coast",
            tiers: [
                .init(tier: .bronze, at: 3),
                .init(tier: .silver, at: 10),
                .init(tier: .gold,   at: 25),
            ],
            progress: { $0.uniquePlaces }
        ),
        Achievement(
            id: "setmaster", title: "Set Master",
            summary: "Make/model sets completed",
            iconName: "setmaster",
            tiers: [
                .init(tier: .bronze, at: 1),
                .init(tier: .silver, at: 3),
                .init(tier: .gold,   at: 8),
            ],
            progress: { $0.completedSets }
        ),
        Achievement(
            id: "rarehunter", title: "Rare Hunter",
            summary: "Distinct rare-or-better airframes",
            iconName: "gems",
            tiers: [
                .init(tier: .bronze,   at: 1),
                .init(tier: .silver,   at: 5),
                .init(tier: .gold,     at: 20),
                .init(tier: .platinum, at: 50),
            ],
            progress: { $0.rarePlusUnique }
        ),
        Achievement(
            id: "regular", title: "Regular",
            summary: "Days out catching",
            iconName: "calendar",
            tiers: [
                .init(tier: .bronze, at: 3),
                .init(tier: .silver, at: 10),
                .init(tier: .gold,   at: 30),
            ],
            progress: { $0.distinctDays }
        ),
    ]

    // MARK: - Evaluation

    /// Compute the input totals from a flat list of catches.
    static func inputs(from catches: [Catch]) -> TrophyProgressInputs {
        var unique = Set<String>()
        var rarePlusUnique = Set<String>()
        var operators = Set<String>()
        var places = Set<String>()
        var days = Set<Date>()
        var wide = 0, narrow = 0, regional = 0, heritage = 0
        var rare = 0, epic = 0, legendary = 0
        var longest: Double = 0
        var night = 0
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
            }
            if let place = c.placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
                places.insert(place)
            }
            days.insert(calendar.startOfDay(for: c.caughtAt))
            let km = c.slantDistanceMeters / 1000
            if km > longest { longest = km }
            let hour = calendar.component(.hour, from: c.caughtAt)
            if hour >= 20 || hour < 6 { night += 1 }
        }

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
            distinctDays: days.count
        )
    }
}

// MARK: - Per-achievement evaluation

extension Achievement {

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
