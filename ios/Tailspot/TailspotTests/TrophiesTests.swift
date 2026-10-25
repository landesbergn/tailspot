//
//  TrophiesTests.swift
//  TailspotTests
//
//  Pin the trophy roster + the `Trophies.inputs(from:)` aggregator
//  + per-achievement `currentTier`/`nextTier`/`isLocked` evaluation
//  so a tier-threshold tweak can't silently relabel achievements
//  the user already earned.
//
//  All inputs are synthetic Catches built inline (no SwiftData
//  container required) since Catch has a public init.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Trophies")
@MainActor
struct TrophiesTests {

    // MARK: - Catch builder

    /// Compact helper for terse tests. Resolved type falls out of the
    /// classifier (or the typecode table) when not specified. Resolved
    /// RARITY comes only from the typecode table or defaults to `.common`
    /// (single-source rule, U3) — pass `typecode:` to land a specific tier.
    private func mk(
        model: String? = nil,
        manufacturer: String? = nil,
        operatorName: String? = nil,
        typecode: String? = nil,
        slantKm: Double = 1.0,
        caughtAt: Date = Date(timeIntervalSince1970: 1_716_000_000)
    ) -> Catch {
        Catch(
            icao24: UUID().uuidString.prefix(6).lowercased(),
            callsign: nil,
            model: model,
            manufacturer: manufacturer,
            operatorName: operatorName,
            caughtAt: caughtAt,
            observerLat: 37.87,
            observerLon: -122.27,
            slantDistanceMeters: slantKm * 1000,
            typecode: typecode
        )
    }

    // MARK: - Inputs aggregator

    @Test func zeroInputsFromEmpty() {
        let inputs = Trophies.inputs(from: [])
        #expect(inputs.totalCatches == 0)
        #expect(inputs.uniqueAirframes == 0)
        #expect(inputs.rarePlusUnique == 0)
        #expect(inputs.wideBodyCatches == 0)
        #expect(inputs.legendaryTierCatches == 0)
        #expect(inputs.longestSlantKm == 0)
    }

    @Test func inputsCountWideBodiesByResolvedType() {
        // A350 + 787 + A380 are .wide; 737 + A320 are .narrow.
        let catches: [Catch] = [
            mk(model: "A350-941",   manufacturer: "AIRBUS"),
            mk(model: "787-9",      manufacturer: "BOEING"),
            mk(model: "A380-800",   manufacturer: "AIRBUS"),
            mk(model: "737-800",    manufacturer: "BOEING"),
            mk(model: "A320-271N",  manufacturer: "AIRBUS"),
        ]
        let inputs = Trophies.inputs(from: catches)
        #expect(inputs.wideBodyCatches == 3)
        #expect(inputs.totalCatches == 5)
    }

    @Test func inputsCountRegionalByResolvedType() {
        let catches: [Catch] = [
            mk(model: "E175-200LR", manufacturer: "EMBRAER"),
            mk(model: "CRJ-700",    manufacturer: "BOMBARDIER"),
            mk(model: "737-800",    manufacturer: "BOEING"),
        ]
        let inputs = Trophies.inputs(from: catches)
        #expect(inputs.regionalCatches == 2)
    }

    @Test func inputsCountTierCatchesSeparately() {
        // Tier now resolves ONLY from the typecode table (single-source rule, U3),
        // so each tier-bearing catch carries a real typecode rather than relying
        // on the removed string-classifier rarity ladder.
        let catches: [Catch] = [
            mk(model: "747-8",   manufacturer: "BOEING",   typecode: "B748"), // epic
            mk(model: "747-400", manufacturer: "BOEING",   typecode: "B744"), // rare (scarce widebody)
            mk(model: "B-2",     manufacturer: "NORTHROP", typecode: "B2"),   // legendary
            mk(model: "737-800", manufacturer: "BOEING",   typecode: "B738"), // common
        ]
        let inputs = Trophies.inputs(from: catches)
        #expect(inputs.rareTierCatches == 1)
        #expect(inputs.epicTierCatches == 1)
        #expect(inputs.legendaryTierCatches == 1)
        // All three rare+ — but each is a different airframe.
        #expect(inputs.rarePlusUnique == 3)
    }

    @Test func longestSlantPicksMax() {
        let catches: [Catch] = [
            mk(slantKm:  5),
            mk(slantKm: 18),
            mk(slantKm: 31),
            mk(slantKm: 12),
        ]
        #expect(Trophies.inputs(from: catches).longestSlantKm == 31)
    }

    @Test func nightCatchesUseLocalHourBoundary() {
        // Production reads Calendar.current — so the test must too,
        // or we'd fail on any non-UTC machine. We construct dates at
        // specific *local* hours so the .hour component round-trips
        // through the same calendar the classifier reads.
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        let nightHour = cal.date(byAdding: .hour, value: 23, to: base)!
        let earlyHour = cal.date(byAdding: .hour, value:  3, to: base)!
        let dayHour   = cal.date(byAdding: .hour, value: 12, to: base)!
        let catches = [mk(caughtAt: nightHour), mk(caughtAt: earlyHour), mk(caughtAt: dayHour)]
        // Both 23 and 3 are in the night window (>= 20 or < 6);
        // 12 is squarely day. Production should count exactly 2.
        #expect(Trophies.inputs(from: catches).nightCatches == 2)
    }

    // MARK: - Per-achievement evaluation

    @Test func catcherEarnsAtTwentyFive() {
        let catcher = Trophies.roster.first { $0.id == "catcher" }!
        let twentyFour = Trophies.inputs(from: (0..<24).map { _ in mk(model: "737-800", manufacturer: "BOEING") })
        #expect(catcher.isEarned(inputs: twentyFour) == false)
        let twentyFive = Trophies.inputs(from: (0..<25).map { _ in mk(model: "737-800", manufacturer: "BOEING") })
        #expect(catcher.isEarned(inputs: twentyFive))
        #expect(catcher.threshold == 25)
    }

    @Test func legendaryEarnsAtOneLegendaryCatch() {
        let legendary = Trophies.roster.first { $0.id == "legendary" }!
        #expect(legendary.isEarned(inputs: .zero) == false)
        // A legendary-tier catch now resolves via the typecode table (B2 →
        // .legendary), not the removed string-classifier rarity ladder.
        let one = Trophies.inputs(from: [mk(model: "B-2", manufacturer: "NORTHROP", typecode: "B2")])
        #expect(legendary.isEarned(inputs: one))
    }

    @Test func everyAchievementIsBinarySingleTier() {
        // Binary model: each achievement has exactly one threshold (no ramp).
        for ach in Trophies.roster {
            #expect(ach.tiers.count == 1, "\(ach.id) should be single-tier (binary)")
        }
    }

    @Test func rosterIsNotEmptyAndHasUniqueIDs() {
        // Sanity: a typo'd duplicate id would break the ForEach on
        // Trophies screen (Identifiable identity collision).
        let ids = Trophies.roster.map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count, "Duplicate achievement ID(s) in roster")
    }
}

@Suite("CardSets")
@MainActor
struct CardSetsTests {

