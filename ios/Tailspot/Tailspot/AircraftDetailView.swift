//
//  AircraftDetailView.swift
//  Tailspot
//
//  Detail sheet shown when the user taps an aircraft's reticle in the AR
//  view. Surfaces every field we have for the aircraft. Two fields we
//  don't have yet (aircraft type + origin/destination) render as "—" with
//  a footer note explaining what's needed to fill them in.
//
//  Pattern: NavigationStack inside a sheet — gives us the title bar plus
//  a "Done" button. Using `List` with `Section` for the sectioned look.
//

import SwiftUI

struct AircraftDetailView: View {
    let observed: ObservedAircraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Identity") {
                    row("Callsign", observed.aircraft.callsign ?? "—")
                    row("ICAO24",   observed.aircraft.icao24)
                    row("Country",  observed.aircraft.originCountry)
                    row("Aircraft type", "—")
                }

                Section("Flight") {
                    row("Origin → Destination", "—")
                    row("Altitude", altitudeText)
                    row("Speed",    speedText)
                    row("Track",    trackText)
                }

                Section("Geometry from you") {
                    row("Bearing",         String(format: "%.1f°", observed.bearingDeg))
                    row("Elevation",       String(format: "%+.1f°", observed.elevationDeg))
                    row("Slant distance",  String(format: "%.1f km", observed.slantDistanceMeters / 1000))
                    row("Ground distance", String(format: "%.1f km", observed.groundDistanceMeters / 1000))
                }

                Section {
                    Text("Aircraft type and origin/destination aren't yet available — they require additional data sources beyond OpenSky's free /states/all endpoint. See PLAN.md.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(observed.aircraft.callsign ?? observed.aircraft.icao24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Formatting

    /// Altitude: feet primary, meters in parens. Whole-number formatted
    /// with locale-appropriate thousand separators (`34,449 ft`).
    private var altitudeText: String {
        let m  = Int(observed.aircraft.altitudeMeters.rounded())
        let ft = Int((observed.aircraft.altitudeMeters * 3.28084).rounded())
        return "\(ft.formatted(.number)) ft (\(m.formatted(.number)) m)"
    }

    /// Speed: mph primary, knots in parens.
    private var speedText: String {
        guard let mps = observed.aircraft.velocityMps else { return "—" }
        let mph = mps * 2.23694
        let kt  = mps * 1.94384
        return String(format: "%.0f mph (%.0f kt)", mph, kt)
    }

    private var trackText: String {
        guard let t = observed.aircraft.trackDeg else { return "—" }
        return String(format: "%.0f°", t)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
