//
//  HangarView.swift
//  Tailspot
//
//  The collection view ("Hangar") — every catch the user has logged.
//  Presented as a sheet from ContentView. Hosts the 3-segment shell
//  (Sets / Recent / Trophies); each segment owns its own body and,
//  where applicable, its own delete state. See `HangarRecentView`,
//  `HangarSetsView`, `HangarTrophiesView`.
//

import SwiftUI
import SwiftData

struct HangarView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// Pulled from the model container injected by TailspotApp. The
    /// @Query auto-updates when new Catches are inserted — so if you
    /// catch a plane, dismiss to the AR view, catch another, then
    /// come back, the grid reflects both without manual refresh.
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    /// Segment selection for the 3-view Hangar shell (Spec § 4.1).
    /// Persisted across launches via @AppStorage so the user lands
    /// on whichever view they were last using.
    @AppStorage("tailspot.hangar.view") private var rawSegment: String = HangarSegment.sets.rawValue

    /// Two-way binding into the @AppStorage-backed raw string —
    /// lets the segmented switcher work in `HangarSegment` units
    /// while we persist the raw value.
    private var segment: Binding<HangarSegment> {
        Binding(
            get: { HangarSegment(rawValue: rawSegment) ?? .sets },
            set: { rawSegment = $0.rawValue }
        )
    }

    /// One shared namespace for every zoom transition inside this stack
    /// (set cell → set detail, model cell → model detail, tail row →
    /// catch detail). Published through the environment so source cells
    /// and the `navigationDestination` destinations — which live in
    /// different views — can match by the route's stable id. See
    /// `HangarZoomNamespace.swift`.
    @Namespace private var zoomNamespace

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                customTopBar
                content
            }
                .toolbar(.hidden, for: .navigationBar)
                .background(Brand.Color.bgPrimary)
                .environment(\.hangarZoomNamespace, zoomNamespace)
                .task {
                    // Collection-wide airframe-fact backfill: resolves
                    // typecode (and other static fields) for catches
                    // written before these fields existed. One metadata
                    // fetch per distinct icao24; idempotent. The @Query
                    // auto-refreshes the UI as fields fill and save().
                    await CatchBackfill.backfillAll(catches, in: modelContext)
                    // One-time photo-focus recovery: derive the crop focus
                    // from the baked bracket for catches that predate the
                    // focus field (or whose bracket was re-healed), so the
                    // Hangar centers the plane instead of center-cropping.
                    // Version-gated, so it scans once (bytes + pixels off
                    // the main actor). Runs after airframe backfill so the
                    // save() coalesces with any field fills.
                    await CatchBackfill.backfillPhotoFocus(catches, in: modelContext)
                }
                .navigationDestination(for: HangarRow.self) { row in
                    CatchDetailView(row: row)
                        // Zoom the catch card open from whichever cell
                        // was tapped (Recent grid, a set's tail row, …),
                        // matched by the row's stable icao24 id.
                        .zoomTransition(id: row, in: zoomNamespace)
                }
                // Tapping a set in the Sets segment pushes its detail. This
                // destination MUST live here on the NavigationStack — NOT inside
                // SetsBrowser — because SetsBrowser renders inside the paged
                // TabView below, and SwiftUI does not register a
                // navigationDestination declared inside a TabView page with the
                // enclosing stack, so the set tap silently did nothing. The
                // standalone Profile path keeps its own copy in SetsBrowser.
                .navigationDestination(for: CardSet.self) { set in
                    SetDetailScreen(set: set)
                }
                .navigationDestination(for: SetDetailRoute.self) { route in
                    // Task 16 — real `SetDetailView` (model-slot grid)
                    // lives in `SetDetailView.swift`. If a set id ever
                    // fails to resolve (e.g., we deleted an entry from
                    // CardSets.all but a stale nav value lingered),
                    // fall through to an empty view rather than crash.
                    if let set = CardSets.all.first(where: { $0.id == route.setId }) {
                        SetDetailView(set: set)
                    }
                }
                .navigationDestination(for: ModelSlotRoute.self) { route in
                    // Resolve the set, then rebuild the model group on
                    // demand from current catches — the route only
                    // carries stable strings (set id + model name).
                    // The model layer is derived dynamically per the
                    // 2026-05-26 Sets revamp, so a model that has been
                    // un-caught since the navigation pushed degrades
                    // to "no tails" gracefully rather than crashing.
                    if let set = CardSets.all.first(where: { $0.id == route.setId }) {
                        ModelGroupBridge(set: set, modelName: route.model)
                            // Grow the model-slot card out of the tapped
                            // SetDetailView model cell (same `route` id on
                            // both ends of the match).
                            .zoomTransition(id: route, in: zoomNamespace)
                    }
                }
        }
    }

    // MARK: - Custom top bar
    //
    // The system nav bar's toolbar items kept clipping the Lockup and
    // truncating the trailing "N catches" pill (iOS's inline-mode auto
    // layout squeezes both leading + trailing items when they fight
    // for space). The canvas design renders a custom top bar inline,
    // not a system nav bar — so we do the same.

    private var customTopBar: some View {
        HStack(spacing: 8) {
            HangarGlyph(lineWidth: 2, tint: Brand.Color.cyan)
                .frame(width: 22, height: 22)
            Text("TAILSPOT")
                .font(Brand.Font.mono(size: 13, weight: .bold))
                .tracking(2)
                .foregroundStyle(Brand.Color.textPrimary)
            Spacer(minLength: 8)
            if !catches.isEmpty {
                Text("\(catches.count) catches")
                    .font(Brand.Font.mono(size: 11, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(Brand.Color.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Brand.Color.cyan.opacity(0.16), in: .capsule)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Brand.Color.bgPrimary)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Brand.Color.textPrimary.opacity(0.04))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if catches.isEmpty {
            // Empty state replaces the whole switcher — easier than
            // threading "empty" into each of the three views.
            emptyState
        } else {
            VStack(spacing: 0) {
                HangarSegmentedSwitcher(selection: segment)
                // A paged TabView keeps every segment alive (no @Query re-run
                // or List rebuild on switch — that was the original lag) AND
                // hands the cross-segment transition to UIKit's page view,
                // which stays smooth even with the List-backed Trophies page.
                // The earlier keep-alive ZStack cross-faded two stacked
                // UICollectionView Lists, which is what still felt janky.
                // The segment buttons drive `selection`; horizontal swipe
                // between pages comes free. Page dots hidden.
                TabView(selection: segment) {
                    SetsBrowser()
                        .tag(HangarSegment.sets)
                    HangarRecentView()
                        .tag(HangarSegment.recent)
                    HangarTrophiesView()
                        .tag(HangarSegment.trophies)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(Brand.Color.bgPrimary)
        }
    }

    // MARK: - Empty state

    /// The first-launch empty state — explains the catch loop and
    /// previews the sets the user has to fill. Matches the design
    /// canvas's "Go outside." treatment.
    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroBlock
                setsPreview
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(Brand.Color.bgPrimary)
    }

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Circle().fill(Brand.Color.cyan.opacity(0.12))
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Brand.Color.cyan)
            }
            .frame(width: 64, height: 64)
            Text("Go outside.")
                .brandDisplayFont()
                .foregroundStyle(Brand.Color.textPrimary)
            Text("Tailspot needs a clear view of the sky. Point your phone up, aim at a plane, then tap to catch it.")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
            Button {
                // Hangar is sheet-presented from ContentView, so
                // dismissing it lands the user back in the AR view.
                dismiss()
            } label: {
                Text("Open AR view")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Brand.Color.bgPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Brand.Color.cyan, in: .rect(cornerRadius: Brand.Radius.row))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private var setsPreview: some View {
        let previewSets: [CardSet] = CardSets.all.filter {
            [.narrow, .wide, .regional, .heritage].contains($0.type)
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("SETS TO COLLECT")
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            VStack(spacing: 8) {
                ForEach(previewSets) { set in
                    setPreviewRow(set)
                }
            }
        }
    }

    private func setPreviewRow(_ set: CardSet) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Brand.Radius.chip).fill(set.type.tint.opacity(0.20))
                Text(set.type.glyph)
                    .font(Brand.Font.mono(size: 14, weight: .bold))
                    .foregroundStyle(set.type.tint)
            }
            .frame(width: 30, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(set.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(set.type.summary)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("0 / \(set.entries.count)")
                .font(Brand.Font.mono(size: 12, weight: .bold))
                .foregroundStyle(Brand.Color.textTertiary)
                .monospacedDigit()
        }
        .padding(12)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.row))
    }
}

// MARK: - HangarFilter

/// What's currently visible in the Hangar grid. Used to drive both
/// the chip selection and the row filter predicate.
enum HangarFilter: Hashable {
    case all
    case rarePlus
    case type(AircraftType)

    func includes(_ row: HangarRow) -> Bool {
        switch self {
        case .all:              return true
        case .rarePlus:         return row.rarity.ordinal >= Rarity.rare.ordinal
        case .type(let t):      return row.aircraftType == t
        }
    }
}

// All three Hangar segment views now live in their own files:
//   - HangarRecentView   → HangarRecentView.swift   (Task 13)
//   - HangarTrophiesView → HangarTrophiesView.swift (Task 14)
//   - HangarSetsView     → HangarSetsView.swift     (Task 15)

#Preview {
    HangarView()
        .modelContainer(for: Catch.self, inMemory: true)
}
