//
//  TrophyTabModelTests.swift
//  TailspotTests
//
//  The pure derivation behind the Trophies tab (what each section shows
//  and in what order), the badge specs, and the tab's analytics property
//  builders. These replace the old `TrophyBoard` tests.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Trophy tab model")
@MainActor
struct TrophyTabModelTests {

    private func feat(_ id: String, secret: Bool = false, at: Int) -> Achievement {
        Achievement(id: id, title: id, summary: "", tiers: [.init(tier: .gold, at: at)],
                    secret: secret, progress: { $0.totalCatches })
    }

    private func inputs(total: Int = 0, wide: Int = 0, airlines: Int = 0) -> TrophyProgressInputs {
        TrophyProgressInputs(
            totalCatches: total, uniqueAirframes: 0,
            wideBodyCatches: wide, regionalCatches: 0, heritageCatches: 0,
            rareTierCatches: 0, epicTierCatches: 0, legendaryTierCatches: 0,
            rarePlusUnique: 0, longestSlantKm: 0,
            bestMultiCatchCount: 0, nightCatches: 0, uniqueOperators: airlines)
    }

    @Test func earnedFeatsLeadAndSecretsStayMaskedUntilEarned() {
        let roster = [
            feat("v1", at: 1),                // earned at total >= 1
            feat("v2", at: 10),               // visible, locked
            feat("s1", secret: true, at: 1),  // secret, earned
            feat("s2", secret: true, at: 10), // secret, locked
        ]
        let items = TrophyTabContent.ordered(feats: roster, inputs: inputs(total: 1))
        // Earned first, then locked visible, then locked secrets last.
        #expect(items.map(\.id) == ["v1", "s1", "v2", "s2"])
        #expect(items.map(\.masked) == [false, false, false, true])
        // Once earned, the secret unmasks and joins the earned block.
        let after = TrophyTabContent.ordered(feats: roster, inputs: inputs(total: 10))
        #expect(after.allSatisfy { !$0.masked })
    }

    @Test func contentSplitsTracksFromFeatsAndCountsEarned() {
        let c = TrophyTabContent.make(inputs: inputs(total: 5, wide: 10))
        // Track levels never appear in the feats grid.
        #expect(c.feats.allSatisfy { TrophyTracks.track(forAchievementID: $0.id) == nil })
        #expect(c.tracks.count == TrophyTracks.all.count)
        // firstcatch + spotter (logbook) + heavy (heavies) = 3 levels.
        #expect(c.levelsEarned == 3)
        #expect(c.earned == c.levelsEarned + c.featsEarned)
        #expect(c.earned == Trophies.roster.filter { $0.isEarned(inputs: inputs(total: 5, wide: 10)) }.count)
    }

    @Test func brandNewPlayerStillHasChases() {
        let c = TrophyTabContent.make(inputs: inputs())
        #expect(c.levelsEarned == 0)
        #expect(!c.chases.isEmpty && c.chases.count <= 3)
        #expect(c.feats.contains { $0.masked })
    }

    @Test func trackFocusIsHeldLevelOrFirstWhenNothingEarned() throws {
        let c = TrophyTabContent.make(inputs: inputs(total: 5))
        let logbook = try #require(c.tracks.first { $0.track.id == "logbook" })
        #expect(TrophyTabContent.focusAchievement(for: logbook, roster: c.roster)?.id == "spotter")
        let heavies = try #require(c.tracks.first { $0.track.id == "heavies" })
        #expect(heavies.level == 0)
        #expect(TrophyTabContent.focusAchievement(for: heavies, roster: c.roster)?.id == "heavy")
    }

    // MARK: Badge spec

    @Test func trackBadgeUsesTheRealLevelCount() throws {
        let c = TrophyTabContent.make(inputs: inputs(total: 5))
        for state in c.tracks {
            let spec = TrophyBadgeSpec(state: state)
            if state.track.endless {
                // No fixed count to segment: one arc toward the next level.
                #expect(spec.segments == 1 && spec.arc == state.fraction)
            } else {
                #expect(spec.segments == state.track.levelIDs.count)
                #expect((2...5).contains(spec.segments) && spec.arc == nil)
            }
            #expect(spec.filled == state.level)
            #expect(spec.earned == (state.level > 0))
        }
    }

    @Test func featBadgeIsOneRingAndSecretMasksUntilEarned() throws {
        let secret = try #require(Trophies.roster.first { $0.secret })
        let locked = TrophyBadgeSpec(feat: secret, earned: false)
        #expect(locked.segments == 1 && locked.filled == 0 && locked.masked && !locked.earned)
        let earned = TrophyBadgeSpec(feat: secret, earned: true)
        #expect(earned.filled == 1 && !earned.masked && earned.earned)
    }

    @Test func justEarnedLevelLightsItsOwnSegments() throws {
        let airlines2 = try #require(Trophies.roster.first { $0.id == "airlines2" })
        let spec = TrophyBadgeSpec(earnedAchievement: airlines2)
        #expect(spec.filled == 2 && spec.segments == 4 && spec.earned)
        // On an endless track an earned level is the full ring.
        let heavy2 = try #require(Trophies.roster.first { $0.id == "heavy2" })
        let full = TrophyBadgeSpec(earnedAchievement: heavy2)
        #expect(full.filled == 1 && full.segments == 1 && full.earned && full.arc == nil)
    }

    // MARK: Analytics

    @Test func tabViewedPropertiesCountEarnedAndListChases() {
        let c = TrophyTabContent.make(inputs: inputs(total: 5, wide: 10))
        let p = TrophyAnalytics.tabViewedProperties(c)
        #expect(p["earned"]?.jsonValue as? Int == c.earned)
        #expect(p["levels_earned"]?.jsonValue as? Int == 3)
        #expect(p["feats_earned"]?.jsonValue as? Int == c.featsEarned)
        #expect(p["chases"]?.jsonValue as? String == c.chases.map(\.id).joined(separator: ","))
    }

    @Test func detailPropertiesCarryTrackAndLevelOnlyForLevels() throws {
        let level = try #require(Trophies.roster.first { $0.id == "heavy2" })
        let p = TrophyAnalytics.detailOpenedProperties(level, earned: false, source: .chase)
        #expect(p["achievement"]?.jsonValue as? String == "heavy2")
        #expect(p["track"]?.jsonValue as? String == "heavies")
        #expect(p["level"]?.jsonValue as? Int == 2)
        #expect(p["earned"]?.jsonValue as? Bool == false)
        #expect(p["secret"]?.jsonValue as? Bool == false)
        #expect(p["source"]?.jsonValue as? String == "chase")

        let secret = try #require(Trophies.roster.first { $0.secret })
        let f = TrophyAnalytics.detailOpenedProperties(secret, earned: true, source: .feat)
        #expect(f["track"] == nil && f["level"] == nil)
        #expect(f["secret"]?.jsonValue as? Bool == true)
        #expect(f["source"]?.jsonValue as? String == "feat")
    }

    @Test func sharePropertiesAreIdentityOnly() throws {
        let level = try #require(Trophies.roster.first { $0.id == "airlines2" })
        let p = TrophyAnalytics.shareProperties(level)
        #expect(Set(p.keys) == ["achievement", "track", "level"])
        let feat = try #require(Trophies.roster.first { $0.id == "topflight" })
        #expect(Set(TrophyAnalytics.shareProperties(feat).keys) == ["achievement"])
    }

    @Test func copyFormatsGroupedFractions() {
        #expect(TrophyCopy.fraction(1234, 5000) == "1,234 / 5,000")
        #expect(TrophyCopy.fraction(60, 50) == "50 / 50")
    }
}
