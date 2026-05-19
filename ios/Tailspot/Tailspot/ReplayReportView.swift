//
//  ReplayReportView.swift
//  Tailspot
//
//  Debug viewer for a recorded replay session. Takes a file URL,
//  runs it through `ReplayAnalyzer`, and renders the human-readable
//  `describe()` output in a scrollable monospaced view.
//
//  Presented as a sheet from ContentView's debug overlay via the
//  "Analyze last recording" row. The recorder's
//  `mostRecentRecording()` helper finds the file to feed in — no
//  in-app file picker yet (the user's normal use case is "I just
//  stopped recording, what did the engine see?").
//

import SwiftUI

struct ReplayReportView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var summary: String = ""
    @State private var loading: Bool = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Analyzing…")
        } else if let error {
            ContentUnavailableView(
                "Couldn't load replay",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else {
            ScrollView {
                Text(summary)
                    .font(Brand.Font.hudData)
                    .foregroundStyle(Brand.Color.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private func load() async {
        do {
            // ReplayAnalyzer is @MainActor; analyze is fast even for
            // ~hundreds of ticks, so we don't bother offloading.
            let report = try ReplayAnalyzer().analyze(fileURL: url)
            summary = report.describe()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
