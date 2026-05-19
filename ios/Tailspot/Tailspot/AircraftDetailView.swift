//
//  AircraftDetailView.swift
//  Tailspot
//
//  Read-only inspection sheet shown when the user taps the locked
//  label in the AR view. Surfaces every field we have, including
//  per-icao24 metadata (manufacturer / model / registration /
//  operator) fetched lazily from OpenSky on first appearance via
//  ADSBManager.metadata(for:). Repeated taps on the same plane hit
//  the in-memory MetadataCache.
//
//  Catching is now auto-only — there is no longer a "Catch this
//  plane" button here. A 3s sustained tap-pin on the AR view fires
//  the catch + camera-photo capture. The path lives in `ContentView`.
//

import SwiftUI
import CoreLocation

struct AircraftDetailView: View {
    let observed: ObservedAircraft
    let manager: ADSBManager
    /// Observer's location at the moment the sheet was presented.
    /// Kept on the value type because future per-tap actions might
    /// need it; currently unused by this view.
    let observerLocation: CLLocation?

    @Environment(\.dismiss) private var dismiss

    @State private var metadata: AircraftMetadata?
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            List {
                Section("Identity") {
                    row("Callsign",     observed.aircraft.callsign ?? "—")
                    row("ICAO24",       observed.aircraft.icao24)
                    row("Country",      observed.aircraft.originCountry)
                    row("Registration", metadata?.registration ?? "—")
                    row("Manufacturer", metadata?.manufacturerName ?? "—")
                    row("Model",        metadata?.model ?? "—")
                    row("Operator",     metadata?.operatorName ?? "—")
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
                    Text(footerText)
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
            }
            .navigationTitle(observed.aircraft.callsign ?? observed.aircraft.icao24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard !didLoad else { return }
                didLoad = true
                metadata = await manager.metadata(for: observed.aircraft.icao24)
            }
        }
    }

    private var footerText: String {
        if metadata == nil && didLoad {
            return "OpenSky has no record for this aircraft. Origin/destination still requires a separate data source (see PLAN.md)."
        }
        return "Origin/destination requires a data source beyond OpenSky's /states/all. See PLAN.md."
    }

    // MARK: - Formatting

    private var altitudeText: String {
        let m  = Int(observed.aircraft.altitudeMeters.rounded())
        let ft = Int((observed.aircraft.altitudeMeters * 3.28084).rounded())
        return "\(ft.formatted(.number)) ft (\(m.formatted(.number)) m)"
    }

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
            Text(value).foregroundStyle(Brand.Color.textSecondary)
        }
    }
}