    private func mk(model: String, manufacturer: String? = nil) -> Catch {
        Catch(
            icao24: UUID().uuidString.prefix(6).lowercased(),
            callsign: nil,
            model: model,
            manufacturer: manufacturer,
            operatorName: nil,
            caughtAt: Date(timeIntervalSince1970: 1_716_000_000),
            observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0
        )
    }

    @Test func emptyCatchesAllSlotsLocked() {
        for set in CardSets.all {
            let result = CardSets.status(of: set, against: [])
            #expect(result.allSatisfy { if case .locked = $0.1 { return true } else { return false } })
        }
    }

    @Test func boeing787CatchFillsWideBodySlot() {
        let wide = CardSets.all.first { $0.id == "wide" }!
        let result = CardSets.status(of: wide, against: [mk(model: "787-9", manufacturer: "BOEING")])
        let entry = result.first { $0.0.id == "w-787" }
        #expect(entry != nil)
        if case .caught = entry!.1 { /* good */ } else {
            Issue.record("787 slot didn't fill from a Boeing 787-9 catch")
        }
        // Other wide slots stay locked.
        let other = result.first { $0.0.id == "w-a380" }!
        if case .locked = other.1 { /* good */ } else {
            Issue.record("A380 slot incorrectly marked caught")
        }
    }

    @Test func a380FillsWideBodyA380Slot() {
        let wide = CardSets.all.first { $0.id == "wide" }!
        let result = CardSets.status(of: wide, against: [mk(model: "A380-800", manufacturer: "AIRBUS")])
        let entry = result.first { $0.0.id == "w-a380" }!
        if case .caught = entry.1 { /* good */ } else {
            Issue.record("A380 slot didn't fill")
        }
    }

    @Test func progressCountsCaughtSlots() {
        let wide = CardSets.all.first { $0.id == "wide" }!
        let catches: [Catch] = [
            mk(model: "787-9"),
            mk(model: "A350-941"),
            mk(model: "777-300ER"),
        ]
        let progress = CardSets.progress(of: wide, against: catches)
        #expect(progress.caught == 3)
        #expect(progress.total == wide.entries.count)
    }

    @Test func wrongSetWontFill() {
        // A 737 should fill a narrow slot, not a wide slot.
        let wide = CardSets.all.first { $0.id == "wide" }!
        let result = CardSets.status(of: wide, against: [mk(model: "737-800", manufacturer: "BOEING")])
        #expect(result.allSatisfy { if case .locked = $0.1 { return true } else { return false } })

        let narrow = CardSets.all.first { $0.id == "narrow" }!
        let narrowResult = CardSets.status(of: narrow, against: [mk(model: "737-800")])
        let entry737 = narrowResult.first { $0.0.id == "n-737-800" }!
        if case .caught = entry737.1 { /* good */ } else {
            Issue.record("737 didn't fill narrow 737-800 slot")
        }
    }

    @Test func caseInsensitiveModelMatching() {
        // Substring match folds case.
        let narrow = CardSets.all.first { $0.id == "narrow" }!
        let lower = CardSets.status(of: narrow, against: [mk(model: "737-800")])
        let upper = CardSets.status(of: narrow, against: [mk(model: "BOEING 737-800")])
        let lowerCaught = lower.first { $0.0.id == "n-737-800" }!
        let upperCaught = upper.first { $0.0.id == "n-737-800" }!
        if case .caught = lowerCaught.1, case .caught = upperCaught.1 {
            // both filled
        } else {
            Issue.record("Case-insensitive match failed")
        }
    }

    @Test func setIDsAreUnique() {
        let setIDs = CardSets.all.map(\.id)
        #expect(Set(setIDs).count == setIDs.count, "Duplicate CardSet id(s)")
        for set in CardSets.all {
            let entryIDs = set.entries.map(\.id)
            #expect(Set(entryIDs).count == entryIDs.count,
                    "Duplicate entry id(s) in set \(set.id)")
        }
    }
}

// MARK: - 2026-06-20 round: new metrics + hidden trophies

@Suite("Trophies — hidden trophies + 2026-06-20 metrics")
@MainActor
struct TrophiesHiddenAndMetricsTests {

    /// Production buckets days/hours with a gregorian calendar; the tests do
    /// too so day/hour boundaries agree exactly.
    private let cal = Calendar(identifier: .gregorian)

