//
//  ModelSlotDetailView.swift
//  Tailspot
//
//  The screen between Set detail and Tail detail — lists every
//  distinct tail (icao24) the user has caught of one model. The model
//  is now derived from caught planes (no curated entry list), so the
//  view takes a `ModelGroup` rather than a `PokeSetEntry`.
//
//  Reached by tapping a model row in `SetDetailView`. Each row is one
//  `HangarRow` (collapsed by icao24) and pushes the existing
//  `CatchDetailView` via the `HangarRow` navigation destination wired
//  in `HangarView`.
//

import SwiftUI
import SwiftData

struct ModelSlotDetailView: View {
    let set: PokeSet
    let group: ModelGroup

    var body: some View {
        VStack(spacing: 0) {
            // Custom back bar — HangarView hides the system nav bar
            // so the push transition shifts content if we let it come
            // back here. Use a matching custom chrome instead.
            HangarChildBar(title: displayModel)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(set.title.uppercased())
                        .font(Brand.Font.mono(size: 10, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(Brand.Color.textTertiary)

                    Text(displayModel)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Brand.Color.textPrimary)

                    Text("\(group.distinctTailCount) distinct tail\(group.distinctTailCount == 1 ? "" : "s")")
                        .font(Brand.Font.mono(size: 11, weight: .regular))
                        .foregroundStyle(set.type.tint)

                    Text("TAILS YOU'VE CAUGHT")
                        .font(Brand.Font.mono(size: 9, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Brand.Color.textTertiary)
                        .padding(.top, 14)
                        .padding(.bottom, 4)

                    VStack(spacing: 6) {
                        ForEach(group.tails) { row in
                            NavigationLink(value: row) {
                                tailRow(row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Brand.Color.bgPrimary)
        .toolbar(.hidden, for: .navigationBar)
        // Preserves swipe-from-left-edge to pop. See SetDetailView for
        // the why — `.navigationBarBackButtonHidden(true)` disables the
        // interactive pop gesture too, which we don't want.
    }

    /// Title-case the manufacturer prefix; leave the model
    /// alphanumerics intact. Mirrors `SetDetailView.displayModel`.
    private var displayModel: String {
        let raw = group.model
        if raw == HangarGrouping.unknownTitle { return "Unknown model" }
        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return raw.capitalized }
        let mfg = parts[0].lowercased().capitalized
        let model = String(parts[1])
        return "\(mfg) \(model)"
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
                Text("\(row.icao24) · \(row.mostRecent.operatorName ?? "—")")
                    .font(Brand.Font.mono(size: 10, weight: .regular))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            Spacer()
            Text(row.firstCatch.caughtAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(Brand.Font.mono(size: 10, weight: .regular))
                .foregroundStyle(Brand.Color.textTertiary)
        }
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
    let set: PokeSet
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
