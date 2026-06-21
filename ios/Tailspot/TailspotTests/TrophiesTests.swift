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

    /// Compact helper for terse tests. Resolved rarity / type fall
    /// out of the classifier when not specified.
    private func mk(
        model: String? = nil,
        manufacturer: String? = nil,
        operatorName: String? = nil,
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
            slantDistanceMeters: slantKm * 1000
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
        let catches: [Catch] = [
            mk(model: "A380-800",  manufacturer: "AIRBUS"),   // epic
            mk(model: "747-400",   manufacturer: "BOEING"),   // rare (scarce widebody)
            mk(model: "VC-25",     manufacturer: "BOEING", operatorName: "USAF"), // legendary
            mk(model: "737-800",   manufacturer: "BOEING"),   // common
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
        let one = Trophies.inputs(from: [mk(model: "VC-25", manufacturer: "BOEING", operatorName: "USAF")])
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

@Suite("MultiCatchReveal combo")
struct MultiCatchComboTests {

    @Test func multiplierLadder() {
        #expect(MultiCatchReveal.comboMultiplier(for: 1) == 1.0)
        #expect(MultiCatchReveal.comboMultiplier(for: 2) == 1.5)
        #expect(MultiCatchReveal.comboMultiplier(for: 3) == 2.0)
        #expect(MultiCatchReveal.comboMultiplier(for: 4) == 2.5)
        #expect(MultiCatchReveal.comboMultiplier(for: 5) == 3.0)
        #expect(MultiCatchReveal.comboMultiplier(for: 9) == 3.0)
    }

    @Test func sub2IsIdentity() {
        // Defensive against a bad caller — fan-of-1 shouldn't bonus.
        #expect(MultiCatchReveal.comboMultiplier(for: 0) == 1.0)
        #expect(MultiCatchReveal.comboMultiplier(for: 1) == 1.0)
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

    @Test func consecutiveDayRun() {
        let three: Set<Date> = [date(dayOffset: 0), date(dayOffset: 1), date(dayOffset: 2)]
        #expect(Trophies.longestConsecutiveDayRun(three, calendar: cal) == 3)
        // A gap breaks the run: 0,1, [skip 2], 3 → longest is 2.
        let gapped: Set<Date> = [date(dayOffset: 0), date(dayOffset: 1), date(dayOffset: 3)]
        #expect(Trophies.longestConsecutiveDayRun(gapped, calendar: cal) == 2)
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

    @Test func constellationAndQuintetAreSecretAndDormant() {
        for id in ["multi", "quintet"] {
            let trophy = ach(id)
            #expect(trophy.secret)
            // bestMultiCatchCount is hardcoded 0 → still locked under any catches.
            #expect(trophy.isEarned(inputs: Trophies.inputs(from: (0..<10).map { _ in mk() })) == false)
        }
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

    @Test func onTheDeckSecretBelowAThousandMeters() {
        let t = ach("ondeck")
        #expect(t.secret)
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk(altM: 600)])))            // low
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk(altM: 5000)])) == false)  // cruising
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk()])) == false)            // no altitude data
        // A zero/bad altitude is ignored — the genuinely-low one still counts.
        #expect(t.isEarned(inputs: Trophies.inputs(from: [mk(altM: 0), mk(altM: 700)])))
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