    /// A date `dayOffset` days from a fixed base, at `hour` local time.
    private func date(dayOffset: Int = 0, hour: Int = 12) -> Date {
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        let shifted = cal.date(byAdding: .day, value: dayOffset, to: base)!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: shifted)!
    }

    private func mk(icao: String = String(UUID().uuidString.prefix(6)).lowercased(),
                    slantKm: Double = 1, country: String? = nil,
                    at: Date = Date(timeIntervalSince1970: 1_716_000_000)) -> Catch {
        Catch(
            icao24: icao, callsign: nil, model: nil, manufacturer: nil,
            caughtAt: at, observerLat: 0, observerLon: 0,
            slantDistanceMeters: slantKm * 1000, country: country
        )
    }

    private func ach(_ id: String) -> Achievement {
        Trophies.roster.first { $0.id == id }!
    }

    // MARK: - Pure window/streak helpers

    @Test func burstSlidesAcrossBucketBoundary() {
        // 0 / 8 / 9 minutes all fall in one 10-min window → 3.
        let times = [date(hour: 0), date(hour: 0).addingTimeInterval(8 * 60), date(hour: 0).addingTimeInterval(9 * 60)]
        #expect(Trophies.maxCountWithinWindow(times, seconds: 600) == 3)
    }

    @Test func burstFixedBucketsWouldUndercount() {
        // 0 / 6 / 12 minutes: no 10-min window holds all three → 2.
        let t0 = date(hour: 0)
        let times = [t0, t0.addingTimeInterval(6 * 60), t0.addingTimeInterval(12 * 60)]
        #expect(Trophies.maxCountWithinWindow(times, seconds: 600) == 2)
        #expect(Trophies.maxCountWithinWindow([], seconds: 600) == 0)
    }

    /// The trophy layer no longer owns a day-run implementation: it reads
    /// `Streaks`, so the secret 7-day trophy and the Profile streak card can
    /// never disagree about the same Hangar. Pin that they're one number.
    @Test func trophyDayStreakReadsTheStreakEngine() {
        // A gap breaks the run: 0,1, [skip 2], 3 → longest is 2.
        let gapped = [date(dayOffset: 0), date(dayOffset: 1), date(dayOffset: 3)].map { mk(at: $0) }
        #expect(Trophies.inputs(from: gapped).longestDayStreak == 2)
        #expect(Trophies.inputs(from: gapped).longestDayStreak
                == Streaks.longestStreak(days: Streaks.daySet(catches: gapped)))
    }

    // MARK: - inputs(from:) metrics

    @Test func distinctCountriesCountsNonEmpty() {
        let inputs = Trophies.inputs(from: [
            mk(country: "US"), mk(country: "CA"), mk(country: "US"), mk(country: nil), mk(country: "  "),
        ])
        #expect(inputs.distinctCountries == 2)
    }

    @Test func farCatchCountAtTwentyFiveKm() {
        let inputs = Trophies.inputs(from: [mk(slantKm: 26), mk(slantKm: 24), mk(slantKm: 25)])
        #expect(inputs.farCatchCount == 2)  // 26 and 25 qualify, 24 doesn't
    }

    @Test func redEyeCountsTwoToFiveAM() {
        let inputs = Trophies.inputs(from: [
            mk(at: date(hour: 3)), mk(at: date(hour: 12)), mk(at: date(hour: 2)), mk(at: date(hour: 5)),
        ])
        #expect(inputs.redEyeCatches == 2)  // 03:00 and 02:00; 05:00 and 12:00 excluded
    }

    @Test func repeatAirframeAcrossDays() {
        let twoDays = Trophies.inputs(from: [
            mk(icao: "aaa111", at: date(dayOffset: 0)), mk(icao: "aaa111", at: date(dayOffset: 1)),
        ])
        #expect(twoDays.hasRepeatAirframeAcrossDays)
        let sameDay = Trophies.inputs(from: [
            mk(icao: "bbb222", at: date(dayOffset: 0, hour: 9)), mk(icao: "bbb222", at: date(dayOffset: 0, hour: 14)),
        ])
        #expect(sameDay.hasRepeatAirframeAcrossDays == false)
    }

    @Test func longestStreakSevenConsecutive() {
        let catches = (0..<7).map { mk(at: date(dayOffset: $0)) }
        #expect(Trophies.inputs(from: catches).longestDayStreak == 7)
    }

    // MARK: - New trophies

    @Test func mrWorldwideSecretEarnsAtTwoCountries() {
        let trophy = ach("mrworldwide")
        #expect(trophy.secret)
        #expect(trophy.isEarned(inputs: Trophies.inputs(from: [mk(country: "US")])) == false)
        #expect(trophy.isEarned(inputs: Trophies.inputs(from: [mk(country: "US"), mk(country: "CA")])))
    }

    @Test func streakSecretEarnsAtSevenLockedAtSix() {
        let trophy = ach("streak")
        #expect(trophy.secret)
        let six = Trophies.inputs(from: (0..<6).map { mk(at: date(dayOffset: $0)) })
        let seven = Trophies.inputs(from: (0..<7).map { mk(at: date(dayOffset: $0)) })
        #expect(trophy.isEarned(inputs: six) == false)
        #expect(trophy.isEarned(inputs: seven))
    }

    @Test func longLensSecretEarnsAtFiveFarCatches() {
        let trophy = ach("longshot")
        #expect(trophy.secret)
        #expect(trophy.isEarned(inputs: Trophies.inputs(from: (0..<4).map { _ in mk(slantKm: 26) })) == false)
        #expect(trophy.isEarned(inputs: Trophies.inputs(from: (0..<5).map { _ in mk(slantKm: 26) })))
    }

    @Test func constellationAndQuintetAreSecretAndPressGated() {
        // Ten catches seconds apart: plenty of planes, but never two in one
        // press, so neither multi-catch trophy can unlock.
        let apart = (0..<10).map { mk(at: date(hour: 12).addingTimeInterval(Double($0) * 5)) }
        for id in ["multi", "quintet"] {
            let trophy = ach(id)
            #expect(trophy.secret)
            #expect(trophy.isEarned(inputs: Trophies.inputs(from: apart)) == false)
        }
        // Two distinct airframes in ONE press (shared caughtAt) earn
        // Constellation; Quintet still needs five.
        let pair = [mk(at: date(hour: 12)), mk(at: date(hour: 12))]
        #expect(ach("multi").isEarned(inputs: Trophies.inputs(from: pair)))
        #expect(ach("quintet").isEarned(inputs: Trophies.inputs(from: pair)) == false)
    }

    @Test func allSecretAchievementsAreFlaggedSecretAndBinary() {
        let secrets = ["mrworldwide", "hattrick", "redeye", "repeat", "streak", "longshot", "multi", "quintet"]
        for id in secrets {
            let trophy = ach(id)
            #expect(trophy.secret, "\(id) should be secret")
            #expect(trophy.tiers.count == 1, "\(id) should be a single binary threshold")
        }
        // And the visible ones are NOT secret.
        for id in ["catcher", "centurion", "heavy", "legendary"] {
            #expect(ach(id).secret == false, "\(id) should be visible")
        }
    }
}

@Suite("TrophyBoard")
@MainActor
struct TrophyBoardTests {

    private func ach(_ id: String, secret: Bool = false, prerequisite: String? = nil, at: Int) -> Achievement {
        Achievement(id: id, title: id, summary: "", iconName: "crown",
                    tiers: [.init(tier: .gold, at: at)], secret: secret, prerequisite: prerequisite,
                    progress: { $0.totalCatches })
    }

    private func inputs(total: Int) -> TrophyProgressInputs {
        TrophyProgressInputs(
            totalCatches: total, uniqueAirframes: 0,
            wideBodyCatches: 0, regionalCatches: 0, heritageCatches: 0,
            rareTierCatches: 0, epicTierCatches: 0, legendaryTierCatches: 0,
            rarePlusUnique: 0, longestSlantKm: 0,
            bestMultiCatchCount: 0, nightCatches: 0
        )
    }

    @Test func secretAlwaysPresentVisibleLockedShownEarnedFirst() {
        let roster = [
            ach("v1", at: 1),                  // earned at total>=1
            ach("v2", at: 10),                 // visible, locked
            ach("s1", secret: true, at: 1),    // secret, earned
            ach("s2", secret: true, at: 10),   // secret, locked → masked but present
        ]
        let shown = TrophyBoard.visible(roster: roster, inputs: inputs(total: 1)).map(\.id)
        #expect(shown.contains("s2"))   // secret-locked is present (rendered masked)
        #expect(shown.contains("v2"))
        // Earned (v1, s1) first, then locked (v2, s2) in roster order.
        #expect(shown == ["v1", "s1", "v2", "s2"])
    }

    @Test func milestonePrerequisiteGatesNextUntilPriorEarned() {
        let roster = [
            ach("m1", at: 5),                       // first milestone, no prereq
            ach("m2", prerequisite: "m1", at: 50),  // hidden until m1 earned
        ]
        // m1 not earned → m2 absent.
        #expect(TrophyBoard.visible(roster: roster, inputs: inputs(total: 1)).map(\.id) == ["m1"])
        // m1 earned → m2 appears.
        #expect(TrophyBoard.visible(roster: roster, inputs: inputs(total: 5)).map(\.id) == ["m1", "m2"])
    }
}

@Suite("Trophies — 2026-06-21 expansion")
@MainActor
struct TrophiesExpansionTests {

