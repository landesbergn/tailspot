//
//  CatchDeletionSyncTests.swift
//  TailspotTests
//
//  `CatchDeletionSync` against a `URLProtocol` stub: the DELETE request
//  shape, the queue (dedupe, removal only on success), the status mapping,
//  and the no-token short circuit. `.serialized` because the stub's state is
//  process-global, and its own stub class so no other suite shares it.
//

import Foundation
import Testing
@testable import Tailspot

final class CatchDeleteStubProtocol: URLProtocol {
    /// Statuses handed out in order; the last one repeats.
    nonisolated(unsafe) static var statuses: [Int] = [204]
    nonisolated(unsafe) static var recorded: [URLRequest] = []

    static func reset() {
        statuses = [204]
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorded.append(request)
        let status = Self.statuses.count > 1 ? Self.statuses.removeFirst() : Self.statuses[0]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Catch deletion sync", .serialized)
struct CatchDeletionSyncTests {

    init() { CatchDeleteStubProtocol.reset() }

    private func makeSync(token: String? = "device-token-abc") -> (CatchDeletionSync, UserDefaults) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatchDeleteStubProtocol.self]
        let suite = "CatchDeletionSyncTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let sync = CatchDeletionSync(
            baseURL: URL(string: "https://api.example.test/")!,
            session: URLSession(configuration: config),
            defaults: defaults,
            tokenProvider: { token })
        return (sync, defaults)
    }

    @Test func sendsAnAuthenticatedDeleteForEachQueuedCatch() async {
        let (sync, _) = makeSync()
        sync.enqueue(["aaaa-1", "bbbb-2"])
        await sync.drain()
        let reqs = CatchDeleteStubProtocol.recorded
        #expect(reqs.map(\.httpMethod) == ["DELETE", "DELETE"])
        #expect(reqs.map { $0.url?.absoluteString } == [
            "https://api.example.test/v1/catches/aaaa-1",
            "https://api.example.test/v1/catches/bbbb-2",
        ])
        #expect(reqs.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer device-token-abc" })
        #expect(sync.pending.isEmpty)
    }

    @Test func enqueueDedupes() {
        let (sync, _) = makeSync()
        sync.enqueue(["a", "b"])
        sync.enqueue(["b", "c"])
        #expect(sync.pending == ["a", "b", "c"])
    }

    @Test func aFailedDeleteStaysQueuedForTheNextOpen() async {
        let (sync, _) = makeSync()
        CatchDeleteStubProtocol.statuses = [500, 204]
        sync.enqueue(["fails", "works"])
        await sync.drain()
        #expect(sync.pending == ["fails"])
        await sync.drain()
        #expect(sync.pending.isEmpty)
    }

    @Test func rateLimitStopsTheRunAndKeepsTheRest() async {
        let (sync, _) = makeSync()
        CatchDeleteStubProtocol.statuses = [429]
        sync.enqueue(["one", "two"])
        await sync.drain()
        #expect(CatchDeleteStubProtocol.recorded.count == 1)
        #expect(sync.pending == ["one", "two"])
    }

    @Test func noTokenMeansNothingToDeleteServerSide() async {
        let (sync, _) = makeSync(token: nil)
        sync.enqueue(["never-uploaded"])
        await sync.drain()
        #expect(CatchDeleteStubProtocol.recorded.isEmpty)
        #expect(sync.pending.isEmpty)
    }

    @Test func statusMapping() {
        #expect(CatchDeletionSync.outcome(forStatus: 204) == .done)
        #expect(CatchDeletionSync.outcome(forStatus: 404) == .retry) // server without the route yet
        #expect(CatchDeletionSync.outcome(forStatus: 400) == .done)
        #expect(CatchDeletionSync.outcome(forStatus: 429) == .stop)
        #expect(CatchDeletionSync.outcome(forStatus: 401) == .retry)
        #expect(CatchDeletionSync.outcome(forStatus: 503) == .retry)
    }
}
