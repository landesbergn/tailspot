//
//  SetDetailView.swift
//  Tailspot
//
//  Set detail screen — model-slot grid for a single PokeSet. Each
//  caught slot shows `×K tails` (distinct icao24 airframes caught in
//  this slot); tap pushes to `ModelSlotDetailView` (Task 17 fleshes
//  out the tail list). Locked slots reveal a small bottom-sheet hint
//  carrying the `PokeSetEntry.summary` blurb. Spec § 5.2.
//

import SwiftUI
import SwiftData

struct SetDetailView: View {
    let set: PokeSet

    /// Same query shape as `HangarSetsView` — flat dedup'd row list
    /// (Recent collapses by icao24 only). `resolveSlots(for:in:)` then
    /// pivots it into one ModelSlot per entry in this set. Pulled
    /// directly here so navigating to set-detail doesn't have to
    /// thread state through the route value.
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

    /// Which locked slot, if any, currently has its hint sheet open.
    /// `ModelSlot` is `Identifiable` (id == entry.id) so `.sheet(item:)`
    /// rebinds cleanly when the user taps a different locked tile.
    @State private var hintSlot: ModelSlot? = nil

    private var rows: [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }
    private var slots: [ModelSlot] {
        HangarGrouping.resolveSlots(for: set, in: rows)
    }
    private var caughtCount: Int { slots.filter(\.isCaught).count }
    private var totalCount: Int { slots.count }
    private var progress: Double {
        totalCount == 0 ? 0 : Double(caughtCount) / Double(totalCount)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                slotGrid
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Brand.Color.bgPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Brand.Color.bgPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $hintSlot) { slot in
            LockedSlotHint(slot: slot, setTint: set.type.tint)
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                // Large type chip — same glyph + tint treatment as the
                // set tile, but at a hero size so the detail screen
                // reads as a destination, not "the tile but bigger."
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(set.type.tint)
                    Text(set.type.glyph)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.75))
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Text("\(caughtCount) of \(totalCount) caught")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(set.type.tint)
                        .monospacedDigit()
                }
                Spacer()
            }

            // Progress bar — pinned to the type tint so it visually
            // belongs to this set. 3pt height keeps it as a thin meter
            // rather than a stripe.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Brand.Color.bgElevated)
                    Rectangle().fill(set.type.tint)
                        .frame(width: max(0, proxy.size.width * progress))
                }
            }
            .frame(height: 3)
            .clipShape(Capsule())

            if let line = nextMilestoneLine {
                Text(line)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
    }

    /// Teaser line under the progress bar. We don't yet map sets to
    /// trophy ladders, so this is a simple "N more to N% / done" hint —
    /// enough to give the bar a target without overstating progress.
    /// Returns nil for the empty / fully-complete states (the progress
    /// bar already carries that signal).
    private var nextMilestoneLine: String? {
        guard totalCount > 0 else { return nil }
        let remaining = totalCount - caughtCount
        if remaining == 0 { return "SET COMPLETE" }
        if caughtCount == 0 { return "CATCH ANY \(set.title.uppercased()) TO START" }
        return "\(remaining) MORE TO COMPLETE"
    }

    // MARK: - Slot grid

    private var slotGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ],
            spacing: 8
        ) {
            // `enumerated()` so the displayed `#NN` index is O(1) per
            // cell — `slots` is order-stable (mirrors `set.entries`).
            ForEach(Array(slots.enumerated()), id: \.element.id) { idx, slot in
                slotCell(slot, index: idx + 1)
            }
        }
    }

    @ViewBuilder
    private func slotCell(_ slot: ModelSlot, index: Int) -> some View {
        if slot.isCaught {
            NavigationLink(value: ModelSlotRoute(setId: set.id, entryId: slot.entry.id)) {
                caughtCell(slot: slot, index: index)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                hintSlot = slot
            } label: {
                lockedCell(slot: slot, index: index)
            }
            .buttonStyle(.plain)
        }
    }

    private func caughtCell(slot: ModelSlot, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("#" + String(format: "%02d", index))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Brand.Color.textTertiary)
                Spacer()
            }
            Spacer(minLength: 4)
            Text(slot.entry.canonicalName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("×\(slot.distinctTailCount) tail" + (slot.distinctTailCount == 1 ? "" : "s"))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(set.type.tint)
                .monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Brand.Color.bgElevated)
        .overlay(alignment: .top) {
            // 2pt top rail in the type tint, per spec § 5.2. Sits
            // above the elevated fill — the clip shape further down
            // keeps it tucked inside the corner radius.
            Rectangle().fill(set.type.tint).frame(height: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func lockedCell(slot: ModelSlot, index: Int) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("#" + String(format: "%02d", index))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Brand.Color.textTertiary)
                Spacer()
            }
            Spacer(minLength: 2)
            Text("?")
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .foregroundStyle(Brand.Color.textTertiary)
            Text(slot.entry.canonicalName)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Brand.Color.textTertiary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
            Spacer(minLength: 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(Brand.Color.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(0.65)
    }
}

/// Stable navigation target for `ModelSlotDetailView` (the slot's
/// tail list, Task 17). We carry only the two stable string ids so
/// the value is trivially `Hashable` and serialization-friendly; the
/// destination resolves them back to the live `PokeSet` /
/// `PokeSetEntry` via `PokeSets.all`.
struct ModelSlotRoute: Hashable {
    let setId: String
    let entryId: String
}

// MARK: - Locked-slot hint sheet

private struct LockedSlotHint: View {
    let slot: ModelSlot
    let setTint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LOCKED SLOT")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(setTint)
            Text("Catch a \(slot.entry.canonicalName) to fill this slot.")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.Color.textPrimary)
            // `PokeSetEntry.summary` was designed for exactly this
            // surface — "tap-to-reveal blurb" per Sets.swift's header.
            Text(slot.entry.summary)
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgPrimary)
    }
}

// `ModelSlotDetailView` lives in `ModelSlotDetailView.swift` (Task 17).
