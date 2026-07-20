//
//  HangarRecentView.swift
//  Tailspot
//
//  Recent-view body for the Hangar sheet — a chronological feed of the
//  dedup'd catches, newest-first, each rendered as the shared TailCard
//  (callsign · airline · date · location). No filters and no rarity/type
//  chrome; that's a Sets-view affordance and pre-redesign noise
//  respectively. Spec § 6.
//

import SwiftUI
import SwiftData
import os

struct HangarRecentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    @State private var rowToDelete: HangarRow?
    /// Memoizes the grouped rows across body evals — this body used to run
    /// the full HangarGrouping pass TWICE per eval (isEmpty + ForEach), on
    /// every segment switch. See HangarDerivedCache.
    @State private var cache = DerivedCacheBox<[HangarRow]>()

    private var rows: [HangarRow] {
        cache.value(for: CatchFingerprint.of(catches)) {
            HangarGrouping.group(catches, by: .recent).first?.rows ?? []
        }
    }

    var body: some View {
        ScrollView {
            if rows.isEmpty {
                Text("No catches yet")
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .padding(.top, 32)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(rows) { row in
                        NavigationLink(value: row) {
                            TailCard(row: row, showPoints: true)
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
        for c in row.allCatches {
            // Drop the photo file with the row — deleting only the
            // model row orphaned JPEGs in Documents/catches forever.
            CatchPhotoStore.delete(filename: c.photoFilename)
            modelContext.delete(c)
        }
        do { try modelContext.save() } catch {
            Log.adsb.error("Hangar delete failed for \(row.icao24, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        rowToDelete = nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
