//
//  ChallengesService.swift
//  Tailspot
//
//  The seam between the Challenges screens and the network. Screens and
//  `ChallengesModel` depend only on this protocol; production injects
//  `ChallengesClient` (URLSession against api.tailspot.app, phase 2) and
//  tests / snapshot harnesses / SwiftUI previews inject
//  `FixtureChallengesService`, which answers from in-memory data and never
//  touches the network — the same dependency-injection shape as
//  `ADSBManager.init(source:)` (see CLAUDE.md "Tests").
//
//  Explain-as-we-go: a protocol with `async throws` requirements is Swift's
//  way of saying "some object that can do these things, possibly slowly,
//  possibly failing". `Sendable` promises the object is safe to hand across
//  concurrency boundaries; the fixture keeps that promise with a lock.
//

import Foundation

/// Every way a Challenges call can fail, mapped from the backend's status
/// codes (spec §10.3) so screens switch on cases, never on numbers.
nonisolated enum ChallengesError: Error, Equatable {
    /// 401 — no or invalid bearer token (registration never happened).
    case unauthorized
    /// 404 — unknown challenge or code, or not a participant. Also what
    /// every challenge route returns while the server flag is off; the
    /// model turns that into `.unavailable` when the config says so.
    case notFound
    /// 409 on join — 10 of 10 already in.
    case full
    /// 410 on join — ended or cancelled.
    case closed
    /// 422 "handle required" — claim a handle first.
    case handleRequired
    /// Other 422s (name too short, profanity, schedule out of range). The
    /// string is the server's plain-language reason, shown as is.
    case invalid(String)
    /// 409 that is not "full" (e.g. cancel after start).
    case conflict(String)
    /// 429 — back off; the screen shows a retry, never a spinner loop.
    case rateLimited
    /// Config says disabled, or the build is below the server minimum.
    case unavailable
    /// Transport failure (offline, DNS, timeout). Carries the description.
    case network(String)
    /// The server answered but the body did not decode.
    case decoding(String)
}

/// What the screens need from the backend. One method per route in spec
/// §10.3; nothing here knows about URLs, tokens or JSON.
nonisolated protocol ChallengesService: Sendable {
    /// GET /v1/challenges/config — unauthenticated, cheap, cacheable.
    func config() async throws -> ChallengesConfig
    /// GET /v1/challenges — everything this device is in, open + history.
    func list() async throws -> ChallengeList
    /// GET /v1/challenges/:id — standings + me; 404 unless a participant.
    func detail(id: String) async throws -> ChallengeDetail
    /// GET /v1/challenges/:id/log/:handle — one spotter's catch log.
    func catchLog(id: String, handle: String) async throws -> ChallengeCatchLog
    /// POST /v1/challenges — creator is the first participant.
    func create(_ request: ChallengeCreateRequest) async throws -> ChallengeDetail
    /// GET /v1/invites/:code — the Join sheet's preview.
    func invitePreview(code: String) async throws -> ChallengeInvitePreview
    /// POST /v1/invites/:code/join.
    func join(code: String) async throws -> ChallengeDetail
    /// POST /v1/challenges/:id/leave.
    func leave(id: String) async throws
    /// POST /v1/challenges/:id/cancel — creator, before start only.
    func cancel(id: String) async throws
}

// MARK: - Fixture service

/// In-memory `ChallengesService` for tests, snapshot harnesses and previews.
/// Seeded with `ChallengeFixtures` by default; every call answers from the
/// stored state and mutating calls update it (join moves a code's preview
/// into `open`, leave removes, cancel marks cancelled), so a screen flow can
/// be exercised end to end without a server. `failures` lets a test make
/// any one method throw next time it is called.
final class FixtureChallengesService: ChallengesService, @unchecked Sendable {
    struct State {
        var config: ChallengesConfig
        var open: [ChallengeSummary]
        var history: [ChallengeSummary]
        var details: [String: ChallengeDetail]
        var logs: [String: ChallengeCatchLog]            // key: "\(id)/\(handle lowercased)"
        var invites: [String: ChallengeInvitePreview]    // key: code
        /// Method name → error to throw on the next call (then cleared).
        var failures: [String: ChallengesError] = [:]
        /// Every call, in order — tests assert on the sequence.
        var calls: [String] = []
    }

