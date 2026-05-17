//
//  AircraftDetailView.swift
//  Tailspot
//
//  Detail sheet shown when the user taps an aircraft's reticle in the AR
//  view. Surfaces every field we have, including per-icao24 metadata
//  (manufacturer / model / registration / operator) fetched lazily
//  from OpenSky on first appearance via ADSBManager.metadata(for:).
//  Repeated taps on the same plane hit the in-memory MetadataCache.
//
//  Also the place the user "catches" a plane — the green button at
//  the bottom inserts a Catch SwiftData row capturing what we know
//  right now (callsign, metadata snapshot, observer pose, slant
//  distance). v1 lets you catch the same plane multiple times; the
//  Hangar view (PLAN §9 #7) will handle dedupe / grouping.
//

import SwiftUI
import SwiftData
import CoreLocation
import os

struct AircraftDetailView: View {
    let observed: ObservedAircraft
    let manager: ADSBManager
    /// Observer's location at the moment the sheet was presented. We
    /// stash it on the Catch so the Hangar can show "where you saw
    /// this plane from." nil → button is disabled (no fix yet).
    let observerLocation: CLLocation?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var metadata: AircraftMetadata?
    @State private var didLoad = false
    @State private var caughtCount: Int = 0

    var body: some View {
        NavigationStack {
            List {
                catchSection

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
            .task {
                guard !didLoad else { return }
                didLoad = true
                metadata = await manager.metadata(for: observed.aircraft.icao24)
            }
            // Haptic on each catch; the trigger value being a counter
            // (not a Bool) lets multiple consecutive catches each fire.
            .sensoryFeedback(.success, trigger: caughtCount)
        }
    }

    // MARK: - Catch action

    private var catchSection: some View {
        Section {
            Button(action: catchTapped) {
                HStack {
                    Spacer()
                    Image(systemName: "scope")
                    Text("Catch this plane")
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(observerLocation == nil)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
    }

    private func catchTapped() {
        guard let loc = observerLocation else { return }
        let c = Catch(
            icao24: observed.aircraft.icao24,
            callsign: observed.aircraft.callsign,
            model: metadata?.model,
            manufacturer: metadata?.manufacturerName,
            operatorName: metadata?.operatorName,
            caughtAt: Date(),
            observerLat: loc.coordinate.latitude,
            observerLon: loc.coordinate.longitude,
            slantDistanceMeters: observed.slantDistanceMeters
        )
        modelContext.insert(c)
        do {
            try modelContext.save()
        } catch {
            Log.adsb.error("Catch save failed for \(observed.aircraft.icao24, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        caughtCount += 1
        Log.adsb.notice("Caught \(observed.aircraft.icao24, privacy: .public) (callsign=\(observed.aircraft.callsign ?? "—", privacy: .public))")
        dismiss()
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
            Text(value).foregroundStyle(.secondary)
        }
    }
}
