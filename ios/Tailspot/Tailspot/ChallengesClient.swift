//
//  ChallengesClient.swift
//  Tailspot
//
//  URLSession-backed `ChallengesService` — the production seam
//  `ChallengesModel` talks to against api.tailspot.app. Conventions mirror
//  `TailspotAccountClient.swift`: nonisolated struct, injectable session,
//  errors mapped from HTTP status onto a typed enum (`ChallengesError`
//  here, `AccountError` there) so screens switch on cases, never numbers.
//
//  The bearer token comes from a caller-supplied closure rather than
//  reading the Keychain directly — the default reads
//  `TailspotAccountClient().storedToken`, registering the device first if
//  none exists yet (mirrors `uploadCatch`'s `guard let token = storedToken`
//  precondition, except this client can self-heal by registering instead of
//  throwing `.notRegistered`). Tests inject a closure that returns a fixed
//  string, so no Keychain access ever happens in the test target.
//
//  Route → error contract (spec §10.3, pinned against the built backend in
//  backend/src/routes/challenges.ts + invites.ts on feat/challenges-backend):
//  401 unauthorized, 404 notFound, 409 → .full when the body's `error`
//  mentions "full" else .conflict(message), 410 closed, 422 → .handleRequired
//  for the exact string "handle required" else .invalid(message), 429
//  rateLimited, anything else non-2xx → .network("HTTP <code>").
//

import Foundation
import os

