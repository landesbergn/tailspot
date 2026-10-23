//
//  RevealShareTests.swift
//  TailspotTests
//
//  Share-on-reveal + honest multi-catch points (2026-10-23):
//   - `RevealShareGate`: when the single reveal's Share CTA is live.
//   - `MultiCatchReveal.tally`: the points a multi-catch shows are what the
//     server awards (base + first-of-type), with no combo multiplier.
//   - `MultiCatchReveal.shareSubject`: which card the multi reveal shares.
//   - `CatchShare` copy + footer shared by the reveal and the detail pill.
//

import Foundation
import Testing
@testable import Tailspot

@Suite struct RevealShareGateTests {

    private func gate(settled: Bool = true, pipelineFinished: Bool = true,
                      hasBonusRound: Bool = false, chipsCollapsed: Bool = false,
                      bonusResolved: Bool = false, voiceOver: Bool = false) -> Bool {
        RevealShareGate.isAvailable(settled: settled, pipelineFinished: pipelineFinished,
                                    hasBonusRound: hasBonusRound, chipsCollapsed: chipsCollapsed,
                                    bonusResolved: bonusResolved, voiceOver: voiceOver)
    }

    @Test func plainSettledRevealCanShare() {
        #expect(gate())
    }

    @Test func notBeforeTheRevealSettles() {
        #expect(!gate(settled: false))
    }

    @Test func notWhileThePhotoIsStillComposing() {
        #expect(!gate(pipelineFinished: false))
    }

    @Test func hiddenWhileTheBonusRoundIsOnScreen() {
        // Chips not popped yet (the 0.2 s beat after settle), then up.
        #expect(!gate(hasBonusRound: true))
        // Answered, chips still flashing the verdict before they collapse.
        #expect(!gate(hasBonusRound: true, bonusResolved: true))
    }

    @Test func availableOnceTheChipsCollapse() {
        #expect(gate(hasBonusRound: true, chipsCollapsed: true, bonusResolved: true))
    }

    @Test func voiceOverResolvedRoundCountsAsDone() {
        // Under VoiceOver the chips never collapse; a resolved round is done.
        #expect(gate(hasBonusRound: true, bonusResolved: true, voiceOver: true))
        #expect(!gate(hasBonusRound: true, bonusResolved: false, voiceOver: true))
    }
}

@MainActor
@Suite struct MultiCatchTallyTests {

    private func entry(_ rarity: Rarity, firstOfType: Bool = false, dup: Bool = false,
                       callsign: String = "TST1") -> MultiCatchReveal.Entry {
        .init(plane: CardPlane(callsign: callsign, model: "Test", carrier: nil,
                               rarity: rarity, type: .narrow, isFirstOfType: firstOfType),
              isDuplicate: dup)
    }

    @Test func awardedIsTheSumOfEachCatchWithNoMultiplier() {
        // Old view: (50 + 10 + 20) × 2.0 = 160. The server awards 80.
        let t = MultiCatchReveal.tally([entry(.rare), entry(.common), entry(.uncommon)])
        #expect(t.freshCount == 3)
        #expect(t.basePoints == 80)
        #expect(t.firstOfTypePoints == 0)
        #expect(t.awarded == 80)
    }

    @Test func firstOfTypeIsCountedLikeTheServer() {
        let t = MultiCatchReveal.tally([entry(.rare, firstOfType: true), entry(.common)])
        #expect(t.firstOfTypePoints == ScoringBonuses.firstOfTypeBonus(base: 50))
        #expect(t.awarded == 60 + ScoringBonuses.firstOfTypeBonus(base: 50))
    }

    @Test func duplicatesEarnNothing() {
        let t = MultiCatchReveal.tally([entry(.rare), entry(.legendary, firstOfType: true, dup: true),
                                        entry(.common)])
        #expect(t.freshCount == 2)
        #expect(t.duplicateCount == 1)
        #expect(t.awarded == 60)
    }

    @Test func bannerKeepsTheCelebrationWithoutAMultiplier() {
        #expect(MultiCatchReveal.bannerLabel(for: .init()) == "ALREADY CAUGHT")
        #expect(MultiCatchReveal.bannerLabel(for: MultiCatchReveal.tally([entry(.rare)])) == "CATCH ×1")
        let two = MultiCatchReveal.tally([entry(.rare), entry(.common)])
        #expect(MultiCatchReveal.bannerLabel(for: two) == "MULTI-CATCH ×2 · +60 pts")
    }

    @Test func announcementSpeaksAwardedPointsAndNoCombo() {
        let t = MultiCatchReveal.tally([entry(.rare, firstOfType: true), entry(.common),
                                        entry(.uncommon, dup: true)])
        let s = MultiCatchReveal.announcement(for: t)
        #expect(!s.lowercased().contains("combo"))
        #expect(s.contains("2 planes caught"))
        #expect(s.contains("1 already in hangar"))
        #expect(s.contains("\(t.awarded) points awarded"))
    }

    @Test func sharesTheRarestFreshCatch() {
        let entries = [entry(.uncommon, callsign: "A"), entry(.epic, callsign: "B"),
                       entry(.legendary, dup: true, callsign: "C"), entry(.epic, callsign: "D")]
        // Legendary is a duplicate; first of the two epics wins the tie.
        #expect(MultiCatchReveal.shareSubject(entries)?.plane.callsign == "B")
    }

    @Test func allDuplicatesStillShareTheRarest() {
        let entries = [entry(.common, dup: true, callsign: "A"), entry(.rare, dup: true, callsign: "B")]
        #expect(MultiCatchReveal.shareSubject(entries)?.plane.callsign == "B")
        #expect(MultiCatchReveal.shareSubject([]) == nil)
    }
}

@MainActor
@Suite struct CatchShareCopyTests {

    @Test func shareTextVariants() {
        #expect(CatchShare.shareText(callsign: "UAL2476", model: "Boeing 737-900")
                == "Caught UAL2476 · Boeing 737-900 on Tailspot")
        #expect(CatchShare.shareText(callsign: "UAL2476", model: nil) == "Caught UAL2476 on Tailspot")
        #expect(CatchShare.shareText(callsign: "  ", model: "Cessna 172") == "Caught Cessna 172 on Tailspot")
        #expect(CatchShare.shareText(callsign: nil, model: nil) == "Caught a plane on Tailspot")
    }

    @Test func shareMessageCarriesTheStoreLinkMidSentence() {
        let m = CatchShare.shareMessage(shareText: "Caught X on Tailspot")
        #expect(m.hasPrefix("Caught X on Tailspot — get the app at "))
        #expect(m.contains(CatchShare.storeURL.absoluteString))
        #expect(m.hasSuffix(" and start spotting."))
    }

    @Test func footerPrintsTheAddress() {
        #expect(CatchShare.footerText.contains("tailspot.app"))
        #expect(CatchShare.footerText.hasPrefix("CAUGHT ON TAILSPOT"))
    }
}
