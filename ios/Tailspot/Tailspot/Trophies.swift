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

    /// Hidden ("secret") awards render as a `???` mystery card with their
    /// `teaser` until earned; on earn, the real title/summary is revealed.
    /// Non-hidden awards always show their real identity. Defaults to false.
    let hidden: Bool
    /// Vague hint shown on the mystery card while a `hidden` award is locked
    /// (e.g. "Three in a hurry"). Ignored for non-hidden awards.
    let teaser: String?

    /// The progress metric this achievement tracks. Resolved against
    /// a `TrophyProgressInputs` value (totals derived from the Hangar
    /// contents) at evaluation time. Marked `@Sendable` because
    /// `Achievement` claims Sendable conformance; the closures in
    /// `Trophies.all` only read fields off the passed-in inputs (no
    /// captured state), so they're trivially Sendable in practice.
    let progress: @Sendable (TrophyProgressInputs) -> Int

    /// Explicit init so `hidden`/`teaser` can default — and so they sit
    /// *before* the trailing `progress` closure, keeping every existing
    /// `Achievement(... progress: { ... })` call site source-compatible.
    init(
        id: String,
        title: String,
        summary: String,
        iconName: String,
        tiers: [AchievementTier],
        hidden: Bool = false,
        teaser: String? = nil,
        progress: @escaping @Sendable (TrophyProgressInputs) -> Int
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.iconName = iconName
        self.tiers = tiers
        self.hidden = hidden
        self.teaser = teaser
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
        longestDayStreak: Int = 0
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
            summary: "Catches farther than 25 km",
            iconName: "longlens",
            tiers: [
                .init(tier: .bronze, at: 1),
                .init(tier: .silver, at: 5),
                .init(tier: .gold,   at: 15),
            ],
            // Counts catches at >= 25 km (inside the < 30 km visibility cap so
            // they actually register) — was a capped 0/1 that could never
            // reach silver/gold.
            progress: { $0.farCatchCount }
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
            // Hidden-dormant: bestMultiCatchCount is hardcoded 0 until the
            // multi-catch mechanic + frame-count stamping ship (PLAN §9 #5).
            // Rendered as a `???` mystery card rather than visibly-locked.
            hidden: true,
            teaser: "More than one at a time…",
            progress: { max(0, $0.bestMultiCatchCount >= 2 ? 1 : 0) }
        ),
        Achievement(
            id: "quintet", title: "Quintet",
            summary: "Five planes in a single frame",
            iconName: "quintet",
            tiers: [.init(tier: .gold, at: 1)],
            // Hidden-dormant alongside Constellation (see above).
            hidden: true,
            teaser: "A whole formation at once…",
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

        // ── Hidden "secret" badges (2026-06-20) — render as `???` mystery
        //    cards until earned, then reveal. Deliberately hard/rare. ──
        Achievement(
            id: "mrworldwide", title: "Mr. Worldwide",
            summary: "Caught planes in 2+ countries",
            iconName: "world",
            tiers: [.init(tier: .gold, at: 1)],
            hidden: true,
            teaser: "Catch under more than one flag.",
            progress: { $0.distinctCountries >= 2 ? 1 : 0 }
        ),
        Achievement(
            id: "hattrick", title: "Hat Trick",
            summary: "Three catches within ten minutes",
            iconName: "sparkle",
            tiers: [.init(tier: .silver, at: 1)],
            hidden: true,
            teaser: "Three in a hurry.",
            progress: { $0.bestBurstWithinTenMin >= 3 ? 1 : 0 }
        ),
        Achievement(
            id: "redeye", title: "Red Eye",
            summary: "A catch between 2 and 5 AM",
            iconName: "night",
            tiers: [.init(tier: .bronze, at: 1)],
            hidden: true,
            teaser: "Caught something at a strange hour.",
            progress: { min(1, $0.redEyeCatches) }
        ),
        Achievement(
            id: "repeat", title: "Repeat Customer",
            summary: "Caught the same airframe on two days",
            iconName: "ticket",
            tiers: [.init(tier: .bronze, at: 1)],
            hidden: true,
            teaser: "Some planes come back around.",
            progress: { $0.hasRepeatAirframeAcrossDays ? 1 : 0 }
        ),
        Achievement(
            id: "streak", title: "Streak",
            summary: "Caught planes seven days in a row",
            iconName: "calendar",
            tiers: [.init(tier: .gold, at: 1)],
            hidden: true,
            teaser: "Keep showing up.",
            progress: { $0.longestDayStreak >= 7 ? 1 : 0 }
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
        var countries = Set<String>()
        var wide = 0, narrow = 0, regional = 0, heritage = 0
        var rare = 0, epic = 0, legendary = 0
        var longest: Double = 0
        var night = 0, far = 0, redEye = 0
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
            }
            if let place = c.placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
                places.insert(place)
            }
            if let country = c.country?.trimmingCharacters(in: .whitespacesAndNewlines), !country.isEmpty {
                countries.insert(country)
            }
            let day = calendar.startOfDay(for: c.caughtAt)
            days.insert(day)
            icaoDays[c.icao24, default: []].insert(day)
            timestamps.append(c.caughtAt)
            let km = c.slantDistanceMeters / 1000
            if km > longest { longest = km }
            if km >= 25 { far += 1 }
            let hour = calendar.component(.hour, from: c.caughtAt)
            if hour >= 20 || hour < 6 { night += 1 }
            if hour >= 2 && hour < 5 { redEye += 1 }
        }

        // Repeat customer: any airframe caught on two or more distinct days.
        let hasRepeat = icaoDays.values.contains { $0.count >= 2 }
        // Hat Trick: most catches inside any 10-minute (600 s) sliding window.
        let bestBurst = maxCountWithinWindow(timestamps, seconds: 600)
        // Streak: longest run of consecutive calendar days with a catch.
        let longestStreak = longestConsecutiveDayRun(days, calendar: calendar)

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
            longestDayStreak: longestStreak
        )
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

    /// A one-shot ("1 of 1") award: a single milestone you either have or
    /// don't — rendered as a **Badge**. Multi-tier awards level up through
    /// bronze → platinum and are rendered as **Medals**.
    var isOneShot: Bool { tiers.count == 1 }
    var isLeveled: Bool { tiers.count > 1 }

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
