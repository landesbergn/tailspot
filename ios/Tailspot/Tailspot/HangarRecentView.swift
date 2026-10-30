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

    /// `initialQuery` exists for the snapshot harness; the app passes nothing.
    init(initialQuery: String = "") {
        _query = State(initialValue: initialQuery)
    }
    /// Memoizes the grouped rows AND the first-of-type row set across body
    /// evals — this body used to run the full HangarGrouping pass TWICE per
    /// eval (isEmpty + ForEach), on every segment switch. See
    /// HangarDerivedCache. The pair is derived in one pass so the sparkle
    /// set can never drift from the rows it describes.
    @State private var cache = DerivedCacheBox<([HangarRow], Set<String>)>()

    private var derived: ([HangarRow], Set<String>) {
        cache.value(for: CatchFingerprint.of(catches)) {
            let rows = HangarGrouping.group(catches, by: .recent).first?.rows ?? []
            return (rows, HangarGrouping.firstOfTypeRowIDs(rows: rows, allCatches: catches))
        }
    }

    var body: some View {
        // Read ONCE per body. Even a cache hit re-hashes every catch
        // (CatchFingerprint), and the ForEach row closure below runs again
        // each time a row scrolls into view. These used to be computed
        // properties read inside that closure, so every row coming on screen
        // hashed the whole Hangar: the Recent-list scroll stutter (2026-10),
        // worst on the biggest Hangars. Locals are captured by value instead.
        let (allRows, firstOfTypeIDs) = derived
        // The field only exists past five cards. Gate the FILTER on the same
        // check, so deleting down to five can't leave an invisible query
        // hiding cards.
        let showsSearch = allRows.count > HangarGrouping.searchMinRowsExclusive
        let rows = showsSearch ? HangarGrouping.search(allRows, query: query) : allRows
        return VStack(spacing: 0) {
            if showsSearch {
                searchField
            }
            ScrollView {
                if allRows.isEmpty {
                    Text("No catches yet")
                        .font(Brand.Font.body)
                        .foregroundStyle(Brand.Color.textTertiary)
                        .padding(.top, 32)
                } else if rows.isEmpty {
                    Text("No catches match \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}")
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

    /// Custom field rather than `.searchable`: that modifier attaches to the
    /// Hangar's NavigationStack, so it would show over Sets and Trophies too.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Brand.Color.textTertiary)
            TextField(
                "",
                text: $query,
                prompt: Text("Search callsign, airline, aircraft")
                    .foregroundStyle(Brand.Color.textTertiary)
            )
            .font(Brand.Font.body)
            .foregroundStyle(Brand.Color.textPrimary)
            .tint(Brand.Color.cyan)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        if row.count == 1 {
            return "Delete catch of \(cs)?"
        }
        return "Delete all \(row.count) catches of \(cs)?"
    }

    private func performDelete(row: HangarRow) {
        // Capture the server ids BEFORE the delete (see CatchDeletionSync).
        let serverUuids = row.allCatches.compactMap(\.serverUuid)
        for c in row.allCatches {
            // Drop the photo file with the row — deleting only the
            // model row orphaned JPEGs in Documents/catches forever.
            CatchPhotoStore.delete(filename: c.photoFilename)
            modelContext.delete(c)
        }
        do { try modelContext.save() } catch {
            Log.adsb.error("Hangar delete failed for \(row.icao24, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        CatchDeletionSync.deleteRemotely(serverUuids)
        rowToDelete = nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
