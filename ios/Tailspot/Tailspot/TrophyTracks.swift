//
//  TrophyTracks.swift
//  Tailspot
//
//  The presentation layer of the trophies rebuild. The roster stays a flat
//  list of binary achievements (ids, thresholds and the unlock ledger are
//  untouched); a TRACK just groups the achievements that share one progress
//  metric as numbered levels (Heavies I, II, III…). Everything else in the
//  roster is a FEAT: a one-off (the secret ones included, which stay
//  secret). CHASES are the up-to-three nearest goals, and a NEAR MISS is the
//  "two to go" card shown after a catch leaves a level within reach.
//
//  Everything here is pure (no SwiftUI, no state) and `nonisolated` — under
//  Xcode 26's MainActor-by-default isolation the extension-free value types
//  below must opt out explicitly so tests and background callers can use them.
//

import Foundation

// MARK: - Track definition

/// A ladder of existing achievements that share one progress metric.
nonisolated struct TrophyTrack: Identifiable, Sendable {
    let id: String
    let name: String
    /// SF Symbol shown for the track.
    let symbol: String
    /// Achievement ids in ascending threshold order.
    let levelIDs: [String]
    /// Threshold -> imperative goal copy ("Catch 10 wide-bodies").
    let goalCopy: @Sendable (Int) -> String
    /// Remaining count -> "3 new airlines to go" (singular handled).
    let remainingCopy: @Sendable (Int) -> String
    /// True when progress needs catching something DIFFERENT (a new
    /// airframe, airline, type…), as opposed to just catching more.
    let variety: Bool
}

