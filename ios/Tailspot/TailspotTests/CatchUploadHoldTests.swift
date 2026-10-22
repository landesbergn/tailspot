//
//  CatchUploadHoldTests.swift
//  TailspotTests
//
//  Pins the route-guess upload hold. A catch row is POSTed exactly once, and
//  the server only awards the +25% route-guess bonus for a guess it sees in
//  that POST. From 1.1.0 the per-catch immediate upload always beat the
//  answer, so the server saw ~10 of ~2,490 guesses. The fix holds a catch
//  hosting a bonus round out of every upload sweep until the guess resolves,
//  with a 120 s safety expiry so a forgotten hold can't strand the catch.
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@Suite("Catch upload guess hold")
struct CatchUploadHoldTests {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("a held row is skipped by the uploader")
    func heldRowSkipped() {
        var holds = CatchUploadHolds()
        holds.hold("uuid-a", now: t0)
        #expect(holds.isHeld("uuid-a", now: t0))
        #expect(holds.isHeld("uuid-a", now: t0.addingTimeInterval(119)))
    }

    @Test("a hold expires after the timeout, so the catch still uploads")
    func expiredHoldReleased() {
        var holds = CatchUploadHolds()
        holds.hold("uuid-a", now: t0)
        #expect(CatchUploadHolds.timeout == 120)
        #expect(!holds.isHeld("uuid-a", now: t0.addingTimeInterval(120)))
        #expect(!holds.isHeld("uuid-a", now: t0.addingTimeInterval(600)))
    }

    @Test("rows without a hold, or without a serverUuid, upload as before")
    func unheldRowPasses() {
        var holds = CatchUploadHolds()
        holds.hold("uuid-a", now: t0)
        #expect(!holds.isHeld("uuid-b", now: t0))
        #expect(!holds.isHeld(nil, now: t0))
        #expect(!CatchUploadHolds.isHeld(key: "uuid-a", holds: [:], now: t0))
    }

    @Test("release removes the hold and reports whether there was one")
    func releaseRemovesHold() {
        var holds = CatchUploadHolds()
        holds.hold("uuid-a", now: t0)
        holds.hold("uuid-b", now: t0)
        let first = holds.release("uuid-a")
        #expect(first)
        #expect(!holds.isHeld("uuid-a", now: t0))
        #expect(holds.isHeld("uuid-b", now: t0))
        // A second release (e.g. answer, then the reveal's close button) is a
        // no-op that tells the caller not to kick another upload.
        let again = holds.release("uuid-a")
        let never = holds.release("never-held")
        #expect(!again)
        #expect(!never)
    }

    @Test("the live registry gates a real Catch row by its serverUuid")
    @MainActor
    func liveRegistryGatesRow() {
        let row = Catch(
            icao24: "abc123", callsign: "UAL1", model: "Boeing 737-800",
            manufacturer: "Boeing", operatorName: "United", caughtAt: t0,
            observerLat: 37.8, observerLon: -122.27, slantDistanceMeters: 9000
        )
        let key = UUID().uuidString
        // Before the row has a serverUuid it can't be held.
        #expect(!CatchUploader.isHeldForGuess(row))
        row.serverUuid = key
        #expect(!CatchUploader.isHeldForGuess(row))
        CatchUploader.guessHolds.hold(key)
        #expect(CatchUploader.isHeldForGuess(row))
        let released = CatchUploader.guessHolds.release(key)
        #expect(released)
        #expect(!CatchUploader.isHeldForGuess(row))
    }

    // MARK: - When runCatch places the hold

    /// Stand-ins for RevealLoader instances (the helper compares identity).
    private final class Shell {}

    @Test("no guess question: never held")
    func noGuessNeverHeld() {
        let shell = Shell()
        #expect(!CatchUploadHolds.shouldHold(hasGuess: false, earlyShell: nil, shellOnScreen: nil))
        #expect(!CatchUploadHolds.shouldHold(hasGuess: false, earlyShell: shell, shellOnScreen: shell))
    }

