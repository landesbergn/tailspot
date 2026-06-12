//
//  CardModelRegistry.swift
//  Tailspot
//
//  Maps aircraft families → bundled OBJ resource names + per-model display
//  adjustments (scale/orientation) so the spike screen can hot-swap models
//  without touching SceneKit setup code.
//
//  nonisolated: pure data, no SwiftUI/MainActor dependency.
//
//  ── Fleet status (as of 2026-06-12) ───────────────────────────────────
//  SHIPPED (bundled OBJ):
//    • jumbo      → Boeing747.obj  (Miha Lunar, CC-BY via Poly Pizza)
//    • helicopter → FleetHelicopter.obj  (Poly by Google, CC-BY via Poly Pizza)
//
//  PENDING MANUAL DOWNLOAD (Sketchfab requires login — login-walled):
//    • narrowbody → Mauro3D "Low Poly Airliner"
//      https://sketchfab.com/3d-models/low-poly-airliner-f06d488f08764e3ca26f2917d4053c69
//      Download to tools/cards/3d/incoming/ as narrowbody-source.glb, then
//      run tools/cards/3d/convert_fleet.py to generate FleetNarrowbody.obj
//    • widebody   → Mauro3D "Low Poly Boeing 787 Dreamliner"
//      https://sketchfab.com/3d-models/low-poly-boeing-787-dreamliner-50baa323fabd49a6b861096cb88e5c25
//      Download as widebody-source.glb
//    • gaProp     → scailman "Low Poly Plane" — ALSO VERIFY LICENSE before use
//      https://sketchfab.com/3d-models/low-poly-plane-76230052903540e9aeb46b7db35329e4
//      Download as gaprop-source.glb
//
//  COMMISSION GAPS (no model yet):
//    regionalJet, bizjet, turboprop, militaryFighter, militaryTransport
//
//  ── Material normalization (applied in Card3DSpikeView) ───────────────
//  All models use flat-shaded `.constant` lighting with a shared palette:
//    body  → near-white (#F5F5F5, slight diffuse)
//    trim  → mid-gray (#595959)
//    detail → cool-tinted blue-gray (#8AAABB)
//  This overrides per-artist OBJ/MTL material assignments so the fleet
//  reads as a coherent family rather than six different art styles.
//

import SceneKit

// MARK: - AircraftFamily

/// 3D-card aircraft families. Each maps to one bundled OBJ (when available).
/// Extensible: add new cases and set `isAvailable: false` until the model ships.
nonisolated enum AircraftFamily: String, CaseIterable, Identifiable {
    case jumbo
    case narrowbody
    case widebody
    case gaProp
    case helicopter
    // Commission gaps — no model yet; shows locked/placeholder treatment
    case regionalJet
    case bizjet
    case turboprop
    case militaryFighter
    case militaryTransport

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jumbo:             return "Jumbo"
        case .narrowbody:        return "Narrowbody"
        case .widebody:          return "Widebody"
        case .gaProp:            return "GA / Prop"
        case .helicopter:        return "Helicopter"
        case .regionalJet:       return "Regional Jet"
        case .bizjet:            return "Business Jet"
        case .turboprop:         return "Turboprop"
        case .militaryFighter:   return "Fighter"
        case .militaryTransport: return "Transport"
        }
    }

    /// Short chip label (fits horizontal chips without truncation).
    var chipLabel: String {
        switch self {
        case .jumbo:             return "JUMBO"
        case .narrowbody:        return "NARROW"
        case .widebody:          return "WIDE"
        case .gaProp:            return "GA"
        case .helicopter:        return "HELI"
        case .regionalJet:       return "REGIONAL"
        case .bizjet:            return "BIZ"
        case .turboprop:         return "TURBO"
        case .militaryFighter:   return "FIGHTER"
        case .militaryTransport: return "MIL"
        }
    }
}

// MARK: - AircraftModelConfig

/// Per-family SceneKit display configuration.
nonisolated struct AircraftModelConfig {
    /// Bundled OBJ resource name (no extension), or `nil` when unavailable.
    /// `isAvailable` is derived from this.
    let resourceName: String?

    /// Uniform scale multiplier applied on top of the normalized 2.0-unit
    /// OBJ scale, in case a model needs additional in-scene sizing.
    /// 1.0 = no adjustment.
    let sceneKitScale: Float

    /// Euler angle tweak (radians) applied in addition to the hero pose
    /// from `Card3DSpikeView`. Use to correct per-model orientation
    /// differences that weren't fixable in the trimesh pipeline.
    /// Typically (0, 0, 0) once trimesh normalizes correctly.
    let orientationAdjustment: SCNVector3

    var isAvailable: Bool { resourceName != nil }

    static let unavailable = AircraftModelConfig(
        resourceName: nil,
        sceneKitScale: 1.0,
        orientationAdjustment: SCNVector3(0, 0, 0)
    )
}

// MARK: - CardModelRegistry

/// Maps each `AircraftFamily` to its display configuration.
///
/// SceneKit loads:
///   `Bundle.main.url(forResource: config.resourceName, withExtension: "obj")`
///
/// Orientation normalization notes (trimesh pipeline, convert_fleet.py):
///   • All OBJs are centered at origin, scaled so max extent = 2.0 units.
///   • Y is "up" in the trimesh output (GLB Y-up convention preserved).
///   • Nose-to-tail runs along the Z axis (largest or second-largest extent).
///   • `orientationAdjustment` corrects any model that doesn't sit nose-forward
///     after normalization — check the SceneKit live view or the rendered
///     stills in tools/cards/3d/output/.
///
nonisolated enum CardModelRegistry {
    static func config(for family: AircraftFamily) -> AircraftModelConfig {
        switch family {

        case .jumbo:
            // Boeing 747 — Miha Lunar, CC-BY 3.0 via Poly Pizza
            // Z is nose-to-tail (2.0 units). Y is up. No adjustment needed.
            return AircraftModelConfig(
                resourceName: "Boeing747",
                sceneKitScale: 1.0,
                orientationAdjustment: SCNVector3(0, 0, 0)
            )

        case .helicopter:
            // "Helicopter" by Poly by Google, CC-BY 3.0 via Poly Pizza
            // X is the dominant axis (rotor diameter ~2.0 units). Y is up.
            // The helicopter model's nose is along X+; rotate 90° about Y
            // so nose points toward the camera (Z+) in the hero pose.
            return AircraftModelConfig(
                resourceName: "FleetHelicopter",
                sceneKitScale: 1.2,   // helicopter is compact — boost slightly
                orientationAdjustment: SCNVector3(0, Float.pi * 0.5, 0)
            )

        case .narrowbody:
            // PENDING: Mauro3D "Low Poly Airliner" from Sketchfab (login-walled)
            // Download → tools/cards/3d/incoming/narrowbody-source.glb
            // Run convert_fleet.py → FleetNarrowbody.obj → ios/Tailspot/Tailspot/
            return .unavailable

        case .widebody:
            // PENDING: Mauro3D "Low Poly Boeing 787 Dreamliner" from Sketchfab
            // Download → tools/cards/3d/incoming/widebody-source.glb
            return .unavailable

        case .gaProp:
            // PENDING: scailman "Low Poly Plane" from Sketchfab
            // IMPORTANT: verify CC-BY license on the Sketchfab page before shipping
            // Download → tools/cards/3d/incoming/gaprop-source.glb
            return .unavailable

        case .regionalJet, .bizjet, .turboprop, .militaryFighter, .militaryTransport:
            // Commission gaps — no model commissioned yet.
            return .unavailable
        }
    }
}
