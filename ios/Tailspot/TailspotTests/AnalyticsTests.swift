//
//  AnalyticsTests.swift
//  TailspotTests
//
//  Swift Testing suite for the Analytics facade (Analytics.swift).
//
//  Analytics is now a thin facade over the PostHog SDK behind an
//  `AnalyticsSink` seam. The SDK itself is process-global and not injectable,
//  so these tests substitute a recording `AnalyticsSink` via `Analytics._testSink`
//  and assert that `capture`/`identify`/`flush` forward faithfully. The previous
//  REST queue/transport/batch tests were removed with that pipeline (consolidated
//  onto the SDK, 2026-06-27).
//
//  `Analytics._testSink` is process-global, so the facade suite is `.serialized`.
//

import Foundation
import Testing
@testable import Tailspot

// MARK: - AnalyticsValue encoding

@Suite("AnalyticsValue")
struct AnalyticsValueTests {

    @Test func stringValueRoundTrips() throws {
        #expect(AnalyticsValue.string("hello").jsonValue as? String == "hello")
    }

    @Test func intValueRoundTrips() throws {
        #expect(AnalyticsValue.int(42).jsonValue as? Int == 42)
    }

    @Test func doubleValueRoundTrips() throws {
        #expect(abs((AnalyticsValue.double(3.14).jsonValue as? Double ?? 0) - 3.14) < 1e-9)
    }

    @Test func boolValueRoundTrips() throws {
        #expect(AnalyticsValue.bool(true).jsonValue as? Bool == true)
        #expect(AnalyticsValue.bool(false).jsonValue as? Bool == false)
    }

    @Test func jsonSerializationPreservesAllTypes() throws {
        // Mirrors what PostHogAnalyticsSink hands the SDK: properties mapped to
        // their jsonValue must survive JSON round-trip with types intact.
        let props: [String: AnalyticsValue] = [
            "name":   .string("vapor_trail"),
            "count":  .int(7),
            "ratio":  .double(0.5),
            "active": .bool(true),
        ]
        let obj = props.mapValues { $0.jsonValue }
        let data = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(decoded?["name"] as? String == "vapor_trail")
        #expect(decoded?["count"] as? Int == 7)
        #expect(decoded?["active"] as? Bool == true)
    }
}

// MARK: - Recording sink

/// Records every facade call. `@unchecked Sendable` + a lock because the
/// `AnalyticsSink` methods are synchronous and may be called off the test thread.
private final class RecordingSink: AnalyticsSink, @unchecked Sendable {
    struct Captured: Sendable { let event: String; let properties: [String: AnalyticsValue] }

    private let lock = NSLock()
    private var _captured: [Captured] = []
    private var _identifies: [(id: String, handle: String?)] = []
    private var _flushes = 0

    var captured: [Captured] { lock.lock(); defer { lock.unlock() }; return _captured }
    var identifies: [(id: String, handle: String?)] { lock.lock(); defer { lock.unlock() }; return _identifies }
    var flushes: Int { lock.lock(); defer { lock.unlock() }; return _flushes }

    func capture(_ event: String, _ properties: [String: AnalyticsValue]) {
        lock.lock(); _captured.append(.init(event: event, properties: properties)); lock.unlock()
    }
    func identify(_ distinctId: String, handle: String?) {
        lock.lock(); _identifies.append((distinctId, handle)); lock.unlock()
    }
    func flush() { lock.lock(); _flushes += 1; lock.unlock() }
}

// MARK: - Facade forwarding

/// The only suite that touches `Analytics._testSink` (process-global), so it is
/// `.serialized` to avoid races with itself across tests.
@Suite("Analytics facade", .serialized)
struct AnalyticsFacadeTests {

    private func withSink(_ body: (RecordingSink) -> Void) {
        let sink = RecordingSink()
        let previous = Analytics._testSink
        defer { Analytics._testSink = previous }
        Analytics._testSink = sink
        body(sink)
    }

