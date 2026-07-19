//
//  SetsScreen.swift
//  Tailspot
//
//  The Sets collection, organized by make/model FAMILY (Boeing 737,
//  Airbus A320, …). Three levels:
//
//    1. SetsBrowser     — every family, with % complete (ring + X of N).
//    2. SetDetailScreen — one family → a LIST of its models, each showing
//                         how many you've caught + the most recent catch.
//    3. ModelDetailScreen — one model → CARDS of each tail you've caught,
//                         showing when and where, tapping into the full
//                         CatchDetailView.
//
//  `SetsBrowser` is the reusable body (it relies on an ambient
//  NavigationStack); `SetsScreen` adds the title for the Profile entry,
//  and the Hangar's Sets segment renders `SetsBrowser` directly.
//
//  Back navigation: the pushed screens use HangarChildBar + `.toolbar(.hidden)`
//  ONLY (never `.navigationBarBackButtonHidden(true)`, which would disable the
//  swipe-from-left-edge pop). So both the chevron and the edge swipe work.
//

import SwiftUI
import SwiftData

// MARK: - Browser

struct SetsBrowser: View {
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    /// Memoizes the scored list across body evals — Hangar segment switches
    /// re-eval this kept-alive page every time. See HangarDerivedCache.
    @State private var cache = DerivedCacheBox<[(set: CardSet, progress: (caught: Int, total: Int))]>()

    // Each set's progress is computed ONCE per DATA change (fingerprint-keyed
    // cache, not per body eval), then sorted by % complete — closest-to-done
    // first, so the sets you're most likely to finish bubble to the top. The
    // previous version sorted with a comparator that recomputed progress for
    // both sides of every comparison (~10× the work).
    private var scored: [(set: CardSet, progress: (caught: Int, total: Int))] {
        cache.value(for: CatchFingerprint.of(catches)) { computeScored() }
    }

    private func computeScored() -> [(set: CardSet, progress: (caught: Int, total: Int))] {
        // Derive per-catch match keys once and share them across all ~30
        // families — the [Catch] overload would rebuild them per family.
        let keys = CardSets.matchKeys(for: catches)
        return CardSets.families
            .map { (set: $0, progress: CardSets.progress(of: $0, againstKeys: keys)) }
            .sorted { a, b in
                let fa = a.progress.total == 0 ? 0 : Double(a.progress.caught) / Double(a.progress.total)
                let fb = b.progress.total == 0 ? 0 : Double(b.progress.caught) / Double(b.progress.total)
                return fa != fb ? fa > fb : a.set.title < b.set.title
            }
    }

    // ScrollView + LazyVStack (not a List) so the top spacing matches the
    // Recent feed exactly and the kept-alive segment stays lightweight —
    // an inset-grouped List is UICollectionView-backed and adds its own
    // section inset before the first row.
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(scored, id: \.set.id) { item in
                    NavigationLink(value: item.set) {
                        SetCompletionCard(set: item.set, progress: item.progress)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("setCard")   // SetsNavigationUITests
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Brand.Color.bgPrimary)
        .navigationDestination(for: CardSet.self) { SetDetailScreen(set: $0) }
    }
}

/// Profile entry point.
struct SetsScreen: View {
    var body: some View {
        SetsBrowser()
            .navigationTitle("Sets")
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Completion card (browser row)

private struct SetCompletionCard: View {
    let set: CardSet
    let progress: (caught: Int, total: Int)

    var body: some View {
        let frac = progress.total == 0 ? 0 : Double(progress.caught) / Double(progress.total)
        let complete = progress.total > 0 && progress.caught == progress.total
        return HStack(spacing: 14) {
            CompletionRing(progress: frac, tint: Brand.Color.cyan, lineWidth: 5)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(set.title)
                        .font(Brand.Font.cardTitle)
                        .foregroundStyle(Brand.Color.textPrimary)
                        .lineLimit(1)
                    if complete {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.Color.alertNormal)
                            .accessibilityHidden(true)
                    }
                }
                Text("\(progress.caught) of \(progress.total) variants")
                    .font(Brand.Font.mono(size: 11, weight: .semibold, relativeTo: .caption2))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.Color.textTertiary.opacity(0.6))
                .accessibilityHidden(true)
        }
        // Same card chrome as TailCard so the Sets browser and the Recent
        // feed read as one design language.
        .padding(12)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.card)
                .strokeBorder(Brand.Color.textPrimary.opacity(0.06), lineWidth: 1)
        )
        // One sentence per card — otherwise the ring percentage, title,
        // count, and the raw symbol names read as five fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(set.title), \(progress.caught) of \(progress.total) variants, \(Int((frac * 100).rounded())) percent complete\(complete ? ", complete" : "")"
        )
    }
}

