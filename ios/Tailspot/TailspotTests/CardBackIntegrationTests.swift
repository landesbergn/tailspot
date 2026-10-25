//
//  CardBackIntegrationTests.swift
//  TailspotTests
//
//  The glue between the card back and its two hosts (CatchDetailView and
//  CatchRevealView, 2026-10-25): which closeup a host shows from its
//  lookups, the `catch_card_turned` event's shape, and the reveal's tap
//  rules once the card can turn over.
//

import Testing
import Foundation
@testable import Tailspot

nonisolated private enum Fx {
    static let spotter = PlanePhoto(
        thumbnailLargeURL: URL(string: "https://t.plnspttrs.net/00000/0000000_280.jpg")!,
        thumbnailURL: URL(string: "https://t.plnspttrs.net/00000/0000000_t.jpg")!,
        link: URL(string: "https://www.planespotters.net/photo/0000000")!,
        photographer: "Test Photographer")
    static let commons = TypePhoto(
        imageURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/x/xx/E.jpg/800px-E.jpg")!,
        pageURL: URL(string: "https://commons.wikimedia.org/wiki/File:E.jpg")!,
        artist: "Example Artist", license: "CC BY-SA 4.0")
}

@Suite struct CardBackCloseupResolveTests {
    @Test func theExactAirframeWins() {
        #expect(CardBackCloseup.resolve(planespotters: Fx.spotter, lookupDone: true,
                                        typePhoto: Fx.commons) == .planespotters(Fx.spotter))
    }

    @Test func loadingUntilPlanespottersAnswers() {
        // The Commons photo must not flash up and then be replaced.
        #expect(CardBackCloseup.resolve(planespotters: nil, lookupDone: false,
                                        typePhoto: Fx.commons) == .loading)
    }

    @Test func aMissFallsBackToTheTypePhotoThenTheSky() {
        #expect(CardBackCloseup.resolve(planespotters: nil, lookupDone: true,
                                        typePhoto: Fx.commons) == .commons(Fx.commons))
        #expect(CardBackCloseup.resolve(planespotters: nil, lookupDone: true,
                                        typePhoto: nil) == .none)
    }
}

@Suite struct CardTurnAnalyticsTests {
    private func strings(_ p: [String: AnalyticsValue]) -> [String: String] {
        p.mapValues { "\($0.jsonValue)" }
    }

    @Test func turningToTheBackFromTheDetail() {
        let p = CardTurnAnalytics.properties(source: .detail, flipped: true,
                                             closeup: .commons(Fx.commons), hasTypeInfo: true)
        #expect(strings(p) == ["source": "detail", "side": "back",
                               "closeup": "commons", "has_type_info": "true"])
        if case .bool(let b)? = p["has_type_info"] { #expect(b) } else { Issue.record("not a bool") }
    }

    @Test func turningBackOnTheReveal() {
        let p = CardTurnAnalytics.properties(source: .reveal, flipped: false,
                                             closeup: .loading, hasTypeInfo: false)
        #expect(strings(p) == ["source": "reveal", "side": "front",
                               "closeup": "loading", "has_type_info": "false"])
    }

    @Test func everyCloseupHasAName() {
        #expect(CardBackCloseup.planespotters(Fx.spotter).analyticsValue == "planespotters")
        #expect(CardBackCloseup.commons(Fx.commons).analyticsValue == "commons")
        #expect(CardBackCloseup.none.analyticsValue == "none")
        #expect(CardBackCloseup.loading.analyticsValue == "loading")
    }
}

@Suite struct RevealCardTurnOverTests {
    @Test func aTurnedCardNeverContinuesOnABodyTap() {
        #expect(!RevealCardTaps.bodyTapDismisses(chipsShown: false, flipped: true))
        #expect(!RevealCardTaps.bodyTapDismisses(chipsShown: true, flipped: true))
        #expect(RevealCardTaps.bodyTapDismisses(chipsShown: false, flipped: false))
    }

    @Test func turnOverGoesLiveWithShare() {
        #expect(RevealCardTaps.turnOverAvailable(shareAvailable: true))
        #expect(!RevealCardTaps.turnOverAvailable(shareAvailable: false))
        // …and whenever it is live the card takes hits, so the button works.
        #expect(RevealCardTaps.cardTakesHits(chipsShown: false, settled: true,
                                             hasZoomablePhoto: false, shareAvailable: true))
    }
}

@Suite struct CardBackLoadPlanTests {
    @Test func nothingIsFetchedBeforeTheFirstTurnOver() {
        #expect(CardBackLoadPlan.make(turnedOver: false, alreadyLoaded: false, loaderHasRow: true,
                                      liveIcao: "a1b2c3", loaderIcao: "a1b2c3") == nil)
    }

    @Test func itLoadsOnlyOnce() {
        #expect(CardBackLoadPlan.make(turnedOver: true, alreadyLoaded: true, loaderHasRow: true,
                                      liveIcao: "a1b2c3", loaderIcao: nil) == nil)
    }

    @Test func theLoaderRowWinsThenTheNewestByIcaoThenNothing() {
        let loader = CardBackLoadPlan.make(turnedOver: true, alreadyLoaded: false, loaderHasRow: true,
                                           liveIcao: "A1B2C3", loaderIcao: "a1b2c3")
        #expect(loader == CardBackLoadPlan(row: .loader, planespottersIcao: "a1b2c3"))

        let dup = CardBackLoadPlan.make(turnedOver: true, alreadyLoaded: false, loaderHasRow: false,
                                        liveIcao: " A1B2C3 ", loaderIcao: nil)
        #expect(dup == CardBackLoadPlan(row: .newestByIcao("a1b2c3"), planespottersIcao: "a1b2c3"))

        let sim = CardBackLoadPlan.make(turnedOver: true, alreadyLoaded: false, loaderHasRow: false,
                                        liveIcao: nil, loaderIcao: "")
        #expect(sim == CardBackLoadPlan(row: .none, planespottersIcao: nil))
    }

    @Test func theLiveIcaoIsPreferredOverTheLoaders() {
        let plan = CardBackLoadPlan.make(turnedOver: true, alreadyLoaded: false, loaderHasRow: false,
                                         liveIcao: "aaaaaa", loaderIcao: "bbbbbb")
        #expect(plan?.planespottersIcao == "aaaaaa")
    }
}
