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
//  pre-enumerated PokeSetEntry slot grid in favor of a count-driven
//  view that grows organically as the user catches new models.
//

import SwiftUI
import SwiftData

struct SetDetailView: View {
    let set: PokeSet

    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

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

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if groups.isEmpty {
                        emptyHint
                    } else {
                        modelList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(Brand.Color.bgPrimary)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
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
                Text(tailCountLine)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
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

    private var modelList: some View {
        VStack(spacing: 8) {
            ForEach(groups) { group in
                NavigationLink(value: ModelSlotRoute(setId: set.id, model: group.model)) {
                    modelRow(group)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func modelRow(_ group: ModelGroup) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayModel(group.model))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(operatorPreview(for: group))
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text("×\(group.distinctTailCount)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(set.type.tint)
                Text(group.distinctTailCount == 1 ? "tail" : "tails")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Brand.Color.bgElevated)
        .overlay(alignment: .leading) {
            Rectangle().fill(set.type.tint).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Human-friendly model string. The raw key from
    /// `HangarGrouping.key(for:c:mode:.aircraftType)` is typically all
    /// caps ("BOEING 737-800") because OpenSky stores them that way.
    /// Title-case the manufacturer; leave model alphanumerics intact.
    private func displayModel(_ raw: String) -> String {
        if raw == HangarGrouping.unknownTitle { return "Unknown model" }
        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return raw.capitalized }
        let mfg = parts[0].lowercased().capitalized
        let model = String(parts[1])
        return "\(mfg) \(model)"
    }

    /// One-line preview of the operators behind a model group — the
    /// first two distinct `operatorName` values from the tails, comma
    /// separated. Falls back to "Various operators" when there are
    /// many. Empty string when no operator data is available.
    private func operatorPreview(for group: ModelGroup) -> String {
        let names = group.tails.compactMap {
            $0.mostRecent.operatorName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
        let distinct = Array(NSOrderedSet(array: names)) as? [String] ?? []
        switch distinct.count {
        case 0:  return ""
        case 1:  return distinct[0]
        case 2:  return distinct.joined(separator: " · ")
        default: return "Various operators"
        }
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
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 8))
    }
}

/// Stable navigation target for `ModelSlotDetailView` — the model-group
/// tail list. Carries the set id + a derived model string (e.g.,
/// "BOEING 737-800") rather than a curated PokeSetEntry id, so the
/// list can grow as the user catches new models.
struct ModelSlotRoute: Hashable {
    let setId: String
    let model: String
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
