//
//  ChallengesClientTests.swift
//  TailspotTests
//
//  `ChallengesClient` against a `URLProtocol` stub: every route's method +
//  path + auth header + body, every status→`ChallengesError` mapping in the
//  contract (pinned against the built backend on feat/challenges-backend),
//  a transport failure, and a decode failure.
//
//  `.serialized`: the stub's queue is process-global static state (a real
//  `URLProtocol` subclass has no instance the session hands back), so tests
//  in this suite must not interleave.
//

import Foundation
import Testing
@testable import Tailspot

/// Records every request `ChallengesClient` sends and answers with a queued
/// response (or a queued transport error) in order.
final class ChallengesStubProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let body: Data
        init(status: Int, json: String = "{}") {
            self.status = status
            self.body = Data(json.utf8)
        }
    }

    nonisolated(unsafe) static var queue: [Stub] = []
    nonisolated(unsafe) static var transportError: Error?
    nonisolated(unsafe) static var recorded: [URLRequest] = []

    static func reset() {
        queue = []
        transportError = nil
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession rewrites `httpBody` into `httpBodyStream` before handing
        // the request to a registered URLProtocol — read the stream back
        // into a request that carries `httpBody` again, or every POST would
        // record a nil body here.
        var recordedRequest = request
        if recordedRequest.httpBody == nil, let stream = request.httpBodyStream {
            recordedRequest.httpBody = Self.drain(stream)
        }
        Self.recorded.append(recordedRequest)
        if let error = Self.transportError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard !Self.queue.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = Self.queue.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@Suite("Challenges network client", .serialized)
struct ChallengesClientTests {

    init() {
        ChallengesStubProtocol.reset()
    }

    private func makeClient(token: String? = "test-token") -> ChallengesClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChallengesStubProtocol.self]
        let session = URLSession(configuration: config)
        return ChallengesClient(
            baseURL: URL(string: "https://stub.tailspot.test")!,
            session: session,
            tokenProvider: {
                guard let token else { throw ChallengesError.unauthorized }
                return token
            }
        )
    }

    private var lastRequest: URLRequest? { ChallengesStubProtocol.recorded.last }

    // MARK: - Routes: path, method, headers, body

    @Test func configHasNoAuthHeaderAndCorrectPath() async throws {
        ChallengesStubProtocol.queue = [.init(status: 200, json: """
        {"enabled": true, "availability": "testflight", "minBuild": 10, "appStoreURL": "https://apps.apple.com/app/id123"}
        """)]
        let config = try await makeClient().config()
        #expect(config.enabled)
        #expect(config.minBuild == 10)
        #expect(lastRequest?.url?.path == "/v1/challenges/config")
        #expect(lastRequest?.httpMethod == "GET")
        #expect(lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func listSendsBearerHeaderAndCorrectPath() async throws {
        ChallengesStubProtocol.queue = [.init(status: 200, json: """
        {"open": [], "history": []}
        """)]
        _ = try await makeClient().list()
        #expect(lastRequest?.url?.path == "/v1/challenges")
        #expect(lastRequest?.httpMethod == "GET")
        #expect(lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test func detailPathIncludesId() async throws {
        ChallengesStubProtocol.queue = [.init(status: 200, json: Self.detailJSON())]
        _ = try await makeClient().detail(id: "c-123")
        #expect(lastRequest?.url?.path == "/v1/challenges/c-123")
        #expect(lastRequest?.httpMethod == "GET")
    }

    @Test func catchLogPercentEncodesTheHandle() async throws {
        ChallengesStubProtocol.queue = [.init(status: 200, json: """
        {"handle": "a b", "catches": []}
        """)]
        let log = try await makeClient().catchLog(id: "c-1", handle: "a b")
        #expect(log.handle == "a b")
        // `.path` percent-DECODES, so assert on the wire-level encoded path
        // to actually prove the space was escaped in the outgoing request.
        #expect(lastRequest?.url?.path(percentEncoded: true) == "/v1/challenges/c-1/log/a%20b")
        #expect(lastRequest?.url?.path == "/v1/challenges/c-1/log/a b")
        #expect(lastRequest?.httpMethod == "GET")
    }

    @Test func createSendsJSONBodyAndExpects201() async throws {
        ChallengesStubProtocol.queue = [.init(status: 201, json: Self.detailJSON())]
        let request = ChallengeCreateRequest.startingNow(name: "Weekend Flyoff", duration: "24h")
        let detail = try await makeClient().create(request)
        #expect(detail.challenge.id == "c-123")
        #expect(lastRequest?.url?.path == "/v1/challenges")
        #expect(lastRequest?.httpMethod == "POST")
        #expect(lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(lastRequest?.httpBody)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        #expect(decoded["name"] == "Weekend Flyoff")
        #expect(decoded["start"] == "now")
        #expect(decoded["duration"] == "24h")
    }

    @Test func invitePreviewPathIncludesCode() async throws {
        ChallengesStubProtocol.queue = [.init(status: 200, json: """
        {"challenge": \(Self.summaryJSON()), "participants": [], "needsHandle": false, "alreadyIn": false, "canJoin": true, "reason": null}
        """)]
        _ = try await makeClient().invitePreview(code: "K7M4QD2X")
        #expect(lastRequest?.url?.path == "/v1/invites/K7M4QD2X")
        #expect(lastRequest?.httpMethod == "GET")
    }

    @Test func joinDecodesAlreadyInAndNewDevice() async throws {
        ChallengesStubProtocol.queue = [.init(status: 200, json: """
        {"challenge": \(Self.summaryJSON()), "standings": [], "me": null, "winners": [], "alreadyIn": true, "newDevice": false}
        """)]
        let detail = try await makeClient().join(code: "K7M4QD2X")
        #expect(detail.alreadyIn == true)
        #expect(detail.newDevice == false)
        #expect(lastRequest?.url?.path == "/v1/invites/K7M4QD2X/join")
        #expect(lastRequest?.httpMethod == "POST")
    }

    @Test func leaveAccepts204() async throws {
        ChallengesStubProtocol.queue = [.init(status: 204, json: "")]
        try await makeClient().leave(id: "c-1")
        #expect(lastRequest?.url?.path == "/v1/challenges/c-1/leave")
        #expect(lastRequest?.httpMethod == "POST")
    }

    @Test func leaveAccepts200() async throws {
        ChallengesStubProtocol.queue = [.init(status: 200, json: "{}")]
        try await makeClient().leave(id: "c-1")
    }

    @Test func cancelAccepts204() async throws {
        ChallengesStubProtocol.queue = [.init(status: 204, json: "")]
        try await makeClient().cancel(id: "c-1")
        #expect(lastRequest?.url?.path == "/v1/challenges/c-1/cancel")
        #expect(lastRequest?.httpMethod == "POST")
    }

    // MARK: - Status → error mapping

    @Test func status401MapsToUnauthorized() async throws {
        ChallengesStubProtocol.queue = [.init(status: 401, json: #"{"error": "unauthorized"}"#)]
        await #expect(throws: ChallengesError.unauthorized) {
            _ = try await makeClient().list()
        }
    }

    @Test func status404MapsToNotFound() async throws {
        ChallengesStubProtocol.queue = [.init(status: 404, json: #"{"error": "not found"}"#)]
        await #expect(throws: ChallengesError.notFound) {
            _ = try await makeClient().detail(id: "c-1")
        }
    }

    @Test func status409WithFullMapsToFull() async throws {
        ChallengesStubProtocol.queue = [.init(status: 409, json: #"{"error": "challenge is full"}"#)]
        await #expect(throws: ChallengesError.full) {
            _ = try await makeClient().join(code: "FULLHSE9")
        }
    }

    @Test func status409WithoutFullMapsToConflict() async throws {
        ChallengesStubProtocol.queue = [.init(status: 409, json: #"{"error": "challenge already started"}"#)]
        await #expect(throws: ChallengesError.conflict("challenge already started")) {
            try await makeClient().cancel(id: "c-1")
        }
    }

    @Test func status410MapsToClosed() async throws {
        ChallengesStubProtocol.queue = [.init(status: 410, json: #"{"error": "challenge has ended or was cancelled"}"#)]
        await #expect(throws: ChallengesError.closed) {
            _ = try await makeClient().join(code: "ENDEDX2Y")
        }
    }

    @Test func status422HandleRequiredMapsToHandleRequired() async throws {
        ChallengesStubProtocol.queue = [.init(status: 422, json: #"{"error": "handle required"}"#)]
        await #expect(throws: ChallengesError.handleRequired) {
            _ = try await makeClient().join(code: "HANDLE9Q")
        }
    }

    @Test func status422OtherMapsToInvalid() async throws {
        ChallengesStubProtocol.queue = [.init(status: 422, json: #"{"error": "name must be 3–24 characters"}"#)]
        await #expect(throws: ChallengesError.invalid("name must be 3–24 characters")) {
            _ = try await makeClient().create(.startingNow(name: "x", duration: "24h"))
        }
    }

    @Test func status429MapsToRateLimited() async throws {
        ChallengesStubProtocol.queue = [.init(status: 429, json: #"{"error": "rate limited"}"#)]
        await #expect(throws: ChallengesError.rateLimited) {
            _ = try await makeClient().list()
        }
    }

    @Test func unexpectedStatusMapsToNetworkWithCode() async throws {
        ChallengesStubProtocol.queue = [.init(status: 500, json: #"{"error": "boom"}"#)]
        await #expect(throws: ChallengesError.network("HTTP 500")) {
            _ = try await makeClient().list()
        }
    }

    // MARK: - Transport + decode failures

    @Test func urlErrorMapsToNetwork() async throws {
        ChallengesStubProtocol.transportError = URLError(.notConnectedToInternet)
        do {
            _ = try await makeClient().list()
            Issue.record("expected a throw")
        } catch let ChallengesError.network(message) {
            #expect(!message.isEmpty)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func malformedBodyMapsToDecoding() async throws {
        ChallengesStubProtocol.queue = [.init(status: 200, json: "{ not json")]
        do {
            _ = try await makeClient().list()
            Issue.record("expected a throw")
        } catch ChallengesError.decoding {
            // expected
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: - Fixtures

    private static func summaryJSON(id: String = "c-123") -> String {
        """
        {"id": "\(id)", "kind": "private", "code": "K7M4QD2X", "inviteURL": "https://tailspot.app/c/K7M4QD2X",
         "name": "Weekend Flyoff", "creatorHandle": "noah", "startsAt": "2026-09-01T00:00:00Z",
         "endsAt": "2026-09-02T00:00:00Z", "durationPreset": "24h", "maxParticipants": 10,
         "status": "live", "outcome": null, "participantCount": 3, "isCreator": true,
         "isParticipant": true, "myResult": null}
        """
    }

    private static func detailJSON() -> String {
        """
        {"challenge": \(summaryJSON()), "standings": [], "me": null, "winners": [], "alreadyIn": null, "newDevice": null}
        """
    }
}
