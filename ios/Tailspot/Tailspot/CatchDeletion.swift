//
//  CatchDeletion.swift
//  Tailspot
//
//  Deleting one catch, the single path both Hangar delete sites use (the
//  row's long-press menu and the detail screen's trash button).
//
//  It deletes exactly the catch you are looking at. A Hangar row can hold
//  several catches of one airframe (Southwest flies one 737 under many
//  flight numbers), and both surfaces show only the most recent one, so
//  until 2026-11-05 a delete silently took the earlier, unseen catches and
//  their photos with it.
//

import Foundation
import SwiftData
import os

enum CatchDeletion {
    /// Removes `c`'s photo file, its SwiftData row, and (queued, retried
    /// offline) its server copy. Returns false if the local save failed.
    /// `deleteRemotely` is injectable so tests don't touch the network.
    @discardableResult
    static func delete(
        _ c: Catch,
        in context: ModelContext,
        deleteRemotely: ([String]) -> Void = CatchDeletionSync.deleteRemotely
    ) -> Bool {
        // Read everything we need BEFORE the delete — a deleted model's
        // properties can't be read afterwards.
        let serverUuid = c.serverUuid
        let icao24 = c.icao24
        // Drop the photo with the row: deleting only the model orphaned
        // JPEGs in Documents/catches, and rows pointing at dead files
        // rendered placeholder stripes.
        CatchPhotoStore.delete(filename: c.photoFilename)
        context.delete(c)
        var saved = true
        do { try context.save() } catch {
            saved = false
            Log.adsb.error("Catch delete failed for \(icao24, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        // Off the server too, so it stops counting toward the leaderboard
        // and challenge scores.
        if let serverUuid { deleteRemotely([serverUuid]) }
        return saved
    }
}
