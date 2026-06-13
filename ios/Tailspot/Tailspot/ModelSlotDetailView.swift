//
//  ModelSlotDetailView.swift
//  Tailspot
//
//  Model-slot detail — card-first view for a caught model in a set.
//
//  Layout (top to bottom):
//    • Custom back bar (HangarChildBar — matches SetDetailView chrome)
//    • Card hero: CatchCardView at .lg for the *representative* catch
//      (earliest first-caught across all tails; see
//      `HangarGrouping.representativeCatch(in:)` for the rule).
//    • "TAILS (N)" section listing every HangarRow — one per distinct
//      icao24 — each navigating to CatchDetailView via the HangarRow
//      navigation destination wired in HangarView.
//
//  Representative-catch rule: earliest `firstCatch.caughtAt` across all
//  tails of the model. That's the "first time you ever caught this model"
//  moment — the collectible meaning behind the card. Ties break by
//  icao24 ascending so rerenders stay stable.
//
//  Reached by tapping a model row in SetDetailView. Uncaught models
//  (no tails) are non-navigable in SetDetailView, so this view only
//  ever shows with tails.count >= 1.
//

import SwiftUI
import SwiftData

struct ModelSlotDetailView: View {
    let set: CardSet
    let group: ModelGroup

    /// Shared zoom-transition namespace from the Hangar NavigationStack —
    /// used to zoom each tail's `CatchDetailView` open from the tapped
    /// row. See `HangarZoomNamespace.swift`.
    @Environment(\.hangarZoomNamespace) private var zoomNamespace
    /// Bumped on each tail-row tap to drive a light `.sensoryFeedback`
    /// impact, matching native cell-selection haptics.
    @State private var tapTick = 0

    /// The catch whose card sits at the top of the screen. Nil only
    /// if the group has no tails — callers guarantee at least one tail,
    /// but the type system allows nil so we handle it gracefully.
    private var representativeCatch: Catch? {
        HangarGrouping.representativeCatch(in: group.tails)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom back bar — HangarView hides the system nav bar
            // so the push transition shifts content if we let it come
            // back here. Use a matching custom chrome instead.
            HangarChildBar(title: displayModel)

            // Native List (insetGrouped): the card hero rides in a
            // borderless full-width row at the top, then the tails ride
            // in a real `Section` so they get system separators, press
            // highlights, and scroll physics. Brand dark look is kept by
            // hiding the stock grouped background.
            List {
                cardHero
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                tailsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 24, for: .scrollContent)
        }
        .background(Brand.Color.bgPrimary)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.impact(weight: .light), trigger: tapTick)
        // Preserves swipe-from-left-edge to pop. See SetDetailView for
        // the why — `.navigationBarBackButtonHidden(true)` disables the
        // interactive pop gesture too, which we don't want.
    }

    // MARK: - Card hero

    /// The model's card at the top: CatchCardView(.lg) for the
    /// representative (earliest) catch of this model. Centered and
    /// given a little breathing room so it reads as the focal point.
    @ViewBuilder
    private var cardHero: some View {
        if let repCatch = representativeCatch {
            VStack(spacing: 8) {
                CatchCardView(
                    plane: CardPlane(catchRecord: repCatch),
                    size: .lg
                )
                Text("FIRST CAUGHT")
                    .font(Brand.Font.mono(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Tails section

    /// Native `Section` of tail rows. Header keeps the Brand mono
    /// "TAILS (N)" identity; rows are real `List` rows (native
    /// separators + press highlight) and each is a zoom source so the
    /// catch card grows out of the tapped tail.
    private var tailsSection: some View {
        Section {
            ForEach(group.tails) { row in
                NavigationLink(value: row) {
                    tailRow(row)
                }
                .matchedZoomSource(id: row, in: zoomNamespace)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .simultaneousGesture(TapGesture().onEnded { tapTick += 1 })
            }
        } header: {
            Text("TAILS (\(group.distinctTailCount))")
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
        }
    }

    // MARK: - Helpers

    /// The group key is already the canonical display name; only the
    /// Unknown sentinel needs a friendlier label.
    private var displayModel: String {
        group.model == HangarGrouping.unknownTitle ? "Unknown model" : group.model
    }

    /// Tail number when we have it ("N779UA"), raw hex as fallback —
    /// the registration is what a spotter actually reads off the plane.
    private func tailIdentifier(_ row: HangarRow) -> String {
        row.mostRecent.registration?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? row.icao24
    }

    private func tailRow(_ row: HangarRow) -> some View {
        let cs = row.mostRecent.callsign?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? row.icao24.uppercased()
        return HStack(spacing: 10) {
            Rectangle()
                .fill(row.rarity.tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(cs)
                    .font(Brand.Font.mono(size: 12, weight: .bold))
                    .foregroundStyle(Brand.Color.cyan)
                Text("\(tailIdentifier(row)) · \(row.mostRecent.operatorName ?? "—")")
                    .font(Brand.Font.mono(size: 10, weight: .regular))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            Spacer()
            Text(row.firstCatch.caughtAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(Brand.Font.mono(size: 10, weight: .regular))
                .foregroundStyle(Brand.Color.textTertiary)
        }
        // System `List` + `NavigationLink` supplies the native trailing
        // disclosure chevron — no hand-rolled one here.
        .padding(.vertical, 8)
        .padding(.trailing, 12)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Navigation bridge

/// Thin wrapper used by HangarView's `.navigationDestination(for:
/// ModelSlotRoute.self)`. The route value (`set id` + `model name`)
/// is intentionally Hashable + serialization-friendly; rebuilding
/// the `ModelGroup` requires a live SwiftData query, which only a
/// view can own. This wrapper performs that query and rebuilds the
/// group on every render so model-name renaming or new catches
/// surface immediately.
struct ModelGroupBridge: View {
    let set: CardSet
    let modelName: String

    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

    private var group: ModelGroup {
        let rows = HangarGrouping.group(catches, by: .recent).first?.rows ?? []
        let groups = HangarGrouping.modelGroups(in: rows, type: set.type)
        return groups.first(where: { $0.model == modelName })
            ?? ModelGroup(model: modelName, type: set.type, tails: [])
    }

    var body: some View {
        ModelSlotDetailView(set: set, group: group)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