    private let lock = NSLock()
    private var state: State

    init(state: State = ChallengeFixtures.demoState()) {
        self.state = state
    }

    /// Read or mutate the state under the lock.
    func withState<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&state)
    }

    /// Arm a one-shot failure for `method` ("list", "join", …).
    func fail(_ method: String, with error: ChallengesError) {
        withState { $0.failures[method] = error }
    }

    var calls: [String] { withState { $0.calls } }

    private func record(_ method: String) throws {
        try withState { s in
            s.calls.append(method)
            if let error = s.failures.removeValue(forKey: method) { throw error }
        }
    }

    func config() async throws -> ChallengesConfig {
        try record("config")
        return withState { $0.config }
    }

    func list() async throws -> ChallengeList {
        try record("list")
        return withState { ChallengeList(open: $0.open, history: $0.history) }
    }

    func detail(id: String) async throws -> ChallengeDetail {
        try record("detail")
        guard let d = withState({ $0.details[id] }) else { throw ChallengesError.notFound }
        return d
    }

    func catchLog(id: String, handle: String) async throws -> ChallengeCatchLog {
        try record("catchLog")
        let key = "\(id)/\(handle.lowercased())"
        guard let log = withState({ $0.logs[key] }) else {
            // A participant with no catches yet is an empty log, not a 404.
            if withState({ $0.details[id]?.standings.contains { $0.handle.lowercased() == handle.lowercased() } ?? false }) {
                return ChallengeCatchLog(handle: handle, catches: [])
            }
            throw ChallengesError.notFound
        }
        return log
    }

    func create(_ request: ChallengeCreateRequest) async throws -> ChallengeDetail {
        try record("create")
        let now = Date()
        let starts = request.start == "now" ? now : (ChallengeJSON.date(from: request.start) ?? now)
        let ends = starts.addingTimeInterval(ChallengeFixtures.seconds(for: request.duration))
        let id = "fixture-\(UUID().uuidString.prefix(8))"
        let code = ChallengeFixtures.code(seed: id)
        let summary = ChallengeFixtures.summary(
            id: id, name: request.name, creator: ChallengeFixtures.meHandle, code: code,
            startsAt: starts, endsAt: ends, preset: request.duration,
            status: starts > now ? .upcoming : .live, participantCount: 1,
            isCreator: true, myResult: nil
        )
        let detail = ChallengeDetail(
            challenge: summary,
            standings: [ChallengeStanding(placement: 1, handle: ChallengeFixtures.meHandle, points: 0, catches: 0, rarityBreakdown: [:], isMe: true)],
            me: ChallengeMyResult(placement: 1, points: 0, catches: 0),
            winners: [], alreadyIn: nil, newDevice: nil
        )
        withState { s in
            s.open.insert(summary, at: 0)
            s.details[id] = detail
            s.invites[code] = ChallengeInvitePreview(
                challenge: summary, participants: [ChallengeFixtures.meHandle],
                needsHandle: false, alreadyIn: true, canJoin: true, reason: nil
            )
        }
        return detail
    }

    func invitePreview(code: String) async throws -> ChallengeInvitePreview {
        try record("invitePreview")
        guard let p = withState({ $0.invites[code] }) else { throw ChallengesError.notFound }
        return p
    }

    func join(code: String) async throws -> ChallengeDetail {
        try record("join")
        guard let preview = withState({ $0.invites[code] }) else { throw ChallengesError.notFound }
        if preview.needsHandle { throw ChallengesError.handleRequired }
        if !preview.canJoin {
            switch preview.reason {
            case "full": throw ChallengesError.full
            default: throw ChallengesError.closed
            }
        }
        let id = preview.challenge.id
        let joined = withState { s -> ChallengeDetail in
            var standings = s.details[id]?.standings ?? []
            if !standings.contains(where: { $0.isMe == true }) {
                standings.append(ChallengeStanding(
                    placement: standings.count + 1, handle: ChallengeFixtures.meHandle,
                    points: 0, catches: 0, rarityBreakdown: [:], isMe: true))
            }
            let summary = ChallengeFixtures.summary(
                from: preview.challenge, participantCount: standings.count, isParticipant: true)
            let detail = ChallengeDetail(
                challenge: summary, standings: standings,
                me: ChallengeMyResult(placement: standings.count, points: 0, catches: 0),
                winners: [], alreadyIn: preview.alreadyIn, newDevice: false)
            s.details[id] = detail
            s.open.removeAll { $0.id == id }
            s.open.insert(summary, at: 0)
            s.invites[code] = ChallengeInvitePreview(
                challenge: summary, participants: standings.map(\.handle),
                needsHandle: false, alreadyIn: true, canJoin: true, reason: nil)
            return detail
        }
        return joined
    }

    func leave(id: String) async throws {
        try record("leave")
        let known = withState { s -> Bool in
            guard s.details[id] != nil else { return false }
            s.open.removeAll { $0.id == id }
            s.details[id] = nil
            return true
        }
        if !known { throw ChallengesError.notFound }
    }

    func cancel(id: String) async throws {
        try record("cancel")
        try withState { s in
            guard let d = s.details[id] else { throw ChallengesError.notFound }
            guard d.challenge.isCreator, d.challenge.status == .upcoming else {
                throw ChallengesError.conflict("challenge already started")
            }
            let cancelled = ChallengeFixtures.summary(from: d.challenge, status: .cancelled)
            s.open.removeAll { $0.id == id }
            s.history.insert(cancelled, at: 0)
            s.details[id] = ChallengeDetail(
                challenge: cancelled, standings: d.standings, me: d.me,
                winners: [], alreadyIn: nil, newDevice: nil)
        }
    }
}