    private let cal = Calendar(identifier: .gregorian)
    private func date(dayOffset: Int = 0, hour: Int = 12) -> Date {
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        let shifted = cal.date(byAdding: .day, value: dayOffset, to: base)!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: shifted)!
    }
    private func ach(_ id: String) -> Achievement { Trophies.roster.first { $0.id == id }! }
    private func mk(model: String? = nil, manufacturer: String? = nil, operatorName: String? = nil,
                    altM: Double? = nil, velMps: Double? = nil, place: String? = nil,
                    at: Date = Date(timeIntervalSince1970: 1_716_000_000)) -> Catch {
        Catch(icao24: String(UUID().uuidString.prefix(6)), callsign: nil, model: model,
              manufacturer: manufacturer, operatorName: operatorName, caughtAt: at,
              observerLat: 0, observerLon: 0, slantDistanceMeters: 0,
              altitudeMeters: altM, velocityMps: velMps, placeName: place)
    }

    /// A date at a fixed Y/M/D at noon — weekday is stable regardless of zone.
    private func ymd(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: - Tag classifier

    @Test func aircraftTagsClassify() {
        #expect(Trophies.aircraftTags(model: "747-400", manufacturer: "Boeing", typecode: "B744", operatorName: nil, type: .wide).contains("heavymetal"))
        #expect(Trophies.aircraftTags(model: "A380-800", manufacturer: "Airbus", typecode: "A388", operatorName: nil, type: .wide).contains("heavymetal"))
        #expect(Trophies.aircraftTags(model: "777-300", manufacturer: "Boeing", typecode: nil, operatorName: "FedEx", type: .wide).contains("freighter"))
        #expect(Trophies.aircraftTags(model: "ATR-72", manufacturer: "ATR", typecode: nil, operatorName: nil, type: .regional).contains("turboprop"))
        #expect(Trophies.aircraftTags(model: nil, manufacturer: "Sikorsky", typecode: nil, operatorName: nil, type: .ga).contains("helicopter"))
        #expect(Trophies.aircraftTags(model: "F-16", manufacturer: nil, typecode: nil, operatorName: nil, type: .mil).contains("military"))
        #expect(Trophies.aircraftTags(model: "Citation X", manufacturer: "Cessna", typecode: nil, operatorName: nil, type: .biz).contains("bizjet"))
        // A plain 737 narrowbody carries no special tag.
        #expect(Trophies.aircraftTags(model: "737-800", manufacturer: "Boeing", typecode: nil, operatorName: "United", type: .narrow).isEmpty)
    }

    @Test func emitterCategoryDrivesHelicopterTagAuthoritatively() {
        // Emitter category A7 tags a helicopter even when NO brand/model/typecode
        // string matches — the whole point of plumbing the category through.
        #expect(Trophies.aircraftTags(model: nil, manufacturer: nil, typecode: nil,
                                      operatorName: nil, type: .ga, category: "A7")
            .contains("helicopter"))
        // A non-rotorcraft category must not spuriously tag a fixed-wing jet.
        #expect(!Trophies.aircraftTags(model: "737-800", manufacturer: "Boeing", typecode: "B738",
                                       operatorName: "United", type: .narrow, category: "A3")
            .contains("helicopter"))
        // No category + no heli strings → no tag (the pre-feature default).
        #expect(!Trophies.aircraftTags(model: "C172", manufacturer: "Cessna", typecode: "C172",
                                       operatorName: nil, type: .ga, category: nil)
            .contains("helicopter"))
    }

    @Test func dayPartBuckets() {
        #expect(Trophies.dayPart(forHour: 8) == "morning")
        #expect(Trophies.dayPart(forHour: 14) == "afternoon")
        #expect(Trophies.dayPart(forHour: 19) == "evening")
        #expect(Trophies.dayPart(forHour: 23) == "night")
        #expect(Trophies.dayPart(forHour: 3) == "night")
    }

    // MARK: - Aggregates

    @Test func altitudeAndSpeedTakeMax() {
        let inputs = Trophies.inputs(from: [mk(altM: 8000, velMps: 200), mk(altM: 12500, velMps: 270)])
        #expect(inputs.highestAltitudeM == 12500)
        #expect(inputs.fastestVelocityMps == 270)
    }

    @Test func bestCatchesInOneDayAndDayParts() {
        let inputs = Trophies.inputs(from: [
            mk(at: date(dayOffset: 0, hour: 9)),    // morning
            mk(at: date(dayOffset: 0, hour: 14)),   // afternoon
            mk(at: date(dayOffset: 0, hour: 23)),   // night
            mk(at: date(dayOffset: 1, hour: 9)),    // next day
        ])
        #expect(inputs.bestCatchesInOneDay == 3)   // three on day 0
        #expect(inputs.dayPartsCovered == 3)       // morning, afternoon, night
    }

    // MARK: - New trophies

    @Test func firstCatchIsVisibleAndEarnsAtOne() {
        let t = ach("firstcatch")
        #expect(t.secret == false)
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk()])))
    }

    @Test func heavyMetalEarnsOnAJumbo() {
        let t = ach("heavymetal")
        #expect(t.secret == false)
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk(model: "747-8", manufacturer: "Boeing")])))
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk(model: "737-800", manufacturer: "Boeing")])) == false)
    }

    @Test func marathonSecretEarnsAtTenInADay() {
        let t = ach("marathon")
        #expect(t.secret)
        let ten = (0..<10).map { _ in mk(at: date(dayOffset: 0, hour: 10)) }
        #expect(t.isEarned(inputs: Trophies.inputs(from: ten)))
        let nine = (0..<9).map { _ in mk(at: date(dayOffset: 0, hour: 10)) }
        #expect(t.isEarned(inputs: Trophies.inputs(from: nine)) == false)
    }

    @Test func aroundTheClockSecretNeedsAllFourParts() {
        let t = ach("aroundclock")
        #expect(t.secret)
        let allFour = [8, 14, 19, 23].map { mk(at: date(hour: $0)) }
        #expect(t.isEarned(inputs: Trophies.inputs(from: allFour)))
        let three = [8, 14, 19].map { mk(at: date(hour: $0)) }
        #expect(t.isEarned(inputs: Trophies.inputs(from: three)) == false)
    }

    // MARK: - Second batch

    @Test func onTheDeckSecretBelowThreeThousandFeet() {
        let t = ach("ondeck")
        #expect(t.secret)
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk(altM: 600)])))            // low
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk(altM: 5000)])) == false)  // cruising
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk()])) == false)            // no altitude data
        // Threshold is the exact conversion: 3,000 ft = 914 m. 950 m (~3,117 ft)
        // was inside the old rounded 1,000 m gate but is above the copy's line.
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk(altM: 950)])) == false)
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk(altM: 914)])))
        // A zero/bad altitude is ignored — the genuinely-low one still counts.
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk(altM: 0), mk(altM: 700)])))
    }

    // Regression (field report, 2026-08-16): a 39,950 ft catch earned the old
    // "Mile High" because the threshold was a rounded 12,000 m (= 39,370 ft).
    // Now "Sky High" with the exact 40,000 ft = 12,192 m line.
    @Test func skyHighNeedsFortyThousandFeet() {
        let t = ach("milehigh")   // id is stable across the rename
        #expect(t.title == "Sky High")
        #expect(t.secret)
        let ft39950InMeters = 39_950 * 0.3048   // ≈ 12,177 m — the reported catch
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk(altM: ft39950InMeters)])) == false)
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk(altM: 12_192)])))
    }

    @Test func homebodyTenAtOnePlace() {
        let here = (0..<10).map { _ in mk(place: "Berkeley, CA") }
        #expect(Trophies.inputs(from: here).maxCatchesAtOnePlace == 10)
        #expect(ach("homebody").isEarned(inputs: Trophies.inputs(from: here)))
        // Spread across two places → best is 5, not earned.
        let split = (0..<5).map { _ in mk(place: "A") } + (0..<5).map { _ in mk(place: "B") }
        #expect(ach("homebody").isEarned(inputs: Trophies.inputs(from: split)) == false)
    }

    @Test func varietyPackCountsDistinctTypes() {
        // 737 narrow, A350 wide, E175 regional, Citation biz, Cessna ga → 5 types.
        let catches = [
            mk(model: "737-800", manufacturer: "Boeing"),
            mk(model: "A350-900", manufacturer: "Airbus"),
            mk(model: "E175", manufacturer: "Embraer"),
            mk(model: "Citation X", manufacturer: "Cessna"),
            mk(model: "Cessna 172", manufacturer: "Cessna"),
        ]
        let inputs = Trophies.inputs(from: catches)
        #expect(inputs.distinctTypes >= 5)
        #expect(ach("varietypack").isEarned(inputs: inputs))
    }

    @Test func dawnPatrolSecretInEarlyMorning() {
        #expect(ach("dawn").isEarned(inputs: Trophies.inputs(from: [mk(at: date(hour: 5))])))
        #expect(ach("dawn").isEarned(inputs: Trophies.inputs(from: [mk(at: date(hour: 12))])) == false)
    }

    @Test func weekendWarriorNeedsSaturdayAndSunday() {
        let sat = ymd(2024, 5, 18)   // a Saturday
        let sun = ymd(2024, 5, 19)   // a Sunday
        #expect(ach("weekend").isEarned(inputs: Trophies.inputs(from: [mk(at: sat), mk(at: sun)])))
        #expect(ach("weekend").isEarned(inputs: Trophies.inputs(from: [mk(at: sat), mk(at: sat)])) == false)
    }

    @Test func doubleheaderConsecutiveOperator() {
        let t0 = date(hour: 9)
        #expect(Trophies.hasConsecutiveSameOperator([(t0, "united"), (t0.addingTimeInterval(120), "united")]))
        #expect(Trophies.hasConsecutiveSameOperator([(t0, "united"), (t0.addingTimeInterval(120), "delta")]) == false)
        #expect(Trophies.hasConsecutiveSameOperator([]) == false)
        #expect(Trophies.hasConsecutiveSameOperator([(t0, "united")]) == false)
        // Sorted by time, so input order doesn't matter.
        #expect(Trophies.hasConsecutiveSameOperator([(t0.addingTimeInterval(120), "ual"), (t0, "ual")]))
    }
}

