//
//  RevealShareTests.swift
//  TailspotTests
//
//  Share-on-reveal + honest multi-catch points (2026-10-23):
//   - `RevealShareGate`: when the single reveal's Share CTA is live.
//   - `RevealShareButtonMetrics`: the callsign-line button's ≥44 pt target.
//   - `MultiCatchReveal.tally`: the points a multi-catch shows are what the
//     server awards (base + first-of-type), with no combo multiplier.
//   - `MultiCatchReveal.entryNumbers` / `chimeStep`: the run's per-plane
//     entry numbers and chime ladder.
//   - `CatchShare` copy + footer shared by the reveal and the detail pill.
//

import CoreGraphics
import Foundation
import Testing
@testable import Tailspot

@Suite struct RevealShareGateTests {

    private func gate(settled: Bool = true, pipelineFinished: Bool = true,
                      catchSaved: Bool = true,
                      hasBonusRound: Bool = false, chipsCollapsed: Bool = false,
                      bonusResolved: Bool = false, voiceOver: Bool = false) -> Bool {
        RevealShareGate.isAvailable(settled: settled, pipelineFinished: pipelineFinished,
                                    catchSaved: catchSaved, hasBonusRound: hasBonusRound, chipsCollapsed: chipsCollapsed,
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

    @Test func notForACatchThatFailedToSave() {
        // The pipeline "finishes" on an error exit too; with no saved row
        // there's nothing to share.
        #expect(!gate(pipelineFinished: true, catchSaved: false))
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

    @Test func announcementSpeaksAwardedPointsAndNoCombo() {
        let t = MultiCatchReveal.tally([entry(.rare, firstOfType: true), entry(.common),
                                        entry(.uncommon, dup: true)])
        let s = MultiCatchReveal.announcement(for: t)
        #expect(!s.lowercased().contains("combo"))
        #expect(s.contains("2 planes caught"))
        #expect(s.contains("1 already in hangar"))
        #expect(s.contains("\(t.awarded) points awarded"))
    }

    @Test func twoOfANewTypeEarnOneFirstOfTypeBonus() {
        // The server checks its history before each insert, so the second
        // B738 of the run is no longer first of its type.
        let flags = MultiCatchReveal.runFirstOfType(typecodes: ["B738", "B738", "A320"],
                                                    heldTypecodes: [])
        #expect(flags == [true, false, true])
        let t = MultiCatchReveal.tally([entry(.common, firstOfType: flags[0]),
                                        entry(.common, firstOfType: flags[1]),
                                        entry(.common, firstOfType: flags[2])])
        #expect(t.firstOfTypePoints == 2 * ScoringBonuses.firstOfTypeBonus(base: 10))
    }

    @Test func entryNumbersCountUpToTheLastFreshEntry() {
        // Two fresh + a duplicate between them; the Hangar holds 48 after.
        let e = [entry(.rare), entry(.common, dup: true), entry(.uncommon)]
        #expect(MultiCatchReveal.entryNumbers(e, lastEntryNumber: 48) == [47, 48, 48])
    }

    @Test func chimeLadderClimbsOnFreshPlanesOnly() {
        let e = [entry(.rare), entry(.common, dup: true), entry(.uncommon)]
        #expect(MultiCatchReveal.chimeStep(e, page: 0) == 0)
        #expect(MultiCatchReveal.chimeStep(e, page: 1) == nil)
        #expect(MultiCatchReveal.chimeStep(e, page: 2) == 1)
        // The summary page (past the last plane) plays nothing.
        #expect(MultiCatchReveal.chimeStep(e, page: 3) == nil)
    }

    @Test func aTypeAlreadyInTheHangarIsNeverFirst() {
        let flags = MultiCatchReveal.runFirstOfType(typecodes: ["B738", nil, "E75L"],
                                                    heldTypecodes: ["B738"])
        // nil typecode has no type identity on the server either.
        #expect(flags == [false, false, true])
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

    @Test func trimsNewlinesLikeTheDetailScreen() {
        #expect(CatchShare.shareText(callsign: "UAL1\n", model: " Boeing 737\n")
                == "Caught UAL1 · Boeing 737 on Tailspot")
        #expect(CatchShare.shareText(callsign: "\n", model: nil) == "Caught a plane on Tailspot")
    }

    /// A callsign-less catch is named by its hex id on every path: the
    /// detail screen, the single reveal and the multi-catch reveal all build
    /// their copy from `CatchShare.shareText(for:)` / `identifier(for:)`.
    @Test func callsignlessCatchFallsBackToTheHexId() {
        let plane = CardPlane(callsign: " ", model: "Cessna 172", carrier: nil,
                              rarity: .common, type: .ga, icao24: "a1b2c3")
        #expect(CatchShare.identifier(for: plane) == "A1B2C3")
        #expect(CatchShare.shareText(for: plane) == "Caught A1B2C3 · Cessna 172 on Tailspot")
        let named = CardPlane(callsign: "N172SP", model: nil, carrier: nil,
                              rarity: .common, type: .ga, icao24: "a1b2c3")
        #expect(CatchShare.identifier(for: named) == "N172SP")
        let bare = CardPlane(callsign: nil, model: nil, carrier: nil, rarity: .common, type: .ga)
        #expect(CatchShare.identifier(for: bare) == nil)
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

/// The card takes hits only with a live control on it, and a body tap that
/// no control claims still continues (except while the chips are up).
@Suite struct RevealCardTapsTests {
    @Test func tapThroughUntilAControlIsLive() {
        #expect(!RevealCardTaps.cardTakesHits(chipsShown: false, settled: false,
                                              hasZoomablePhoto: true, shareAvailable: false))
        #expect(!RevealCardTaps.cardTakesHits(chipsShown: false, settled: true,
                                              hasZoomablePhoto: false, shareAvailable: false))
        #expect(RevealCardTaps.cardTakesHits(chipsShown: false, settled: true,
                                             hasZoomablePhoto: false, shareAvailable: true))
        #expect(RevealCardTaps.cardTakesHits(chipsShown: true, settled: true,
                                             hasZoomablePhoto: false, shareAvailable: false))
    }

    @Test func bodyTapContinuesUnlessTheChipsAreUp() {
        #expect(RevealCardTaps.bodyTapDismisses(chipsShown: false))
        #expect(!RevealCardTaps.bodyTapDismisses(chipsShown: true))
    }
}