nonisolated enum TrophyTracks {

    // MARK: Copy helpers

    /// "1,000" style grouping, locale-independent so copy is stable.
    static func grouped(_ n: Int) -> String {
        let digits = Array(String(abs(n)))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(grouped(n)) \(n == 1 ? one : many)"
    }

    // MARK: The tracks

    static let all: [TrophyTrack] = [
        TrophyTrack(
            id: "logbook", name: "Logbook", symbol: "book.closed",
            levelIDs: ["firstcatch", "spotter", "catcher", "centurion", "veteran"],
            goalCopy: { $0 == 1 ? "Catch your first plane" : "Reach \(grouped($0)) catches" },
            remainingCopy: { "\(count($0, "more catch", "more catches")) to go" },
            variety: false),
        TrophyTrack(
            id: "airframes", name: "Airframes", symbol: "number",
            levelIDs: ["world", "world2", "world3"],
            goalCopy: { "Catalogue \(grouped($0)) unique airframes" },
            remainingCopy: { "\(count($0, "new airframe", "new airframes")) to go" },
            variety: true),
        TrophyTrack(
            id: "airlines", name: "Airlines", symbol: "ticket",
            levelIDs: ["airlines", "airlines2", "airlines3", "airlines4"],
            goalCopy: { "Collect \(grouped($0)) airlines" },
            remainingCopy: { "\(count($0, "new airline", "new airlines")) to go" },
            variety: true),
        TrophyTrack(
            id: "heavies", name: "Heavies", symbol: "airplane",
            levelIDs: ["heavy", "heavy2", "heavy3"],
            goalCopy: { "Catch \(grouped($0)) wide-bodies" },
            remainingCopy: { "\(count($0, "more wide-body", "more wide-bodies")) to go" },
            variety: false),
        TrophyTrack(
            id: "narrow", name: "Single aisle", symbol: "airplane.departure",
            levelIDs: ["narrow", "narrow2", "narrow3"],
            goalCopy: { "Catch \(grouped($0)) narrow-bodies" },
            remainingCopy: { "\(count($0, "more narrow-body", "more narrow-bodies")) to go" },
            variety: false),
        TrophyTrack(
            id: "regional", name: "Regionals", symbol: "airplane.arrival",
            levelIDs: ["regional", "regional2", "regional3"],
            goalCopy: { "Catch \(grouped($0)) regional jets" },
            remainingCopy: { "\(count($0, "more regional jet", "more regional jets")) to go" },
            variety: false),
        TrophyTrack(
            id: "rare", name: "Rare finds", symbol: "diamond",
            levelIDs: ["rarehunter", "rarehunter2", "rarehunter3"],
            goalCopy: { "Find \(grouped($0)) rare-or-better airframes" },
            remainingCopy: { "\(count($0, "more rare find", "more rare finds")) to go" },
            variety: true),
        TrophyTrack(
            id: "sets", name: "Sets", symbol: "square.grid.2x2",
            levelIDs: ["setcollector", "setmaster", "sets3"],
            goalCopy: { "Complete \(grouped($0)) sets" },
            remainingCopy: { "\(count($0, "more set", "more sets")) to go" },
            variety: true),
        TrophyTrack(
            id: "types", name: "Types", symbol: "square.stack.3d.up",
            levelIDs: ["varietypack", "fulldeck"],
            goalCopy: { $0 == 7 ? "Catch all 7 aircraft types" : "Catch \(grouped($0)) different aircraft types" },
            remainingCopy: { "\(count($0, "more type", "more types")) to go" },
            variety: true),
        TrophyTrack(
            id: "heritage", name: "Heritage", symbol: "clock.arrow.circlepath",
            levelIDs: ["heritage", "heritage2"],
            goalCopy: { $0 == 1 ? "Catch a heritage aircraft" : "Catch \(grouped($0)) heritage aircraft" },
            remainingCopy: { "\(grouped($0)) more heritage aircraft to go" },
            variety: true),
        TrophyTrack(
            id: "places", name: "Places", symbol: "mappin.and.ellipse",
            levelIDs: ["places", "places2", "places3"],
            goalCopy: { "Spot from \(grouped($0)) locations" },
            remainingCopy: { "\(count($0, "new location", "new locations")) to go" },
            variety: false),
        TrophyTrack(
            id: "days", name: "Days out", symbol: "calendar",
            levelIDs: ["regular", "devotee", "days3"],
            goalCopy: { "Catch on \(grouped($0)) different days" },
            remainingCopy: { "\(count($0, "more day", "more days")) to go" },
            variety: false),
        TrophyTrack(
            id: "night", name: "Night", symbol: "moon.stars",
            levelIDs: ["night", "night2", "night3"],
            goalCopy: { "Catch \(grouped($0)) after sundown" },
            remainingCopy: { "\(count($0, "more night catch", "more night catches")) to go" },
            variety: false),
        TrophyTrack(
            id: "calls", name: "Route calls", symbol: "arrow.triangle.swap",
            levelIDs: ["calledit", "clairvoyant", "calls3"],
            goalCopy: { $0 == 1 ? "Nail your first route call" : "Nail \(grouped($0)) route calls" },
            remainingCopy: { "\(count($0, "more route call", "more route calls")) to go" },
            variety: false),
        TrophyTrack(
            id: "points", name: "Points", symbol: "dollarsign.circle",
            levelIDs: ["fourfigures", "highroller", "points3"],
            goalCopy: { "Bank \(grouped($0)) lifetime points" },
            remainingCopy: { "\(count($0, "more point", "more points")) to go" },
            variety: false),
    ]

    private static let trackByAchievementID: [String: TrophyTrack] = {
        var map: [String: TrophyTrack] = [:]
        for t in all { for id in t.levelIDs { map[id] = t } }
        return map
    }()

    /// The track an achievement is a level of, or nil for a feat.
    static func track(forAchievementID id: String) -> TrophyTrack? {
        trackByAchievementID[id]
    }

    /// 1-based level number of a track-level achievement, nil for a feat.
    static func level(ofAchievementID id: String) -> Int? {
        guard let t = trackByAchievementID[id], let i = t.levelIDs.firstIndex(of: id) else { return nil }
        return i + 1
    }

    /// Everything in the roster that is not a track level, in roster order.
    static func feats(roster: [Achievement] = Trophies.roster) -> [Achievement] {
        roster.filter { trackByAchievementID[$0.id] == nil }
    }

    // MARK: Feat symbols

    /// SF Symbol per feat id. Unknown ids (new feats added without a symbol)
    /// fall back to `"trophy"`; a test pins that every roster feat has an entry.
    static let featSymbols: [String: String] = [
        "topflight": "trophy",
        "charttopper": "chart.line.uptrend.xyaxis",
        "firstrare": "rosette",
        "epic": "sparkles",
        "legendary": "crown",
        "heavymetal": "scalemass",
        "freighter": "shippingbox",
        "bizjet": "briefcase",
        "turboprop": "wind",
        "homebody": "house",
        "mrworldwide": "globe",
        "hattrick": "3.circle",
        "redeye": "eye",
        "repeat": "repeat",
        "streak": "flame",
        "longshot": "scope",
        "multi": "viewfinder",
        "quintet": "5.circle",
        "military": "star",
        "helicopter": "fanblades",
        "milehigh": "arrow.up.to.line",
        "speeddemon": "speedometer",
        "marathon": "figure.run",
        "aroundclock": "clock",
        "ondeck": "arrow.down.to.line",
        "weekend": "sun.max",
        "dawn": "sunrise",
        "doubleheader": "rectangle.on.rectangle",
        "hotstreak": "bolt",
        "dynasty": "medal",
        "groundstop": "xmark.octagon",
    ]

    static func featSymbol(for achievementID: String) -> String {
        featSymbols[achievementID] ?? "trophy"
    }

    // MARK: Naming

    /// "I"…"V" for 1...5; anything else falls back to the digits.
    static func roman(_ n: Int) -> String {
        switch n {
        case 1: return "I"
        case 2: return "II"
        case 3: return "III"
        case 4: return "IV"
        case 5: return "V"
        default: return String(n)
        }
    }

    /// "Heavies II" for a track level; the achievement's own title for a feat.
    static func displayTitle(for achievement: Achievement) -> String {
        guard let track = trackByAchievementID[achievement.id],
              let level = level(ofAchievementID: achievement.id) else { return achievement.title }
        return "\(track.name) \(roman(level))"
    }

    /// The track's `goalCopy(threshold)` for a level; the unit-aware summary
    /// for a feat.
    static func displaySummary(for achievement: Achievement, units: DisplayUnits) -> String {
        guard let track = trackByAchievementID[achievement.id] else {
            return achievement.summary(units: units)
        }
        return track.goalCopy(achievement.threshold)
    }
}

