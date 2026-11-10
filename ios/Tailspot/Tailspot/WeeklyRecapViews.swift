//
//  WeeklyRecapViews.swift
//  Tailspot
//
//  The screens for the weekly recap (data and rules: WeeklyRecap.swift):
//   - WeeklyRecapBanner: one slim row above the Hangar's segment switcher,
//     shown all week for the week before. Tap opens the recap; X hides it
//     until next Monday.
//   - WeeklyRecapScreen: the recap card plus "Share my week".
//   - WeeklyRecapShareImage: the 9:16 picture that goes to Messages or a
//     story, rendered offscreen with ImageRenderer at 1080 × 1920 px.
//
//  The share image ends with the tailspot.app address in the pixels (an
//  image re-posted without its text still leads back), and the share text
//  carries the "Weekly Recap" App Store campaign link so App Store Connect
//  counts the installs it brings. No QR code: the image is almost always
//  viewed on the phone that would have to scan it.
//

import SwiftUI
import SwiftData

// MARK: - Banner

struct WeeklyRecapBanner: View {
    let recap: WeeklyRecap
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Brand.Color.cyan.opacity(0.14))
                        Image(systemName: "calendar")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.Color.cyan)
                    }
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("YOUR WEEK · \(recap.rangeLabel())")
                            .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
                            .tracking(1)
                            .foregroundStyle(Brand.Color.textTertiary)
                        Text(recap.headline)
                            .font(Brand.Font.cardTitle)
                            .foregroundStyle(Brand.Color.textPrimary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.Color.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your week, \(recap.headline). \(recap.subline)")
            .accessibilityHint("Opens your weekly recap")
            .accessibilityAddTraits(.isButton)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide this week's recap")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.card))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - Shared pieces

/// Seven bars, Monday first, drawn to scale. A day with no catches keeps a
/// short dim stub so the week's shape still reads.
struct WeeklyRecapDayBars: View {
    let counts: [Int]
    var height: CGFloat = 56
    var labelFont: Font = Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2)

    var body: some View {
        let peak = max(counts.max() ?? 0, 1)
        let letters = WeeklyRecap.weekdayLetters()
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(counts.enumerated()), id: \.offset) { i, n in
                VStack(spacing: 6) {
                    // The day's count sits on its bar; empty days stay blank
                    // so the busy days read first.
                    Text(n > 0 ? "\(n)" : " ")
                        .font(labelFont)
                        .foregroundStyle(Brand.Color.textPrimary)
                        .padding(.bottom, -2)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(n > 0 ? Brand.Color.cyan : Brand.Color.textPrimary.opacity(0.12))
                        .frame(height: n > 0 ? max(6, height * CGFloat(n) / CGFloat(peak)) : 3)
                        .frame(height: height, alignment: .bottom)
                    Text(i < letters.count ? letters[i] : "")
                        .font(labelFont)
                        .foregroundStyle(n > 0 ? Brand.Color.textSecondary : Brand.Color.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(counts))
    }

    static func spoken(_ counts: [Int]) -> String {
        let days = Calendar(identifier: .gregorian).standaloneWeekdaySymbols
        let mondayFirst = days.count == 7 ? Array(days[1...]) + [days[0]] : []
        let parts = counts.enumerated().compactMap { i, n -> String? in
            guard n > 0, i < mondayFirst.count else { return nil }
            return "\(mondayFirst[i]) \(n)"
        }
        return parts.isEmpty ? "No catches" : "Catches by day: " + parts.joined(separator: ", ")
    }
}

/// What the recap shows about its standout catch.
struct WeeklyRecapStandout {
    let title: String      // "DLH455" (callsign, else registration, else hex)
    let model: String?     // "Airbus A350-900"
    let route: String?     // "SFO → MUC"
    let rarity: Rarity
    let photoURL: URL?
    let focus: CGPoint?

    /// "RAREST · EPIC", or "TOP CATCH · COMMON" when nothing beat common
    /// ("rarest" of all-common planes reads like a joke at the user).
    var eyebrow: String {
        "\(rarity == .common ? "TOP CATCH" : "RAREST") · \(rarity.label)"
    }

    init(_ c: Catch) {
        let trimmed = { (s: String?) -> String? in
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        title = trimmed(c.callsign) ?? trimmed(c.registration) ?? c.icao24.uppercased()
        model = AircraftNaming.canonical(
            typecode: c.typecode, manufacturer: c.manufacturer, model: c.model
        ).displayName
        switch (c.displayOrigin, c.displayDest) {
        case let (o?, d?): route = "\(o) → \(d)"
        case let (o?, nil): route = "From \(o)"
        case let (nil, d?): route = "To \(d)"
        default: route = nil
        }
        rarity = c.resolvedRarity
        // fileURL: no exists-check per body; a missing file renders the placeholder.
        photoURL = c.photoFilename.flatMap { CatchPhotoStore.fileURL(forFilename: $0) }
        focus = c.photoFocus
    }
}

/// The four small numbers under the bars.
struct WeeklyRecapStat: Identifiable {
    let label: String
    let value: String
    var id: String { label }

    /// `weeklyRank`: the final rank on last week's board (server, may be
    /// nil while loading / offline / unranked → "—").
    static func all(_ r: WeeklyRecap, weeklyRank: Int?) -> [WeeklyRecapStat] {
        [
            WeeklyRecapStat(label: "WEEKLY RANK", value: weeklyRank.map { "#\($0.formatted())" } ?? "—"),
            WeeklyRecapStat(label: "POINTS", value: r.points.formatted()),
            WeeklyRecapStat(label: "NEW TYPES", value: r.newTypes.formatted()),
            WeeklyRecapStat(
                label: "STREAK",
                // A lapsed streak shows a dash, not a "0 days" on a share image.
                value: r.currentStreak > 0 ? CountCopy.phrase(r.currentStreak, singular: "day") : "—"
            ),
        ]
    }
}

// MARK: - Recap card (in the app)

struct WeeklyRecapCard: View {
    let recap: WeeklyRecap
    var weeklyRank: Int? = nil

    var body: some View {
        let standout = recap.rarest.isDeleted ? nil : WeeklyRecapStandout(recap.rarest)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR WEEK · \(recap.rangeLabel())")
                    .font(Brand.Font.mono(size: 11, weight: .bold, relativeTo: .caption))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.cyan)
                Text(recap.headline)
                    .brandDisplayFont()
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(recap.subline)
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textSecondary)
            }

            WeeklyRecapDayBars(counts: recap.dayCounts)

            // Opens the catch's detail (WeeklyRecapScreen's stack). Skipped
            // if that catch was just deleted from its own detail: reading a
            // deleted SwiftData model crashes, and the Hangar recomputes the
            // recap on the next count change.
            if let standout {
                NavigationLink(value: recap.rarestRow) {
                    standoutRow(standout)
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(WeeklyRecapStat.all(recap, weeklyRank: weeklyRank)) { stat in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stat.label)
                            .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
                            .tracking(1)
                            .foregroundStyle(Brand.Color.textTertiary)
                        Text(stat.value)
                            .font(Brand.Font.mono(size: 17, weight: .bold, relativeTo: .headline))
                            .foregroundStyle(Brand.Color.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Brand.Color.bgSurface, in: .rect(cornerRadius: Brand.Radius.row))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(18)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.card))
    }

    private func standoutRow(_ s: WeeklyRecapStandout) -> some View {
        HStack(spacing: 12) {
            // Thumbnail-size decode off the main actor; RevealPhoto would
            // decode the full camera still for a 64 pt square.
            FocusThumbnail(url: s.photoURL, focus: s.focus, side: 64)
                .clipShape(.rect(cornerRadius: Brand.Radius.row))
            VStack(alignment: .leading, spacing: 3) {
                Text(s.eyebrow)
                    .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
                    .tracking(1)
                    .foregroundStyle(s.rarity.textTint)
                Text(s.title)
                    .font(Brand.Font.mono(size: 15, weight: .bold, relativeTo: .subheadline))
                    .foregroundStyle(Brand.Color.cyan)
                if let model = s.model {
                    Text(model)
                        .font(Brand.Font.body)
                        .foregroundStyle(Brand.Color.textPrimary)
                        .lineLimit(2)
                }
                if let route = s.route {
                    Text(route)
                        .font(Brand.Font.mono(size: 12, weight: .semibold, relativeTo: .caption))
                        .foregroundStyle(Brand.Color.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.Color.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .contentShape(.rect)
        .background(Brand.Color.bgSurface, in: .rect(cornerRadius: Brand.Radius.row))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.row)
                .strokeBorder(s.rarity.tint.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this catch")
    }
}

// MARK: - Recap screen (sheet)

struct WeeklyRecapScreen: View {
    let recap: WeeklyRecap
    @Environment(\.dismiss) private var dismiss
    @State private var shareItems: ShareItems?
    @State private var rendering = false
    /// Last week's final rank, from the server (WeeklyRecapRank). Seeded from
    /// the on-device cache so a reopen shows it at once, offline included.
    @State private var weeklyRank: Int?

    init(recap: WeeklyRecap, weeklyRank: Int? = nil) {
        self.recap = recap
        _weeklyRank = State(initialValue: weeklyRank ?? WeeklyRecapRank.cached(weekStart: recap.weekStartKey))
    }

    private struct ShareItems: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    var body: some View {
        // Its own stack so the standout catch can push its detail inside
        // the sheet (the Hangar's stack sits under the sheet).
        NavigationStack {
            content
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: HangarRow.self) { row in
                    CatchDetailView(row: row)
                }
        }
        .task {
            if let rank = await WeeklyRecapRank.fetch(weekStart: recap.weekStartKey) {
                weeklyRank = rank
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                ChromeButton(.close, accessibilityLabel: "Close recap") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            ScrollView {
                VStack(spacing: 16) {
                    WeeklyRecapCard(recap: recap, weeklyRank: weeklyRank)
                    Button(action: share) {
                        HStack(spacing: 8) {
                            if rendering {
                                ProgressView().tint(Brand.Color.bgPrimary)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                            Text("Share my week")
                        }
                        .font(Brand.Font.button)
                        .foregroundStyle(Brand.Color.bgPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Brand.Color.cyan, in: .rect(cornerRadius: Brand.Radius.row))
                    }
                    .buttonStyle(.plain)
                    .disabled(rendering)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
        }
        .background(Brand.Color.bgPrimary)
        .sheet(item: $shareItems) { share in
            ActivityShareSheet(items: share.items) { method in
                if let method {
                    WeeklyRecapTelemetry.fire(
                        WeeklyRecapTelemetry.sharedEvent, recap, extra: ["method": .string(method)]
                    )
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func share() {
        rendering = true
        // Let the spinner draw before the synchronous 3× render.
        Task {
            await Task.yield()
            var items: [Any] = []
            if let image = WeeklyRecapShareImage.render(recap, weeklyRank: weeklyRank) { items.append(image) }
            items.append(WeeklyRecapShareImage.message(recap))
            rendering = false
            shareItems = ShareItems(items: items)
        }
    }
}

// MARK: - Share image (9:16)

struct WeeklyRecapShareImage: View {
    let recap: WeeklyRecap
    var weeklyRank: Int? = nil
    /// Points; rendered at scale 3 → 1080 × 1920 px.
    static let canvas = CGSize(width: 360, height: 640)

    static var storeURL: URL { AppStoreListing.url(campaign: WeeklyRecapTelemetry.campaign) }

    /// Text that rides with the image. The link sits mid-sentence for the
    /// same reason as the catch share (CatchShare.shareMessage): Messages
    /// keeps it a plain link instead of a big preview bubble.
    static func message(_ r: WeeklyRecap) -> String {
        "My week on Tailspot: \(r.headline) — get the app at \(storeURL.absoluteString) and start spotting."
    }

    @MainActor
    static func render(_ r: WeeklyRecap, weeklyRank: Int? = nil) -> UIImage? {
        guard !r.rarest.isDeleted else { return nil } // see WeeklyRecapCard
        let renderer = ImageRenderer(
            content: WeeklyRecapShareImage(recap: r, weeklyRank: weeklyRank)
                .frame(width: canvas.width, height: canvas.height)
                .environment(\.replayMaskingDisabled, true)
                .environment(\.dynamicTypeSize, .large)
        )
        renderer.scale = 3
        return renderer.uiImage
    }

    var body: some View {
        let s = WeeklyRecapStandout(recap.rarest)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HangarGlyph(lineWidth: 1.6, tint: Brand.Color.cyan)
                    .frame(width: 16, height: 16)
                Text("TAILSPOT")
                    .font(Brand.Font.mono(fixedSize: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Brand.Color.textPrimary)
                Spacer()
                Text(recap.rangeLabel())
                    .font(Brand.Font.mono(fixedSize: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Brand.Color.textTertiary)
            }

            Text("I caught \(CountCopy.phrase(recap.catchCount, singular: "plane")) this week")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Brand.Color.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.top, 22)
            Text(recap.sharedSubline)
                .font(.system(size: 14))
                .foregroundStyle(Brand.Color.textSecondary)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 0) {
                RevealPhoto(url: s.photoURL, focus: s.focus)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.eyebrow)
                        .font(Brand.Font.mono(fixedSize: 10, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(s.rarity.textTint)
                    Text(s.title)
                        .font(Brand.Font.mono(fixedSize: 18, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                    if let model = s.model {
                        Text(model)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.Color.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    if let route = s.route {
                        Text(route)
                            .font(Brand.Font.mono(fixedSize: 11, weight: .bold))
                            .foregroundStyle(Brand.Color.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .background(Brand.Color.bgSurface)
            .clipShape(.rect(cornerRadius: Brand.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.card)
                    .strokeBorder(s.rarity.tint.opacity(0.6), lineWidth: 1.5)
            )
            .padding(.top, 20)

            WeeklyRecapDayBars(
                counts: recap.dayCounts,
                height: 54,
                labelFont: Brand.Font.mono(fixedSize: 10, weight: .bold)
            )
            .padding(.top, 22)

            HStack(spacing: 0) {
                ForEach(WeeklyRecapStat.all(recap, weeklyRank: weeklyRank)) { stat in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stat.label)
                            .font(Brand.Font.mono(fixedSize: 8, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Brand.Color.textTertiary)
                        Text(stat.value)
                            .font(Brand.Font.mono(fixedSize: 13, weight: .bold))
                            .foregroundStyle(Brand.Color.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 20)

            Spacer(minLength: 12)

            Text(CatchShare.footerLead + CatchShare.footerURL)
                .font(Brand.Font.mono(fixedSize: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.cyan)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .background(
            LinearGradient(colors: [Brand.Color.bgElevated, Brand.Color.bgPrimary, Brand.Color.bgSurface],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}
