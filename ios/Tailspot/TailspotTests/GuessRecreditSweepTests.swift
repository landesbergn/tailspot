//
//  GuessRecreditSweepTests.swift
//  TailspotTests
//
//  The one-time guess re-credit sweep: the status mapping, which rows it
//  sends, what it marks done, when it stops and resumes, and its telemetry.
//  Network via its own `URLProtocol` stub; `.serialized` because the stub's
//  state is process-global.
//

import Foundation
import SwiftData
import Testing
@testable import Tailspot

final class GuessRecreditStubProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: String = "{}"
        var headers: [String: String] = [:]
    }
    /// Replies handed out in order; the last one repeats.
    nonisolated(unsafe) static var replies: [Reply] = [Reply(status: 200)]
    nonisolated(unsafe) static var recorded: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []

    static func reset(_ replies: [Reply] = [Reply(status: 200, body: #"{"applied":true,"guessCorrect":true}"#)]) {
        self.replies = replies
        recorded = []
        bodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorded.append(request)
        // URLProtocol sees the body as a stream, not httpBody.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Self.bodies.append(obj)
            }
        }
        let reply = Self.replies.count > 1 ? Self.replies.removeFirst() : Self.replies[0]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Guess re-credit outcome mapping")
struct GuessRecreditOutcomeTests {
    private func classify(_ status: Int, _ body: String = "{}", retryAfter: String? = nil) -> GuessRecreditOutcome {
        GuessRecreditOutcome.classify(status: status, body: Data(body.utf8), retryAfter: retryAfter)
    }

    @Test func applied200ReadsTheVerdict() {
        #expect(classify(200, #"{"applied":true,"points":88,"guessKind":"route","guessCorrect":true}"#)
                == .applied(correct: true))
        #expect(classify(200, #"{"applied":true,"guessCorrect":false}"#) == .applied(correct: false))
    }

    @Test func notApplied200MeansTheServerAlreadyHadAGuess() {
        #expect(classify(200, #"{"applied":false,"guessCorrect":true}"#) == .alreadyHadGuess)
        #expect(classify(200, "not json") == .alreadyHadGuess)
    }

    @Test func the404WithTheRouteCodeIsNotFound_anyOther404IsAMissingEndpoint() {
        #expect(classify(404, #"{"error":"catch not found","code":"catch_not_found"}"#) == .notFound)
        // What Fastify answers for a route an older server doesn't have.
        #expect(classify(404, #"{"message":"Route POST:/v1/catches/x/guess not found","error":"Not Found","statusCode":404}"#)
                == .endpointMissing)
        #expect(classify(404, "") == .endpointMissing)
        #expect(classify(410) == .endpointMissing)
    }

    @Test func cutoverAndRejections() {
        #expect(classify(409, #"{"code":"after_cutover"}"#) == .afterCutover)
        #expect(classify(409) == .retryLater)
        #expect(classify(422) == .rejected)
        #expect(classify(400) == .rejected)
    }

    @Test func rateLimitAndTransientFailures() {
        #expect(classify(429, retryAfter: "7") == .rateLimited(retryAfter: 7))
        #expect(classify(429) == .rateLimited(retryAfter: nil))
        #expect(classify(401) == .retryLater)
        #expect(classify(500) == .retryLater)
        #expect(classify(503) == .retryLater)
    }

    @Test func onlyFinalAnswersMarkTheRowDone() {
        let done: [GuessRecreditOutcome] = [.applied(correct: true), .applied(correct: false),
                                            .alreadyHadGuess, .notFound, .afterCutover, .rejected]
        let notDone: [GuessRecreditOutcome] = [.rateLimited(retryAfter: 1), .endpointMissing, .retryLater]
        #expect(done.allSatisfy { $0.marksRowDone })
        #expect(!notDone.contains { $0.marksRowDone })
    }

    @Test func tallyProperties() {
        var tally = GuessRecreditTally()
        tally.candidates = 6
        tally.record(.applied(correct: true))
        tally.record(.applied(correct: false))
        tally.record(.alreadyHadGuess)
        tally.record(.notFound)
        tally.record(.retryLater)
        tally.stop = .network
        let p = tally.properties
        #expect(p["sent"].map(intValue) == 4)
        #expect(p["applied"].map(intValue) == 2)
        #expect(p["credited"].map(intValue) == 1)
        #expect(p["already_had_guess"].map(intValue) == 1)
        #expect(p["not_found"].map(intValue) == 1)
        #expect(p["remaining"].map(intValue) == 2)
        if case .string(let s) = p["stopped"] { #expect(s == "network") } else { Issue.record("stopped missing") }
    }
}

private func intValue(_ v: AnalyticsValue) -> Int? {
    if case .int(let i) = v { return i }
    return nil
}