    /// Run `body` with the stored spotter handle set to `handle` (or cleared),
    /// restoring whatever was there before. The facade reads the handle from
    /// UserDefaults, so these tests have to drive that same global.
    private func withStoredHandle(_ handle: String?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: SpotterHandle.storageKey)
        defer {
            if let previous { defaults.set(previous, forKey: SpotterHandle.storageKey) }
            else { defaults.removeObject(forKey: SpotterHandle.storageKey) }
        }
        if let handle { defaults.set(handle, forKey: SpotterHandle.storageKey) }
        else { defaults.removeObject(forKey: SpotterHandle.storageKey) }
        body()
    }

    // MARK: - handle stamping (the facade WIRING, not the pure decorator)

    // AnalyticsIdentityTests covers withHandleProperty in isolation. These pin
    // the seam it hangs off: that Analytics.capture actually reads the stored
    // handle and hands the decorated properties to the sink. Without these the
    // decorator could be perfect and still never run in production.

    @Test func captureStampsHandleOnCatchSpineEvents() {
        withStoredHandle("mach_6415") {
            withSink { sink in
                Analytics.capture("catch_uploaded", ["icao24": .string("a1b2c3")])
                let props = sink.captured.first?.properties
                #expect(props?["handle"]?.jsonValue as? String == "mach_6415")
                #expect(props?["icao24"]?.jsonValue as? String == "a1b2c3")
            }
        }
    }

    @Test func captureStampsHandleOnEveryDeclaredEvent() {
        withStoredHandle("mach_6415") {
            withSink { sink in
                for event in AnalyticsIdentity.eventsCarryingHandle {
                    Analytics.capture(event)
                }
                #expect(sink.captured.count == AnalyticsIdentity.eventsCarryingHandle.count)
                for row in sink.captured {
                    #expect(row.properties["handle"]?.jsonValue as? String == "mach_6415",
                            "\(row.event) lost the handle through the facade")
                }
            }
        }
    }

    @Test func captureLeavesUndeclaredEventsUntouched() {
        withStoredHandle("mach_6415") {
            withSink { sink in
                Analytics.capture("catch_local_gate", ["verdict": .string("pass")])
                let props = sink.captured.first?.properties
                #expect(props?["handle"] == nil)
                #expect(props?.count == 1)
            }
        }
    }

    @Test func captureNeverStampsThePlaceholderHandle() {
        withStoredHandle(SpotterHandle.defaultPlaceholder) {
            withSink { sink in
                Analytics.capture("catch_uploaded")
                #expect(sink.captured.first?.properties["handle"] == nil)
            }
        }
    }

    @Test func captureOmitsHandleWhenNoneStored() {
        withStoredHandle(nil) {
            withSink { sink in
                Analytics.capture("catch_uploaded")
                #expect(sink.captured.first?.properties["handle"] == nil)
            }
        }
    }

    @Test func captureForwardsEventAndProperties() {
        withSink { sink in
            Analytics.capture("app_opened", ["app_build": .string("99"), "n": .int(3)])
            #expect(sink.captured.count == 1)
            #expect(sink.captured.first?.event == "app_opened")
            #expect(sink.captured.first?.properties["app_build"]?.jsonValue as? String == "99")
            #expect(sink.captured.first?.properties["n"]?.jsonValue as? Int == 3)
        }
    }

    @Test func captureWithNoPropertiesForwardsEmpty() {
        withSink { sink in
            Analytics.capture("leaderboard_viewed")
            #expect(sink.captured.first?.event == "leaderboard_viewed")
            #expect(sink.captured.first?.properties.isEmpty == true)
        }
    }

    @Test func identifyForwardsIdAndHandle() {
        withSink { sink in
            Analytics.identify("e28e8d13-server-id", handle: "mach_6415")
            #expect(sink.identifies.count == 1)
            #expect(sink.identifies.first?.id == "e28e8d13-server-id")
            #expect(sink.identifies.first?.handle == "mach_6415")
        }
    }

    @Test func identifyWithoutHandleForwardsNilHandle() {
        withSink { sink in
            Analytics.identify("e28e8d13-server-id")
            #expect(sink.identifies.first?.id == "e28e8d13-server-id")
            #expect(sink.identifies.first?.handle == nil)
        }
    }

    @Test func flushForwards() {
        withSink { sink in
            Analytics.flush()
            #expect(sink.flushes == 1)
        }
    }
}

// MARK: - No-op when keyless

@Suite("Analytics keyless no-op", .serialized)
struct AnalyticsKeylessTests {
    // With no _testSink installed and no PostHogAPIKey in the test bundle, the
    // production sink is nil — every call must be a silent no-op (no crash).
    @Test func captureAndIdentifyAreNoOpWithoutKey() {
        let previous = Analytics._testSink
        defer { Analytics._testSink = previous }
        Analytics._testSink = nil

        Analytics.capture("keyless_event", ["should": .string("drop")])
        Analytics.identify("keyless-id", handle: "nobody")
        Analytics.flush()
        // Absence of crash IS the test.
    }
}
