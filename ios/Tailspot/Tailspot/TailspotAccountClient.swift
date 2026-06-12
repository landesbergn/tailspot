//
//  TailspotAccountClient.swift
//  Tailspot
//
//  HTTP client for the Tailspot account + leaderboard API (WP 1.7).
//  Handles device registration, handle claiming, catch upload, and
//  leaderboard queries.
//
//  Conventions mirror TailspotBackendClient.swift exactly:
//    - nonisolated struct — pure value type, safe across actors.
//    - Separate wire DTOs (named inner types) insulated from app models.
//    - Errors typed as AccountError (separate from OpenSkyClient.ClientError
//      because `handleTaken` is specific to this layer; the rest of the
//      error vocabulary is shared by convention).
//    - baseURL injectable for tests / local dev.
//
//  Device token is stored in the system Keychain (kSecClassGenericPassword,
//  service "com.landesberg.tailspot", account "deviceToken") via the
//  KeychainStore helper below. Device ID (a UUID string, not a secret) is
//  stored in UserDefaults. The token is never written to UserDefaults — it
//  is a credential and must not be plist-exportable.
//

import Foundation
import Security

// MARK: - KeychainStore

/// Minimal Keychain wrapper for a single stored secret. Nonisolated so
/// it can be called from any isolation context. Errors are swallowed
/// into optionals — the caller decides whether a nil read is fatal.
///
/// Layout: kSecClassGenericPassword, service = "com.landesberg.tailspot",
/// account = supplied `account` argument (e.g. "deviceToken").
nonisolated enum KeychainStore {
    static let service = "com.landesberg.tailspot"

    /// Write `secret` to the Keychain. Overwrites any existing value for the same account.
    /// Returns true on success.
    @discardableResult
    static func save(secret: String, account: String) -> Bool {
        let data = Data(secret.utf8)
        // Delete any existing item first (an Add after an existing item returns errSecDuplicateItem).
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            // Accessible after first unlock — survives device restarts while
            // the app is backgrounded; appropriate for a long-lived bearer token.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Read the secret for `account`. Returns nil if not found or on error.
    static func load(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Delete the stored secret for `account`. Safe to call when absent.
    static func delete(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Wire DTOs

/// Response from POST /v1/devices.
nonisolated private struct RegisterDeviceResponse: Decodable {
    let deviceId: String
    let deviceToken: String
}

/// Response from PUT /v1/devices/me/handle.
nonisolated private struct ClaimHandleResponse: Decodable {
    let handle: String
}

/// Request body for POST /v1/catches.
nonisolated struct UploadCatchRequest: Encodable {
    struct Observer: Encodable {
        let lat: Double
        let lon: Double
        let headingDeg: Double?
        let elevationDeg: Double?
        let headingAccuracyDeg: Double?
    }

    let catchUuid: String
    let icao24: String
    let callsign: String?
    /// Unix seconds at which the catch occurred.
    let caughtAt: Double
    let observer: Observer
    /// Aircraft position — always nil for pre-WP-1.7 backfill (see backend spec).
    /// Typed as a nullable JSON object: the server distinguishes null (skip validation)
    /// from an absent key.
    let aircraft: String? // nil serialises as JSON null via custom encoder below

    // Custom Encodable so `aircraft` becomes JSON null (not the Swift String? nullable).
    // We keep the field as String? just to carry nil; the real encoding is explicit.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(catchUuid, forKey: .catchUuid)
        try container.encode(icao24, forKey: .icao24)
        try container.encodeIfPresent(callsign, forKey: .callsign)
        try container.encode(caughtAt, forKey: .caughtAt)
        try container.encode(observer, forKey: .observer)
        // Always encode aircraft as explicit JSON null (backend distinguishes
        // `null` from a missing key; null = "no position, still accept").
        try container.encodeNil(forKey: .aircraft)
    }

    enum CodingKeys: String, CodingKey {
        case catchUuid, icao24, callsign, caughtAt, observer, aircraft
    }
}

/// Response from POST /v1/catches (201 or 200).
nonisolated struct UploadCatchResponse: Decodable {
    let catchId: String
    let points: Int
    let rarity: String?
    let typecode: String?
    let duplicate: Bool
}

/// One row in GET /v1/leaderboard's `entries` array.
nonisolated struct LeaderboardEntry: Decodable, Identifiable {
    let rank: Int
    let handle: String
    let points: Int
    let catches: Int

    var id: String { handle }
}

/// The caller's own standing in GET /v1/leaderboard (`me` key).
nonisolated struct MyStanding: Decodable {
    let rank: Int
    let points: Int
}

/// Full leaderboard response.
nonisolated struct LeaderboardResponse: Decodable {
    let entries: [LeaderboardEntry]
    /// Present when a valid bearer token was sent, even handle-less.
    let me: MyStanding?
}

// MARK: - Client

/// Errors specific to the account API layer.
nonisolated enum AccountError: Error, LocalizedError {
    /// PUT /v1/devices/me/handle returned 409 — the handle is taken.
    case handleTaken
    /// The server returned an unexpected HTTP status.
    case http(status: Int)
    /// A URLSession transport error.
    case transport(Error)
    /// Response body couldn't be decoded.
    case decoding(Error)
    /// No device token available (registration never completed).
    case notRegistered

    var errorDescription: String? {
        switch self {
        case .handleTaken:       return "Handle already taken"
        case .http(let s):       return "HTTP \(s)"
        case .transport(let e):  return "Network error: \(e.localizedDescription)"
        case .decoding(let e):   return "Decode error: \(e.localizedDescription)"
        case .notRegistered:     return "Device not registered — call ensureRegistered() first"
        }
    }
}

/// UserDefaults key for the device ID (non-secret, public-facing identifier).
private let deviceIdDefaultsKey = "tailspot.account.deviceId"
/// Keychain account name for the device bearer token.
private let deviceTokenKeychainAccount = "deviceToken"

nonisolated struct TailspotAccountClient {
    /// Production API base URL.
    static let defaultBaseURL = URL(string: "https://api.tailspot.app")!

    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = TailspotAccountClient.defaultBaseURL,
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Stored credentials (token → Keychain, id → UserDefaults)

    /// The device bearer token stored in the Keychain, or nil if not yet registered.
    var storedToken: String? {
        KeychainStore.load(account: deviceTokenKeychainAccount)
    }

    /// The device ID stored in UserDefaults, or nil if not yet registered.
    var storedDeviceId: String? {
        UserDefaults.standard.string(forKey: deviceIdDefaultsKey)
    }

    // MARK: - ensureRegistered

    /// Register this device with the backend, persisting the token to Keychain
    /// and the device ID to UserDefaults. Idempotent: if a token is already in
    /// the Keychain the network call is skipped entirely. Returns the device ID.
    ///
    /// Call once on first launch (or after a Keychain wipe). Subsequent calls
    /// return instantly from the Keychain/UserDefaults cache.
    @discardableResult
    func ensureRegistered() async throws -> String {
        // Short-circuit: if both the token (Keychain) and deviceId (UserDefaults)
        // are already present, we're already registered.
        if let existingToken = storedToken,
           let existingId = storedDeviceId,
           !existingToken.isEmpty, !existingId.isEmpty {
            return existingId
        }

        // POST /v1/devices — no auth, no body.
        let url = baseURL.appendingPathComponent("v1/devices")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let data = try await perform(request, expectedStatus: 201)
        let response: RegisterDeviceResponse
        do {
            response = try JSONDecoder().decode(RegisterDeviceResponse.self, from: data)
        } catch {
            throw AccountError.decoding(error)
        }

        // Persist: token → Keychain (secret), id → UserDefaults (non-secret).
        KeychainStore.save(secret: response.deviceToken, account: deviceTokenKeychainAccount)
        UserDefaults.standard.set(response.deviceId, forKey: deviceIdDefaultsKey)

        return response.deviceId
    }

    // MARK: - claimHandle

    /// Claim or replace the caller's public handle. The backend enforces
    /// case-insensitive uniqueness. Throws `AccountError.handleTaken` on 409.
    func claimHandle(_ handle: String) async throws {
        guard let token = storedToken else { throw AccountError.notRegistered }

        let url = baseURL.appendingPathComponent("v1/devices/me/handle")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["handle": handle]
        request.httpBody = try JSONEncoder().encode(body)

        _ = try await perform(request, expectedStatus: 200, on409: .handleTaken)
    }

    // MARK: - uploadCatch

    /// Upload a single catch to the backend. `catchUuid` is the caller-supplied
    /// idempotency key — sending the same UUID twice returns the original result
    /// with `duplicate: true`. Always sends `aircraft: null` (backfill path).
    func uploadCatch(
        catchUuid: String,
        icao24: String,
        callsign: String?,
        caughtAt: Date,
        observerLat: Double,
        observerLon: Double,
        headingDeg: Double?,
        elevationDeg: Double?,
        headingAccuracyDeg: Double?
    ) async throws -> UploadCatchResponse {
        guard let token = storedToken else { throw AccountError.notRegistered }

        let url = baseURL.appendingPathComponent("v1/catches")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = UploadCatchRequest(
            catchUuid: catchUuid,
            icao24: icao24,
            callsign: callsign,
            caughtAt: caughtAt.timeIntervalSince1970,
            observer: .init(
                lat: observerLat,
                lon: observerLon,
                headingDeg: headingDeg,
                elevationDeg: elevationDeg,
                headingAccuracyDeg: headingAccuracyDeg
            ),
            aircraft: nil
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await perform(request, expectedStatus: 201, alsoAccept: 200)
        do {
            return try JSONDecoder().decode(UploadCatchResponse.self, from: data)
        } catch {
            throw AccountError.decoding(error)
        }
    }

    // MARK: - leaderboard

    /// Fetch the global leaderboard. Passes the bearer token when available
    /// (fills `me`); anonymous if not registered.
    func leaderboard(limit: Int = 50) async throws -> LeaderboardResponse {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("v1/leaderboard"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = comps?.url else { throw AccountError.http(status: -1) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Auth is optional for this endpoint — include token when available.
        if let token = storedToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data = try await perform(request, expectedStatus: 200)
        do {
            return try JSONDecoder().decode(LeaderboardResponse.self, from: data)
        } catch {
            throw AccountError.decoding(error)
        }
    }

    // MARK: - Shared transport

    /// Perform a URLRequest, return the body on success, throw on errors.
    /// `alsoAccept` allows a second success status (e.g. 200 as well as 201).
    /// `on409` maps a 409 conflict to a specific AccountError.
    private func perform(
        _ request: URLRequest,
        expectedStatus: Int,
        alsoAccept: Int? = nil,
        on409: AccountError? = nil
    ) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AccountError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AccountError.http(status: -1)
        }
        if http.statusCode == expectedStatus || http.statusCode == alsoAccept {
            return data
        }
        if http.statusCode == 409, let mapped = on409 {
            throw mapped
        }
        throw AccountError.http(status: http.statusCode)
    }
}
