//
//  TrophyTracksTests.swift
//  TailspotTests
//
//  The trophies-rebuild model layer: tracks group existing achievements as
//  levels (ids/thresholds/ledger untouched), feats are everything else,
//  chases pick the nearest goals, and a near miss names the track a catch
//  left one or two short. Plus the roster-bump anti-flood rule and the near-miss card on the
//  unlock center.
//

import Testing
import Foundation
import UIKit
@testable import Tailspot

@Suite("TrophyTracks")
@MainActor
struct TrophyTracksTests {

    /// id -> threshold for every achievement that shipped BEFORE the rebuild,
    /// copied from the roster before it was edited. A change to any of these
    /// would re-fire or strand an earned trophy.
    static let preexisting: [String: Int] = [
        "firstcatch": 1,
        "spotter": 5,
        "catcher": 25,
        "centurion": 100,
        "veteran": 500,
        "fourfigures": 1000,
        "highroller": 5000,
        "calledit": 1,
        "clairvoyant": 10,
        "topflight": 1,
        "charttopper": 1,
        "heavy": 10,
        "heavy2": 50,
        "narrow": 25,
        "narrow2": 120,
        "regional": 15,
        "regional2": 60,
        "world": 25,
        "world2": 100,
        "airlines": 10,
        "airlines2": 30,
        "places": 10,
        "places2": 25,
        "setcollector": 3,
        "setmaster": 8,
        "rarehunter": 5,
        "rarehunter2": 25,
        "regular": 10,
        "devotee": 40,
        "night": 5,
        "night2": 25,
        "heritage": 1,
        "heritage2": 5,
        "firstrare": 1,
        "epic": 1,
        "legendary": 1,
        "heavymetal": 1,
        "freighter": 1,
        "bizjet": 1,
        "turboprop": 1,
        "varietypack": 5,
        "fulldeck": 7,
        "homebody": 10,
        "mrworldwide": 1,
        "hattrick": 1,
        "redeye": 1,
        "repeat": 1,
        "streak": 1,
        "longshot": 5,
        "multi": 1,
        "quintet": 1,
        "military": 1,
        "helicopter": 1,
        "milehigh": 1,
        "speeddemon": 1,
        "marathon": 10,
        "aroundclock": 4,
        "ondeck": 1,
        "weekend": 2,
        "dawn": 1,
        "doubleheader": 1,
        "hotstreak": 1,
        "dynasty": 3,
        "groundstop": 1,
    ]

    private let roster = Trophies.roster
    private func ach(_ id: String) -> Achievement { roster.first { $0.id == id }! }

    private func inputs(
        totalCatches: Int = 0, uniqueAirframes: Int = 0, wide: Int = 0, narrow: Int = 0,
        operators: Int = 0, days: Int = 0, points: Int = 0, tags: Set<String> = [],
        rareTier: Int = 0, correctGuesses: Int = 0, sets: Int = 0
    ) -> TrophyProgressInputs {
        TrophyProgressInputs(
            totalCatches: totalCatches, uniqueAirframes: uniqueAirframes,
            wideBodyCatches: wide, regionalCatches: 0, heritageCatches: 0,
            rareTierCatches: rareTier, epicTierCatches: 0, legendaryTierCatches: 0,
            rarePlusUnique: 0, longestSlantKm: 0, bestMultiCatchCount: 0, nightCatches: 0,
            narrowBodyCatches: narrow, uniqueOperators: operators, completedSets: sets, distinctDays: days,
            caughtTags: tags, totalPoints: points, correctGuesses: correctGuesses)
    }

    // MARK: Structure

    @Test func everyLevelIDExistsInTheRoster() {
        let ids = Set(roster.map(\.id))
        for t in TrophyTracks.all {
            for id in t.levelIDs { #expect(ids.contains(id), "\(t.id): \(id) missing from roster") }
        }
    }

    @Test func noIDIsInTwoTracks() {
        let all = TrophyTracks.all.flatMap(\.levelIDs)
        #expect(Set(all).count == all.count)
    }

    @Test func thresholdsAscendAndPrerequisitesChain() {
        for t in TrophyTracks.all {
            let levels = t.levelIDs.map(ach)
            let thresholds = levels.map(\.threshold)
            #expect(thresholds == thresholds.sorted() && Set(thresholds).count == thresholds.count,
                    "\(t.id) thresholds must strictly ascend: \(thresholds)")
        }
    }

