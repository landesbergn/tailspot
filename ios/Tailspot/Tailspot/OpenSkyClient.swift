//
//  OpenSkyClient.swift
//  Tailspot
//
//  Thin HTTP client for the OpenSky Network REST API.
//  https://openskynetwork.github.io/opensky-api/rest.html
//
//  Auth: OpenSky moved from HTTP basic auth (username + password) to
//  OAuth2 client-credentials (clientId + clientSecret). When credentials
//  are configured we run the standard OAuth2 client_credentials grant
//  against OpenSky's Keycloak token endpoint, cache the access token,
//  and send it as a Bearer token on every API request. When credentials
//  aren't configured we fall back to anonymous (rate-limited).
//
//  Marked `Sendable` so it can be safely held by the @MainActor
//  ADSBManager and called across an `await`. The token cache is the
//  only mutable state — it lives in an OSAllocatedUnfairLock so
//  Sendable conformance holds.
//
//  v1 of Tailspot is non-commercial and free. Phase 1 will move this
//  call behind our own backend proxy that adds caching and supports
//  paid providers — at that point this file becomes one of several
//  adapters behind a shared interface.
//

import Foundation
import os.lock

nonisolated final class OpenSkyClient: ADSBSource, Sendable {

    private let base = URL(string: "https://opensky-network.org/api")!
    private let tokenURL = URL(string:
        "https://auth.opensky-network.org/realms/opensky-network/protocol/openid-connect/token"
    )!
    private let session = URLSession.shared

    /// OAuth2 client credentials. To set: in Xcode →
    /// Product → Scheme → Edit Scheme → Run → Arguments → Environment
    /// Variables, add OPENSKY_CLIENT_ID and OPENSKY_CLIENT_SECRET.
    /// Scheme env vars live under xcuserdata/ which is gitignored, so
    /// credentials never get committed.
    private let credentials: (clientId: String, clientSecret: String)?

    /// Cached OAuth2 access token. Locked because OpenSkyClient is
    /// Sendable and may be touched from any actor that holds it.
    private let tokenCache = OSAllocatedUnfairLock<CachedToken?>(initialState: nil)

    private struct CachedToken: Sendable {
        let bearer: String
        let expiresAt: Date
    }

    init(credentials: (clientId: String, clientSecret: String)? = nil) {
        if let creds = credentials {
            self.credentials = creds
        } else {
            let env = ProcessInfo.processInfo.environment
            if let id = env["OPENSKY_CLIENT_ID"], !id.isEmpty,
               let secret = env["OPENSKY_CLIENT_SECRET"], !secret.isEmpty {
                self.credentials = (id, secret)
            } else {
                self.credentials = nil
            }
        }
    }

    enum ClientError: Error, LocalizedError {
        case badURL
        case rateLimited                 // HTTP 429 — daily quota exhausted, back off
        case http(status: Int)
        case decoding(Error)
        case authFailed(status: Int)     // OAuth token fetch failed

        var errorDescription: String? {
            switch self {
            case .badURL:                  return "Bad URL"
            case .rateLimited:             return "OpenSky rate limit (HTTP 429)"
            case .http(let s):             return "HTTP \(s)"
            case .decoding(let inner):     return "Decoding: \(inner.localizedDescription)"
            case .authFailed(let s):       return "OAuth token fetch failed (HTTP \(s))"
            }
        }
    }

    // MARK: - Aircraft fetch

    /// Fetch all aircraft with a known position inside the bbox.
    /// Aircraft missing required fields (lat/lon/...) are dropped.
    func aircraftInBbox(
        lamin: Double, lomin: Double, lamax: Double, lomax: Double
    ) async throws -> [Aircraft] {
        var components = URLComponents(
            url: base.appendingPathComponent("states/all"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "lamin", value: String(lamin)),
            URLQueryItem(name: "lomin", value: String(lomin)),
            URLQueryItem(name: "lamax", value: String(lamax)),
            URLQueryItem(name: "lomax", value: String(lomax)),
        ]
        guard let url = components.url else {
            throw ClientError.badURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0

        // If we have credentials, attach a Bearer token (fetching one
        // if needed). If we don't, the request goes anonymous.
        if let token = try await bearerTokenIfPossible() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw ClientError.rateLimited
            }
            if http.statusCode != 200 {
                throw ClientError.http(status: http.statusCode)
            }
        }

        do {
            let envelope = try JSONDecoder().decode(StatesEnvelope.self, from: data)
            // states is null when the bbox is empty.
            // FailableDecodable + compactMap drops malformed rows.
            return envelope.states?.compactMap(\.value) ?? []
        } catch {
            throw ClientError.decoding(error)
        }
    }

    private struct StatesEnvelope: Decodable {
        let time: Int
        let states: [FailableDecodable<Aircraft>]?
    }

    // MARK: - OAuth2

    /// Returns a valid bearer token if credentials are configured;
    /// returns nil if running in anonymous mode. Throws if a token
    /// fetch was needed but failed.
    private func bearerTokenIfPossible() async throws -> String? {
        guard let credentials else { return nil }

        // Use the cached token if it's still valid (with a 30s safety
        // margin — don't hand out a token that's about to expire).
        let cached = tokenCache.withLock { $0 }
        if let cached, cached.expiresAt > Date().addingTimeInterval(30) {
            return cached.bearer
        }

        let fresh = try await fetchToken(
            clientId: credentials.clientId,
            clientSecret: credentials.clientSecret
        )
        tokenCache.withLock { $0 = fresh }
        return fresh.bearer
    }

    /// OAuth2 client_credentials grant against OpenSky's Keycloak token
    /// endpoint. Returns a CachedToken with the access token and its
    /// computed expiration time.
    private func fetchToken(clientId: String, clientSecret: String) async throws -> CachedToken {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8.0

        let bodyParams: [(String, String)] = [
            ("grant_type", "client_credentials"),
            ("client_id", clientId),
            ("client_secret", clientSecret),
        ]
        req.httpBody = bodyParams
            .map { (k, v) in
                let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
                return "\(ek)=\(ev)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: req)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.authFailed(status: http.statusCode)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
        }
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)

        return CachedToken(
            bearer: resp.access_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(resp.expires_in))
        )
    }
}