// MARK: - Per-track state

nonisolated struct TrophyTrackState: Sendable {
    let track: TrophyTrack
    /// 0 = none earned; N = levels earned, contiguous from the bottom.
    let level: Int
    let levelCount: Int
    /// Current value of the metric being chased (the next level's, or the
    /// top level's once maxed).
    let progress: Int
    /// Threshold of the next level; nil when maxed.
    let nextGoal: Int?
    let nextAchievement: Achievement?

    var isMaxed: Bool { nextGoal == nil }

    /// Progress toward `nextGoal` measured from 0, clamped 0...1; 1 when maxed.
    var fraction: Double {
        guard let goal = nextGoal, goal > 0 else { return 1 }
        return min(1, max(0, Double(progress) / Double(goal)))
    }

    var remaining: Int { max(0, (nextGoal ?? progress) - progress) }

    /// Pure function of the inputs + roster. Levels missing from `roster`
    /// (a custom test roster) are skipped; nil when none are present.
    static func make(track: TrophyTrack, inputs: TrophyProgressInputs, roster: [Achievement]) -> TrophyTrackState? {
        make(track: track, inputs: inputs,
             byID: Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    /// `make` against a prebuilt id index, so `all` builds it once.
    static func make(track: TrophyTrack, inputs: TrophyProgressInputs, byID: [String: Achievement]) -> TrophyTrackState? {
        let levels = track.levelIDs.compactMap { byID[$0] }
        guard !levels.isEmpty else { return nil }
        var earned = 0
        for ach in levels {
            if ach.isEarned(inputs: inputs) { earned += 1 } else { break }
        }
        let next = earned < levels.count ? levels[earned] : nil
        let metric = (next ?? levels[levels.count - 1]).currentProgress(inputs: inputs)
        return TrophyTrackState(
            track: track, level: earned, levelCount: levels.count,
            progress: metric, nextGoal: next?.threshold, nextAchievement: next)
    }

    /// States for every track the roster carries, in `TrophyTracks.all` order.
    static func all(inputs: TrophyProgressInputs, roster: [Achievement] = Trophies.roster) -> [TrophyTrackState] {
        let byID = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return TrophyTracks.all.compactMap { make(track: $0, inputs: inputs, byID: byID) }
    }
}

// MARK: - Chases

/// One of the (up to three) nearest goals.
nonisolated struct TrophyChase: Identifiable, Sendable {
    enum Kind: Sendable { case trackLevel, feat }
    let kind: Kind
    /// The achievement being chased (a track's next level, or the feat).
    let achievement: Achievement
    /// Set for `.trackLevel`.
    let track: TrophyTrack?
    /// 1-based level being chased, for `.trackLevel`.
    let level: Int?
    let progress: Int
    let goal: Int
    /// Short human line: a track's `remainingCopy`, or a feat's summary.
    let blurb: String

    var id: String { achievement.id }
    var remaining: Int { max(0, goal - progress) }
    var fraction: Double { goal > 0 ? min(1, max(0, Double(progress) / Double(goal))) : 1 }
}

nonisolated enum TrophyChases {
    /// Feats offered as the "different plane" pick, in order.
    static let differentPlaneFeats = ["heavymetal", "freighter", "bizjet", "turboprop",
                                      "firstrare", "epic", "legendary"]

    static func pick(inputs: TrophyProgressInputs, roster: [Achievement] = Trophies.roster) -> [TrophyChase] {
        let states = TrophyTrackState.all(inputs: inputs, roster: roster).filter { !$0.isMaxed }
        var chosenTracks = Set<String>()
        var chosenFeats = Set<String>()
        var result: [TrophyChase] = []

        /// Highest fraction wins; `max(by:)` keeps the FIRST of equals, which
        /// is `TrophyTracks.all` order.
        func best(_ candidates: [TrophyTrackState]) -> TrophyTrackState? {
            var winner: TrophyTrackState?
            for c in candidates where winner == nil || c.fraction > winner!.fraction { winner = c }
            return winner
        }
        func takeTrack(_ s: TrophyTrackState) {
            guard let next = s.nextAchievement, let goal = s.nextGoal else { return }
            chosenTracks.insert(s.track.id)
            result.append(TrophyChase(
                kind: .trackLevel, achievement: next, track: s.track, level: s.level + 1,
                progress: s.progress, goal: goal,
                blurb: s.track.remainingCopy(max(0, goal - s.progress))))
        }
        func nextFeat(from ids: [String]?) -> Achievement? {
            let feats = TrophyTracks.feats(roster: roster)
            let pool: [Achievement]
            if let ids {
                let byID = Dictionary(feats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                pool = ids.compactMap { byID[$0] }
            } else {
                pool = feats
            }
            return pool.first {
                !$0.secret && !chosenFeats.contains($0.id) && !$0.isEarned(inputs: inputs)
            }
        }
        func takeFeat(_ a: Achievement) {
            chosenFeats.insert(a.id)
            let goal = a.threshold
            result.append(TrophyChase(
                kind: .feat, achievement: a, track: nil, level: nil,
                progress: min(goal, a.currentProgress(inputs: inputs)), goal: goal,
                blurb: a.summary))
        }

        // 1. The nearest unmaxed track.
        if let s = best(states) { takeTrack(s) }

        // 2. A "different plane" pick.
        let variety = states.filter { $0.track.variety && !chosenTracks.contains($0.track.id) }
        if let s = best(variety.filter { $0.progress > 0 }) {
            takeTrack(s)
        } else if let f = nextFeat(from: differentPlaneFeats) {
            takeFeat(f)
        } else if let s = best(variety) {
            takeTrack(s)
        }

        // 3. Fill to three: the nearest remaining tracks, then unearned
        // feats (a player who has maxed most tracks still gets three).
        while result.count < 3 {
            if let s = best(states.filter({ !chosenTracks.contains($0.track.id) })) {
                takeTrack(s)
            } else if let f = nextFeat(from: nil) {
                takeFeat(f)
            } else {
                break
            }
        }
        return result
    }
}

// MARK: - Almost there

/// "Two to go": a track a catch just moved to within reach of its next
/// level. Shown as a card AFTER the reveal (never on it), once per level.
nonisolated struct TrophyNearMiss: Equatable, Sendable {
    let track: TrophyTrack
    /// 1-based level being chased (current level + 1).
    let level: Int
    let progress: Int
    let goal: Int
    let achievement: Achievement
    /// Next-level ids of the OTHER tracks this catch also left within reach.
    /// They are marked shown with this card, so the next catch doesn't
    /// bring up a second one for a neighbouring track.
    var alsoClose: [String] = []

    var remaining: Int { max(0, goal - progress) }

    /// "Airlines III": the track and the level being chased.
    var title: String { "\(track.name) \(TrophyTracks.roman(level))" }
    /// "2 new airlines to go".
    var remainingText: String { track.remainingCopy(remaining) }
    /// "Collect 30 airlines".
    var goalText: String { track.goalCopy(goal) }

    /// The ring: the track's segments, those below the chased level lit.
    var badgeSpec: TrophyBadgeSpec {
        TrophyBadgeSpec(symbol: track.symbol, segments: max(1, track.levelIDs.count),
                        filled: max(0, level - 1), earned: level > 1, masked: false)
    }

    static func == (a: TrophyNearMiss, b: TrophyNearMiss) -> Bool {
        a.achievement.id == b.achievement.id && a.progress == b.progress
    }

    /// At most this many short of the level counts as "almost there".
    static let maxRemaining = 2
    /// Levels with a smaller goal never get the card: on a goal of 3, the
    /// very first step would already be "2 to go".
    static let minGoal = 5
    /// Tracks that move on nearly every catch; they only surface when no
    /// other track qualifies.
    static let noisyTrackIDs: Set<String> = ["logbook", "points"]

    /// The track this catch (the step from `before` to `after`) moved to
    /// within `maxRemaining` of its next level, or nil. `excluding` holds
    /// the achievement ids whose card has already been shown.
    static func find(
        before: TrophyProgressInputs,
        after: TrophyProgressInputs,
        roster: [Achievement] = Trophies.roster,
        excluding shown: Set<String> = []
    ) -> TrophyNearMiss? {
        let beforeStates = Dictionary(
            TrophyTrackState.all(inputs: before, roster: roster).map { ($0.track.id, $0) },
            uniquingKeysWith: { a, _ in a })
        var close: [TrophyTrackState] = []
        for s in TrophyTrackState.all(inputs: after, roster: roster) where !s.isMaxed {
            guard let b = beforeStates[s.track.id], let goal = s.nextGoal, let next = s.nextAchievement else { continue }
            // Moved by this catch, without levelling up (a level-up gets the
            // unlock card instead).
            guard s.level == b.level, s.progress > b.progress else { continue }
            guard goal >= minGoal, (1...maxRemaining).contains(s.remaining) else { continue }
            guard !shown.contains(next.id) else { continue }
            close.append(s)
        }
        let quiet = close.filter { !noisyTrackIDs.contains($0.track.id) }
        var winner: TrophyTrackState?
        for s in quiet.isEmpty ? close : quiet {
            guard let w = winner else { winner = s; continue }
            if s.remaining < w.remaining || (s.remaining == w.remaining && s.track.variety && !w.track.variety) {
                winner = s
            }
        }
        guard let w = winner, let next = w.nextAchievement, let goal = w.nextGoal else { return nil }
        return TrophyNearMiss(track: w.track, level: w.level + 1, progress: w.progress,
                              goal: goal, achievement: next,
                              alsoClose: close.compactMap { $0.nextAchievement?.id }.filter { $0 != next.id })
    }
}

/// Which "almost there" cards have been shown, so each level gets one.
nonisolated struct TrophyNearStore {
    private let defaults: UserDefaults
    private static let key = "trophy.nearShown.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var shown: Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    func markShown(_ achievementIDs: [String]) {
        let ids = shown.union(achievementIDs)
        guard ids != shown else { return }
        defaults.set(ids.sorted(), forKey: Self.key)
    }
}