    @Test func everyRosterIDIsOneTrackLevelOrAFeat() {
        let feats = Set(TrophyTracks.feats(roster: roster).map(\.id))
        for a in roster {
            let isLevel = TrophyTracks.track(forAchievementID: a.id) != nil
            #expect(isLevel != feats.contains(a.id), "\(a.id) must be exactly a level or a feat")
        }
        #expect(feats.count + TrophyTracks.all.flatMap(\.levelIDs).count == roster.count)
    }

    @Test func everySymbolResolves() {
        for t in TrophyTracks.all {
            #expect(UIImage(systemName: t.symbol) != nil, "track symbol \(t.symbol)")
        }
        for f in TrophyTracks.feats(roster: roster) {
            #expect(TrophyTracks.featSymbols[f.id] != nil, "feat \(f.id) has no symbol")
            #expect(UIImage(systemName: TrophyTracks.featSymbol(for: f.id)) != nil,
                    "feat symbol for \(f.id)")
        }
    }

    @Test func preexistingIdsAndThresholdsAreUnchanged() {
        for (id, threshold) in Self.preexisting {
            guard let a = roster.first(where: { $0.id == id }) else {
                Issue.record("\(id) was removed from the roster"); continue
            }
            #expect(a.threshold == threshold, "\(id) threshold changed")
        }
        let ids = roster.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(roster.count == Self.preexisting.count + 13)
    }

    @Test func newLevelsHaveTheBriefedThresholds() {
        let expected: [String: Int] = [
            "world3": 300, "airlines3": 60, "airlines4": 100, "heavy3": 150, "narrow3": 400,
            "regional3": 150, "rarehunter3": 75, "sets3": 15, "places3": 50, "days3": 100,
            "night3": 100, "calls3": 50, "points3": 25_000,
        ]
        for (id, at) in expected { #expect(ach(id).threshold == at, "\(id)") }
    }

    // MARK: Naming

    @Test func levelTitlesUsePlainDigits() {
        #expect(TrophyTracks.levelTitle("Airlines", level: 4) == "Airlines Level 4")
    }

    @Test func displayTitleAndSummary() {
        #expect(TrophyTracks.displayTitle(for: ach("heavy2")) == "Heavies Level 2")
        #expect(TrophyTracks.displayTitle(for: ach("firstcatch")) == "Logbook Level 1")
        #expect(TrophyTracks.displayTitle(for: ach("redeye")) == "Red Eye")
        let units = DisplayUnits(altitude: .feet, speed: .knots, distance: .kilometers)
        #expect(TrophyTracks.displaySummary(for: ach("heavy"), units: units) == "Catch 10 wide-bodies")
        #expect(TrophyTracks.displaySummary(for: ach("points3"), units: units) == "Bank 25,000 lifetime points")
        #expect(TrophyTracks.displaySummary(for: ach("milehigh"), units: units) == "Catch one above 40,000 ft")
    }

    @Test func remainingCopyHandlesSingular() {
        let airlines = TrophyTracks.track(forAchievementID: "airlines")!
        #expect(airlines.remainingCopy(1) == "1 new airline to go")
        #expect(airlines.remainingCopy(3) == "3 new airlines to go")
    }

    @Test func featCopyIsImperative() {
        #expect(ach("mrworldwide").summary == "Catch planes in two countries")
        #expect(ach("hattrick").summary == "Catch three planes within ten minutes")
        #expect(ach("repeat").summary == "Catch the same airframe on two different days")
        #expect(ach("streak").summary == "Catch on seven days in a row")
        #expect(ach("groundstop").summary == "Try to catch a parked plane")
        #expect(ach("redeye").summary == "Catch one between 2 and 5 AM")
        #expect(ach("dawn").summary == "Catch one between 4 and 7 AM")
        #expect(ach("homebody").summary == "Make 10 catches from one spot")
        #expect(ach("doubleheader").summary == "Catch the same airline twice in a row")
    }

    // MARK: Track state

    @Test func stateForEmptyMidAndMaxed() {
        let logbook = TrophyTracks.all[0]
        let empty = TrophyTrackState.make(track: logbook, inputs: .zero, roster: roster)!
        #expect(empty.level == 0 && empty.levelCount == 5 && empty.progress == 0)
        #expect(empty.nextGoal == 1 && empty.nextAchievement?.id == "firstcatch")
        #expect(empty.fraction == 0 && !empty.isMaxed)

        let mid = TrophyTrackState.make(track: logbook, inputs: inputs(totalCatches: 30), roster: roster)!
        #expect(mid.level == 3 && mid.progress == 30 && mid.nextGoal == 100)
        #expect(mid.nextAchievement?.id == "centurion")
        #expect(abs(mid.fraction - 0.3) < 1e-9)

        let maxed = TrophyTrackState.make(track: logbook, inputs: inputs(totalCatches: 600), roster: roster)!
        #expect(maxed.level == 5 && maxed.isMaxed && maxed.nextGoal == nil && maxed.nextAchievement == nil)
        #expect(maxed.fraction == 1)
    }

    // MARK: Chases

    /// Everything earned except the secret/unreachable: a rich Hangar.
    private var rich: TrophyProgressInputs {
        inputs(totalCatches: 120, uniqueAirframes: 40, wide: 12, narrow: 30, operators: 12, days: 12,
               points: 6000, tags: ["heavymetal", "freighter"], rareTier: 1, correctGuesses: 1)
    }

    @Test func brandNewPlayerGetsThreeChasesStartingWithLogbookI() {
        let chases = TrophyChases.pick(inputs: .zero, roster: roster)
        #expect(chases.count == 3)
        #expect(chases.first?.achievement.id == "firstcatch")
        #expect(chases.first?.track?.id == "logbook" && chases.first?.level == 1)
        #expect(chases.first?.blurb == "1 more catch to go")
        #expect(chases.map(\.id) == ["firstcatch", "heavymetal", "world"])
    }

    @Test func chasesNeverIncludeSecretsEarnedOrMaxed() {
        for input in [TrophyProgressInputs.zero, rich, inputs(totalCatches: 600, tags: ["heavymetal"])] {
            let chases = TrophyChases.pick(inputs: input, roster: roster)
            #expect(chases.count <= 3)
            for c in chases {
                #expect(!c.achievement.secret)
                #expect(!c.achievement.isEarned(inputs: input), "\(c.id) is already earned")
                #expect(c.fraction < 1)
            }
            #expect(Set(chases.map(\.id)).count == chases.count)
        }
        let maxedLogbook = TrophyChases.pick(inputs: inputs(totalCatches: 600), roster: roster)
        #expect(!maxedLogbook.contains { $0.track?.id == "logbook" })
    }

    @Test func chasesAreDeterministic() {
        let a = TrophyChases.pick(inputs: rich, roster: roster).map(\.id)
        let b = TrophyChases.pick(inputs: rich, roster: roster).map(\.id)
        #expect(a == b)
    }

    @Test func differentPlanePickPrefersAVarietyTrackWithProgress() {
        // Logbook 3/5 leads; airframes (variety) has progress -> it is pick 2.
        let chases = TrophyChases.pick(inputs: inputs(totalCatches: 3, uniqueAirframes: 3), roster: roster)
        #expect(chases[0].track?.id == "logbook")
        #expect(chases[1].track?.id == "airframes")
    }

    @Test func differentPlanePickFallsBackToFeatsInOrder() {
        // No variety track has progress -> first unearned feat in the list.
        let first = TrophyChases.pick(inputs: inputs(totalCatches: 3), roster: roster)
        #expect(first[1].id == "heavymetal" && first[1].kind == .feat)
        let second = TrophyChases.pick(inputs: inputs(totalCatches: 3, tags: ["heavymetal"]), roster: roster)
        #expect(second[1].id == "freighter")
    }

    /// A player who has maxed nearly every track: only the heritage track is
    /// left (no heritage catches), and no aircraft tags are earned, so the
    /// feats that need tags stay open.
    private var nearlyMaxed: TrophyProgressInputs {
        let big = 100_000
        return TrophyProgressInputs(
            totalCatches: big, uniqueAirframes: big, wideBodyCatches: big, regionalCatches: big,
            heritageCatches: 0, rareTierCatches: big, epicTierCatches: big, legendaryTierCatches: big,
            rarePlusUnique: big, longestSlantKm: 500, bestMultiCatchCount: 5, nightCatches: big,
            narrowBodyCatches: big, uniqueOperators: big, uniquePlaces: big, completedSets: big,
            distinctDays: big, distinctCountries: big, farCatchCount: big, redEyeCatches: big,
            bestBurstWithinTenMin: big, longestDayStreak: big, distinctTypes: big, fullDeckTypes: big,
            totalPoints: big * 100, correctGuesses: big, bestGuessStreak: big)
    }

    @Test func aNearlyMaxedPlayerStillGetsThreeDistinctChases() {
        let input = nearlyMaxed
        let unmaxed = TrophyTrackState.all(inputs: input, roster: roster).filter { !$0.isMaxed }
        #expect(unmaxed.count < 3, "fixture should leave fewer than three open tracks")

        let chases = TrophyChases.pick(inputs: input, roster: roster)
        #expect(chases.count == 3)
        #expect(Set(chases.map(\.id)).count == chases.count, "no duplicates")
        for c in chases {
            #expect(!c.achievement.secret, "\(c.id) is secret")
            #expect(!c.achievement.isEarned(inputs: input), "\(c.id) is already earned")
        }
        // The open tracks come first, feats fill the rest.
        #expect(chases.filter { $0.kind == .trackLevel }.count == unmaxed.count)
        #expect(chases.filter { $0.kind == .feat }.count == 3 - unmaxed.count)
    }

    // MARK: Near miss

    @Test func nearMissIsNilWhenNothingChanged() {
        #expect(TrophyNearMiss.find(before: rich, after: rich, roster: roster) == nil)
    }

    @Test func nearMissFiresWithinTwoOfTheNextLevel() {
        // Airlines II is 30: 27 -> 28 leaves two to go.
        let near = TrophyNearMiss.find(before: inputs(totalCatches: 60, operators: 27),
                                       after: inputs(totalCatches: 61, operators: 28), roster: roster)
        #expect(near?.track.id == "airlines")
        #expect(near?.achievement.id == "airlines2")
        #expect(near?.remaining == 2)
        #expect(near?.title == "Airlines Level 2")
        #expect(near?.remainingText == "2 new airlines to go")
        #expect(near?.goalText == "Collect 30 airlines")
        #expect(near?.badgeSpec.filled == 1)
    }

    @Test func nearMissNeedsTheTrackToHaveMovedOnThisCatch() {
        // Already at 28 before the catch: another catch that adds no airline
        // must not bring the card up.
        #expect(TrophyNearMiss.find(before: inputs(totalCatches: 60, operators: 28),
                                    after: inputs(totalCatches: 61, operators: 28), roster: roster)?.track.id != "airlines")
    }

    @Test func nearMissIsNotShownThreeOrMoreAway() {
        #expect(TrophyNearMiss.find(before: inputs(totalCatches: 60, operators: 26),
                                    after: inputs(totalCatches: 61, operators: 27), roster: roster) == nil)
    }

    @Test func nearMissSkipsLevelsAlreadyShownAndLevelUps() {
        let before = inputs(totalCatches: 60, operators: 28), after = inputs(totalCatches: 61, operators: 29)
        #expect(TrophyNearMiss.find(before: before, after: after, roster: roster)?.remaining == 1)
        #expect(TrophyNearMiss.find(before: before, after: after, roster: roster, excluding: ["airlines2"]) == nil)
        // Crossing the level is the unlock card's job, not this one's.
        #expect(TrophyNearMiss.find(before: inputs(totalCatches: 60, operators: 29),
                                    after: inputs(totalCatches: 61, operators: 30), roster: roster) == nil)
    }

    @Test func nearMissSkipsSmallGoals() {
        // Logbook II is 5 catches (the smallest allowed goal): 3 is two away.
        #expect(TrophyNearMiss.find(before: inputs(totalCatches: 2), after: inputs(totalCatches: 3), roster: roster)?.track.id == "logbook")
        // Sets I is 3 sets: one set is "2 to go" on the very first step.
        #expect(TrophyNearMiss.find(before: inputs(totalCatches: 60), after: inputs(totalCatches: 61, sets: 1), roster: roster) == nil)
    }

    @Test func nearMissPrefersAQuietTrackOverLogbook() {
        // Logbook III is 25 (23 -> 24 is one away); airlines 27 -> 28 is two.
        let near = TrophyNearMiss.find(before: inputs(totalCatches: 23, operators: 27),
                                       after: inputs(totalCatches: 24, operators: 28), roster: roster)
        #expect(near?.track.id == "airlines")
    }

    @Test func nearStoreRemembersShownLevels() {
        let store = TrophyNearStore(defaults: suite())
        #expect(store.shown.isEmpty)
        store.markShown(["airlines2"]); store.markShown(["airlines2", "heavy2"])
        #expect(store.shown == ["airlines2", "heavy2"])
    }

    // MARK: Unlock center

    private func freshLedger() -> UserDefaultsTrophyLedger {
        UserDefaultsTrophyLedger(defaults: UserDefaults(suiteName: "test.tracks.\(UUID().uuidString)")!)
    }

    private func suite() -> UserDefaults { UserDefaults(suiteName: "test.tracks.facts.\(UUID().uuidString)")! }

    private func catches(_ n: Int) -> [Catch] {
        (0..<n).map { i in
            Catch(icao24: "ab\(String(format: "%04d", i))", callsign: nil, model: "737-800",
                  manufacturer: "BOEING", operatorName: nil,
                  caughtAt: Date(timeIntervalSince1970: 1_716_000_000 + Double(i)),
                  observerLat: 0, observerLon: 0, slantDistanceMeters: 0, typecode: "B738")
        }
    }

    private func badge(_ id: String) -> Achievement {
        Achievement(id: id, title: id, summary: "", tiers: [.init(tier: .gold, at: 1)], progress: { $0.totalCatches })
    }

    @Test func reseedGrantingMoreThanThreeQueuesARecapAndNoCards() {
        let ledger = freshLedger()
        let base = badge("base")
        let added = ["a", "b", "c", "d"].map(badge)
        TrophyUnlockCenter(ledger: ledger, roster: [base], rosterVersion: 1).enqueueNewUnlocks(from: catches(1))
        let new = TrophyUnlockCenter(ledger: ledger, roster: [base] + added, rosterVersion: 2)
        new.enqueueNewUnlocks(from: catches(1))
        #expect(new.pendingEvents.isEmpty)
        #expect(new.pendingRecap?.achievements.map(\.id) == ["a", "b", "c", "d"])
        #expect(ledger.rosterVersion == 2)
        for a in added { #expect(ledger.acknowledgedOrdinal(for: a.id) == TrophyTier.gold.ordinal) }
    }

    @Test func reseedGrantingThreeOrFewerQueuesCards() {
        let ledger = freshLedger()
        let base = badge("base")
        let added = ["a", "b", "c"].map(badge)
        TrophyUnlockCenter(ledger: ledger, roster: [base], rosterVersion: 1).enqueueNewUnlocks(from: catches(1))
        let new = TrophyUnlockCenter(ledger: ledger, roster: [base] + added, rosterVersion: 2)
        new.enqueueNewUnlocks(from: catches(1))
        #expect(new.pendingRecap == nil)
        #expect(new.pendingEvents.map(\.achievementID) == ["a", "b", "c"])
    }

    @Test func nearMissCardIsQueuedOnceWhenACatchLeavesALevelTwoAway() {
        let s = suite()
        let ledger = freshLedger()
        func center() -> TrophyUnlockCenter {
            TrophyUnlockCenter(ledger: ledger, events: TrophyEventStore(defaults: s),
                               standing: LeaderboardStandingCache(defaults: s),
                               nearStore: TrophyNearStore(defaults: s))
        }
        // Logbook III is 25 catches. Seed at 22 (the launch diff), then catch.
        let c = center()
        c.enqueueNewUnlocks(from: catches(22))
        c.dismissRecap()
        #expect(c.pendingNearMiss == nil, "the first evaluation never produces one")

        c.enqueueNewUnlocks(from: catches(23))
        let near = try? #require(c.pendingNearMiss)
        #expect(near?.remaining == 2)
        #expect(c.hasPending)

        // A re-diff at the same count leaves the card alone.
        c.enqueueNewUnlocks(from: catches(23))
        #expect(c.pendingNearMiss != nil)

        if let near { c.markNearMissShown(near) }
        c.dismissNearMiss()
        #expect(!c.hasPending)

        // One more catch (one to go): the level has had its card.
        c.enqueueNewUnlocks(from: catches(24))
        #expect(c.pendingNearMiss == nil)
        // And a fresh center (a relaunch) remembers too.
        let relaunched = center()
        relaunched.enqueueNewUnlocks(from: catches(23))
        relaunched.enqueueNewUnlocks(from: catches(24))
        #expect(relaunched.pendingNearMiss == nil)
    }

    @Test func aCatchThatUnlocksSomethingGetsNoNearMissCard() {
        let s = suite()
        let c = TrophyUnlockCenter(ledger: freshLedger(), events: TrophyEventStore(defaults: s),
                                   standing: LeaderboardStandingCache(defaults: s),
                                   nearStore: TrophyNearStore(defaults: s))
        c.enqueueNewUnlocks(from: catches(24))
        c.dismissRecap()
        c.enqueueNewUnlocks(from: catches(25))   // Logbook III unlocks
        #expect(!c.pendingEvents.isEmpty)
        #expect(c.pendingNearMiss == nil)
    }

    @Test func unlockPropertiesCarryTrackAndLevelForLevelsOnly() {
        let level = TrophyUnlockEvent(achievement: ach("heavy2"), newTier: .gold, kind: .badgeEarned)
        let p = TrophyUnlockCenter.unlockProperties(level)
        #expect(p["track"]?.jsonValue as? String == "heavies")
        #expect(p["level"]?.jsonValue as? Int == 2)
        #expect(p["title"]?.jsonValue as? String == "Heavy Hitter")
        #expect(p["achievement"]?.jsonValue as? String == "heavy2")

        let feat = TrophyUnlockEvent(achievement: ach("redeye"), newTier: .gold, kind: .badgeEarned)
        let f = TrophyUnlockCenter.unlockProperties(feat)
        #expect(f["track"] == nil && f["level"] == nil)
    }

    // MARK: Near-miss analytics

    @Test func nearShownPropertiesCarryTrackLevelProgressGoal() {
        let near = TrophyNearMiss.find(before: inputs(totalCatches: 60, operators: 27),
                                       after: inputs(totalCatches: 61, operators: 28), roster: roster)!
        let p = TrophyAnalytics.nearShownProperties(near)
        #expect(TrophyAnalytics.nearShown == "trophy_near_shown")
        #expect(p["track"]?.jsonValue as? String == "airlines")
        #expect(p["level"]?.jsonValue as? Int == 2)
        #expect(p["progress"]?.jsonValue as? Int == 28)
        #expect(p["goal"]?.jsonValue as? Int == 30)
        #expect(p.count == 4)
    }
}
