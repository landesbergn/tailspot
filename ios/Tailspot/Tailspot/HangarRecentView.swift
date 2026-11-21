//
//  HangarRecentView.swift
//  Tailspot
//
//  Catches-view body for the Hangar sheet (labelled "Recent" until
//  2026-10-30) — a chronological feed of the dedup'd catches,
//  newest-first, each rendered as the shared TailCard (callsign ·
//  airline · date · location). A search field sits on top once there
//  are more than five cards (HangarGrouping.search). No rarity/type
//  chrome; that's pre-redesign noise. Spec § 6.
//

import SwiftUI
import SwiftData
import os

struct HangarRecentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    @State private var rowToDelete: HangarRow?
    @State private var query: String
    /// The Notable toggle in the search field: show notable airframes only.
    @State private var notableOnly: Bool

    /// The parameters exist for the snapshot harness; the app passes nothing.
    init(initialQuery: String = "", initialNotableOnly: Bool = false) {
        _query = State(initialValue: initialQuery)
        _notableOnly = State(initialValue: initialNotableOnly)
    }
    /// Memoizes the grouped rows AND the first-of-type row set across body
    /// evals — this body used to run the full HangarGrouping pass TWICE per
    /// eval (isEmpty + ForEach), on every segment switch. See
    /// HangarDerivedCache. The pair is derived in one pass so the sparkle
    /// set can never drift from the rows it describes.
    /// The search index rides the same memo, so typing a query filters
    /// precomputed entries instead of rebuilding every row's text.
    @State private var cache = DerivedCacheBox<([HangarRow], Set<String>, [HangarGrouping.SearchEntry])>()

    private var derived: ([HangarRow], Set<String>, [HangarGrouping.SearchEntry]) {
        cache.value(for: CatchFingerprint.of(catches)) {
            let rows = HangarGrouping.group(catches, by: .recent).first?.rows ?? []
            return (
                rows,
                HangarGrouping.firstOfTypeRowIDs(rows: rows, allCatches: catches),
                HangarGrouping.searchIndex(for: rows)
            )
        }
    }

    var body: some View {
        // Read ONCE per body. Even a cache hit re-hashes every catch
        // (CatchFingerprint), and the ForEach row closure below runs again
        // each time a row scrolls into view. These used to be computed
        // properties read inside that closure, so every row coming on screen
        // hashed the whole Hangar: the Recent-list scroll stutter (2026-10),
        // worst on the biggest Hangars. Locals are captured by value instead.
        let (allRows, firstOfTypeIDs, searchIndex) = derived
        // The field only exists past five cards. Gate the FILTER on the same
        // check, so deleting down to five can't leave an invisible query
        // hiding cards.
        let showsSearch = allRows.count >= HangarGrouping.searchMinRows
        // The Notable toggle only exists once the Hangar holds a notable
        // airframe, and the filter is gated on the same checks as the
        // toggle, so it can never hide cards with no control to undo it.
        let showsNotableToggle = showsSearch && searchIndex.contains(where: \.isNotablePlane)
        let filtersNotable = showsNotableToggle && notableOnly
        let rows = HangarRecentView.visibleRows(
            allRows, index: searchIndex, query: showsSearch ? query : "",
            notableOnly: filtersNotable)
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        return VStack(spacing: 0) {
            if showsSearch {
                searchField(showsNotableToggle: showsNotableToggle)
            }
            ScrollView {
                if allRows.isEmpty {
                    Text("No catches yet")
                        .font(Brand.Font.body)
                        .foregroundStyle(Brand.Color.textTertiary)
                        .padding(.top, 32)
                } else if rows.isEmpty {
                    Text(HangarRecentView.emptyMessage(query: trimmedQuery, notableOnly: filtersNotable))
                        .font(Brand.Font.body)
                        .foregroundStyle(Brand.Color.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 32)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(rows) { row in
                            // `firstOfTypeIDs`: icao24s whose card gets the
                            // first-of-type sparkle + bonus share.
                            NavigationLink(value: row) {
                                TailCard(
                                    row: row,
                                    showPoints: true,
                                    isFirstOfType: firstOfTypeIDs.contains(row.icao24)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    rowToDelete = row
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            // Scrolling the results puts the keyboard away.
            .scrollDismissesKeyboard(.immediately)
        }
        .background(Brand.Color.bgPrimary)
        .alert(
            deleteAlertTitle,
            isPresented: Binding(
                get: { rowToDelete != nil },
                set: { if !$0 { rowToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let row = rowToDelete { performDelete(row: row) }
            }
            Button("Cancel", role: .cancel) {
                rowToDelete = nil
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    /// The rows the list shows: the search, then the Notable toggle.
    static func visibleRows(_ rows: [HangarRow], index: [HangarGrouping.SearchEntry],
                            query: String, notableOnly: Bool) -> [HangarRow] {
        let base = notableOnly ? HangarGrouping.notableOnly(rows, index: index) : rows
        let baseIndex = notableOnly ? index.filter(\.isNotablePlane) : index
        return HangarGrouping.search(base, index: baseIndex, query: query)
    }

    /// What the list says when the search or the Notable toggle leaves
    /// nothing to show.
    static func emptyMessage(query: String, notableOnly: Bool) -> String {
        let wordIsNotable = query.lowercased() == HangarGrouping.notableTerm
        if query.isEmpty || wordIsNotable { return "No notable planes caught yet" }
        return notableOnly
            ? "No notable catches match \u{201C}\(query)\u{201D}"
            : "No catches match \u{201C}\(query)\u{201D}"
    }

    /// The Notable toggle at the trailing end of the search field: a gold
    /// star chip that narrows the list to notable airframes. Lives inside
    /// the field so the Catches list keeps one control, not two rows.
    private var notableToggle: some View {
        Button {
            notableOnly.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Notable")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(notableOnly ? Brand.Color.bgPrimary : Brand.Color.ledgerGold)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                notableOnly ? Brand.Color.ledgerGold : Brand.Color.ledgerGold.opacity(0.12),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(Brand.Color.ledgerGold.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Notable planes only")
        .accessibilityAddTraits(notableOnly ? [.isButton, .isSelected] : .isButton)
    }

    /// Custom field rather than `.searchable`: that modifier attaches to the
    /// Hangar's NavigationStack, so it would show over Sets and Trophies too.
    private func searchField(showsNotableToggle: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Brand.Color.textTertiary)
            TextField(
                "",
                text: $query,
                // The Notable toggle takes a third of the field, so the
                // long hint would be cut mid-word beside it.
                prompt: Text(showsNotableToggle
                             ? "Search catches"
                             : "Search callsign, airline, aircraft, tier")
                    .foregroundStyle(Brand.Color.textTertiary)
            )
            .font(Brand.Font.body)
            .foregroundStyle(Brand.Color.textPrimary)
            .tint(Brand.Color.cyan)
            .accessibilityLabel("Search catches")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Brand.Color.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            if showsNotableToggle {
                notableToggle
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, showsNotableToggle ? 8 : 12)
        .padding(.vertical, showsNotableToggle ? 7 : 10)
        .background(
            Brand.Color.bgElevated,
            in: RoundedRectangle(cornerRadius: Brand.Radius.row)
        )
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private var deleteAlertTitle: String {
        guard let row = rowToDelete else { return "" }
        let cs = row.mostRecent.callsign?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? row.icao24
        return "Delete catch of \(cs)?"
    }

    /// Deletes only the catch the cell shows (`mostRecent`); earlier
    /// catches of the same airframe stay (see CatchDeletion).
    private func performDelete(row: HangarRow) {
        CatchDeletion.delete(row.mostRecent, in: modelContext)
        rowToDelete = nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
