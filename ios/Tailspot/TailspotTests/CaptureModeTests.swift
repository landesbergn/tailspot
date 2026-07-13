//
//  CaptureModeTests.swift
//  TailspotTests
//
//  The capture button's mode is derived per frame by `CaptureMode.resolve`
//  from three projections: the tap-pin (if still on frame), the tight central
//  catch-zone set (anti-cheat L1), and every plane on frame. These pin the
//  resolution precedence — in particular the lone-plane fallback that keeps a
//  single off-centre plane catchable (the Portland field report: reticle
//  passive, plane plainly in frame, shutter dead) WITHOUT reopening the
//  dense-airspace spray exploit that the central zone exists to close.
//

import Testing
@testable import Tailspot

@Suite("Capture mode resolution")
@MainActor
struct CaptureModeTests {

    private typealias CaptureMode = ContentView.CaptureMode

    // MARK: - Tap-pin wins (deliberate choice, catchable anywhere on frame)

    @Test func pinnedPlaneStillOnScreenIsSingleEvenOffCentre() {
        // Pinned plane isn't in the central zone (drifted off), but it's still
        // on frame → stays catchable as the pinned single.
        let mode = CaptureMode.resolve(
            pinnedOnScreen: "PIN", catchable: [], onScreen: ["PIN", "OTHER"]
        )
        #expect(mode == .single("PIN"))
    }

    @Test func pinBeatsCentralZoneWhenBothPresent() {
        let mode = CaptureMode.resolve(
            pinnedOnScreen: "PIN", catchable: ["CENTER"], onScreen: ["PIN", "CENTER"]
        )
        #expect(mode == .single("PIN"))
    }

    // MARK: - Central catch zone (anti-cheat L1 preserved)

    @Test func singleCentredPlaneIsSingle() {
        let mode = CaptureMode.resolve(
            pinnedOnScreen: nil, catchable: ["A"], onScreen: ["A"]
        )
        #expect(mode == .single("A"))
    }

    @Test func multipleInCentralZoneStaysMulti() {
        // A real formation / approach pair centred together → multi, unchanged.
        let mode = CaptureMode.resolve(
            pinnedOnScreen: nil, catchable: ["L", "R"], onScreen: ["L", "R"]
        )
        #expect(mode == .multi(["L", "R"]))
    }

    @Test func denseSkyOffCentreStaysDisabled_noSprayExploit() {
        // The exploit the central zone closes: several planes on frame, none
        // centred, no pin. Must NOT collapse to a catch-all — you have to aim
        // or tap. The lone-plane fallback only fires for a *single* plane.
        let mode = CaptureMode.resolve(
            pinnedOnScreen: nil, catchable: [], onScreen: ["A", "B", "C"]
        )
        #expect(mode == .disabled)
    }

    // MARK: - Lone-plane fallback (the fix)

    @Test func loneOffCentrePlaneIsCatchable() {
        // The Portland case: exactly one visible plane in the whole frame,
        // outside the tight central zone, never tapped. Nothing to
        // disambiguate → catchable as a single instead of a dead shutter.
        let mode = CaptureMode.resolve(
            pinnedOnScreen: nil, catchable: [], onScreen: ["LONE"]
        )
        #expect(mode == .single("LONE"))
    }

    @Test func loneCentredPlaneUnaffected() {
        // When the lone plane IS centred it's already in `catchable`; the
        // fallback must resolve it identically (no double-count, still single).
        let mode = CaptureMode.resolve(
            pinnedOnScreen: nil, catchable: ["A"], onScreen: ["A"]
        )
        #expect(mode == .single("A"))
    }

    // MARK: - Empty frame

    @Test func emptyFrameIsDisabled() {
        let mode = CaptureMode.resolve(
            pinnedOnScreen: nil, catchable: [], onScreen: []
        )
        #expect(mode == .disabled)
    }
}