nonisolated struct ChallengesClient: ChallengesService {
    /// Same production host the account/leaderboard client uses — one
    /// backend, one base URL.
    static let defaultBaseURL = TailspotAccountClient.defaultBaseURL

    let baseURL: URL
    private let session: URLSession
    /// Resolves the bearer token for every authenticated route. Defaulted to
    /// read-or-register against `TailspotAccountClient`; overridden in tests
    /// so no Keychain access happens off the happy path.
    private let resolveToken: @Sendable () async throws -> String

    init(
        baseURL: URL = ChallengesClient.defaultBaseURL,
        session: URLSession = .shared,
        tokenProvider: (@Sendable () async throws -> String)? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        if let tokenProvider {
            self.resolveToken = tokenProvider
        } else {
            self.resolveToken = {
                let account = TailspotAccountClient(baseURL: baseURL, session: session)
                if let token = account.storedToken { return token }
                _ = try await account.ensureRegistered()
                guard let token = account.storedToken else { throw ChallengesError.unauthorized }
                return token
            }
        }
    }

    // MARK: - ChallengesService

    func config() async throws -> ChallengesConfig {
        let request = try await makeRequest(path: "v1/challenges/config", method: "GET", authorized: false)
        let (data, status) = try await send(request)
        guard status == 200 else { throw mapError(status: status, data: data) }
        return try decode(ChallengesConfig.self, from: data)
    }

    func list() async throws -> ChallengeList {
        let request = try await makeRequest(path: "v1/challenges", method: "GET", authorized: true)
        let (data, status) = try await send(request)
        guard status == 200 else { throw mapError(status: status, data: data) }
        return try decode(ChallengeList.self, from: data)
    }

    func detail(id: String) async throws -> ChallengeDetail {
        let request = try await makeRequest(path: "v1/challenges/\(id)", method: "GET", authorized: true)
        let (data, status) = try await send(request)
        guard status == 200 else { throw mapError(status: status, data: data) }
        return try decode(ChallengeDetail.self, from: data)
    }

    func catchLog(id: String, handle: String) async throws -> ChallengeCatchLog {
        let path = "v1/challenges/\(id)/log/\(Self.percentEncodedHandle(handle))"
        let request = try await makeRequest(path: path, method: "GET", authorized: true)
        let (data, status) = try await send(request)
        guard status == 200 else { throw mapError(status: status, data: data) }
        return try decode(ChallengeCatchLog.self, from: data)
    }

    func create(_ requestBody: ChallengeCreateRequest) async throws -> ChallengeDetail {
        let body: Data
        do {
            body = try JSONEncoder().encode(requestBody)
        } catch {
            throw ChallengesError.network("encode failed: \(error.localizedDescription)")
        }
        let request = try await makeRequest(path: "v1/challenges", method: "POST", authorized: true, body: body)
        let (data, status) = try await send(request)
        guard status == 201 else { throw mapError(status: status, data: data) }
        return try decode(ChallengeDetail.self, from: data)
    }

    func invitePreview(code: String) async throws -> ChallengeInvitePreview {
        let request = try await makeRequest(path: "v1/invites/\(code)", method: "GET", authorized: true)
        let (data, status) = try await send(request)
        guard status == 200 else { throw mapError(status: status, data: data) }
        return try decode(ChallengeInvitePreview.self, from: data)
    }

    func join(code: String) async throws -> ChallengeDetail {
        let request = try await makeRequest(path: "v1/invites/\(code)/join", method: "POST", authorized: true)
        let (data, status) = try await send(request)
        guard status == 200 else { throw mapError(status: status, data: data) }
        return try decode(ChallengeDetail.self, from: data)
    }

    func leave(id: String) async throws {
        let request = try await makeRequest(path: "v1/challenges/\(id)/leave", method: "POST", authorized: true)
        let (data, status) = try await send(request)
        guard status == 204 || status == 200 else { throw mapError(status: status, data: data) }
    }

    func cancel(id: String) async throws {
        let request = try await makeRequest(path: "v1/challenges/\(id)/cancel", method: "POST", authorized: true)
        let (data, status) = try await send(request)
        guard status == 204 || status == 200 else { throw mapError(status: status, data: data) }
    }

    // MARK: - Request building

    /// `baseURL` carries no path (e.g. "https://api.tailspot.app"), so a
    /// relative reference resolves per RFC 3986 §5.3's empty-base-path case:
    /// the reference's path is appended straight onto the authority — no
    /// double-encoding risk from `appendingPathComponent` re-escaping an
    /// already-percent-encoded segment (the handle route).
    private func makeRequest(
        path: String, method: String, authorized: Bool, body: Data? = nil
    ) async throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw ChallengesError.network("bad path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if authorized {
            let token = try await bearerToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func bearerToken() async throws -> String {
        do {
            return try await resolveToken()
        } catch let error as ChallengesError {
            throw error
        } catch {
            Log.ui.debug("Challenges token resolution failed: \(String(describing: error), privacy: .public)")
            throw ChallengesError.network(String(describing: error))
        }
    }

    /// A-Z0-9_ handles never need escaping, but a wire handle from a future
    /// looser format might — encode defensively, and never leave a literal
    /// "/" that would split the path into an extra segment.
    private static let handlePathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    private static func percentEncodedHandle(_ handle: String) -> String {
        handle.addingPercentEncoding(withAllowedCharacters: handlePathAllowed) ?? handle
    }

    // MARK: - Transport

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Log.ui.debug("Challenges request failed: \(error.localizedDescription, privacy: .public)")
            throw ChallengesError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ChallengesError.network("no HTTP response")
        }
        return (data, http.statusCode)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try ChallengeJSON.decoder.decode(T.self, from: data)
        } catch {
            Log.ui.debug("Challenges decode failed: \(error.localizedDescription, privacy: .public)")
            throw ChallengesError.decoding(error.localizedDescription)
        }
    }

    /// Every non-2xx status → a typed `ChallengesError`, per the contract
    /// pinned against the built backend (see file header).
    private func mapError(status: Int, data: Data) -> ChallengesError {
        let message = (try? JSONDecoder().decode(ChallengeAPIError.self, from: data))?.error ?? ""
        switch status {
        case 401: return .unauthorized
        case 404: return .notFound
        case 409: return message.lowercased().contains("full") ? .full : .conflict(message)
        case 410: return .closed
        case 422: return message == "handle required" ? .handleRequired : .invalid(message)
        case 429: return .rateLimited
        default:  return .network("HTTP \(status)")
        }
    }
}
