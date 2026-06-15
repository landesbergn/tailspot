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
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(Array(slotStatus.enumerated()), id: \.element.0.id) { _, pair in
                        let entry = pair.0
                        // Filled slots show the catch's REAL collectible card
                        // (photo, points, holo on rare+) — the set page becomes a
                        // wall of your own cards instead of generic glyphs. Locked
                        // slots are ghost-card placeholders to hunt.
                        let matching = catches.filter { CardSets.matches(catch: $0, entry: entry) }
                        let rep = HangarGrouping.representativeCatch(
                            in: HangarGrouping.group(matching, by: .recent).first?.rows ?? [])
                        if let rep {
                            NavigationLink {
                                SetSlotCardView(entry: entry, matchingCatches: matching)
                            } label: {
                                SetSlotCard(entry: entry, representative: rep)
                            }
                            .buttonStyle(.plain)
                        } else {
                            GhostSlotCard(entry: entry)
                                .onTapGesture { inspected = entry }
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

// MARK: - Slot cards (uniform grid)
//
// Both the caught card and the ghost share the exact same footprint
// (fill-width column, image area on top, solid label strip below, fixed
// height) so the set page reads as a clean, uniform wall. Purpose-built
// for the grid — NOT the standalone CatchCardView, whose callsign/rarity
// header, type pill, points, and rarity-tinted border don't belong here.

private enum SlotCardMetrics {
    static let imageHeight: CGFloat = 118
    static let totalHeight: CGFloat = 176
    static let corner: CGFloat = 14
}

/// A CAUGHT slot: the catch photo (your capture) on top, with the model
/// name + operator in a solid strip below so text is always legible. Rarity
/// is signalled only by a small sparkle on rare-and-above.
private struct SetSlotCard: View {
    let entry: CardSetEntry
    let representative: Catch

    private var photoURL: URL? {
        representative.photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let photoURL {
                    AsyncImage(url: photoURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            SlotPlaceholder()
                        }
                    }
                } else {
                    SlotPlaceholder()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: SlotCardMetrics.imageHeight)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(entry.canonicalName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .lineLimit(1)
                    if entry.rarity.isNotable {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(entry.rarity.tint)
                    }
                    Spacer(minLength: 0)
                }
                Text(representative.operatorName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.Color.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: SlotCardMetrics.totalHeight)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: SlotCardMetrics.corner))
        .clipShape(RoundedRectangle(cornerRadius: SlotCardMetrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: SlotCardMetrics.corner)
                .strokeBorder(Brand.Color.textPrimary.opacity(0.06), lineWidth: 1)
        )
    }
}

/// A LOCKED slot: same footprint as the caught card, dashed + dimmed, naming
/// the target to hunt. Rare-and-above keeps its sparkle.
private struct GhostSlotCard: View {
    let entry: CardSetEntry

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Brand.Color.bgSurface.opacity(0.5)
                Image(systemName: "airplane")
                    .font(.system(size: 30, weight: .ultraLight))
                    .foregroundStyle(Brand.Color.textTertiary.opacity(0.3))
                    .rotationEffect(.degrees(-45))
            }
            .frame(maxWidth: .infinity)
            .frame(height: SlotCardMetrics.imageHeight)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(entry.canonicalName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.Color.textTertiary)
                        .lineLimit(1)
                    if entry.rarity.isNotable {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(entry.rarity.tint.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 8))
                    Text("NOT CAUGHT")
                        .font(Brand.Font.mono(size: 9, weight: .bold))
                        .tracking(0.6)
                }
                .foregroundStyle(Brand.Color.textTertiary.opacity(0.7))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: SlotCardMetrics.totalHeight)
        .background(Brand.Color.bgElevated.opacity(0.35), in: .rect(cornerRadius: SlotCardMetrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: SlotCardMetrics.corner)
                .strokeBorder(Brand.Color.textTertiary.opacity(0.22),
                              style: .init(lineWidth: 1, dash: [5, 5]))
        )
        .contentShape(.rect)
    }
}

/// Calm placeholder for the image area when no capture photo exists — a
/// single muted glyph, not the busy diagonal stripes of the standalone card.
private struct SlotPlaceholder: View {
    var body: some View {
        ZStack {
            Brand.Color.bgSurface
            Image(systemName: "airplane")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Brand.Color.textTertiary.opacity(0.5))
                .rotationEffect(.degrees(-45))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    tailsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
        }
        .background(Brand.Color.bgPrimary)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: Hero

    private var heroPhotoURL: URL? {
        representative?.photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) }
    }

    /// First-caught date — the meaningful, always-present datum. Per-catch
    /// stats (altitude, speed, distance) live in each tail's CatchDetailView,
    /// so the hero never shows empty "—" chips.
    private var firstCaughtText: String? {
        guard let c = representative else { return nil }
        return "First caught \(c.caughtAt.formatted(.dateTime.month().day().year()))"
    }

    private var hero: some View {
        VStack(spacing: 0) {
            ZStack {
                if let heroPhotoURL {
                    AsyncImage(url: heroPhotoURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            SlotPlaceholder()
                        }
                    }
                } else {
                    SlotPlaceholder()
                }
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    // The slot name is typecode-authoritative — show it, not the
                    // catch's free-text model (which can disagree, e.g. an A20N
                    // catch whose model string reads "A321neo").
                    Text(entry.canonicalName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    if entry.rarity.isNotable {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14))
                            .foregroundStyle(entry.rarity.tint)
                    }
                    Spacer(minLength: 0)
                }
                if let op = representative?.operatorName?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    Text(op)
                        .font(Brand.Font.body)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                if let firstCaughtText {
                    Text(firstCaughtText)
                        .font(Brand.Font.mono(size: 11, weight: .regular))
                        .foregroundStyle(Brand.Color.textTertiary)
                        .padding(.top, 2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Brand.Color.textPrimary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: Tails

    private var tailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TAILS (\(rows.count))")
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
                .padding(.leading, 4)
            ForEach(rows) { row in
                NavigationLink { CatchDetailView(row: row) } label: { tailRow(row) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func tailRow(_ row: HangarRow) -> some View {
        let callsign = row.mostRecent.callsign?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let reg = row.mostRecent.registration?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let op = row.mostRecent.operatorName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // Title: callsign, else the registration, else the hex id (last resort).
        let title = callsign ?? reg ?? row.icao24.uppercased()
        // Subtitle: registration (only if not already the title) + operator,
        // joined with " · " — never the raw hex, never a dangling separator.
        let regPart = (callsign == nil) ? nil : reg
        let subtitle = [regPart, op].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Brand.Color.cyan)
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Brand.Font.mono(size: 13, weight: .bold))
                    .foregroundStyle(Brand.Color.cyan)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Brand.Font.mono(size: 10))
                        .foregroundStyle(Brand.Color.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(row.firstCatch.caughtAt,
                 format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(Brand.Font.mono(size: 10))
                .foregroundStyle(Brand.Color.textTertiary)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.Color.textTertiary.opacity(0.6))
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 10))
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
