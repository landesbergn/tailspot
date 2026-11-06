//
//  HangarRowDeletion.swift
//  Tailspot
//
//  The one way to delete a Hangar row. Both delete buttons (the card's
//  long-press menu and the catch detail screen) call this, so they can't
//  drift apart again: until 2026-11-05 only the detail screen fired
//  `catch_deleted`, and the delete metric missed most real deletes.
//
//  Order matters:
//    1. analytics, while the row's catches can still be read;
//    2. capture the server uuids (a deleted model's properties can't be
//       read afterwards);
//    3. delete each catch and its photo file, then save;
//    4. queue the server delete, even if the save failed: the rows are
//       already gone from the context, and leaving the server copy is the
//       bug this whole path exists to prevent.
//

import Foundation
import SwiftData

enum HangarRowDeletion {
    /// `fireEvent` / `deleteRemotely` are test seams; nil means the real
    /// analytics event and server delete. (Defaults live in the body, not as
    /// default-argument closures: those are built outside the main actor,
    /// where these MainActor calls aren't allowed.)
    static func delete(
        _ row: HangarRow,
        context: ModelContext,
        fireEvent: ((HangarRow) -> Void)? = nil,
        deleteRemotely: (([String]) -> Void)? = nil
    ) throws {
        if let fireEvent {
            fireEvent(row)
        } else {
            CatchTelemetry.fireDeleted(
                icao24: row.icao24,
                count: row.count,
                rarity: row.allCatches.first?.resolvedRarity.rawValue,
                source: .hangarDelete
            )
        }
        let serverUuids = row.allCatches.compactMap(\.serverUuid)
        for c in row.allCatches {
            // Drop the photo file with the row, or orphaned JPEGs pile up
            // in Documents/catches forever.
            CatchPhotoStore.delete(filename: c.photoFilename)
            context.delete(c)
        }
        defer {
            if let deleteRemotely { deleteRemotely(serverUuids) }
            else { CatchDeletionSync.deleteRemotely(serverUuids) }
        }
        try context.save()
    }
}
