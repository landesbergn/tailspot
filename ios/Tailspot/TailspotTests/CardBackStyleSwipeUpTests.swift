//
//  CardBackStyleSwipeUpTests.swift
//  TailspotTests
//
//  Pins the "Swipe up" card-back pager's geometry (PullUpMath): the slot's
//  fixed height, the scroll distance between the card and the back, and
//  the tab's label turning over as the scroll goes.
//

import Testing
import CoreGraphics
@testable import Tailspot

@Suite("Swipe-up card back math")
struct CardBackStyleSwipeUpTests {
    let frontHeight: CGFloat = 560

    /// Just the card and a compact tab: nothing of the back peeks below,
    /// so the slot is as short as it can be (it has to fit above the
    /// reveal's "tap to continue" strip).
    @Test func windowHoldsJustTheCardAndTheTab() {
        #expect(PullUpMath.windowHeight(frontHeight: frontHeight)
                == frontHeight + PullUpMath.tabHeight)
        #expect(PullUpMath.tabHeight <= 40)
    }

    /// At the back's snap point the window shows the tab and the whole back
    /// (the back is laid out at the card's height), exactly — nothing cut
    /// off at the bottom.
    @Test func backSnapPointShowsTheTabAndTheWholeBack() {
        let step = PullUpMath.step(frontHeight: frontHeight)
        #expect(step == frontHeight)
        let shownBelowSnap = PullUpMath.windowHeight(frontHeight: frontHeight)
        #expect(shownBelowSnap == PullUpMath.tabHeight + frontHeight)
        #expect(PullUpMath.step(frontHeight: -5) == 0)
    }

    @Test func tabLabelTurnsOverAcrossTheScroll() {
        #expect(PullUpMath.aboutOpacity(progress: 0) == 1)
        #expect(PullUpMath.backToCatchOpacity(progress: 0) == 0)
        // Never both at once: one fades out before the other fades in.
        #expect(PullUpMath.aboutOpacity(progress: 0.5) == 0)
        #expect(PullUpMath.backToCatchOpacity(progress: 0.5) == 0)
        #expect(PullUpMath.aboutOpacity(progress: 1) == 0)
        #expect(PullUpMath.backToCatchOpacity(progress: 1) == 1)
    }

    @Test func chevronTurnsFromUpToDown() {
        #expect(PullUpMath.chevronDegrees(progress: 0) == 0)
        #expect(PullUpMath.chevronDegrees(progress: 0.5) == 90)
        #expect(PullUpMath.chevronDegrees(progress: 1) == 180)
        #expect(PullUpMath.chevronDegrees(progress: 1.3) == 180)
    }
}
