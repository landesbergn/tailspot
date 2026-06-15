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
        return HStack(spacing: 14) {
            // The completion ring is the leading anchor now (replacing the
            // type-letter pill) — it keeps the set's category color via the
            // tint while making "% complete" the thing you read first.
            CompletionRing(progress: frac, tint: set.type.tint, lineWidth: 5)
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
                    }
                }
                Text("\(p.caught) of \(p.total) \(lens == .type ? "models" : "variants")")
                    .font(Brand.Font.mono(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 4)
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
        VStack(spacing: 0) {
            // Custom back bar — the Hangar hides the system nav bar, so a
            // system back button wouldn't render there. HangarChildBar pops
            // via dismiss() and works in both the Hangar and Profile stacks.
            HangarChildBar(title: set.title)
            ScrollView {
            VStack(spacing: 20) {
                header
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(slotStatus.enumerated()), id: \.element.0.id) { idx, pair in
                        let entry = pair.0
                        let isCaught = pair.1 != .locked
                        let tile = SlotChecklistTile(index: idx + 1, entry: entry, isCaught: isCaught)
                        if isCaught {
                            // Caught → push the full card (photo + catch info)
                            // and every tail of this model.
                            NavigationLink {
                                SetSlotCardView(
                                    entry: entry,
                                    matchingCatches: catches.filter { CardSets.matches(catch: $0, entry: entry) }
                                )
                            } label: { tile }
                            .buttonStyle(.plain)
                        } else {
                            // Locked → a light "here's the target" sheet.
                            tile.onTapGesture { inspected = entry }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .padding(.top, 8)
            }
        }
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .sheet(item: $inspected) { entry in
            LockedSlotSheet(entry: entry)
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

            // Name shown even when locked — the set is a checklist of
            // targets, so you should know what you're hunting. No rarity
            // text: only rare-and-above gets a small sparkle so the
            // special ones stand out without labelling every common plane.
            HStack(spacing: 4) {
                Text(entry.canonicalName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCaught ? Brand.Color.textPrimary : Brand.Color.textTertiary)
                    .lineLimit(1)
                if entry.rarity.isNotable {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(entry.rarity.tint)
                        .opacity(isCaught ? 1 : 0.6)
                }
            }
        }
        .contentShape(.rect)
    }
}

// MARK: - Locked-slot target sheet

/// Lightweight sheet for a LOCKED slot: names the target and nudges you
/// to go catch it. (Caught slots navigate to the full card instead.)
private struct LockedSlotSheet: View {
    let entry: CardSetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Brand.Color.bgElevated)
                        .overlay(Circle().strokeBorder(
                            Brand.Color.textTertiary.opacity(0.25),
                            style: .init(lineWidth: 1, dash: [4, 4])))
                    Image(systemName: "airplane")
                        .font(.system(size: 22))
                        .foregroundStyle(Brand.Color.textTertiary)
                        .rotationEffect(.degrees(-45))
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.canonicalName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    if entry.rarity.isNotable {
                        Label(entry.rarity.label, systemImage: "sparkles")
                            .font(Brand.Font.mono(size: 11, weight: .bold))
                            .foregroundStyle(entry.rarity.tint)
                    }
                }
                Spacer()
            }

            Text(entry.summary)
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)

            Divider().overlay(Brand.Color.textTertiary.opacity(0.2))

            Label("Not yet caught — point, lock, and capture one to fill this slot.",
                  systemImage: "scope")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
    }
}

// MARK: - Caught-slot card (photo + catch info + every tail)

/// Tapping a CAUGHT slot opens this: the model's card (with photo) for the
/// representative catch, then a TAILS section listing every distinct tail
/// you've caught of this model — each opening its full CatchDetailView.
/// Reuses HangarGrouping so it stays consistent with the Hangar's own model
/// view, but uses HangarChildBar + standard navigation so it works from both
/// the Hangar (system bar hidden) and Profile entry points.
private struct SetSlotCardView: View {
    let entry: CardSetEntry
    let matchingCatches: [Catch]

    private var rows: [HangarRow] {
        HangarGrouping.group(matchingCatches, by: .recent).first?.rows ?? []
    }
    private var representative: Catch? {
        HangarGrouping.representativeCatch(in: rows)
    }

    var body: some View {
        VStack(spacing: 0) {
            HangarChildBar(title: entry.canonicalName)
            List {
                if let rep = representative {
                    VStack(spacing: 8) {
                        CatchCardView(plane: CardPlane(catchRecord: rep), size: .lg)
                        Text("FIRST CAUGHT")
                            .font(Brand.Font.mono(size: 9, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(Brand.Color.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(rows) { row in
                        NavigationLink { CatchDetailView(row: row) } label: { tailRow(row) }
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("TAILS (\(rows.count))")
                        .font(Brand.Font.mono(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Brand.Color.textTertiary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .background(Brand.Color.bgPrimary)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    private func tailRow(_ row: HangarRow) -> some View {
        let cs = row.mostRecent.callsign?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (cs?.isEmpty == false) ? cs! : row.icao24.uppercased()
        let reg = row.mostRecent.registration?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = (reg?.isEmpty == false) ? reg! : row.icao24
        return HStack(spacing: 10) {
            Rectangle().fill(row.rarity.tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Brand.Font.mono(size: 12, weight: .bold))
                    .foregroundStyle(Brand.Color.cyan)
                Text("\(tail) · \(row.mostRecent.operatorName ?? "—")")
                    .font(Brand.Font.mono(size: 10))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 8))
    }
}

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

#Preview {
    NavigationStack { SetsScreen() }
        .modelContainer(for: Catch.self, inMemory: true)
}