// MARK: - 2026-07-10 roster expansion (game-layer PR4)

@Suite("Trophies — points + guess trophies (2026-07-10 expansion)")
@MainActor
struct TrophyRosterExpansionTests {

    /// Base epoch for deterministic ordering; each catch offsets by minutes.
    private let t0 = Date(timeIntervalSince1970: 1_716_000_000)

    /// A catch at a known rarity via typecode (single-source rule): nil →
    /// .common (10 pts), "B744" → .rare (50), "C17" → .epic (100),
    /// "B2" → .legendary (500).
    private func mk(typecode: String? = nil, minute: Int = 0) -> Catch {
        Catch(
            icao24: UUID().uuidString.prefix(6).lowercased(),
            callsign: nil, model: nil, manufacturer: nil,
            caughtAt: t0.addingTimeInterval(Double(minute) * 60),
            observerLat: 0, observerLon: 0, slantDistanceMeters: 1000,
            typecode: typecode
        )
    }

    /// A catch that ANSWERED the bonus round with the given verdict
    /// (guessing is route-only; SKIP would leave all three fields nil).
    private func guessed(_ correct: Bool, minute: Int) -> Catch {
        let c = mk(minute: minute)
        c.guessKind = GuessKind.route.rawValue
        c.guessValue = "KSFO"
        c.guessCorrect = correct
        return c
    }

    private func ach(_ id: String) -> Achievement {
        Trophies.roster.first { $0.id == id }!
    }

    // MARK: totalPoints (offline base-points approximation)

    @Test func totalPointsSumsCurrentBasePoints() {
        // common 10 + rare 50 + epic 100 + legendary 500 = 660.
        let catches = [mk(), mk(typecode: "B744"), mk(typecode: "C17"), mk(typecode: "B2")]
        #expect(Trophies.inputs(from: catches).totalPoints == 660)
        #expect(Trophies.inputs(from: []).totalPoints == 0)
    }

    @Test func fourFiguresBoundaryAtExactlyOneThousand() {
        // 99 commons = 990 → locked; 100 commons = 1000 → earned (>= threshold).
        let ninetyNine = (0..<99).map { mk(minute: $0) }
        #expect(ach("fourfigures").isEarned(inputs: Trophies.inputs(from: ninetyNine)) == false)
        #expect(ach("fourfigures").isEarned(inputs: Trophies.inputs(from: ninetyNine + [mk(minute: 99)])))
    }

    @Test func highRollerAtFiveThousandChainedBehindFourFigures() {
        #expect(ach("highroller").prerequisite == "fourfigures")
        // 9 legendaries = 4500 → locked; 10 = 5000 → earned.
        let nine = (0..<9).map { mk(typecode: "B2", minute: $0) }
        #expect(ach("highroller").isEarned(inputs: Trophies.inputs(from: nine)) == false)
        #expect(ach("highroller").isEarned(inputs: Trophies.inputs(from: nine + [mk(typecode: "B2", minute: 9)])))
    }

    @Test func pointsMilestonesAreVisibleNotSecret() {
        #expect(ach("fourfigures").secret == false)
        #expect(ach("highroller").secret == false)
        #expect(ach("fourfigures").prerequisite == nil)
    }

    // MARK: correctGuesses / Called It / Clairvoyant

    @Test func correctGuessesCountsOnlyAnsweredCorrectRows() {
        let catches = [
            guessed(true, minute: 0),
            guessed(false, minute: 1),
            guessed(true, minute: 2),
            mk(minute: 3),               // no round → doesn't count
        ]
        #expect(Trophies.inputs(from: catches).correctGuesses == 2)
    }

    @Test func calledItEarnsOnFirstCorrectCallOnly() {
        #expect(ach("calledit").isEarned(inputs: Trophies.inputs(from: [guessed(true, minute: 0)])))
        // A wrong answer (or no round at all) earns nothing.
        #expect(ach("calledit").isEarned(inputs: Trophies.inputs(from: [guessed(false, minute: 0)])) == false)
        #expect(ach("calledit").isEarned(inputs: Trophies.inputs(from: [mk()])) == false)
    }

