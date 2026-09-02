//
//  AnalyticsIdentityTests.swift
//  TailspotTests
//
//  Swift Testing suite for AnalyticsIdentity — the pure decision logic that
//  governs WHEN and with WHICH id we call PostHog's identify() at launch.
//
//  Background: the duplicate-person bug (2026-06-26). Identifying at launch
//  with a freshly-minted local id (before the device registered and got its
//  canonical server id) pinned the SDK to a non-canonical identity, fragmenting
//  one device into two PostHog persons. These tests pin the corrected rule:
//  identify at launch ONLY for a returning, registered user (a persisted device
//  id already exists) who has a claimed handle.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("AnalyticsIdentity")
struct AnalyticsIdentityTests {

    private let placeholder = "spotter_42"

    // MARK: - launchIdentity

    @Test func identifiesReturningUserWithIdAndHandle() {
        let id = "f07c3db3-71d1-46a6-9e90-1d22364a66ff"
        #expect(AnalyticsIdentity.launchIdentity(deviceId: id, hasClaimedHandle: true) == id)
    }

    @Test func defersWhenNoDeviceIdYet() {
        // Genuine first launch: no canonical id exists. Must NOT identify
        // (would otherwise mint/pin a throwaway local id).
        #expect(AnalyticsIdentity.launchIdentity(deviceId: nil, hasClaimedHandle: true) == nil)
    }

    @Test func defersWhenDeviceIdEmpty() {
        #expect(AnalyticsIdentity.launchIdentity(deviceId: "", hasClaimedHandle: true) == nil)
    }

    @Test func defersWhenNoClaimedHandle() {
        // Registered but mid-onboarding (placeholder/no handle): defer to the
        // post-claim identify so the SDK's first identify uses the server id.
        let id = "f07c3db3-71d1-46a6-9e90-1d22364a66ff"
        #expect(AnalyticsIdentity.launchIdentity(deviceId: id, hasClaimedHandle: false) == nil)
    }

    // MARK: - isClaimedHandle

    @Test func placeholderIsNotClaimed() {
        #expect(AnalyticsIdentity.isClaimedHandle(placeholder, placeholder: placeholder) == false)
    }

    @Test func nilIsNotClaimed() {
        #expect(AnalyticsIdentity.isClaimedHandle(nil, placeholder: placeholder) == false)
    }

    @Test func emptyAndWhitespaceAreNotClaimed() {
        #expect(AnalyticsIdentity.isClaimedHandle("", placeholder: placeholder) == false)
        #expect(AnalyticsIdentity.isClaimedHandle("   ", placeholder: placeholder) == false)
    }

    @Test func realHandleIsClaimed() {
        #expect(AnalyticsIdentity.isClaimedHandle("purple_hour", placeholder: placeholder) == true)
    }

    @Test func realHandleWithSurroundingWhitespaceIsClaimed() {
        #expect(AnalyticsIdentity.isClaimedHandle("  purple_hour  ", placeholder: placeholder) == true)
    }

    // MARK: - End-to-end decision

    @Test func returningUserEndToEnd() {
        // Mirrors the launch wiring: a returning user with a real handle and a
        // persisted device id identifies with that id.
        let id = "E7E670A3-A5E6-4C7A-B4E1-806188D006F0"
        let claimed = AnalyticsIdentity.isClaimedHandle("purple_hour", placeholder: placeholder)
        #expect(AnalyticsIdentity.launchIdentity(deviceId: id, hasClaimedHandle: claimed) == id)
    }

    @Test func firstLaunchUserEndToEnd() {
        // First launch: placeholder handle + no device id → defer.
        let claimed = AnalyticsIdentity.isClaimedHandle(placeholder, placeholder: placeholder)
        #expect(AnalyticsIdentity.launchIdentity(deviceId: nil, hasClaimedHandle: claimed) == nil)
    }

    // MARK: - launchUserProperties (handle self-heal on launch)

    @Test func launchSetsHandleForClaimedUser() {
        // A returning user with a real handle re-attaches it to the canonical
        // person on launch, so a profile missing the handle self-heals.
        let props = AnalyticsIdentity.launchUserProperties(handle: "purple_hour", placeholder: placeholder)
        #expect(props?["handle"] as? String == "purple_hour")
    }

    @Test func launchTrimsHandleWhitespace() {
        let props = AnalyticsIdentity.launchUserProperties(handle: "  purple_hour  ", placeholder: placeholder)
        #expect(props?["handle"] as? String == "purple_hour")
    }

    @Test func launchSetsNothingWithoutClaimedHandle() {
        // Placeholder / nil / empty / whitespace → no $set (nothing to sync).
        #expect(AnalyticsIdentity.launchUserProperties(handle: placeholder, placeholder: placeholder) == nil)
        #expect(AnalyticsIdentity.launchUserProperties(handle: nil, placeholder: placeholder) == nil)
        #expect(AnalyticsIdentity.launchUserProperties(handle: "", placeholder: placeholder) == nil)
        #expect(AnalyticsIdentity.launchUserProperties(handle: "   ", placeholder: placeholder) == nil)
    }

