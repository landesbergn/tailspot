//
//  GuessRoundPlannerTests.swift
//  TailspotTests
//
//  Pins the pure eligibility translation (game-layer PR3; route-only per Noah
//  2026-07-09): the mapping from a catch batch's shape + its single fresh
//  row's frozen route to the GuessScheduler inputs. Keeps ContentView's
//  sequencing a thin call — the "should this catch host a route round?" rule
//  lives here and is tested off the MainActor. Route availability delegates to
//  GuessOptions (pinned by GuessOptionsTests); these assert the batch gate +
//  wiring.
//

import Foundation
import Testing
@testable import Tailspot

@Suite("GuessRoundPlanner — eligibility inputs")
struct GuessRoundPlannerTests {

    @Test func freshSingleWithRouteCanOfferRound() {
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 1, duplicateCount: 0, suspectReason: nil,
            originIcao: "KSFO", destIcao: "VHHH"
        )
        #expect(inputs.isFreshSingle)
        #expect(!inputs.isSuspect)
        #expect(inputs.routeAvailable)
        #expect(inputs.canOfferRound)
    }

    @Test func aDuplicateInTheBatchIsNeverFreshSingle() {
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 1, duplicateCount: 1, suspectReason: nil,
            originIcao: "KSFO", destIcao: "VHHH"
        )
        #expect(!inputs.isFreshSingle)
        #expect(!inputs.canOfferRound)
    }

    @Test func aMultiCatchIsNeverFreshSingle() {
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 2, duplicateCount: 0, suspectReason: nil,
            originIcao: "KSFO", destIcao: "VHHH"
        )
        #expect(!inputs.isFreshSingle)
        #expect(!inputs.canOfferRound)
    }

    @Test func aDuplicateOnlyBatchIsNeverFreshSingle() {
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 0, duplicateCount: 1, suspectReason: nil,
            originIcao: nil, destIcao: nil
        )
        #expect(!inputs.isFreshSingle)
        #expect(!inputs.canOfferRound)
    }

    @Test func suspectReasonFlagsSuspectButStaysFreshSingle() {
        // The scheduler (not this flag) uses isSuspect to decline; a suspect
        // fresh single is still a fresh single, so the flag must surface.
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 1, duplicateCount: 0, suspectReason: "too_far",
            originIcao: "KSFO", destIcao: "VHHH"
        )
        #expect(inputs.isFreshSingle)
        #expect(inputs.isSuspect)
    }

    @Test func noRouteCannotOfferRound() {
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 1, duplicateCount: 0, suspectReason: nil,
            originIcao: nil, destIcao: nil
        )
        #expect(inputs.isFreshSingle)
        #expect(!inputs.routeAvailable)
        #expect(!inputs.canOfferRound)
    }

    @Test func routelessCatchCannotOfferRound() {
        // A routeless catch (small/unknown fields) hosts no round now that
        // type guessing is gone — even with a resolvable typecode.
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 1, duplicateCount: 0, suspectReason: nil,
            originIcao: "K0X9", destIcao: "K1X1"
        )
        #expect(inputs.isFreshSingle)
        #expect(!inputs.routeAvailable)
        #expect(!inputs.canOfferRound)
    }
}
