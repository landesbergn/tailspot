//
//  ChallengeState.swift
//  Tailspot
//
//  Pure, clock-injected derivations shared by every Challenges surface: the
//  status state machine (server-authoritative but re-derivable client-side
//  for optimistic UI, section 10.1), the mono countdown copy the leaderboard
//  style uses (section 7), and placement label formatting (section 8's
//  "never colour only" rule needs the ordinal text everywhere a medal tint
//  appears). `nonisolated` — no UI, no networking.
//

import Foundation

/// The four duration presets the server accepts, as seconds (spec §5).
nonisolated enum ChallengeDurations {
    static let presets = ["1h", "24h", "3d", "7d"]

    static func seconds(for preset: String) -> TimeInterval {
        switch preset {
        case "1h": return 3600
        case "24h": return 86_400
        case "3d": return 3 * 86_400
        default: return 7 * 86_400
        }
    }
}

nonisolated enum ChallengeTiming {
    /// Section 10.1: "Status is derived, never stored... cancelled if
    /// cancelled_at, else upcoming before starts_at, live until ends_at,
    /// finished after." Cancellation wins over every other state.
    static func status(
        startsAt: Date,
        endsAt: Date,
        cancelledAt: Date?,
        now: Date
    ) -> ChallengeStatus {
        if cancelledAt != nil { return .cancelled }
        if now < startsAt { return .upcoming }
        if now < endsAt { return .live }
        return .finished
    }

    /// The mono ALL-CAPS countdown the leaderboard's live card uses.
    /// Bucketing: under 1h → minutes only, under 24h → hours + minutes,
    /// otherwise days + hours. Never seconds. A zero remainder in the
    /// finer unit is dropped ("3D" not "3D 0H") to match the terse style.
    static func timeRemainingCopy(until: Date, now: Date) -> String {
        let interval = until.timeIntervalSince(now)
        guard interval > 0 else { return "ENDED" }
        return "\(magnitudeCopy(interval)) LEFT"
    }

    /// Same bucketing as `timeRemainingCopy`, phrased for a challenge that
    /// hasn't started yet ("STARTS IN 3H"). Kept as a separate function
    /// rather than folding a mode flag into `timeRemainingCopy`: a single
    /// `(until:now:)` pure function has no way to know which label applies
    /// (a live challenge's end and an upcoming challenge's start are both
    /// just "a future instant" to the math), and the spec names both
    /// phrasings as fixed strings rather than parameterizing one.
    static func startsInCopy(startsAt: Date, now: Date) -> String {
        let interval = startsAt.timeIntervalSince(now)
        guard interval > 0 else { return "STARTS IN 0M" }
        return "STARTS IN \(magnitudeCopy(interval))"
    }

    private static func magnitudeCopy(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60) // floor — never round up into a lie
        if totalMinutes < 60 {
            return "\(totalMinutes)M"
        }
        if totalMinutes < 24 * 60 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            return minutes == 0 ? "\(hours)H" : "\(hours)H \(minutes)M"
        }
        let totalHours = totalMinutes / 60
        let days = totalHours / 24
        let hours = totalHours % 24
        return hours == 0 ? "\(days)D" : "\(days)D \(hours)H"
    }

    /// Locale-aware ordinal, cached like `ProfileScreen.ordinalRank`. A tie
    /// prefixes "T-" per section 8: "Ties read 'tied 1st'" — the visible
    /// text form of that is "T-1st".
    private static let ordinalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f
    }()

    static func placementLabel(placement: Int, isTie: Bool) -> String {
        let ordinal = ordinalFormatter.string(from: NSNumber(value: placement)) ?? "\(placement)"
        return isTie ? "T-\(ordinal)" : ordinal
    }

    /// "3rd of 6" — the catch-log / detail-header form that also states the
    /// field size. The spec's bullet names this `placementOf(participants:)`
    /// without a second label; a placement-less "of 6" reads as nonsense, so
    /// this resolves it as `placementOf(placement:participants:)`.
    static func placementOf(placement: Int, participants: Int) -> String {
        let ordinal = ordinalFormatter.string(from: NSNumber(value: placement)) ?? "\(placement)"
        return "\(ordinal) of \(participants)"
    }
}
