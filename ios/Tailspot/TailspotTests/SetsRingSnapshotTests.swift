//
//  SetsRingSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the Sets browser row (TailCardSnapshotTests
//  pattern): renders SetCompletionCard across the Dynamic Type ladder so the
//  completion ring's percentage label can be eyeballed at the sizes a
//  larger-text user actually runs. Regression for the 2026-09-13 report:
//  at bigger text settings "100%" wrapped to "100 / %" inside the fixed
//  44 pt ring. NOT an assertion test: it writes PNGs to
//  /private/tmp/tailspot_snaps and passes. Review the PNGs after running.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
import os
@testable import Tailspot

@MainActor
@Suite("Sets ring snapshots (visual pass)")
struct SetsRingSnapshotTests {

    @Test func renderSetsRowsAcrossDynamicType() {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sizes: [(String, DynamicTypeSize)] = [
            ("large", .large),                       // the default
            ("xxxLarge", .xxxLarge),                 // top of the standard slider
            ("ax1", .accessibility1),
            ("ax3", .accessibility3),
            ("ax5", .accessibility5),
        ]
        let sets = CardSets.all
        let longest = sets.max(by: { $0.title.count < $1.title.count })!
        // Three rows: a 100% set (the reported wrap), a two-digit one, and a
        // long title so truncation against the ring is visible too.
        let rows: [(CardSet, (caught: Int, total: Int))] = [
            (sets[0], (caught: sets[0].entries.count, total: sets[0].entries.count)),
            (sets[1], (caught: max(1, sets[1].entries.count - 1), total: sets[1].entries.count)),
            (longest, (caught: 1, total: 2)),
        ]

        for (name, size) in sizes {
            let view = VStack(spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    SetCompletionCard(set: row.0, progress: row.1)
                }
            }
            .padding(16)
            .frame(width: 393)      // iPhone 16 logical width
            .background(Brand.Color.bgPrimary)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, size)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            guard let ui = renderer.uiImage, let png = ui.pngData() else {
                Log.ui.error("Sets ring snapshot render failed: \(name, privacy: .public)")
                continue
            }
            try? png.write(to: dir.appendingPathComponent("sets_ring_\(name).png"))
        }
        #expect(true)
    }
}
#endif