// MARK: - Set detail (a family → list of its models)

struct SetDetailScreen: View {
    let set: CardSet
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

    var body: some View {
        VStack(spacing: 0) {
            HangarChildBar(title: set.title)
            List {
                Section {
                    header
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(set.entries) { entry in
                        let matching = catches.filter { CardSets.matches(catch: $0, entry: entry) }
                        let tailCount = Set(matching.map(\.icao24)).count
                        let mostRecent = matching.map(\.caughtAt).max()
                        NavigationLink {
                            ModelDetailScreen(entry: entry)
                        } label: {
                            modelRow(entry: entry, tailCount: tailCount, mostRecent: mostRecent)
                        }
                        .listRowBackground(Brand.Color.bgElevated)
                    }
                } header: {
                    Text("MODELS")
                        .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
                        .tracking(1.2)
                        .foregroundStyle(Brand.Color.textTertiary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.Color.bgPrimary)
        }
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackEnabled()
    }

    private var header: some View {
        let p = CardSets.progress(of: set, against: catches)
        let frac = p.total == 0 ? 0 : Double(p.caught) / Double(p.total)
        let complete = p.total > 0 && p.caught == p.total
        return HStack(spacing: 16) {
            CompletionRing(progress: frac, tint: Brand.Color.cyan, lineWidth: 7)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(p.caught) of \(p.total) collected")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(complete ? "Set complete" : "Catch \(p.total - p.caught) more to finish.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(complete ? Brand.Color.alertNormal : Brand.Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func modelRow(entry: CardSetEntry, tailCount: Int, mostRecent: Date?) -> some View {
        let caught = tailCount > 0
        return HStack(spacing: 12) {
            Circle()
                .fill(caught ? Brand.Color.cyan : Brand.Color.textTertiary.opacity(0.3))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.canonicalName)
                        // .callout == 16 pt at the default setting, but
                        // scales with Dynamic Type (a bare size: 16 doesn't).
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(caught ? Brand.Color.textPrimary : Brand.Color.textTertiary)
                        .lineLimit(1)
                        // The sparkle below is hidden from VoiceOver (it
                        // reads as the junk word "sparkles"), so the rarity
                        // it signals rides on the name instead.
                        .accessibilityLabel(entry.rarity.isNotable
                            ? "\(entry.canonicalName), rare"
                            : entry.canonicalName)
                    if entry.rarity.isNotable {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(entry.rarity.tint)
                            .accessibilityHidden(true)
                    }
                }
                if caught, let mostRecent {
                    Text("Caught \(mostRecent.formatted(.relative(presentation: .named)))")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                } else {
                    Text("Not caught yet")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if caught {
                Text("\(tailCount)")
                    .font(Brand.Font.mono(size: 16, weight: .heavy))
                    .foregroundStyle(Brand.Color.cyan)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
    }
}

// MARK: - Model detail (a model → cards of every tail caught)

struct ModelDetailScreen: View {
    let entry: CardSetEntry
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

    private var rows: [HangarRow] {
        let matching = catches.filter { CardSets.matches(catch: $0, entry: entry) }
        return HangarGrouping.group(matching, by: .recent).first?.rows ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HangarChildBar(title: entry.canonicalName)
            ScrollView {
                if rows.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(rows) { row in
                            NavigationLink {
                                CatchDetailView(row: row)
                            } label: {
                                TailCard(row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
        }
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackEnabled()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "binoculars")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Brand.Color.textTertiary)
            Text("No \(entry.canonicalName) yet")
                .brandDisplayFont()
                .foregroundStyle(Brand.Color.textPrimary)
            Text("Point, lock, and capture one to add it to your collection.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 80)
    }
}

// TailCard + SlotPlaceholder moved to TailCardView.swift so the Recent
// feed and the model-detail screen render the identical clean card.

private extension Rarity {
    /// Rare and above — the tiers worth flagging with a small indicator.
    var isNotable: Bool { ordinal >= Rarity.rare.ordinal }
}

// MARK: - Reusable progress views

/// Circular completion ring with a centered percentage.
struct CompletionRing: View {
    let progress: Double          // 0…1
    var tint: Color = Brand.Color.cyan
    var lineWidth: CGFloat = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Brand.Color.textTertiary.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(1, progress)))
                .stroke(tint, style: .init(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((progress * 100).rounded()))%")
                .font(Brand.Font.mono(size: lineWidth >= 8 ? 18 : 13, weight: .heavy))
                .foregroundStyle(Brand.Color.textPrimary)
                .monospacedDigit()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: progress)
    }
}

#Preview {
    NavigationStack { SetsScreen() }
        .modelContainer(for: Catch.self, inMemory: true)
}