@Suite("Guess re-credit sweep", .serialized)
@MainActor
struct GuessRecreditSweepTests {
    final class Captured {
        var events: [(String, [String: AnalyticsValue])] = []
    }

    let container: ModelContainer
    let defaults: UserDefaults
    let captured = Captured()

    init() throws {
        GuessRecreditStubProtocol.reset()
        container = try ModelContainer(
            for: Catch.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        TestContainerRetention.retain(container)
        defaults = UserDefaults(suiteName: "GuessRecreditSweepTests-\(UUID().uuidString)")!
    }

    private func makeSweep(token: String? = "device-token-abc") -> GuessRecreditSweep {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GuessRecreditStubProtocol.self]
        let captured = self.captured
        return GuessRecreditSweep(
            baseURL: URL(string: "https://api.example.test/")!,
            session: URLSession(configuration: config),
            defaults: defaults,
            tokenProvider: { token },
            pace: .zero,
            maxRateLimitWait: 0,
            capture: { captured.events.append(($0, $1)) })
    }

    @discardableResult
    private func addRow(
        uuid: String? = UUID().uuidString,
        kind: String? = "route",
        value: String? = "KSFO",
        correct: Bool? = true,
        uploaded: Bool = true,
        done: Bool = false,
        caughtAt: Date = Date(timeIntervalSince1970: 1_756_000_000)
    ) throws -> Catch {
        let row = Catch(
            icao24: "a1b2c3", callsign: "UAL1", model: nil, manufacturer: nil,
            caughtAt: caughtAt, observerLat: 37.8, observerLon: -122.27, slantDistanceMeters: 9000)
        row.serverUuid = uuid
        row.guessKind = kind
        row.guessValue = value
        row.guessCorrect = correct
        row.uploadedAt = uploaded ? Date() : nil
        row.guessRecreditedAt = done ? Date() : nil
        container.mainContext.insert(row)
        try container.mainContext.save()
        return row
    }

    @Test("sends only uploaded rows with a guess that haven't been re-credited")
    func sendsOnlyEligibleRows() async throws {
        let eligible = try addRow(uuid: "AAAA-1", kind: "type", value: "B738", correct: false)
        try addRow(uuid: "BBBB-2", kind: nil, value: nil, correct: nil)    // no guess
        try addRow(uuid: nil)                                              // never given a uuid
        try addRow(uuid: "CCCC-3", uploaded: false)                        // its upload carries the guess
        try addRow(uuid: "DDDD-4", done: true)                             // already handled

        await makeSweep().runIfNeeded(container: container)

        let reqs = GuessRecreditStubProtocol.recorded
        #expect(reqs.map { $0.url?.absoluteString } == ["https://api.example.test/v1/catches/AAAA-1/guess"])
        #expect(reqs.first?.httpMethod == "POST")
        #expect(reqs.first?.value(forHTTPHeaderField: "Authorization") == "Bearer device-token-abc")
        let body = try #require(GuessRecreditStubProtocol.bodies.first)
        #expect(body["kind"] as? String == "type")
        #expect(body["value"] as? String == "B738")
        #expect(body["localCorrect"] as? Bool == false)
        #expect(eligible.guessRecreditedAt != nil)
    }

