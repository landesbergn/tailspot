//
//  PushTokenClient.swift
//  Tailspot
//
//  Uploads this device's APNs token to the backend
//  (`POST /v1/devices/push-token`), so the server can send the remote
//  challenge moments. Conventions mirror `ChallengesClient`: nonisolated
//  struct, injectable session, bearer token from the same read-or-register
//  path, 15 s timeout.
//
//  Wire contract (the backend half is being built to this — do not drift):
//
//      POST /v1/devices/push-token
//      Authorization: Bearer <device token>
//      { "token": "<lowercase hex>",
//        "environment": "sandbox" | "production",
//        "build": <Int CFBundleVersion> }
//      → 204
//
//  Idempotence is the whole design. `didRegisterForRemoteNotifications`
//  fires on EVERY launch, and iOS usually hands back the same token, so the
//  naive version would POST once per app open forever. The last successful
//  upload's token+environment is remembered in UserDefaults and an unchanged
//  pair is skipped; a FAILED upload writes nothing, so the next launch
//  retries. `build` rides along so the server can tell which client version
//  a token came from without a second lookup — and because a rebuilt app
//  with the same token is still worth a row update.
//

import Foundation
import os

nonisolated struct PushTokenClient {
    /// One backend, one base URL.
    static let defaultBaseURL = TailspotAccountClient.defaultBaseURL

    /// UserDefaults key holding the last successfully uploaded
    /// `environment:token` stamp.
    static let lastUploadedKey = "tailspot.push.lastUploaded"

    let baseURL: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private let build: Int
    /// Same read-or-register path `ChallengesClient` uses, for the same
    /// reason: a push token can arrive before anything else has registered
    /// this device, and throwing `.notRegistered` there would just lose it.
    private let resolveToken: @Sendable () async throws -> String

    init(
        baseURL: URL = PushTokenClient.defaultBaseURL,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        build: Int = ChallengeBuildGate.currentBuild(),
        tokenProvider: (@Sendable () async throws -> String)? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.defaults = defaults
        self.build = build
        if let tokenProvider {
            self.resolveToken = tokenProvider
        } else {
            self.resolveToken = {
                let account = TailspotAccountClient(baseURL: baseURL, session: session)
                if let token = account.storedToken { return token }
                _ = try await account.ensureRegistered()
                guard let token = account.storedToken else { throw PushTokenError.unauthorized }
                return token
            }
        }
    }

    // MARK: - Idempotence

    /// The remembered form of an upload. Environment first so the string
    /// splits unambiguously — a hex token can't contain a colon, but the
    /// order makes that irrelevant.
    ///
    /// The BUILD is part of the stamp, not just the token and environment
    /// (review of PR #289). It is in the request body, so the server's row
    /// records which client version a token came from — and with a
    /// two-field stamp an app update never re-sent it, leaving every
    /// upgraded device permanently recorded at the build it first
    /// registered on. Including it costs one extra POST per update.
    static func stamp(token: String, environment: String, build: Int) -> String {
        "\(environment):\(token):\(build)"
    }

    /// Pure: is this triple worth a request? Separated from the transport so
    /// the rule can be read and tested on its own.
    static func shouldUpload(token: String, environment: String, build: Int,
                             lastUploaded: String?) -> Bool {
        guard !token.isEmpty else { return false }
        return stamp(token: token, environment: environment, build: build) != lastUploaded
    }

    /// The last pair this install successfully uploaded.
    var lastUploaded: String? {
        defaults.string(forKey: Self.lastUploadedKey)
    }

    // MARK: - Upload

    /// Upload unless this exact token+environment is already on the server.
    /// Non-throwing: this runs from a UIKit delegate callback where there is
    /// nobody to tell, and the retry is simply the next launch.
    func registerIfChanged(token: String, environment: String) async {
        guard Self.shouldUpload(token: token, environment: environment, build: build,
                                lastUploaded: lastUploaded) else {
            Log.ui.debug("APNs token unchanged — not re-uploading")
            return
        }
        do {
            try await register(token: token, environment: environment)
            // Only a SUCCESS is remembered, so a failed upload retries on
            // the next launch instead of being latched away forever.
            defaults.set(Self.stamp(token: token, environment: environment, build: build),
                         forKey: Self.lastUploadedKey)
            Log.ui.notice("APNs token uploaded (\(environment, privacy: .public))")
        } catch {
            Log.ui.error("APNs token upload failed: \(String(describing: error), privacy: .public)")
            PushFailureReporter.report(
                stage: .upload, reason: String(describing: error), defaults: defaults)
        }
    }

    /// The bare POST, throwing. Separate from `registerIfChanged` so a
    /// caller (and the tests) can drive one request with no memoization.
    func register(token: String, environment: String) async throws {
        guard let url = URL(string: "v1/devices/push-token", relativeTo: baseURL)?.absoluteURL else {
            throw PushTokenError.badURL
        }
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: [
                "token": token,
                "environment": environment,
                "build": build,
            ])
        } catch {
            throw PushTokenError.encoding(error.localizedDescription)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await resolveToken())", forHTTPHeaderField: "Authorization")

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw PushTokenError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PushTokenError.network("no HTTP response")
        }
        // 204 is the contract; 200 is accepted so a server that starts
        // echoing the stored row doesn't look like a failure.
        guard http.statusCode == 204 || http.statusCode == 200 else {
            if http.statusCode == 401 { throw PushTokenError.unauthorized }
            throw PushTokenError.http(http.statusCode)
        }
    }
}

// MARK: - Failure reporting

/// The one place `push_registration_failed` is fired, so its properties
/// cannot drift between the two things that can fail.
///
/// The APNs stage is THROTTLED to once per local day. Registration fails on
/// every launch with no network, and an event that fires once per app open
/// for an offline user is not a signal — it is a graph of how often that
/// person opened the app in a tunnel. The upload stage is not throttled: it
/// only runs when there is a genuinely new token to send, which is rare.
nonisolated enum PushFailureReporter {
    enum Stage: String {
        /// iOS refused to hand over a device token.
        case apns
        /// We have a token; the backend would not take it.
        case upload
    }

    static let eventName = "push_registration_failed"
    /// Local day key of the last APNs-stage report.
    static let apnsReportedKey = "tailspot.push.apnsFailureReported"

    /// Pure: may the APNs stage report on this local day?
    static func shouldReportAPNsFailure(dayKey: String, lastReported: String?) -> Bool {
        dayKey != lastReported
    }

    /// Fire the event, subject to the per-stage rules. Returns whether it
    /// actually fired, which is what the tests assert on.
    @discardableResult
    static func report(stage: Stage,
                       reason: String,
                       defaults: UserDefaults = .standard,
                       now: Date = Date()) -> Bool {
        if stage == .apns {
            let dayKey = Streaks.dayKey(for: now)
            guard shouldReportAPNsFailure(
                dayKey: dayKey, lastReported: defaults.string(forKey: apnsReportedKey)
            ) else { return false }
            defaults.set(dayKey, forKey: apnsReportedKey)
        }
        Analytics.capture(eventName, [
            "stage": .string(stage.rawValue),
            "reason": .string(reason),
        ])
        return true
    }
}

nonisolated enum PushTokenError: Error, Equatable {
    case badURL
    case unauthorized
    case http(Int)
    case network(String)
    case encoding(String)
}