    @Test("no early shell: held, runCatch presents the reveal with the question")
    func noEarlyShellHeld() {
        #expect(CatchUploadHolds.shouldHold(hasGuess: true, earlyShell: nil, shellOnScreen: nil))
        // Whatever is on screen doesn't matter on this path.
        #expect(CatchUploadHolds.shouldHold(hasGuess: true, earlyShell: nil, shellOnScreen: Shell()))
    }

    @Test("this catch's own shell is on screen: held")
    func ownShellHeld() {
        let shell = Shell()
        #expect(CatchUploadHolds.shouldHold(hasGuess: true, earlyShell: shell, shellOnScreen: shell))
    }

    @Test("another catch's shell is on screen: not held")
    func otherShellNotHeld() {
        // The user closed catch 1's shell and started catch 2. Catch 2's
        // callbacks only release catch 2's row, so holding catch 1 would
        // strand it until the 120 s expiry.
        #expect(!CatchUploadHolds.shouldHold(hasGuess: true, earlyShell: Shell(), shellOnScreen: Shell()))
    }

    @Test("the shell was dismissed: not held")
    func dismissedShellNotHeld() {
        #expect(!CatchUploadHolds.shouldHold(hasGuess: true, earlyShell: Shell(), shellOnScreen: nil))
    }

    // MARK: - Timeout path

    @Test("the timeout path drops an unreleased hold and sweeps")
    @MainActor
    func timeoutExpiresUnreleasedHold() {
        let key = UUID().uuidString
        CatchUploader.guessHolds.hold(key)
        #expect(CatchUploader.expireGuessHold(key))
        #expect(CatchUploader.guessHolds.placedAt[key] == nil)
    }

    @Test("a hold released early leaves the timeout path nothing to do")
    @MainActor
    func timeoutSkipsReleasedHold() {
        let key = UUID().uuidString
        CatchUploader.guessHolds.hold(key)
        let released = CatchUploader.guessHolds.release(key)
        #expect(released)
        #expect(!CatchUploader.expireGuessHold(key))
    }
}

// MARK: - The real uploadPending honours a hold

/// Answers every request with a 500 and records it. A 500 has no side
/// effects in the uploader: registration (if it runs) throws before touching
/// the Keychain, and a failed catch POST leaves the row pending, with no
/// save and no telemetry.
final class CatchUploadHoldStubProtocol: URLProtocol {
    nonisolated(unsafe) static var recorded: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorded.append(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("CatchUploader.uploadPending skips held rows", .serialized)
@MainActor
struct CatchUploadHoldSweepTests {

    init() { CatchUploadHoldStubProtocol.recorded = [] }

    private func makeUploader() -> CatchUploader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatchUploadHoldStubProtocol.self]
        return CatchUploader(client: TailspotAccountClient(
            baseURL: URL(string: "https://api.example.test/")!,
            session: URLSession(configuration: config)))
    }

    private func makeRow(in context: ModelContext) throws -> Catch {
        let row = Catch(
            icao24: "abc123", callsign: "UAL1", model: "Boeing 737-800",
            manufacturer: "Boeing", operatorName: "United", caughtAt: Date(),
            observerLat: 37.8, observerLon: -122.27, slantDistanceMeters: 9000
        )
        row.serverUuid = UUID().uuidString
        context.insert(row)
        try context.save()
        return row
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Catch.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        TestContainerRetention.retain(container)
        return ModelContext(container)
    }

    @Test("a held row never reaches the network")
    func heldRowMakesNoRequest() async throws {
        let ctx = try makeContext()
        let row = try makeRow(in: ctx)
        let key = try #require(row.serverUuid)
        CatchUploader.guessHolds.hold(key)
        defer { _ = CatchUploader.guessHolds.release(key) }

        await makeUploader().uploadPending(context: ctx)

        #expect(CatchUploadHoldStubProtocol.recorded.isEmpty)
        #expect(row.uploadedAt == nil)
    }

    @Test("the same row, unheld, does reach the network (control)")
    func unheldRowMakesRequest() async throws {
        let ctx = try makeContext()
        let row = try makeRow(in: ctx)

        await makeUploader().uploadPending(context: ctx)

        // Either the registration POST or the catch POST, depending on
        // whether the test host already holds a device token. Both 500.
        #expect(!CatchUploadHoldStubProtocol.recorded.isEmpty)
        #expect(row.uploadedAt == nil)
    }
}
