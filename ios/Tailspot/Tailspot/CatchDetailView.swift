//
//  CatchDetailView.swift
//  Tailspot
//
//  Read-only detail for a single Catch row in the Hangar. The Catch
//  is a frozen snapshot of what we knew at catch time — we don't try
//  to re-fetch live metadata or position here; that would make a
//  catch from yesterday look different tomorrow, which defeats the
//  point of a collection.
//

import SwiftUI

struct CatchDetailView: View {
    let catchRecord: Catch

    var body: some View {
        List {
            Section("Identity") {
                row("Callsign", catchRecord.callsign ?? "—")
                row("ICAO24",   catchRecord.icao24)
                row("Aircraft", aircraftText)
                row("Operator", catchRecord.operatorName ?? "—")
            }

            Section("When & where") {
                row("Caught",          catchRecord.caughtAt.formatted(date: .abbreviated, time: .shortened))
                row("From",            String(format: "%.4f°, %.4f°", catchRecord.observerLat, catchRecord.observerLon))
                row("Slant distance",  String(format: "%.1f km", catchRecord.slantDistanceMeters / 1000))
            }
        }
        .navigationTitle(catchRecord.callsign?.trimmedNonEmpty ?? catchRecord.icao24)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var aircraftText: String {
        let key = HangarGrouping.key(for: catchRecord, mode: .aircraftType)
        return key == HangarGrouping.unknownTitle ? "—" : key
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
