//
//  StreakCover.swift
//  Tailspot
//
//  Forgiven days: days the operator declares, for everyone, on which a
//  missed catch does not break a streak (an FAA ground stop, say). The app
//  reads the list from `GET /v1/streak-forgiveness` on every foreground and
//  applies it locally; the push that announces a day is only the
//  announcement, so people with notifications off are covered too.
//
//  A forgiven day is a COVERED day: it bridges a streak and never counts
//  toward it (`Streaks.currentStreak`), so every counted day is still a
//  real catch. `Streaks.coveredDays()` hands the same set to every streak
//  reader.
//
//  Shape follows the repo's planner convention: pure rules (`StreakCover`),
//  a thin UserDefaults store, and a small coordinator the app calls on
//  foreground.
//
//  Earned freezes and a manual repair were built alongside this and parked
//  on branch `claude/streak-freezes-repair` (Noah, 2026-11-14). They plug
//  into the same covered set.
//

import Foundation
import os

/// One operator-forgiven day, as served by the backend.
nonisolated struct ForgivenDay: Codable, Equatable, Sendable {
    let day: String
    let reason: String
}

nonisolated enum StreakCover {

    /// The forgiven day worth one toast line, if any: today or yesterday,
    /// one that actually spared this user a catch, while there is a streak
    /// for it to have spared, and not already announced.
    static func dayToAnnounce(
        catchDays: Set<String>,
        forgiven: [ForgivenDay],
        announced: Set<String>,
        todayKey: String
    ) -> ForgivenDay? {
        let covered = Set(forgiven.map(\.day))
        guard Streaks.currentStreak(days: catchDays, todayKey: todayKey, covered: covered) > 0 else {
            return nil
        }
        let yesterday = Streaks.key(byAdding: -1, to: todayKey)
        return forgiven.last {
            ($0.day == todayKey || $0.day == yesterday)
                && !catchDays.contains($0.day)
                && !announced.contains($0.day)
        }
    }

    // MARK: Copy (dry voice)

    static func forgivenLine(_ day: ForgivenDay, todayKey: String) -> String {
        if day.day == todayKey { return "No catch needed today: \(day.reason)." }
        let phrase = Streaks.dayPhrase(forKey: day.day, todayKey: todayKey)
        return "\(phrase.prefix(1).uppercased())\(phrase.dropFirst()) didn't count against your streak: \(day.reason)."
    }

    // MARK: Wire validation

    /// Keep only well-formed rows from the server: a real "yyyy-MM-dd" key
    /// and a non-empty reason, trimmed to something a toast can hold.
    static func sanitized(_ days: [ForgivenDay]) -> [ForgivenDay] {
        var seen = Set<String>()
        return days.compactMap { row in
            let reason = row.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard row.day.count == 10,
                  let next = Streaks.key(byAdding: 1, to: row.day),
                  Streaks.key(byAdding: -1, to: next) == row.day,
                  !reason.isEmpty,
                  seen.insert(row.day).inserted else { return nil }
            return ForgivenDay(day: row.day, reason: String(reason.prefix(80)))
        }
        .sorted { $0.day < $1.day }
    }
}

// MARK: - Store

