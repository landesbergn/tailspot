//
//  ChallengeViews.swift
//  Tailspot
//
//  The small shared vocabulary of the Challenges screens: the glass tint
//  and backdrop (borrowed from Profile so the hub reads as the same family),
//  the placement disc, the rarity chip, the live countdown, section labels,
//  and `ChallengeCopy` — every human-readable string the hub, join sheet and
//  detail derive from a challenge, kept pure so the tests can pin them.
//
//  Explain-as-we-go: `TimelineView(.periodic(from:by:))` re-evaluates its
//  content on a schedule without a Timer or a @State tick — the closure
//  receives the current date, so a countdown re-renders once a minute and
//  nothing else on the screen invalidates. The leaderboard's reset line is
//  recomputed per render for the same reason; this one just adds the tick.
//

import SwiftUI

// MARK: - Shared style

enum ChallengeStyle {
    /// Liquid Glass anchored to the brand's elevated dark tone — the
    /// ProfileScreen tint, so the hub and Profile are one surface family.
    static let glass: Glass = .regular.tint(Brand.Color.bgElevated.opacity(0.88))

    static func placementTint(_ placement: Int) -> Color {
        switch placement {
        case 1: return Brand.Color.podiumGold
        case 2: return Brand.Color.podiumSilver
        case 3: return Brand.Color.podiumBronze
        default: return Brand.Color.textTertiary
        }
    }

    static func rarityTint(_ raw: String) -> Color {
        Rarity(rawValue: raw)?.tint ?? Brand.Color.textTertiary
    }

    static func rarityLabel(_ raw: String) -> String {
        Rarity(rawValue: raw)?.label ?? raw.uppercased()
    }
}