    @Test func clairvoyantBoundaryAtTenCorrect() {
        #expect(ach("clairvoyant").prerequisite == "calledit")
        let nine = (0..<9).map { guessed(true, minute: $0) }
        #expect(ach("clairvoyant").isEarned(inputs: Trophies.inputs(from: nine)) == false)
        #expect(ach("clairvoyant").isEarned(inputs: Trophies.inputs(from: nine + [guessed(true, minute: 9)])))
        // Wrong answers never help: 9 correct + 5 wrong is still locked.
        let mixed = nine + (10..<15).map { guessed(false, minute: $0) }
        #expect(ach("clairvoyant").isEarned(inputs: Trophies.inputs(from: mixed)) == false)
    }

    // MARK: Hot Streak (secret; 3 correct in a row)

    @Test func hotStreakNeedsThreeConsecutiveCorrect() {
        // correct, correct, wrong, correct, correct → best run 2 → locked.
        let broken = [guessed(true, minute: 0), guessed(true, minute: 1),
                      guessed(false, minute: 2),
                      guessed(true, minute: 3), guessed(true, minute: 4)]
        #expect(Trophies.inputs(from: broken).bestGuessStreak == 2)
        #expect(ach("hotstreak").isEarned(inputs: Trophies.inputs(from: broken)) == false)
        // Append a third consecutive correct → earned.
        let streak = broken + [guessed(true, minute: 5)]
        #expect(Trophies.inputs(from: streak).bestGuessStreak == 3)
        #expect(ach("hotstreak").isEarned(inputs: Trophies.inputs(from: streak)))
    }

    @Test func hotStreakUnbrokenByCatchesWithoutARound() {
        // Plain catches (and SKIPs — same nil verdict) between correct calls
        // don't reset the run; only a WRONG answer does.
        let catches = [guessed(true, minute: 0), mk(minute: 1),
                       guessed(true, minute: 2), mk(minute: 3),
                       guessed(true, minute: 4)]
        #expect(Trophies.inputs(from: catches).bestGuessStreak == 3)
        #expect(ach("hotstreak").isEarned(inputs: Trophies.inputs(from: catches)))
    }

    @Test func hotStreakOrdersByCatchTimeNotArrayOrder() {
        // Shuffled array order; caughtAt order is correct(0), wrong(1),
        // correct(2), correct(3), correct(4) → best run 3.
        let catches = [guessed(true, minute: 4), guessed(true, minute: 0),
                       guessed(correctAt: 2), guessed(false, minute: 1),
                       guessed(true, minute: 3)]
        #expect(Trophies.inputs(from: catches).bestGuessStreak == 3)
    }

    /// Convenience overload so the shuffled test reads naturally.
    private func guessed(correctAt minute: Int) -> Catch { guessed(true, minute: minute) }

    @Test func hotStreakIsSecretAndBinary() {
        #expect(ach("hotstreak").secret)
        #expect(ach("hotstreak").tiers.count == 1)
    }

    // MARK: Roster generation

    @Test func rosterVersionIsStampedAtFour() {
        // The 2026-10-21 unearnable-trophies fix. Bumping this constant is
        // what triggers the reseed + unlock cards on devices stamped behind it —
        // pin it so an accidental edit is loud.
        #expect(Trophies.rosterVersion == 4)
    }

    @Test func newIdsPresentExactlyOnce() {
        let ids = Trophies.roster.map(\.id)
        for id in ["fourfigures", "highroller", "calledit", "clairvoyant", "hotstreak",
                   "topflight", "dynasty", "charttopper"] {
            #expect(ids.filter { $0 == id }.count == 1, "\(id) missing or duplicated")
        }
    }
}

// MARK: - Leaderboard winner trophies (dynamic-leaderboards PR3)

@Suite("Trophies — leaderboard winner trophies")
@MainActor
struct TrophiesWinnerTests {

    private func ach(_ id: String) -> Achievement {
        Trophies.roster.first { $0.id == id }!
    }

    /// Suite-isolated standing cache pre-loaded via the same `update(from:)`
    /// path the screens use — so these tests also exercise the write side.
    private func standing(wins: Int = 0, topped: Bool = false) -> LeaderboardStandingCache {
        let cache = LeaderboardStandingCache(
            defaults: UserDefaults(suiteName: "trophies.standing.\(UUID().uuidString)")!)
        cache.update(from: MyStanding(rank: 1, points: 0,
                                      weeklyWins: wins, everToppedAllTime: topped))
        return cache
    }

    private func inputs(wins: Int = 0, topped: Bool = false) -> TrophyProgressInputs {
        Trophies.inputs(from: [], standing: standing(wins: wins, topped: topped))
    }

    // MARK: Inputs plumbing

    @Test func serverFactInputsDefaultToZero() {
        // The zero-churn contract: call sites (and fixtures) that don't pass
        // the new params get locked-state values.
        #expect(TrophyProgressInputs.zero.weeklyWins == 0)
        #expect(TrophyProgressInputs.zero.everToppedAllTime == false)
        // And a fresh install with no server contact reads the same.
        let fresh = inputs()
        #expect(fresh.weeklyWins == 0)
        #expect(fresh.everToppedAllTime == false)
    }

    @Test func inputsReadServerFactsFromStandingCache() {
        let i = inputs(wins: 2, topped: true)
        #expect(i.weeklyWins == 2)
        #expect(i.everToppedAllTime)
    }

    @Test func hangarAloneNeverEarnsWinnerTrophies() {
        // Server truth only: a huge Hangar with no server-credited wins
        // leaves all three locked — the app must never infer a win locally.
        let catches = (0..<100).map { i in
            Catch(icao24: String(UUID().uuidString.prefix(6)), callsign: nil,
                  model: nil, manufacturer: nil,
                  caughtAt: Date(timeIntervalSince1970: 1_716_000_000 + Double(i) * 60),
                  observerLat: 0, observerLon: 0, slantDistanceMeters: 0)
        }
        let i = Trophies.inputs(from: catches, standing: standing())
        for id in ["topflight", "dynasty", "charttopper"] {
            #expect(ach(id).isEarned(inputs: i) == false, "\(id) must stay locked without server facts")
        }
    }

    // MARK: Earn boundaries

    @Test func topFlightEarnsAtOneWin() {
        let t = ach("topflight")
        #expect(t.secret == false)
        #expect(t.isEarned(inputs: inputs(wins: 0)) == false)
        #expect(t.isEarned(inputs: inputs(wins: 1)))
        #expect(t.isEarned(inputs: inputs(wins: 3)))
    }

    @Test func dynastyEarnsAtThreeWins() {
        let t = ach("dynasty")
        #expect(t.isEarned(inputs: inputs(wins: 0)) == false)
        #expect(t.isEarned(inputs: inputs(wins: 1)) == false)
        #expect(t.isEarned(inputs: inputs(wins: 2)) == false)
        #expect(t.isEarned(inputs: inputs(wins: 3)))
    }

