//
//  ChallengeModels.swift
//  Tailspot
//
//  Wire models for the Challenges backend, pinned to PR #276's actual
//  response shapes (superseding the spec-derived draft this file started
//  as — see git history for that version). Additive-tolerant by
//  construction: Swift's synthesized Decodable conformance already calls
//  `decodeIfPresent` for any `Optional`-typed stored property, so a field
//  the server hasn't shipped yet (or omits for this response) decodes to
//  nil instead of failing the whole payload — hand-written `init(from:)`
//  is used only where a non-optional field needs a null/absent default
//  (a "no catches yet" empty array or dictionary, never a thrown error).
//  `nonisolated` throughout: pure value types, no UI, no networking — the
//  transport client that decodes these lives elsewhere (phase 2).
//

import Foundation

/// Shared date handling for every Challenges response. The backend is
/// Postgres `timestamptz` serialized by Fastify, which emits fractional-
/// second ISO-8601 — but the fallback formatter (no fractional seconds)
/// mirrors the belt-and-suspenders pattern already used for `resetsAt` in
/// `TailspotAccountClient.LeaderboardResponse`, in case a future route ever
/// emits a whole-second stamp. `isoString(from:)` is the encode-side mirror,
/// used by `ChallengeCreateRequest.scheduled`.
nonisolated enum ChallengeJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = fractionalISO8601.date(from: raw) { return date }
            if let date = plainISO8601.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid ISO-8601 date: \(raw)"
            )
        }
        return d
    }()

    static func isoString(from date: Date) -> String {
        fractionalISO8601.string(from: date)
    }

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainISO8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Derived challenge status (never stored server-side). `unknown` is the
/// forward-compat fallback for a status string this build doesn't
/// recognize yet, so a future server-side addition degrades instead of
/// throwing away the whole response.
nonisolated enum ChallengeStatus: String, Equatable, Sendable {
    case upcoming
    case live
    case finished
    case cancelled
    case unknown
}

nonisolated extension ChallengeStatus: Decodable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChallengeStatus(rawValue: raw) ?? .unknown
    }
}

/// The requester's own result on a challenge — either embedded in a list
/// row (`myResult`) or the detail/create/join response's `me`. Same three
/// fields either way, so one type serves both.
nonisolated struct ChallengeMyResult: Decodable, Equatable {
    let placement: Int
    let points: Int
    let catches: Int
}

/// The one serialized-challenge shape, used everywhere a `challenge`
/// appears (list rows, the detail/create/join `challenge` field, and
/// nested in `ChallengeInvitePreview`). `code`/`inviteURL` are nil for a
/// participant who isn't the creator in a future response shape that
/// withholds them (v1 always sends both to participants, but the type
/// doesn't assume that). `outcome` is null while live/upcoming, "decided"
/// or "no_contest" once finalized.
nonisolated struct ChallengeSummary: Decodable, Identifiable, Equatable {
    let id: String
    let kind: String
    let code: String?
    let inviteURL: String?
    let name: String
    let creatorHandle: String
    let startsAt: Date
    let endsAt: Date
    let durationPreset: String
    let maxParticipants: Int
    let status: ChallengeStatus
    let outcome: String?
    let participantCount: Int
    let isCreator: Bool
    let isParticipant: Bool
    /// Present only on GET /v1/challenges list rows; nil elsewhere.
    let myResult: ChallengeMyResult?

    /// Section 5 "No Contest" as observed by the client: the server is the
    /// only source of truth for the verdict (it already ran the threshold
    /// at finalization), so this just reads the frozen `outcome` rather
    /// than re-deriving it from standings.
    var isNoContest: Bool { outcome == "no_contest" }
    var isDecided: Bool { outcome == "decided" }
}

/// GET /v1/challenges → `{ open, history }`, each an array of
/// `ChallengeSummary` rows (with `myResult` populated).
nonisolated struct ChallengeList: Decodable, Equatable {
    let open: [ChallengeSummary]
    let history: [ChallengeSummary]

    private enum CodingKeys: String, CodingKey { case open, history }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        open = try c.decodeIfPresent([ChallengeSummary].self, forKey: .open) ?? []
        history = try c.decodeIfPresent([ChallengeSummary].self, forKey: .history) ?? []
    }

    init(open: [ChallengeSummary], history: [ChallengeSummary]) {
        self.open = open
        self.history = history
    }
}

