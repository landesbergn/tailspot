//
//  SetsScreen.swift
//  Tailspot
//
//  The Sets collection browser. A set is a complete-able category: you
//  can see how many models exist in it and how many you've caught, as a
//  percentage. Two lenses over the same collection:
//
//    • By Type   — broad category (Narrow-body, Wide-body, …)  → CardSets.all
//    • By Family — airframe lineage (Boeing 737, Airbus A320, …) → CardSets.families
//
//  Drilling into a set shows a checklist grid: every model in the set,
//  caught ones in full color, locked ones as dimmed silhouettes that
//  still name the target (so you know what to hunt). A circular ring
//  carries the "% complete" collection feel throughout.
//
//  `SetsBrowser` is the reusable body (it relies on an ambient
//  NavigationStack); `SetsScreen` wraps it in one for the Profile entry,
//  and the Hangar's Sets segment renders `SetsBrowser` directly.
//

import SwiftUI
import SwiftData

// MARK: - Browser

struct SetsBrowser: View {
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    @State private var lens: SetLens = .type

    private var sets: [CardSet] { CardSets.sets(for: lens) }

    /// Aggregate completion across the visible lens.
    private var totals: (caught: Int, total: Int) {
        sets.reduce(into: (0, 0)) { acc, set in
            let p = CardSets.progress(of: set, against: catches)
            acc.0 += p.caught; acc.1 += p.total
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Lens", selection: $lens.animation(.easeInOut(duration: 0.2))) {
                ForEach(SetLens.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Brand.Color.bgPrimary)

            List {
                Section {
                    overallHero
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(sets) { set in
                        NavigationLink(value: set) {
                            SetCompletionCard(set: set, lens: lens, catches: catches)
                        }
                        .listRowBackground(Brand.Color.bgElevated)
                    }
                } header: {
                    Text(lens == .type ? "Categories" : "Families")
                        .font(Brand.Font.mono(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Brand.Color.textTertiary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.Color.bgPrimary)
        }
        .background(Brand.Color.bgPrimary)
        .navigationDestination(for: CardSet.self) { SetDetailScreen(set: $0) }
    }

    private var overallHero: some View {
        let t = totals
        let frac = t.total == 0 ? 0 : Double(t.caught) / Double(t.total)
        return HStack(spacing: 18) {
            CompletionRing(progress: frac, tint: Brand.Color.cyan, lineWidth: 7)
                .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text("COLLECTION")
                    .font(Brand.Font.mono(size: 10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Brand.Color.cyan)
                Text("\(t.caught) of \(t.total) collected")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text("across \(sets.count) \(lens == .type ? "categories" : "families")")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

/// Profile entry point — owns its NavigationStack via the caller.
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
    let lens: SetLens
    let catches: [Catch]

    var body: some View {
        let p = CardSets.progress(of: set, against: catches)
        let frac = p.total == 0 ? 0 : Double(p.caught) / Double(p.total)
        let complete = p.total > 0 && p.caught == p.total
        return HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(set.type.tint.opacity(0.18))
                Text(set.type.glyph)
                    .font(Brand.Font.mono(size: 17, weight: .bold))
                    .foregroundStyle(set.type.tint)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(set.title)
                        .font(Brand.Font.cardTitle)
                        .foregroundStyle(Brand.Color.textPrimary)
                        .lineLimit(1)
                    if complete {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.Color.alertNormal)
                    }
                }
                ProgressBar(fraction: frac, tint: set.type.tint)
                    .frame(height: 5)
                Text("\(p.caught) of \(p.total) \(lens == .type ? "models" : "variants")")
                    .font(Brand.Font.mono(size: 10, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            Text("\(Int((frac * 100).rounded()))%")
                .font(Brand.Font.mono(size: 13, weight: .heavy))
                .foregroundStyle(complete ? Brand.Color.alertNormal : set.type.tint)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Detail

struct SetDetailScreen: View {
    let set: CardSet
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    @State private var inspected: CardSetEntry?

    private var slotStatus: [(CardSetEntry, CardSets.SlotStatus)] {
        CardSets.status(of: set, against: catches)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(slotStatus.enumerated()), id: \.element.0.id) { idx, pair in
                        let isCaught = pair.1 != .locked
                        SlotChecklistTile(index: idx + 1, entry: pair.0, isCaught: isCaught)
                            .onTapGesture { inspected = pair.0 }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .padding(.top, 8)
        }
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .navigationTitle(set.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $inspected) { entry in
            SlotDetailSheet(
                entry: entry,
                isCaught: slotStatus.first { $0.0.id == entry.id }?.1 != .locked,
                matchingCatches: catches.filter { CardSets.matches(catch: $0, entry: entry) }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        let p = CardSets.progress(of: set, against: catches)
        let frac = p.total == 0 ? 0 : Double(p.caught) / Double(p.total)
        let complete = p.total > 0 && p.caught == p.total
        return HStack(spacing: 18) {
            CompletionRing(progress: frac, tint: set.type.tint, lineWidth: 8)
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                TypeBadge(type: set.type, size: .sm)
                Text("\(p.caught) of \(p.total) collected")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Brand.Color.textPrimary)
                if complete {
                    Label("Set complete", systemImage: "checkmark.seal.fill")
                        .font(Brand.Font.mono(size: 11, weight: .bold))
                        .foregroundStyle(Brand.Color.alertNormal)
                } else {
                    Text("Catch \(p.total - p.caught) more to finish the set.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 16)
    }
}

// MARK: - Checklist tile

private struct SlotChecklistTile: View {
    let index: Int
    let entry: CardSetEntry
    let isCaught: Bool

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isCaught ? entry.rarity.tint.opacity(0.15) : Brand.Color.bgElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                isCaught ? entry.rarity.tint : Brand.Color.textTertiary.opacity(0.22),
                                style: .init(lineWidth: 1, dash: isCaught ? [] : [4, 4])
                            )
                    )
                Image(systemName: "airplane")
                    .font(.system(size: 34, weight: isCaught ? .regular : .ultraLight))
                    .foregroundStyle(isCaught ? entry.rarity.tint : Brand.Color.textTertiary.opacity(0.4))
                    .rotationEffect(.degrees(-45))
                VStack {
                    HStack {
                        Text(String(format: "#%02d", index))
                            .font(Brand.Font.mono(size: 9, weight: .bold))
                            .foregroundStyle(Brand.Color.textTertiary)
                        Spacer()
                        Image(systemName: isCaught ? "checkmark.circle.fill" : "lock.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(isCaught ? Brand.Color.alertNormal
                                                      : Brand.Color.textTertiary.opacity(0.5))
                    }
                    Spacer()
                }
                .padding(9)
            }
            .aspectRatio(1.25, contentMode: .fit)

            VStack(spacing: 3) {
                // Name shown even when locked — the set is a checklist of
                // targets, so you should know what you're hunting.
                Text(entry.canonicalName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCaught ? Brand.Color.textPrimary : Brand.Color.textTertiary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                RarityBadge(rarity: entry.rarity, size: .sm)
                    .opacity(isCaught ? 1 : 0.5)
            }
        }
        .contentShape(.rect)
    }
}

// MARK: - Slot detail sheet

private struct SlotDetailSheet: View {
    let entry: CardSetEntry
    let isCaught: Bool
    let matchingCatches: [Catch]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(entry.rarity.tint.opacity(0.16))
                    Image(systemName: "airplane")
                        .font(.system(size: 22))
                        .foregroundStyle(entry.rarity.tint)
                        .rotationEffect(.degrees(-45))
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.canonicalName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    RarityBadge(rarity: entry.rarity, size: .sm)
                }
                Spacer()
                if isCaught {
                    Label("Caught", systemImage: "checkmark.circle.fill")
                        .font(Brand.Font.mono(size: 12, weight: .bold))
                        .foregroundStyle(Brand.Color.alertNormal)
                }
            }

            Text(entry.summary)
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)

            Divider().overlay(Brand.Color.textTertiary.opacity(0.2))

            if isCaught {
                Text("\(matchingCatches.count) in your hangar")
                    .font(Brand.Font.mono(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Brand.Color.textTertiary)
                ForEach(matchingCatches.prefix(3)) { c in
                    HStack(spacing: 8) {
                        Image(systemName: "airplane.circle.fill")
                            .foregroundStyle(entry.rarity.tint)
                        Text(c.callsign ?? c.icao24.uppercased())
                            .font(Brand.Font.mono(size: 13, weight: .bold))
                            .foregroundStyle(Brand.Color.textPrimary)
                        Spacer()
                        if let op = c.operatorName {
                            Text(op).font(Brand.Font.caption)
                                .foregroundStyle(Brand.Color.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                Label("Not yet caught — point, lock, and capture one to fill this slot.",
                      systemImage: "scope")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
    }
}

// MARK: - Reusable progress views

/// Circular completion ring with a centered percentage.
struct CompletionRing: View {
    let progress: Double          // 0…1
    var tint: Color = Brand.Color.cyan
    var lineWidth: CGFloat = 7

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
        .animation(.easeInOut(duration: 0.3), value: progress)
    }
}

/// Slim horizontal completion bar.
private struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.Color.textTertiary.opacity(0.18))
                Capsule().fill(tint)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
    }
}

#Preview {
    NavigationStack { SetsScreen() }
        .modelContainer(for: Catch.self, inMemory: true)
}