/// Two faint radial glows under the glass, same as ProfileScreen's backdrop —
/// glass over a flat colour has nothing to refract and reads matte.
struct ChallengeBackdrop: View {
    var body: some View {
        ZStack {
            Brand.Color.bgPrimary
            RadialGradient(colors: [Brand.Color.cyan.opacity(0.10), .clear],
                           center: .init(x: 0.85, y: 0.05), startRadius: 10, endRadius: 420)
            RadialGradient(colors: [Brand.Color.alertAdvisory.opacity(0.05), .clear],
                           center: .init(x: 0.1, y: 0.75), startRadius: 10, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

/// Mono ALL-CAPS section header — the app-wide style.
struct ChallengeSectionLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
            .tracking(1.2)
            .foregroundStyle(Brand.Color.textTertiary)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The placement disc: ordinal text on a tinted circle. Text is always
/// present, so placement is never colour-only (spec §8).
struct PlacementDisc: View {
    let placement: Int
    var isTie: Bool = false
    var size: CGFloat = 34

    var body: some View {
        let tint = ChallengeStyle.placementTint(placement)
        ZStack {
            Circle().fill(tint.opacity(0.16))
            Circle().strokeBorder(tint.opacity(0.5), lineWidth: 1)
            Text(ChallengeTiming.placementLabel(placement: placement, isTie: isTie))
                .font(Brand.Font.mono(size: size * 0.32, weight: .bold, relativeTo: .caption))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "3 RARE" chip in the tier's tint — the standings row's rarity breakdown.
struct RarityChip: View {
    let tier: String
    let count: Int

    var body: some View {
        let tint = ChallengeStyle.rarityTint(tier)
        HStack(spacing: 4) {
            Text("\(count)")
                .font(Brand.Font.mono(size: 11, weight: .bold, relativeTo: .caption2))
                .monospacedDigit()
            Text(ChallengeStyle.rarityLabel(tier))
                .font(Brand.Font.mono(size: 9, weight: .semibold, relativeTo: .caption2))
                .tracking(0.8)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(ChallengeStyle.rarityLabel(tier).lowercased())")
    }
}

/// The live countdown ("48M LEFT"), ticking once a minute. `now` is the
/// injected clock for snapshots; when nil the timeline's own date is used.
struct ChallengeCountdown: View {
    let endsAt: Date
    var now: (() -> Date)? = nil
    var color: Color = Brand.Color.textSecondary

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(ChallengeTiming.timeRemainingCopy(until: endsAt, now: now?() ?? context.date))
                .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
                .tracking(1.1)
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }
}

// MARK: - Copy

/// Every derived string on the Challenges screens, pure and clock-injected
/// so the tests pin them and the screens stay declarative.
nonisolated enum ChallengeCopy {

    static func spotters(_ n: Int) -> String {
        CountCopy.phrase(n, singular: "spotter", plural: "spotters")
    }

    static func durationLabel(_ preset: String) -> String {
        switch preset {
        case "1h": return "1 hour"
        case "24h": return "24 hours"
        case "3d": return "3 days"
        case "7d": return "7 days"
        default: return preset
        }
    }

    static func durationShort(_ preset: String) -> String {
        preset.uppercased()
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar))
    }

    private static func dayAndTime(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar).weekday(.abbreviated).hour().minute())
    }

    private static func monthDayTime(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar).month(.abbreviated).day().hour().minute())
    }

    /// "today at 6:00 PM" / "tomorrow at 9:00 AM" / "Sat 9:00 AM" /
    /// "Sep 22, 9:00 AM" (more than six days out or in the past week+).
    static func relativeMoment(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time(date, calendar: calendar))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time(date, calendar: calendar))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time(date, calendar: calendar))"
        }
        let days = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                               to: calendar.startOfDay(for: date)).day ?? 0)
        return days < 7 ? dayAndTime(date, calendar: calendar) : monthDayTime(date, calendar: calendar)
    }

    static func endsLine(endsAt: Date, now: Date, calendar: Calendar = .current) -> String {
        "ends \(relativeMoment(endsAt, now: now, calendar: calendar))"
    }

    static func startsLine(startsAt: Date, now: Date, calendar: Calendar = .current) -> String {
        "starts \(relativeMoment(startsAt, now: now, calendar: calendar))"
    }

    /// "Sat 9:00 AM – Sun 9:00 AM", the join sheet's window line.
    static func windowLine(startsAt: Date, endsAt: Date, calendar: Calendar = .current) -> String {
        "\(dayAndTime(startsAt, calendar: calendar)) – \(dayAndTime(endsAt, calendar: calendar))"
    }

    /// Short date for history rows: "Aug 18".
    static func shortDate(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar).month(.abbreviated).day())
    }

    /// The history row's one-word-ish outcome. A tie at the top reads
    /// "Won" here — the list row carries only my placement, not who shared
    /// it; the detail shows "T-1st".
    static func historyLabel(_ s: ChallengeSummary) -> String {
        if s.status == .cancelled { return "Cancelled" }
        if s.isNoContest { return "No contest" }
        guard let mine = s.myResult else { return "Finished" }
        if mine.placement == 1 { return "Won" }
        return ChallengeTiming.placementOf(placement: mine.placement, participants: s.participantCount)
    }

    /// The results verdict (spec §4.5). `nil` me → "Finished".
    static func verdict(_ d: ChallengeDetail) -> String {
        if d.challenge.status == .cancelled { return "Cancelled" }
        if d.challenge.isNoContest { return "No contest" }
        guard let me = d.me else { return "Finished" }
        let mine = d.standings.first { $0.isMe == true }
        let tiedAtMine = d.standings.filter { $0.placement == me.placement }.count > 1
        if me.placement == 1 {
            if tiedAtMine { return "You tied for 1st" }
            let runnerUp = d.standings.filter { $0.isMe != true }.map(\.points).max() ?? 0
            let margin = (mine?.points ?? me.points) - runnerUp
            return "You won by \(margin.formatted(.number)) \(margin == 1 ? "point" : "points")"
        }
        let field = max(d.standings.count, d.challenge.participantCount)
        let label = ChallengeTiming.placementOf(placement: me.placement, participants: field)
        return tiedAtMine ? "Tied \(label)" : label
    }

    /// Whether my placement is shared with someone else.
    static func isTie(_ d: ChallengeDetail) -> Bool {
        guard let me = d.me else { return false }
        return d.standings.filter { $0.placement == me.placement }.count > 1
    }

    /// Prefilled create-sheet name: "Weekend Flyoff" on Fri–Sun, otherwise
    /// "Tuesday Flyoff".
    static func suggestedName(for date: Date, calendar: Calendar = .current) -> String {
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        if weekday == 1 || weekday == 6 || weekday == 7 { return "Weekend Flyoff" }
        let name = calendar.weekdaySymbols[weekday - 1]
        return "\(name) Flyoff"
    }

    /// The share-sheet message beside the link.
    static func shareMessage(name: String, preset: String, startsAt: Date, now: Date,
                             calendar: Calendar = .current) -> String {
        let when = startsAt <= now ? "starting now" : "starting \(relativeMoment(startsAt, now: now, calendar: calendar))"
        return "Race me on Tailspot — \(name), \(durationLabel(preset)) \(when)."
    }

    /// The join sheet's rule card.
    static func ruleCard(startsAt: Date, endsAt: Date, calendar: Calendar = .current) -> String {
        "Everything you catch between \(dayAndTime(startsAt, calendar: calendar)) and \(dayAndTime(endsAt, calendar: calendar)) counts, including planes you already caught since it started. Standard Tailspot points. Only your handle, points and catch models are shared."
    }

    /// Plain sentences for every error a screen can show.
    static func message(for error: ChallengesError) -> String {
        switch error {
        case .unauthorized: return "Tailspot couldn't sign this phone in. Try again in a moment."
        case .notFound: return "That challenge doesn't exist, or the link is wrong."
        case .full: return "This challenge is full (10 of 10)."
        case .closed: return "This challenge has already ended."
        case .handleRequired: return "Claim a handle first."
        case .invalid(let msg): return msg.prefix(1).uppercased() + msg.dropFirst() + "."
        case .conflict(let msg): return msg.prefix(1).uppercased() + msg.dropFirst() + "."
        case .rateLimited: return "Too many tries. Give it a minute."
        case .unavailable: return "Challenges aren't available right now."
        case .network: return "No connection. Check your internet and try again."
        case .decoding: return "Tailspot got a reply it didn't understand. Try again."
        }
    }
}