// MARK: - Fixtures

/// Hand-built data covering every state the screens must render (spec §6):
/// a live challenge with a tie, an upcoming one I created, a won one, a
/// lost one, a No Contest, a cancelled one, and invite codes for each
/// joinability outcome. Handles are invented; the "me" handle is `noah`.
nonisolated enum ChallengeFixtures {
    static let meHandle = "noah"

    /// Invite codes the fixture service understands.
    enum Codes {
        static let joinable   = "K7M4QD2X"   // upcoming, 3 in, can join
        static let full       = "FULLHSE9"   // 10 of 10
        static let ended      = "ENDEDX2Y"   // finished
        static let cancelled  = "CNCLDA7B"
        static let needsHandle = "HANDLE9Q"  // joinable but I have no handle
        static let alreadyIn  = "WKNDFLY7"   // the live one I'm already in
    }

    static func seconds(for preset: String) -> TimeInterval {
        switch preset {
        case "1h": return 3600
        case "24h": return 86_400
        case "3d": return 3 * 86_400
        default: return 7 * 86_400
        }
    }

    /// A deterministic 8-char code from a seed, using the invite alphabet.
    static func code(seed: String) -> String {
        let alphabet = Array(InviteCode.alphabet)
        var hash: UInt64 = 1469598103934665603
        for b in seed.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        var out = ""
        for _ in 0..<8 {
            out.append(alphabet[Int(hash % UInt64(alphabet.count))])
            hash /= UInt64(alphabet.count) &+ 7
        }
        return out
    }

    static func summary(
        id: String, name: String, creator: String, code: String?,
        startsAt: Date, endsAt: Date, preset: String, status: ChallengeStatus,
        participantCount: Int, isCreator: Bool = false, isParticipant: Bool = true,
        outcome: String? = nil, myResult: ChallengeMyResult? = nil
    ) -> ChallengeSummary {
        ChallengeSummary(
            id: id, kind: "private", code: code,
            inviteURL: code.map { InviteCode.inviteURL(for: $0).absoluteString },
            name: name, creatorHandle: creator, startsAt: startsAt, endsAt: endsAt,
            durationPreset: preset, maxParticipants: 10, status: status, outcome: outcome,
            participantCount: participantCount, isCreator: isCreator,
            isParticipant: isParticipant, myResult: myResult
        )
    }

    /// Copy with a few fields changed (the wire structs are `let`-only).
    static func summary(
        from s: ChallengeSummary, status: ChallengeStatus? = nil,
        participantCount: Int? = nil, isParticipant: Bool? = nil,
        outcome: String?? = nil, myResult: ChallengeMyResult?? = nil
    ) -> ChallengeSummary {
        ChallengeSummary(
            id: s.id, kind: s.kind, code: s.code, inviteURL: s.inviteURL, name: s.name,
            creatorHandle: s.creatorHandle, startsAt: s.startsAt, endsAt: s.endsAt,
            durationPreset: s.durationPreset, maxParticipants: s.maxParticipants,
            status: status ?? s.status, outcome: outcome ?? s.outcome,
            participantCount: participantCount ?? s.participantCount,
            isCreator: s.isCreator, isParticipant: isParticipant ?? s.isParticipant,
            myResult: myResult ?? s.myResult
        )
    }

    static func standing(_ placement: Int, _ handle: String, _ points: Int, _ catches: Int,
                         rarity: [String: Int] = [:], me: Bool = false) -> ChallengeStanding {
        ChallengeStanding(placement: placement, handle: handle, points: points, catches: catches,
                          rarityBreakdown: rarity, isMe: me)
    }

    /// The full demo world, anchored on `now` so countdowns render sensibly
    /// ("48M LEFT" on the live one, "STARTS IN 3H" on the upcoming one).
    static func demoState(now: Date = Date()) -> FixtureChallengesService.State {
        let h: TimeInterval = 3600
        let d: TimeInterval = 86_400

        // Live: Weekend Flyoff — 24h, 48 minutes left, five in, I'm 2nd,
        // two spotters tied 3rd.
        let live = summary(
            id: "c-live", name: "Weekend Flyoff", creator: "maya", code: Codes.alreadyIn,
            startsAt: now.addingTimeInterval(-23 * h - 12 * 60), endsAt: now.addingTimeInterval(48 * 60),
            preset: "24h", status: .live, participantCount: 5,
            myResult: nil)
        let liveStandings = [
            standing(1, "maya", 404, 12, rarity: ["common": 6, "uncommon": 4, "rare": 2]),
            standing(2, meHandle, 380, 11, rarity: ["common": 7, "uncommon": 3, "epic": 1], me: true),
            standing(3, "eli", 210, 8, rarity: ["common": 6, "uncommon": 2]),
            standing(3, "jetset", 210, 7, rarity: ["common": 4, "uncommon": 2, "rare": 1]),
            standing(5, "skywatch", 40, 3, rarity: ["common": 3]),
        ]
        let liveDetail = ChallengeDetail(
            challenge: live, standings: liveStandings,
            me: ChallengeMyResult(placement: 2, points: 380, catches: 11),
            winners: [], alreadyIn: nil, newDevice: nil)

        // Upcoming: Sunday Circuit — I created it, starts in 3 h, 3 in.
        let upcoming = summary(
            id: "c-upcoming", name: "Sunday Circuit", creator: meHandle, code: Codes.joinable,
            startsAt: now.addingTimeInterval(3 * h), endsAt: now.addingTimeInterval(3 * h + 3 * d),
            preset: "3d", status: .upcoming, participantCount: 3, isCreator: true)
        let upcomingDetail = ChallengeDetail(
            challenge: upcoming,
            standings: [standing(1, meHandle, 0, 0, me: true), standing(1, "eli", 0, 0), standing(1, "avgeek", 0, 0)],
            me: ChallengeMyResult(placement: 1, points: 0, catches: 0),
            winners: [], alreadyIn: nil, newDevice: nil)

        // History: won, lost, no contest, cancelled.
        let won = summary(
            id: "c-won", name: "Golden Hour", creator: "eli", code: nil,
            startsAt: now.addingTimeInterval(-28 * d), endsAt: now.addingTimeInterval(-28 * d + h),
            preset: "1h", status: .finished, participantCount: 4, outcome: "decided",
            myResult: ChallengeMyResult(placement: 1, points: 620, catches: 9))
        let wonDetail = ChallengeDetail(
            challenge: won,
            standings: [
                standing(1, meHandle, 620, 9, rarity: ["common": 4, "rare": 3, "legendary": 1], me: true),
                standing(2, "eli", 580, 10, rarity: ["common": 8, "uncommon": 2]),
                standing(3, "maya", 250, 6, rarity: ["common": 5, "uncommon": 1]),
                standing(4, "jetset", 0, 0),
            ],
            me: ChallengeMyResult(placement: 1, points: 620, catches: 9),
            winners: [meHandle], alreadyIn: nil, newDevice: nil)

        let lost = summary(
            id: "c-lost", name: "Bay Area Spotters", creator: "skywatch", code: nil,
            startsAt: now.addingTimeInterval(-36 * d), endsAt: now.addingTimeInterval(-29 * d),
            preset: "7d", status: .finished, participantCount: 6, outcome: "decided",
            myResult: ChallengeMyResult(placement: 3, points: 410, catches: 14))
        let lostDetail = ChallengeDetail(
            challenge: lost,
            standings: [
                standing(1, "skywatch", 1120, 31), standing(1, "maya", 1120, 28),
                standing(3, meHandle, 410, 14, me: true), standing(4, "eli", 390, 12),
                standing(5, "avgeek", 120, 5), standing(6, "jetset", 60, 2),
            ],
            me: ChallengeMyResult(placement: 3, points: 410, catches: 14),
            winners: ["skywatch", "maya"], alreadyIn: nil, newDevice: nil)

        let noContest = summary(
            id: "c-nocontest", name: "Solo Sortie", creator: meHandle, code: nil,
            startsAt: now.addingTimeInterval(-40 * d), endsAt: now.addingTimeInterval(-39 * d),
            preset: "24h", status: .finished, participantCount: 1, isCreator: true,
            outcome: "no_contest", myResult: ChallengeMyResult(placement: 1, points: 150, catches: 4))
        let noContestDetail = ChallengeDetail(
            challenge: noContest,
            standings: [standing(1, meHandle, 150, 4, me: true)],
            me: ChallengeMyResult(placement: 1, points: 150, catches: 4),
            winners: [], alreadyIn: nil, newDevice: nil)

        let cancelled = summary(
            id: "c-cancelled", name: "Fogged Out", creator: "eli", code: nil,
            startsAt: now.addingTimeInterval(-45 * d), endsAt: now.addingTimeInterval(-44 * d),
            preset: "24h", status: .cancelled, participantCount: 2)
        let cancelledDetail = ChallengeDetail(
            challenge: cancelled, standings: [], me: nil, winners: [], alreadyIn: nil, newDevice: nil)

        // Catch logs (aircraft strings the server composes: "Make Model").
        let myLiveLog = ChallengeCatchLog(handle: meHandle, catches: [
            .init(aircraft: "Boeing 737-800", rarity: "common", points: 10, caughtAt: now.addingTimeInterval(-20 * h)),
            .init(aircraft: "Airbus A320neo", rarity: "common", points: 10, caughtAt: now.addingTimeInterval(-19 * h)),
            .init(aircraft: "Boeing 777-300ER", rarity: "uncommon", points: 20, caughtAt: now.addingTimeInterval(-15 * h)),
            .init(aircraft: "Embraer 175", rarity: "common", points: 10, caughtAt: now.addingTimeInterval(-14 * h)),
            .init(aircraft: "Gulfstream G650", rarity: "epic", points: 150, caughtAt: now.addingTimeInterval(-6 * h)),
            .init(aircraft: "Cessna 172", rarity: "uncommon", points: 20, caughtAt: now.addingTimeInterval(-2 * h)),
            .init(aircraft: nil, rarity: "common", points: 10, caughtAt: now.addingTimeInterval(-40 * 60)),
        ])
        let mayaLiveLog = ChallengeCatchLog(handle: "maya", catches: [
            .init(aircraft: "Boeing 747-8F", rarity: "rare", points: 50, caughtAt: now.addingTimeInterval(-21 * h)),
            .init(aircraft: "Airbus A321", rarity: "common", points: 10, caughtAt: now.addingTimeInterval(-18 * h)),
            .init(aircraft: "Boeing 787-9", rarity: "uncommon", points: 20, caughtAt: now.addingTimeInterval(-9 * h)),
        ])

        // Invite previews for every joinability outcome.
        let joinablePreview = ChallengeInvitePreview(
            challenge: summary(from: upcoming, isParticipant: false), participants: [meHandle, "eli", "avgeek"],
            needsHandle: false, alreadyIn: false, canJoin: true, reason: nil)
        let fullChallenge = summary(
            id: "c-full", name: "Fence Line Friday", creator: "avgeek", code: Codes.full,
            startsAt: now.addingTimeInterval(-h), endsAt: now.addingTimeInterval(23 * h),
            preset: "24h", status: .live, participantCount: 10, isParticipant: false)
        let fullPreview = ChallengeInvitePreview(
            challenge: fullChallenge,
            participants: ["avgeek", "maya", "eli", "jetset", "skywatch", "contrail", "dotbali", "heavywatcher", "skykid", "n12345"],
            needsHandle: false, alreadyIn: false, canJoin: false, reason: "full")
        let endedPreview = ChallengeInvitePreview(
            challenge: summary(from: won, isParticipant: false), participants: ["eli", "maya", "jetset"],
            needsHandle: false, alreadyIn: false, canJoin: false, reason: "ended")
        let cancelledPreview = ChallengeInvitePreview(
            challenge: summary(from: cancelled, isParticipant: false), participants: ["eli"],
            needsHandle: false, alreadyIn: false, canJoin: false, reason: "cancelled")
        let needsHandlePreview = ChallengeInvitePreview(
            challenge: summary(from: upcoming, isParticipant: false), participants: ["eli", "avgeek"],
            needsHandle: true, alreadyIn: false, canJoin: true, reason: nil)
        let alreadyInPreview = ChallengeInvitePreview(
            challenge: live, participants: liveStandings.map(\.handle),
            needsHandle: false, alreadyIn: true, canJoin: true, reason: nil)

        return FixtureChallengesService.State(
            config: ChallengesConfig(enabled: true, availability: "testflight", minBuild: 1,
                                     appStoreURL: "https://apps.apple.com/app/id6773470079"),
            open: [live, upcoming],
            history: [won, lost, noContest, cancelled],
            details: [
                live.id: liveDetail, upcoming.id: upcomingDetail, won.id: wonDetail,
                lost.id: lostDetail, noContest.id: noContestDetail, cancelled.id: cancelledDetail,
                fullChallenge.id: ChallengeDetail(challenge: fullChallenge, standings: [], me: nil, winners: [], alreadyIn: nil, newDevice: nil),
            ],
            logs: [
                "\(live.id)/\(meHandle)": myLiveLog,
                "\(live.id)/maya": mayaLiveLog,
            ],
            invites: [
                Codes.joinable: joinablePreview, Codes.full: fullPreview, Codes.ended: endedPreview,
                Codes.cancelled: cancelledPreview, Codes.needsHandle: needsHandlePreview,
                Codes.alreadyIn: alreadyInPreview,
            ]
        )
    }

    /// An empty world: first-run hub.
    static func emptyState() -> FixtureChallengesService.State {
        var s = demoState()
        s.open = []; s.history = []; s.details = [:]; s.logs = [:]
        return s
    }
}