    @Test("a full run marks every row, finishes for good, and reports counts")
    func fullRunCompletes() async throws {
        GuessRecreditStubProtocol.reset([
            .init(status: 200, body: #"{"applied":true,"guessCorrect":true}"#),
            .init(status: 200, body: #"{"applied":false,"guessCorrect":false}"#),
            .init(status: 404, body: #"{"code":"catch_not_found"}"#),
            .init(status: 409, body: #"{"code":"after_cutover"}"#),
        ])
        let rows = try (0..<4).map { i in
            try addRow(uuid: "ROW-\(i)", caughtAt: Date(timeIntervalSince1970: 1_756_000_000 + Double(i)))
        }

        let tally = await makeSweep().runIfNeeded(container: container)

        #expect(rows.allSatisfy { $0.guessRecreditedAt != nil })
        #expect(defaults.bool(forKey: GuessRecreditSweep.completeKey))
        #expect(tally?.stop == GuessRecreditTally.StopReason.none)
        #expect(captured.events.count == 1)
        let (name, props) = try #require(captured.events.first)
        #expect(name == "guess_recredit_sent")
        #expect(props["candidates"].map(intValue) == 4)
        #expect(props["sent"].map(intValue) == 4)
        #expect(props["credited"].map(intValue) == 1)
        #expect(props["already_had_guess"].map(intValue) == 1)
        #expect(props["not_found"].map(intValue) == 1)
        #expect(props["after_cutover"].map(intValue) == 1)
        #expect(props["remaining"].map(intValue) == 0)

        // Finished: a later foreground sends nothing.
        GuessRecreditStubProtocol.reset()
        try addRow(uuid: "LATER")
        await makeSweep().runIfNeeded(container: container)
        #expect(GuessRecreditStubProtocol.recorded.isEmpty)
    }

    @Test("an old server without the endpoint: stop, mark nothing, retry next launch")
    func endpointMissingRetriesLater() async throws {
        GuessRecreditStubProtocol.reset([.init(status: 404, body: #"{"error":"Not Found","statusCode":404}"#)])
        let a = try addRow(uuid: "A")
        let b = try addRow(uuid: "B")

        let first = await makeSweep().runIfNeeded(container: container)

        #expect(first?.stop == .endpointMissing)
        #expect(GuessRecreditStubProtocol.recorded.count == 1)
        #expect(a.guessRecreditedAt == nil && b.guessRecreditedAt == nil)
        #expect(!defaults.bool(forKey: GuessRecreditSweep.completeKey))
        #expect(captured.events.isEmpty)

        // The server deploys; the next launch resumes and finishes.
        GuessRecreditStubProtocol.reset()
        await makeSweep().runIfNeeded(container: container)
        #expect(GuessRecreditStubProtocol.recorded.count == 2)
        #expect(a.guessRecreditedAt != nil && b.guessRecreditedAt != nil)
        #expect(defaults.bool(forKey: GuessRecreditSweep.completeKey))
    }

    @Test("a server error stops quietly; finished rows stay done and the rest resume")
    func serverErrorStopsAndResumes() async throws {
        GuessRecreditStubProtocol.reset([
            .init(status: 200, body: #"{"applied":true,"guessCorrect":true}"#),
            .init(status: 503),
        ])
        let a = try addRow(uuid: "A", caughtAt: Date(timeIntervalSince1970: 1_756_000_000))
        let b = try addRow(uuid: "B", caughtAt: Date(timeIntervalSince1970: 1_756_000_100))
        let c = try addRow(uuid: "C", caughtAt: Date(timeIntervalSince1970: 1_756_000_200))

        let tally = await makeSweep().runIfNeeded(container: container)

        #expect(tally?.stop == .network)
        #expect(GuessRecreditStubProtocol.recorded.count == 2)   // stopped at B, never tried C
        #expect(a.guessRecreditedAt != nil)
        #expect(b.guessRecreditedAt == nil && c.guessRecreditedAt == nil)
        #expect(!defaults.bool(forKey: GuessRecreditSweep.completeKey))
        #expect(captured.events.first?.1["remaining"].map(intValue) == 2)

        GuessRecreditStubProtocol.reset()
        await makeSweep().runIfNeeded(container: container)
        #expect(GuessRecreditStubProtocol.recorded.compactMap { $0.url?.pathComponents.dropLast().last } == ["B", "C"])
        #expect(defaults.bool(forKey: GuessRecreditSweep.completeKey))
    }

    @Test("a 429 waits and retries the same row")
    func rateLimitRetriesSameRow() async throws {
        GuessRecreditStubProtocol.reset([
            .init(status: 429, headers: ["Retry-After": "1"]),
            .init(status: 200, body: #"{"applied":true,"guessCorrect":true}"#),
        ])
        let row = try addRow(uuid: "A")

        await makeSweep().runIfNeeded(container: container)

        #expect(GuessRecreditStubProtocol.recorded.count == 2)
        #expect(Set(GuessRecreditStubProtocol.recorded.compactMap { $0.url?.absoluteString }).count == 1)
        #expect(row.guessRecreditedAt != nil)
    }

    @Test("no token: nothing sent, nothing marked")
    func noTokenSendsNothing() async throws {
        let row = try addRow(uuid: "A")
        await makeSweep(token: nil).runIfNeeded(container: container)
        #expect(GuessRecreditStubProtocol.recorded.isEmpty)
        #expect(row.guessRecreditedAt == nil)
        #expect(!defaults.bool(forKey: GuessRecreditSweep.completeKey))
    }

    @Test("nothing to send: finishes without a request or an event")
    func noCandidatesFinishes() async throws {
        try addRow(uuid: "A", kind: nil, value: nil, correct: nil)
        await makeSweep().runIfNeeded(container: container)
        #expect(GuessRecreditStubProtocol.recorded.isEmpty)
        #expect(captured.events.isEmpty)
        #expect(defaults.bool(forKey: GuessRecreditSweep.completeKey))
    }

    @Test("a nil local verdict sends localCorrect false")
    func nilVerdictSendsFalse() async throws {
        try addRow(uuid: "A", correct: nil)
        await makeSweep().runIfNeeded(container: container)
        #expect(GuessRecreditStubProtocol.bodies.first?["localCorrect"] as? Bool == false)
    }
}
