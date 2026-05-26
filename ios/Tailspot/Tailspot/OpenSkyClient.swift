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
    // OpenSky's Keycloak uses the older `/auth/realms/...` path. Modern
    // Keycloak (post-version 17) drops the `/auth` prefix, but OpenSky
    // is still on the older release as of this writing — verified
    // empirically: `/auth/realms/...` returns 401 to an unauthenticated
    // POST, `/realms/...` returns 404.
    private let tokenURL = URL(string:
        "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token"
    )!
    private let session = URLSession.shared

    /// OAuth2 client credentials. Resolution order:
    ///   1. Explicit `credentials:` argument (tests).
    ///   2. `OPENSKY_CLIENT_ID` / `_SECRET` process environment vars
    ///      — populated for local dev via the user-only Xcode scheme.
    ///      These don't survive home-screen relaunches or
    ///      `devicectl process launch` from a fresh shell, which is
    ///      why TestFlight builds can't rely on them.
    ///   3. `OpenSkyClientID` / `OpenSkyClientSecret` from
    ///      `Bundle.main.infoDictionary` — baked into Info.plist at
    ///      build time via xcconfig substitution
    ///      (`ios/Tailspot/Tailspot.secrets.xcconfig`). This is the
    ///      path that survives every launch type (TestFlight, home
    ///      screen, devicectl, simulator).
    ///   4. nil → anonymous mode (400 credits/day per IP, exhausted
    ///      in ~1.3hr).
    /// Env-var first preserves the existing dev iteration loop —
    /// Noah's xcscheme env vars stay authoritative for his machine;
    /// the baked Info.plist values are the fallback for shipped
    /// builds (and any tester install).
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
            self.credentialSource = "explicit"
        } else if let envCreds = Self.credentialsFromEnvironment() {
            self.credentials = envCreds
            self.credentialSource = "env"
        } else if let bundleCreds = Self.credentialsFromBundle() {
            self.credentials = bundleCreds
            self.credentialSource = "bundle"
        } else {
            self.credentials = nil
            self.credentialSource = "none"
        }
        Log.openSky.notice("OpenSkyClient init: credentials \(self.credentials == nil ? "MISSING (anonymous)" : "present (authed, source=\(self.credentialSource))", privacy: .public)")
    }

    /// Where the active credentials came from (for log/debug only).
    /// One of: "explicit", "env", "bundle", "none". Not sensitive —
    /// it names the source, not the value.
    private let credentialSource: String

    private static func credentialsFromEnvironment() -> (clientId: String, clientSecret: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["OPENSKY_CLIENT_ID"], !id.isEmpty,
              let secret = env["OPENSKY_CLIENT_SECRET"], !secret.isEmpty else {
            return nil
        }
        return (id, secret)
    }

    private static func credentialsFromBundle() -> (clientId: String, clientSecret: String)? {
        let info = Bundle.main.infoDictionary
        guard let id = info?["OpenSkyClientID"] as? String, !id.isEmpty,
              let secret = info?["OpenSkyClientSecret"] as? String, !secret.isEmpty else {
            return nil
        }
        return (id, secret)
    }

    /// True when the client has OAuth credentials and will run
    /// against OpenSky's 4000-credit/day registered tier. False
    /// means anonymous (400/day, exhausted in ~1.3h). Exposed so
    /// the debug overlay can surface the auth state directly.
    nonisolated var hasCredentials: Bool {
        credentials != nil
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

    // MARK: - Aircraft metadata

    /// Fetch metadata for a single icao24 from OpenSky's
    /// /metadata/aircraft/icao/{icao24} endpoint. Returns nil on 404
    /// (OpenSky doesn't have this aircraft in its DB).
    func aircraftMetadata(icao24: String) async throws -> AircraftMetadata? {
        // Trim & lowercase: OpenSky expects the bare 24-bit hex,
        // and callsigns we hand in from Aircraft.icao24 already are lower.
        let key = icao24.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }

        let url = base
            .appendingPathComponent("metadata")
            .appendingPathComponent("aircraft")
            .appendingPathComponent("icao")
            .appendingPathComponent(key)

        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0

        if let token = try await bearerTokenIfPossible() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                return nil
            }
            if http.statusCode == 429 {
                throw ClientError.rateLimited
            }
            if http.statusCode != 200 {
                throw ClientError.http(status: http.statusCode)
            }
        }

        do {
            return try JSONDecoder().decode(AircraftMetadata.self, from: data)
        } catch {
            throw ClientError.decoding(error)
        }
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
