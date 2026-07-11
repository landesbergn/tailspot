//
//  HangarRestoreSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the Hangar restore prompt (PLAN §9 #7): renders
//  each phase of `HangarRestorePromptView` — offer (N=1 and N=500 for copy
//  wrapping), restoring, done, failed — as static frames. NOT an assertion
//  test: it writes PNGs to /private/tmp/tailspot_snaps and passes. Review
//  the PNGs.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import Tailspot

@MainActor
@Suite("Hangar restore snapshots (visual pass)")
struct HangarRestoreSnapshotTests {

    @Test func renderRestorePromptPhases() throws {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let screen = CGSize(width: 393, height: 852)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)
        let context = ModelContext(container)
        let center = TrophyUnlockCenter(
            ledger: UserDefaultsTrophyLedger(defaults: UserDefaults(suiteName: "snap.restore")!)
        )

        func frame(_ phase: HangarRestoreManager.Phase, name: String) {
            let manager = HangarRestoreManager()
            manager._setPhaseForSnapshot(phase)
            let view = HangarRestorePromptView(manager: manager, context: context, unlockCenter: center)
                .frame(width: screen.width, height: screen.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            // Pure side-effect harness — never fail CI over a render/write hiccup.
            guard let img = renderer.uiImage, let data = img.pngData() else { return }
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
        }

        frame(.offer(total: 62), name: "restore_offer_62")
        frame(.offer(total: 1), name: "restore_offer_1")     // singular copy
        frame(.offer(total: 500), name: "restore_offer_500") // widest count
        frame(.restoring, name: "restore_restoring")
        frame(.done(restored: 62), name: "restore_done_62")
        frame(.failed(total: 62), name: "restore_failed")
    }
}
#endif