/// UserDefaults persistence for the cached forgiveness list. The read is
/// cheap (one small JSON blob) and happens on every streak read, which is
/// what keeps every reader on the same covered set.
nonisolated enum StreakCoverStore {
    static let forgivenKey = "tailspot.streak.forgiven.v1"
    /// Forgiven days already announced in a toast.
    static let announcedKey = "tailspot.streak.forgivenAnnounced.v1"

    static func forgiven(defaults: UserDefaults = .standard) -> [ForgivenDay] {
        guard let data = defaults.data(forKey: forgivenKey) else { return [] }
        return (try? JSONDecoder().decode([ForgivenDay].self, from: data)) ?? []
    }

    static func saveForgiven(_ days: [ForgivenDay], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(days) else { return }
        defaults.set(data, forKey: forgivenKey)
    }

    static func announced(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: announcedKey) ?? [])
    }

    static func markAnnounced(_ day: String, defaults: UserDefaults = .standard) {
        // Only recent days are ever announced, so the list needs no history.
        let kept = (defaults.stringArray(forKey: announcedKey) ?? []).suffix(13)
        defaults.set(Array(kept) + [day], forKey: announcedKey)
    }

    /// How long the operator has to take back a day declared by mistake.
    static let takeBackWindowDays = 7

    /// The server's list, plus any cached day older than the take-back
    /// window that the server no longer lists. Recent days follow the
    /// server exactly, which is what lets a mistake be removed; older days
    /// are settled history, and a server that comes back empty (a restore,
    /// a fresh database) must not break every streak that crossed one.
    static func merged(
        cached: [ForgivenDay], server: [ForgivenDay], todayKey: String
    ) -> [ForgivenDay] {
        guard let cutoff = Streaks.key(byAdding: -takeBackWindowDays, to: todayKey) else {
            return server
        }
        let listed = Set(server.map(\.day))
        let kept = cached.filter { $0.day < cutoff && !listed.contains($0.day) }
        return (server + kept).sorted { $0.day < $1.day }
    }

    /// A hash of the stored list, for memo keys that must recompute when
    /// the covered set changes.
    static func stateToken(defaults: UserDefaults = .standard) -> Int {
        var hasher = Hasher()
        hasher.combine(defaults.data(forKey: forgivenKey))
        return hasher.finalize()
    }

    static func coveredDays(defaults: UserDefaults = .standard) -> Set<String> {
        Set(forgiven(defaults: defaults).map(\.day))
    }
}

// MARK: - Client

/// `GET /v1/streak-forgiveness` → `{ "days": [ { "day", "reason" } ] }`.
/// Public and cached server-side; no bearer token.
nonisolated struct StreakForgivenessClient {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = TailspotAccountClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private struct Envelope: Decodable {
        let days: [ForgivenDay]
    }

    static func decode(_ data: Data) throws -> [ForgivenDay] {
        StreakCover.sanitized(try JSONDecoder().decode(Envelope.self, from: data).days)
    }

    func fetch() async throws -> [ForgivenDay] {
        guard let url = URL(string: "v1/streak-forgiveness", relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self.decode(data)
    }
}

// MARK: - Telemetry

nonisolated enum StreakCoverTelemetry {
    /// Fired once per forgiven day that spared this user a catch, when the
    /// toast for it is shown.
    static let forgivenessAppliedEvent = "streak_forgiveness_applied"

    static func forgivenessProperties(_ day: ForgivenDay) -> [String: AnalyticsValue] {
        ["day_key": .string(day.day), "reason": .string(day.reason)]
    }
}

// MARK: - Coordinator

enum StreakCoverCenter {

    /// On every foreground: refresh the forgiven list and return the toast
    /// line to show, if any. A failed fetch keeps the cached list. The
    /// caller re-plans the streak reminder afterwards so it sees the result.
    static func foreground(
        catchDays: Set<String>,
        now: Date = Date(),
        client: StreakForgivenessClient = StreakForgivenessClient(),
        defaults: UserDefaults = .standard
    ) async -> String? {
        let todayKey = Streaks.dayKey(for: now)
        do {
            let server = try await client.fetch()
            StreakCoverStore.saveForgiven(
                StreakCoverStore.merged(cached: StreakCoverStore.forgiven(defaults: defaults),
                                        server: server, todayKey: todayKey),
                defaults: defaults)
        } catch {
            Log.ui.debug("Streak forgiveness fetch failed: \(String(describing: error), privacy: .public)")
        }
        guard let day = StreakCover.dayToAnnounce(
            catchDays: catchDays,
            forgiven: StreakCoverStore.forgiven(defaults: defaults),
            announced: StreakCoverStore.announced(defaults: defaults),
            todayKey: todayKey) else { return nil }
        StreakCoverStore.markAnnounced(day.day, defaults: defaults)
        Analytics.capture(StreakCoverTelemetry.forgivenessAppliedEvent,
                          StreakCoverTelemetry.forgivenessProperties(day))
        return StreakCover.forgivenLine(day, todayKey: todayKey)
    }
}