    // MARK: - identifyRoute (pinned-id fallback)
    //
    // posthog-ios silently drops identify() when the SDK is already identified
    // under a different distinct_id — the handle `$set` inside it included.
    // These tests pin the routing that works around it (2026-07-04: claimed
    // handles eagle_eye/skywatcher never reached PostHog because of this).

    private let serverId = "edd4da6a-e4d9-49a3-8476-71d604edd2eb"
    private let staleLocalId = "91DB621E-E353-4874-9991-8986FB8D823F"
    private let anonId = "019EE2B8-D400-708E-A2BE-BB72D4FDD331"

    @Test func firstIdentifyRoutesToIdentify() {
        // Not yet identified (distinct id == anonymous id): the SDK accepts
        // identify with a new id — the normal registration/claim path.
        #expect(AnalyticsIdentity.identifyRoute(target: serverId,
                                                currentDistinctId: anonId,
                                                anonymousId: anonId,
                                                hasHandle: true) == .identify)
    }

    @Test func reIdentifySameIdRoutesToIdentify() {
        // Already identified with the SAME id: posthog-ios turns the repeat
        // into a `$set` of the user properties — the launch self-heal.
        #expect(AnalyticsIdentity.identifyRoute(target: serverId,
                                                currentDistinctId: serverId,
                                                anonymousId: anonId,
                                                hasHandle: true) == .identify)
    }

    @Test func pinnedToStaleIdFallsBackToSetHandle() {
        // Identified under a DIFFERENT id (pre-#76 pinned device): identify
        // would be silently dropped, so the handle must be `$set` on the
        // person the SDK is pinned to.
        #expect(AnalyticsIdentity.identifyRoute(target: serverId,
                                                currentDistinctId: staleLocalId,
                                                anonymousId: anonId,
                                                hasHandle: true) == .setHandleOnCurrentPerson)
    }

    @Test func pinnedToStaleIdWithoutHandleDrops() {
        // Same pinned state but nothing to salvage: don't emit anything.
        #expect(AnalyticsIdentity.identifyRoute(target: serverId,
                                                currentDistinctId: staleLocalId,
                                                anonymousId: anonId,
                                                hasHandle: false) == .drop)
    }

    // MARK: - withHandleProperty (handle as an EVENT property)

    private func handleValue(_ props: [String: AnalyticsValue]) -> String? {
        props["handle"]?.jsonValue as? String
    }

    @Test func stampsHandleOnCatchSpineEvents() {
        for event in AnalyticsIdentity.eventsCarryingHandle {
            let p = AnalyticsIdentity.withHandleProperty(
                event: event,
                properties: ["icao24": .string("a1b2c3")],
                handle: "mach_6415",
                placeholder: placeholder
            )
            #expect(handleValue(p) == "mach_6415", "\(event) should carry the handle")
            // The decorator must never disturb the caller's own properties.
            #expect(p["icao24"]?.jsonValue as? String == "a1b2c3")
        }
    }

    @Test func theSixDocumentedEventsCarryTheHandle() {
        // Pin the exact set: adding one is a deliberate act, not a drive-by.
        #expect(AnalyticsIdentity.eventsCarryingHandle == [
            "catch_uploaded", "catch_performed", "first_plane_catch",
            "catch_deleted", "streak_extended", "trophy_unlocked",
        ])
    }

    @Test func leavesOtherEventsAlone() {
        // Gate/timing events stay lean - they're read in aggregate, per-user
        // attribution would only add noise and payload.
        let p = AnalyticsIdentity.withHandleProperty(
            event: "catch_local_gate",
            properties: ["verdict": .string("pass")],
            handle: "mach_6415",
            placeholder: placeholder
        )
        #expect(handleValue(p) == nil)
        #expect(p.count == 1)
    }

    @Test func doesNotStampThePlaceholderHandle() {
        // An un-onboarded user must never ship the placeholder as a real handle.
        let p = AnalyticsIdentity.withHandleProperty(
            event: "catch_uploaded", properties: [:],
            handle: placeholder, placeholder: placeholder
        )
        #expect(handleValue(p) == nil)
    }

    @Test func doesNotStampMissingOrBlankHandle() {
        for handle in [nil, "", "   "] as [String?] {
            let p = AnalyticsIdentity.withHandleProperty(
                event: "catch_uploaded", properties: [:],
                handle: handle, placeholder: placeholder
            )
            #expect(handleValue(p) == nil)
        }
    }

    @Test func trimsHandleWhitespace() {
        let p = AnalyticsIdentity.withHandleProperty(
            event: "streak_extended", properties: [:],
            handle: "  mach_6415  ", placeholder: placeholder
        )
        #expect(handleValue(p) == "mach_6415")
    }

    @Test func anExplicitHandlePropertyWins() {
        // A call site that already knows the handle stays authoritative.
        let p = AnalyticsIdentity.withHandleProperty(
            event: "catch_uploaded",
            properties: ["handle": .string("explicit_one")],
            handle: "stored_one", placeholder: placeholder
        )
        #expect(handleValue(p) == "explicit_one")
    }
}