/// The callsign-line Share button: a small disc, but always a ≥44 pt tap.
@Suite struct RevealShareButtonMetricsTests {
    /// Card scales the reveal actually uses: card width = min(screen − 28,
    /// 420) over the 300 pt reference, from the 375 pt SE/mini up to the cap.
    static let scales: [CGFloat] = [1.0, 347.0 / 300, 365.0 / 300, 374.0 / 300, 412.0 / 300, 420.0 / 300]

    @Test(arguments: scales)
    func hitTargetIsAtLeast44(scale: CGFloat) {
        #expect(RevealShareButtonMetrics.hitSide(scale: scale) >= 44)
        #expect(RevealShareButtonMetrics.hitSide(scale: scale) >= RevealShareButtonMetrics.disc(scale: scale))
    }

    /// The tap rect is exactly the hit side square (not wider: it used to be
    /// ~58 × 44 and reached into the name text), centred on the disc.
    @Test(arguments: scales + [2.0])
    func hitRectIsExactlyTheHitSquare(scale: CGFloat) {
        let r = RevealShareButtonMetrics.hitRect(scale: scale)
        let hit = RevealShareButtonMetrics.hitSide(scale: scale)
        let disc = RevealShareButtonMetrics.disc(scale: scale)
        #expect(r.width == hit)
        #expect(r.height == hit)
        #expect(r.minX == 0)
        #expect(abs(r.midY - disc / 2) < 0.0001)
    }

    @Test func discScalesWithTheCard() {
        #expect(RevealShareButtonMetrics.disc(scale: 1) == 30)
        #expect(RevealShareButtonMetrics.disc(scale: 1.2) == 36)
        // A disc bigger than 44 is its own hit target.
        #expect(RevealShareButtonMetrics.hitSide(scale: 2) == 60)
    }
}