    @Test func chartTopperTracksEverToppedFlag() {
        let t = ach("charttopper")
        #expect(t.secret == false)
        #expect(t.isEarned(inputs: inputs(topped: false)) == false)
        #expect(t.isEarned(inputs: inputs(topped: true)))
    }

    // MARK: Dynasty secrecy

    @Test func dynastyIsSecretMaskedUntilEarned() {
        let t = ach("dynasty")
        #expect(t.secret)
        #expect(t.tiers.count == 1)
        // No prereq chain: TrophyBoard ignores prerequisites for secrets
        // (always listed, masked), so chaining behind Top Flight would be
        // a silent no-op — pin the deliberate nil.
        #expect(t.prerequisite == nil)
        // Locked → present in the board (rendered as the masked "???" row).
        let locked = TrophyBoard.visible(inputs: inputs(wins: 1))
        #expect(locked.contains { $0.id == "dynasty" })
        // Earned → sorts into the earned block with the others.
        let earned = TrophyBoard.visible(inputs: inputs(wins: 3, topped: true))
        let earnedIds = earned.prefix(3).map(\.id)
        #expect(earnedIds.contains("dynasty") && earnedIds.contains("topflight")
                && earnedIds.contains("charttopper"))
    }

    // MARK: Cache semantics

    @Test func standingCacheMirrorsWinsAndLatchesTopped() {
        let cache = LeaderboardStandingCache(
            defaults: UserDefaults(suiteName: "trophies.standing.\(UUID().uuidString)")!)
        // Old-backend payload (nil fields) writes nothing.
        cache.update(from: MyStanding(rank: 5, points: 100))
        #expect(cache.weeklyWins == 0)
        #expect(cache.monthlyWins == 0)
        #expect(cache.everToppedAllTime == false)
        // Server facts land.
        cache.update(from: MyStanding(rank: 1, points: 900, weeklyWins: 2,
                                      monthlyWins: 1, everToppedAllTime: true))
        #expect(cache.weeklyWins == 2)
        #expect(cache.monthlyWins == 1)
        #expect(cache.everToppedAllTime)
        // Wins mirror the server as-is (it may correct the count)…
        cache.update(from: MyStanding(rank: 1, points: 900, weeklyWins: 1, everToppedAllTime: false))
        #expect(cache.weeklyWins == 1)
        #expect(cache.monthlyWins == 1)
        // …but the monotonic "ever topped" flag never un-latches.
        #expect(cache.everToppedAllTime)
    }
}

// MARK: - Unearnable-trophies fix (2026-10-21)

/// Constellation / Quintet read `bestMultiCatchCount` (was hard-coded 0) and
/// Heritage / Living History / Full Deck read heritage catches (no typecode
/// resolves to `.heritage`, so they were 0 for everyone). Both now derive
/// from the Hangar; these pin the new derivations.
@Suite("Trophies — multi-catch + heritage wiring")
@MainActor
struct TrophiesUnearnableFixTests {

    private let press = Date(timeIntervalSince1970: 1_716_000_000)

    private func mk(icao: String = String(UUID().uuidString.prefix(6)).lowercased(),
                    typecode: String? = nil, model: String? = nil, manufacturer: String? = nil,
                    at: Date = Date(timeIntervalSince1970: 1_716_000_000)) -> Catch {
        Catch(icao24: icao, callsign: nil, model: model, manufacturer: manufacturer,
              caughtAt: at, observerLat: 0, observerLon: 0,
              slantDistanceMeters: 1000, typecode: typecode)
    }

    private func ach(_ id: String) -> Achievement { Trophies.roster.first { $0.id == id }! }

    // MARK: Multi-catch

    @Test func threeAirframesInOnePressCountThree() {
        let catches = [mk(icao: "aaa001", at: press), mk(icao: "aaa002", at: press),
                       mk(icao: "aaa003", at: press),
                       mk(icao: "aaa004", at: press.addingTimeInterval(60))]
        #expect(Trophies.inputs(from: catches).bestMultiCatchCount == 3)
    }

    @Test func sameAirframeTwiceInOnePressCountsOnce() {
        // A restored duplicate row (same icao24, same caughtAt) must not turn
        // a single catch into a "multi-catch".
        let catches = [mk(icao: "abc123", at: press), mk(icao: "abc123", at: press)]
        let inputs = Trophies.inputs(from: catches)
        #expect(inputs.bestMultiCatchCount == 1)
        #expect(ach("multi").isEarned(inputs: inputs) == false)
    }

    @Test func separatePressesDoNotMerge() {
        // One millisecond apart is two presses — only identical timestamps group.
        let catches = [mk(at: press), mk(at: press.addingTimeInterval(0.001))]
        #expect(Trophies.inputs(from: catches).bestMultiCatchCount == 1)
    }

    @Test func constellationAtTwoQuintetStillLockedAtThree() {
        let three = (0..<3).map { _ in mk(at: press) }
        let inputs = Trophies.inputs(from: three)
        #expect(ach("multi").isEarned(inputs: inputs))
        #expect(ach("quintet").isEarned(inputs: inputs) == false)
        let five = (0..<5).map { _ in mk(at: press) }
        #expect(ach("quintet").isEarned(inputs: Trophies.inputs(from: five)))
    }

    // MARK: Heritage

    @Test func vintageCatchEarnsHeritage() {
        // DC3 resolves to .ga in the typecode table — the bug: it never
        // counted as heritage. It fills the fam-vintage DC-3 slot.
        let dc3 = mk(typecode: "DC3", model: "DC-3")
        #expect(dc3.resolvedType != .heritage)
        let inputs = Trophies.inputs(from: [dc3])
        #expect(inputs.heritageCatches == 1)
        #expect(ach("heritage").isEarned(inputs: inputs))
        #expect(ach("heritage2").isEarned(inputs: inputs) == false)
    }

    @Test func modernCatchesAreNotHeritage() {
        let inputs = Trophies.inputs(from: [mk(typecode: "B738"), mk(typecode: "C172")])
        #expect(inputs.heritageCatches == 0)
        #expect(ach("heritage").isEarned(inputs: inputs) == false)
    }

    @Test func fiveVintageCatchesEarnLivingHistory() {
        // Living History counts distinct AIRFRAMES, not distinct models:
        // three different DC-3 airframes plus two Stearmans is five.
        let catches = [mk(typecode: "DC3"), mk(typecode: "DC3"), mk(typecode: "DC3"),
                       mk(typecode: "ST75"), mk(typecode: "ST75", model: "75 Kaydet")]
        let inputs = Trophies.inputs(from: catches)
        #expect(inputs.heritageCatches == 5)
        #expect(ach("heritage2").isEarned(inputs: inputs))
        #expect(ach("heritage2").isEarned(inputs: Trophies.inputs(from: Array(catches.prefix(4)))) == false)
    }

