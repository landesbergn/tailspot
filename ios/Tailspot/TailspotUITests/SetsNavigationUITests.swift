//
//  SetsNavigationUITests.swift
//  TailspotUITests
//
//  Regression guard for the Hangar → Sets → model navigation. A real bug
//  shipped where tapping a set in the Sets segment did nothing: the
//  `navigationDestination(for: CardSet.self)` was declared inside SetsBrowser,
//  which renders inside HangarView's paged TabView — and SwiftUI does not
//  register a navigationDestination placed inside a TabView page with the
//  enclosing NavigationStack, so the value-based set tap had no destination.
//  Only a UI test catches this (SwiftUI view structure isn't unit-introspectable).
//
//  Uses the `-uiTestHangar` launch hook (RootView) to boot straight into the
//  Hangar with a seeded catch, avoiding the camera/permission AR flow the
//  simulator can't run.
//
//  NOTE: the default CI gate runs unit tests only (`-only-testing:TailspotTests`).
//  This UI test lives in the TailspotUITests target — run it before a release,
//  or add it to CI if you want it gating merges.
//

import XCTest

final class SetsNavigationUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testTappingASetOpensItsModelList() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestHangar"]
        app.launch()

        // Boots into the Hangar (seeded catch makes the segmented browser show).
        // The Sets segment is the default, but tap it to be explicit.
        let setsSegment = app.buttons["Sets"]
        XCTAssertTrue(setsSegment.waitForExistence(timeout: 15),
                      "Hangar Sets segment never appeared")
        setsSegment.tap()

        // Tap the first set card.
        let firstSet = app.buttons["setCard"].firstMatch
        XCTAssertTrue(firstSet.waitForExistence(timeout: 5),
                      "No set cards rendered in the Sets browser")
        firstSet.tap()

        // The set detail must appear — its "MODELS" section header. Before the
        // fix the tap was a no-op and this never showed up.
        let modelsHeader = app.staticTexts["MODELS"]
        XCTAssertTrue(modelsHeader.waitForExistence(timeout: 5),
                      "Tapping a set did not open its model list — Sets navigation regression")
    }
}
