//
//  ChallengeModels.swift
//  Tailspot
//
//  Wire models for the Challenges backend (spec: 2026-09-15-challenges-v1-spec.html,
//  sections 5/6/10/11.2/13). Additive-tolerant by construction: Swift's
//  synthesized Decodable conformance already calls `decodeIfPresent` for any
//  `Optional`-typed stored property, so a field the server hasn't shipped yet
//  (or omits for this response) decodes to nil instead of failing the whole
//  payload — no hand-written `init(from:)` needed for the plain structs below.
//  `nonisolated` throughout: pure value types, no UI, no networking — the
//  transport client that decodes these lives elsewhere (phase 2).
//

import Foundation

/// Shared date handling for every Challenges response. The backend is
/// Postgres `timestamptz` serialized by Fastify, which emits fractional-
/// second ISO-8601 — but the fallback formatter (no fractional seconds)
/// mirrors the belt-and-suspenders pattern already used for `resetsAt` in
/// `TailspotAccountClient.LeaderboardResponse`, in case a future route ever
/// emits a whole-second stamp.
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

/// Derived challenge status (never stored server-side — section 10.1).
/// `unknown` is the forward-compat fallback for a status string this build
/// doesn't recognize yet, so a future server-side addition degrades instead
/// of throwing away the whole response.
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

/// GET /v1/challenges list row, and the `challenge` half of a detail
/// response (section 10.3). `code` is present for a creator/participant's
/// own summaries but withheld nowhere in v1 (no public-quest seam yet, kind
/// is always "private") — kept optional per the additive-tolerant contract.
nonisolated struct ChallengeSummary: Decodable, Identifiable, Equatable {
    let id: String
    let kind: String
    let name: String
    let code: String?
    let creatorHandle: String
    let startsAt: Date
    let endsAt: Date
    let durationPreset: String
    let participantCount: Int
    let maxParticipants: Int
    let status: ChallengeStatus
    let cancelledAt: Date?
    let outcome: String?
    let myPlacement: Int?
    let myPoints: Int?
}

/// One row of GET /v1/challenges/:id standings (section 10.2). `isMe` is
/// only meaningful when the caller is a participant; the bearer route
/// always includes the requester's own row, so `isMe` is optional rather
/// than assumed-false for a future response shape that omits it.
nonisolated struct ChallengeStanding: Decodable, Equatable {
    let handle: String
    let points: Int
    let catches: Int
    let placement: Int
    let rarityBreakdown: [String: Int]
    let isMe: Bool?

    private enum CodingKeys: String, CodingKey {
        case handle, points, catches, placement, rarityBreakdown, isMe
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        points = try c.decode(Int.self, forKey: .points)
        catches = try c.decode(Int.self, forKey: .catches)
        placement = try c.decode(Int.self, forKey: .placement)
        // `jsonb_object_agg` returns null (never `{}`) for a participant
        // with zero catches — decode that as an empty breakdown rather than
        // failing the row.
        rarityBreakdown = try c.decodeIfPresent([String: Int].self, forKey: .rarityBreakdown) ?? [:]
        isMe = try c.decodeIfPresent(Bool.self, forKey: .isMe)
    }

    init(handle: String, points: Int, catches: Int, placement: Int,
         rarityBreakdown: [String: Int], isMe: Bool? = nil) {
        self.handle = handle
        self.points = points
        self.catches = catches
        self.placement = placement
        self.rarityBreakdown = rarityBreakdown
        self.isMe = isMe
    }
}

/// GET /v1/challenges/:id (section 10.3). `winners` and a No Contest verdict
/// are both server-computed at finalization (or live-derived before it) so
/// the client never re-implements the No Contest threshold — it only reads
/// `noContest`. `winners`/empty defaults for a not-yet-finalized live
/// challenge that hasn't shipped either field yet.
nonisolated struct ChallengeDetail: Decodable, Equatable {
    let challenge: ChallengeSummary
    let standings: [ChallengeStanding]
    let winners: [String]
    let noContest: Bool

    private enum CodingKeys: String, CodingKey {
        case challenge, standings, winners, noContest
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        challenge = try c.decode(ChallengeSummary.self, forKey: .challenge)
        standings = try c.decodeIfPresent([ChallengeStanding].self, forKey: .standings) ?? []
        winners = try c.decodeIfPresent([String].self, forKey: .winners) ?? []
        noContest = try c.decodeIfPresent(Bool.self, forKey: .noContest) ?? false
    }

    init(challenge: ChallengeSummary, standings: [ChallengeStanding],
         winners: [String], noContest: Bool) {
        self.challenge = challenge
        self.standings = standings
        self.winners = winners
        self.noContest = noContest
    }
}

/// One row of GET /v1/challenges/:id/log/:handle (section 10.3). The
/// privacy boundary (section 9) is enforced server-side — this struct only
/// carries what that route is allowed to return: make/model, rarity, points
/// and time, never location, photo, callsign or registration.
nonisolated struct ChallengeCatchLogEntry: Decodable, Equatable {
    let make: String?
    let model: String?
    let rarity: String
    let points: Int
    let caughtAt: Date
}

/// GET /v1/invites/:code preview (bearer route — section 9's participant
/// handles list; distinct from the public `/preview` route, which never
/// carries handles). `status` reuses `ChallengeStatus` since the same
/// derived-status rules apply to an unjoined invite.
nonisolated struct ChallengeInvitePreview: Decodable, Equatable {
    let name: String
    let creatorHandle: String
    let startsAt: Date
    let endsAt: Date
    let participantHandles: [String]
    let participantCount: Int
    let maxParticipants: Int
    let status: ChallengeStatus
}

/// GET /v1/challenges/config (section 11.2) — unauthenticated, read by both
/// the app and the web landing page. Drives `ChallengeBuildGate`.
nonisolated struct ChallengesConfig: Decodable, Equatable {
    let enabled: Bool
    let availability: String
    let minBuild: Int
    let appStoreURL: String?
}
