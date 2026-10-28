//
//  CardFlipDemoUITests.swift
//  TailspotUITests
//
//  Not a regression test: a scripted walk through the catch card's flip for
//  screen recordings (`xcrun simctl io <udid> recordVideo` while it runs).
//  Boots on the `-demoCatchReveal` hook, waits for the peek, then swipes
//  both ways, swipes from the photo, and taps both halves of the turn control.
//

import XCTest

final class CardFlipDemoUITests: XCTestCase {

    func testFlipWalkthrough() {
        let app = XCUIApplication()
        app.launchArguments = ["-demoCatchReveal"]
        app.launch()

        // The reveal ceremony, then the peek (first five showings only).
        sleep(6)

        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        }
        func swipe(fromX: CGFloat, toX: CGFloat, y: CGFloat) {
            point(fromX, y).press(forDuration: 0.05, thenDragTo: point(toX, y),
                                  withVelocity: .fast, thenHoldForDuration: 0)
            sleep(2)
        }

        // Swipe left on the card body: it turns over to the back.
        swipe(fromX: 0.8, toX: 0.2, y: 0.55)
        // Swipe right: back to the front the other way.
        swipe(fromX: 0.2, toX: 0.8, y: 0.55)
        // A swipe that starts on the photo turns the card and opens nothing.
        swipe(fromX: 0.75, toX: 0.15, y: 0.22)

        // Tap BACK TO CATCH (under the card) on its left half: the card
        // turns left. The same control then reads ABOUT THIS PLANE; tap
        // its right half.
        let back = app.buttons["Back to catch"]
        if back.waitForExistence(timeout: 3) {
            let f = back.frame
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: f.minX + f.width * 0.2, dy: f.midY)).tap()
            sleep(2)
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: f.minX + f.width * 0.75, dy: f.midY)).tap()
            sleep(3)
        }
    }

    /// Still screenshots of both faces for review docs: the settled front,
    /// then the back after a tap on ABOUT THIS PLANE. Saved as test
    /// attachments (`xcresulttool export attachments`).
    func testFaceScreenshots() {
        let app = XCUIApplication()
        app.launchArguments = ["-demoCatchReveal"]
        app.launch()
        sleep(7)
        keep(app, "front")
        let about = app.buttons["About this plane"]
        if about.waitForExistence(timeout: 3) {
            about.tap()
            sleep(2)
            keep(app, "back")
        }
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