/// One row of a challenge's standings. `isMe` is only meaningful when the
/// caller is a participant; kept optional rather than assumed-false for a
/// future response shape that omits it.
nonisolated struct ChallengeStanding: Decodable, Equatable {
    let placement: Int
    let handle: String
    let points: Int
    let catches: Int
    let rarityBreakdown: [String: Int]
    let isMe: Bool?

    private enum CodingKeys: String, CodingKey {
        case placement, handle, points, catches, rarityBreakdown, isMe
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        placement = try c.decode(Int.self, forKey: .placement)
        handle = try c.decode(String.self, forKey: .handle)
        points = try c.decode(Int.self, forKey: .points)
        catches = try c.decode(Int.self, forKey: .catches)
        // The server sends `rarityBreakdown: null` (never `{}`) for a
        // participant with zero catches — decode that as an empty
        // breakdown rather than failing the row.
        rarityBreakdown = try c.decodeIfPresent([String: Int].self, forKey: .rarityBreakdown) ?? [:]
        isMe = try c.decodeIfPresent(Bool.self, forKey: .isMe)
    }

    init(placement: Int, handle: String, points: Int, catches: Int,
         rarityBreakdown: [String: Int], isMe: Bool? = nil) {
        self.placement = placement
        self.handle = handle
        self.points = points
        self.catches = catches
        self.rarityBreakdown = rarityBreakdown
        self.isMe = isMe
    }
}

/// GET /v1/challenges/:id, POST /v1/challenges (201) and POST
/// /v1/invites/:code/join (200) all share this shape. `alreadyIn` and
/// `newDevice` only appear on the join response; nil on detail/create.
/// `noContest` isn't a field here — it's `challenge.isNoContest`, so there
/// is exactly one source of truth for the verdict.
nonisolated struct ChallengeDetail: Decodable, Equatable {
    let challenge: ChallengeSummary
    let standings: [ChallengeStanding]
    let me: ChallengeMyResult?
    let winners: [String]
    let alreadyIn: Bool?
    let newDevice: Bool?

    private enum CodingKeys: String, CodingKey {
        case challenge, standings, me, winners, alreadyIn, newDevice
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        challenge = try c.decode(ChallengeSummary.self, forKey: .challenge)
        standings = try c.decodeIfPresent([ChallengeStanding].self, forKey: .standings) ?? []
        me = try c.decodeIfPresent(ChallengeMyResult.self, forKey: .me)
        winners = try c.decodeIfPresent([String].self, forKey: .winners) ?? []
        alreadyIn = try c.decodeIfPresent(Bool.self, forKey: .alreadyIn)
        newDevice = try c.decodeIfPresent(Bool.self, forKey: .newDevice)
    }

    init(challenge: ChallengeSummary, standings: [ChallengeStanding], me: ChallengeMyResult?,
         winners: [String], alreadyIn: Bool? = nil, newDevice: Bool? = nil) {
        self.challenge = challenge
        self.standings = standings
        self.me = me
        self.winners = winners
        self.alreadyIn = alreadyIn
        self.newDevice = newDevice
    }
}

/// One row of GET /v1/challenges/:id/log/:handle's `catches` array. The
/// privacy boundary (section 9) is enforced server-side — the server
/// composes make+model into one `aircraft` string (e.g. "Boeing 737-800")
/// rather than sending them separately; this struct carries only what that
/// route is allowed to return, never location, photo, callsign or
/// registration.
nonisolated struct ChallengeCatchLogEntry: Decodable, Equatable {
    let aircraft: String?
    let rarity: String
    let points: Int
    let caughtAt: Date
}

/// GET /v1/challenges/:id/log/:handle — `{ handle, catches }`.
nonisolated struct ChallengeCatchLog: Decodable, Equatable {
    let handle: String
    let catches: [ChallengeCatchLogEntry]
}

/// GET /v1/invites/:code (bearer route). `participants` is a plain handle
/// list — no per-participant stats, unlike standings. `reason` is only
/// present when `canJoin` is false.
nonisolated struct ChallengeInvitePreview: Decodable, Equatable {
    let challenge: ChallengeSummary
    let participants: [String]
    let needsHandle: Bool
    let alreadyIn: Bool
    let canJoin: Bool
    let reason: String?
}

/// GET /v1/challenges/config (section 11.2) — unauthenticated, read by both
/// the app and the web landing page. Drives `ChallengeBuildGate`.
nonisolated struct ChallengesConfig: Decodable, Equatable {
    let enabled: Bool
    let availability: String
    let minBuild: Int
    let appStoreURL: String?
}

/// POST /v1/challenges request body — `{ name, start, duration }`, where
/// `start` is the literal string `"now"` or an ISO-8601 instant up to 14
/// days ahead. Two named constructors instead of a raw `start: String`
/// initializer so a caller can't accidentally send a malformed date string.
nonisolated struct ChallengeCreateRequest: Encodable, Equatable {
    let name: String
    let start: String
    let duration: String

    static func startingNow(name: String, duration: String) -> ChallengeCreateRequest {
        ChallengeCreateRequest(name: name, start: "now", duration: duration)
    }

    static func scheduled(name: String, at date: Date, duration: String) -> ChallengeCreateRequest {
        ChallengeCreateRequest(name: name, start: ChallengeJSON.isoString(from: date), duration: duration)
    }
}

/// Every Challenges error response body: `{ "error": "..." }`, across every
/// documented status (401/404/409/410/422/429).
nonisolated struct ChallengeAPIError: Decodable, Equatable {
    let error: String
}
