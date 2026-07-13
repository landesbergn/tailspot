//
//  SetDetailView.swift
//  Tailspot
//
//  Set detail screen — lists the model groups the user has actually
//  caught in a single AircraftType (no curated enumeration, no locked
//  slots). Each row = derived model name + ×K distinct-tail count;
//  tap pushes `ModelSlotDetailView` for that model.
//
//  Revamped 2026-05-26 per Noah's field-test feedback: drop the
//  pre-enumerated CardSetEntry slot grid in favor of a count-driven
//  view that grows organically as the user catches new models.
//

import SwiftUI
import SwiftData

struct SetDetailView: View {
    let set: CardSet

    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    /// Shared zoom-transition namespace from the Hangar NavigationStack.
    /// Tapping a model cell zooms its `ModelSlotDetailView` open from the
    /// tapped frame instead of sliding in as a flat push. See
    /// `HangarZoomNamespace.swift`.
    @Environment(\.hangarZoomNamespace) private var zoomNamespace
    /// Bumped on each model-cell tap so `.sensoryFeedback` fires a light
    /// impact — the same physical "tick" iOS gives native cell selection.
    @State private var tapTick = 0

    private var rows: [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }
    private var groups: [ModelGroup] {
        HangarGrouping.modelGroups(in: rows, type: set.type)
    }
    private var tailCount: Int {
        groups.reduce(0) { $0 + $1.distinctTailCount }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom back bar — HangarView hides the system nav bar
            // so the push transition shifts content if we let it come
            // back here. Use a matching custom chrome instead.
            HangarChildBar(title: set.title)

            // Native List (insetGrouped) replaces the hand-stacked
            // ScrollView + VStack: we get system row insets, separators,
            // tap highlight states, and scroll physics for free. The
            // Brand dark look is preserved by hiding the stock grouped
            // background (`.scrollContentBackground(.hidden)`) and
            // painting our own row/section backgrounds.
            List {
                header
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if groups.isEmpty {
                    emptyHint
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    modelSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 24, for: .scrollContent)
        }
        .background(Brand.Color.bgPrimary)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.impact(weight: .light), trigger: tapTick)
        // Keep the interactive-pop gesture (swipe-from-left-edge) by
        // NOT setting `.navigationBarBackButtonHidden(true)` — that
        // flag disables the gesture in addition to hiding the back
        // button. The nav bar is hidden anyway via `.toolbar(.hidden)`
        // so the system back button never renders.
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Brand.Radius.row).fill(set.type.tint)
                Text(set.type.glyph)
                    .font(Brand.Font.mono(size: 18, weight: .bold))
                    .foregroundStyle(.black.opacity(0.75))
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(set.title)
                    // .title3 == 20 pt at the default setting, but scales
                    // with Dynamic Type (a bare size: 20 doesn't).
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(tailCountLine)
                    .font(Brand.Font.mono(size: 11, weight: .semibold, relativeTo: .caption2))
                    .tracking(0.4)
                    .foregroundStyle(tailCount > 0 ? set.type.tint : Brand.Color.textTertiary)
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    private var tailCountLine: String {
        switch tailCount {
        case 0: return "Nothing caught yet"
        case 1: return "1 tail caught · \(groups.count) model"
        default:
            let modelWord = groups.count == 1 ? "model" : "models"
            return "\(tailCount) tails caught · \(groups.count) \(modelWord)"
        }
    }

    // MARK: - Model list

    /// One native `Section` per set. The header keeps the Brand mono
    /// "MODELS" label (the HUD-flavored identity stays); the rows are
    /// real `List` rows so they pick up native separators, the system
    /// press-highlight, and swipe geometry. Each cell is a zoom source
    /// keyed by the route, so the tapped frame is what grows into the
    /// model detail.
    private var modelSection: some View {
        Section {
            ForEach(groups) { group in
                let route = ModelSlotRoute(setId: set.id, model: group.model)
                NavigationLink(value: route) {
                    modelRow(group)
                }
                .matchedZoomSource(id: route, in: zoomNamespace)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .simultaneousGesture(TapGesture().onEnded { tapTick += 1 })
            }
        } header: {
            Text("MODELS")
                .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
        }
    }

    private func modelRow(_ group: ModelGroup) -> some View {
        HStack(spacing: 12) {
            Text(displayModel(group.model))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.Color.textPrimary)
                // Long model names wrap instead of crowding the count
                // column at larger text sizes.
                .lineLimit(2)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text("×\(group.distinctTailCount)")
                    .font(Brand.Font.mono(size: 16, weight: .bold, relativeTo: .body))
                    .monospacedDigit()
                    .foregroundStyle(set.type.tint)
                Text(group.distinctTailCount == 1 ? "tail" : "tails")
                    .font(Brand.Font.mono(size: 9, weight: .semibold, relativeTo: .caption2))
                    .tracking(0.8)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
        // System `List` + `NavigationLink` already draws the native
        // trailing disclosure chevron; we don't hand-roll one.
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Brand.Color.bgElevated)
        .overlay(alignment: .leading) {
            Rectangle().fill(set.type.tint).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.row))
    }

    /// The group key is already the canonical display name; only the
    /// Unknown sentinel needs a friendlier label.
    private func displayModel(_ raw: String) -> String {
        raw == HangarGrouping.unknownTitle ? "Unknown model" : raw
    }

    // MARK: - Empty state

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing caught yet")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
            Text("Catch any \(set.title.lowercased()) and it'll appear here.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.row))
    }
}

/// Stable navigation target for `ModelSlotDetailView` — the model-group
/// tail list. Carries the set id + a derived model string (e.g.,
/// "Boeing 737-800") rather than a curated CardSetEntry id, so the
/// list can grow as the user catches new models.
struct ModelSlotRoute: Hashable {
    let setId: String
    let model: String
}