    @Test func sixTypesPlusVintageEarnFullDeck() {
        let six = [mk(typecode: "B738"), mk(typecode: "B789"), mk(typecode: "E75L"),
                   mk(typecode: "GLF6"), mk(typecode: "C17"), mk(typecode: "C172")]
        let without = Trophies.inputs(from: six)
        #expect(without.distinctTypes == 6)
        #expect(ach("fulldeck").isEarned(inputs: without) == false)
        let with = Trophies.inputs(from: six + [mk(typecode: "DC3")])
        #expect(with.distinctTypes == 6)   // the DC-3 is GA in the table
        #expect(with.fullDeckTypes == 7)
        #expect(ach("fulldeck").isEarned(inputs: with))
    }

    @Test func heritageCountMatchesPerCatchScan() {
        // The per-distinct-key count must equal the naive per-catch scan it
        // replaces (mixed repeats, case variants, non-vintage noise).
        let catches = [mk(typecode: "DC3"), mk(typecode: "dc3"), mk(typecode: "PA18", model: "PA-18 Super Cub"),
                       mk(typecode: "PA18", model: "PA-18 Super Cub"), mk(typecode: "B738"),
                       mk(typecode: nil, model: "Stearman"), mk(typecode: "C172")]
        let vintage = CardSets.families.first { $0.id == Trophies.heritageFamilyID }!
        let naive = catches.filter { c in vintage.entries.contains { CardSets.matches(catch: c, entry: $0) } }.count
        #expect(naive == 5)
        #expect(Trophies.inputs(from: catches).heritageCatches == naive)
    }

    @Test func oneResidentAirframeCaughtRepeatedlyIsOneHeritage() {
        // The local Cub caught on five different days is ONE heritage
        // aircraft — Living History needs five airframes, not five rows.
        let day: Double = 86_400
        let cub = (0..<5).map { i in
            mk(icao: "a1cub1", typecode: "PA18", model: "PA-18 Super Cub",
               at: press.addingTimeInterval(Double(i) * day))
        }
        let inputs = Trophies.inputs(from: cub)
        #expect(inputs.heritageCatches == 1)
        #expect(ach("heritage").isEarned(inputs: inputs))
        #expect(ach("heritage2").isEarned(inputs: inputs) == false)
    }

    @Test func modernLookalikesAreNotHeritage() {
        // Names that hit a vintage token but are modern airframes.
        let modern = [
            mk(typecode: "CC11", model: "CC11-160 Carbon Cub SS"),         // CubCrafters, by typecode
            mk(typecode: nil, model: "Carbon Cub EX-3"),                   // CubCrafters, by token
            mk(typecode: "TEX2", model: "T-6A Texan II"),                  // Beechcraft, by typecode
            mk(typecode: nil, model: "T-6A Texan II"),                     // no typecode, by token
            mk(typecode: nil, model: "T-6A Texan", manufacturer: "RAYTHEON AIRCRAFT CO"),  // by builder
            mk(typecode: nil, model: "AT-6B Wolverine", manufacturer: "TEXTRON AVIATION"),
            mk(typecode: "TEXA", model: "Texan"),                          // Fly Synthesis microlight
        ]
        #expect(Trophies.inputs(from: modern).heritageCatches == 0)
        // The real warbird with the same "T-6A Texan" model string still counts.
        let warbird = mk(typecode: nil, model: "T-6A Texan", manufacturer: "NORTH AMERICAN")
        #expect(Trophies.inputs(from: modern + [warbird]).heritageCatches == 1)
        #expect(Trophies.inputs(from: [mk(typecode: "T6", model: "T-6G Texan")]).heritageCatches == 1)
    }

    @Test func superCubStillCountsAsHeritage() {
        // Open taste call (Noah): until decided, the PA-18 keeps its credit.
        #expect(Trophies.inputs(from: [mk(typecode: "PA18", model: "PA-18 Super Cub")]).heritageCatches == 1)
    }

    @Test func vintageCatchDoesNotInflateVarietyPack() {
        // Four table types, one of them GA via a DC-3. The heritage stand-in
        // is Full Deck's alone: Variety Pack (and the Hangar chips) see 4.
        let four = [mk(typecode: "B738"), mk(typecode: "B789"), mk(typecode: "E75L"), mk(typecode: "DC3")]
        let inputs = Trophies.inputs(from: four)
        #expect(inputs.distinctTypes == 4)
        #expect(inputs.fullDeckTypes == 5)
        #expect(ach("varietypack").isEarned(inputs: inputs) == false)
    }

    @Test func memberwiseInputsDefaultFullDeckToDistinctTypes() {
        // Call sites that only set distinctTypes keep Full Deck's old reading.
        let inputs = TrophyProgressInputs(
            totalCatches: 0, uniqueAirframes: 0, wideBodyCatches: 0, regionalCatches: 0,
            heritageCatches: 0, rareTierCatches: 0, epicTierCatches: 0, legendaryTierCatches: 0,
            rarePlusUnique: 0, longestSlantKm: 0, bestMultiCatchCount: 0, nightCatches: 0,
            distinctTypes: 7)
        #expect(inputs.fullDeckTypes == 7)
        #expect(ach("fulldeck").isEarned(inputs: inputs))
    }

    // MARK: Roster bump → one unlock card per new trophy

    @Test func rosterBumpQueuesAnUnlockCardPerNewTrophy() {
        let ledger = UserDefaultsTrophyLedger(defaults: UserDefaults(suiteName: "test.unearnable.\(UUID().uuidString)")!)
        let suite = UserDefaults(suiteName: "test.unearnable.facts.\(UUID().uuidString)")!
        let events = TrophyEventStore(defaults: suite)
        let standing = LeaderboardStandingCache(defaults: suite)
        // A Hangar that qualifies for all four newly-earnable trophies once
        // the wiring is fixed: a two-plane press + five vintage catches.
        let hangar = [mk(at: press), mk(at: press)]
            + (0..<5).map { i in mk(typecode: "DC3", at: press.addingTimeInterval(Double(i + 1) * 3600)) }
        let newlyEarnable = ["multi", "heritage", "heritage2"]
        // Yesterday's build (roster 3) could never earn these, so its seed
        // never acknowledged them — model that by leaving them out.
        let oldRoster = Trophies.roster.filter { !newlyEarnable.contains($0.id) }
        let old = TrophyUnlockCenter(ledger: ledger, roster: oldRoster, events: events,
                                     standing: standing, rosterVersion: 3)
        old.enqueueNewUnlocks(from: hangar)
        #expect(ledger.rosterVersion == 3)

        let new = TrophyUnlockCenter(ledger: ledger, events: events, standing: standing)
        new.enqueueNewUnlocks(from: hangar)
        #expect(new.pendingRecap == nil, "a roster bump gets unlock cards, not the recap sheet")
        // One card per trophy the reseed newly acknowledged — not First
        // Catch & co., which the old ledger already had.
        #expect(Set(new.pendingEvents.map(\.achievementID)) == Set(newlyEarnable))
        #expect(new.pendingEvents.count == newlyEarnable.count)
        #expect(ledger.rosterVersion == 4)

        // Once seen, a re-diff stays quiet.
        while let head = new.head { new.markShown(head); new.advance() }
        new.enqueueNewUnlocks(from: hangar)
        #expect(new.pendingRecap == nil)
        #expect(new.pendingEvents.isEmpty)
    }
}
