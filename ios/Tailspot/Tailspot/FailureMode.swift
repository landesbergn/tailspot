//
//  FailureMode.swift
//  Tailspot
//
//  The catch-engine failure taxonomy and its offline scoring. A recorded
//  session carries tap-pin ground truth (the plane the observer actually
//  saw); scoring compares that against what the app's projection /
//  visibility / lock-on did, and classifies each divergence into one of
//  the eight failure modes. This is the measurement half of the
//  regression bench — it does not change the engine.
//
//  Scope (plan KTD2): only the modes a pinned replay can prove are scored
//  here — missed, spatial offset, lag, mis-association, and a partial
//  phantom proxy. Ghost (needs an empty-sky report), missing-identity
//  (needs the resolved catch row) and misidentification (no field ground
//  truth) are out of this pass; their cases still exist so the schema is
//  stable. Full phantom (a *catch* on a not-in-view plane) lives in the
//  catch flow, not the replay tick stream — see the note on phantom below.
//

import Foundation
import CoreGraphics

/// The eight failure modes from the origin taxonomy. Stable schema:
/// all eight exist even though only the geometric subset is scored today.
nonisolated enum FailureMode: String, CaseIterable, Sendable, Codable {
    case missedPlane        // 1 · Detection — visible, no catchable label
    case ghostTarget        // 2 · Detection — label on empty sky (deferred)
    case spatialOffset      // 3 · Tracking — label near but off the plane
    case lag                // 4 · Tracking — label trails a moving plane
    case misAssociation     // 5 · Identity — locked the wrong nearby plane
    case misidentification  // 6 · Identity — wrong type/airline (out of reach)
    case missingIdentity    // 7 · Identity — "Unknown operator" (deferred)
    case phantomCapture     // 8 · Validity — engine committed to a plane not in view
}

/// One failure occurrence at one tick.
nonisolated struct FailureModeFinding: Equatable, Sendable {
    let mode: FailureMode
    /// Index into the session's ticks (0-based) — locates the moment.
    let tickIndex: Int
    let timestamp: Date
    /// The aircraft involved: the pinned plane for missed/offset/lag, the
    /// wrongly-targeted plane for mis-association/phantom.
    let icao24: String?
    /// Human-readable ground-truth delta ("78 px off pin"; "locked abc,
    /// expected def") — the locating detail a diagnosis surfaces.
    let detail: String
}

/// Whole-session failure scoring.
nonisolated struct FailureModeReport: Equatable, Sendable {
    let findings: [FailureModeFinding]

    var isClean: Bool { findings.isEmpty }
    var modesFired: Set<FailureMode> { Set(findings.map(\.mode)) }
    func findings(for mode: FailureMode) -> [FailureModeFinding] {
        findings.filter { $0.mode == mode }
    }
}

// MARK: - Scoring tuning

/// Thresholds for the geometric modes. Defaults are starting points;
/// tune against the pin recordings in `FieldReplays/` — do not change
/// without new pin-protocol data (mirrors the `ADSBManager` visibility
/// constants convention of documenting the field basis inline).
nonisolated enum FailureModeThresholds {
    /// A pinned plane whose projected label sits farther than this from
    /// the tap point is "off the plane" (mode 3). The live bracket box
    /// was 56–140 pt, so ~60 pt reads as clearly not on it.
    static let offsetPx: CGFloat = 60
    /// Tick-over-tick offset growth above this reads as temporal lag
    /// (mode 4) rather than a static offset.
    static let lagGrowthPx: CGFloat = 20
}

// MARK: - Analyzer scoring

@MainActor
extension ReplayAnalyzer {
    /// Score a recorded session against the geometric failure modes. Runs
    /// the standard analysis, then walks the same timestamp-ordered events
    /// to recover per-tick pin state, and compares ground truth (the pin)
    /// against app behavior per tick.
    func scoreFailureModes(_ events: [ReplayEvent]) -> FailureModeReport {
        let report = analyze(events)
        let pinStates = Self.pinStatePerTick(events)

        var findings: [FailureModeFinding] = []
        // Per-icao previous offset, for lag detection across pinned ticks.
        var lastOffset: [String: CGFloat] = [:]

        for (i, tick) in report.ticks.enumerated() {
            let pin = i < pinStates.count ? pinStates[i] : nil
            let visible = Set(tick.aircraft.filter(\.isVisible).map(\.icao24))

            // Phantom (8): the engine *committed* a lock (not the brief
            // sticky grace period) on an icao that isn't visible. This is a
            // partial proxy — the live app's true phantom is a catch on a
            // not-in-view plane, which lives in the catch flow, not the tick
            // stream. Sticky-on-gone is the engine's intended flicker grace,
            // so it is deliberately NOT flagged.
            if let locked = Self.committedLockIcao(tick.lockState), !visible.contains(locked) {
                findings.append(.init(mode: .phantomCapture, tickIndex: i,
                    timestamp: tick.timestamp, icao24: locked,
                    detail: "engine locked \(locked), which is not visible"))
            }

            guard let pin else {
                lastOffset.removeAll()   // pin cleared → restart lag history
                continue
            }

            let pinned = tick.aircraft.first { $0.icao24 == pin.icao }

            // Missed (1): the pinned plane is in the data but the app filtered
            // it below the visibility tier — the user saw it, the app didn't.
            if let pinned, !pinned.isVisible {
                findings.append(.init(mode: .missedPlane, tickIndex: i,
                    timestamp: tick.timestamp, icao24: pin.icao,
                    detail: String(format: "pinned %@ not visible (%.1f km @ %+.1f°)",
                                   pin.icao, pinned.slantDistanceMeters / 1000, pinned.elevationDeg)))
            }

            // Offset (3) + Lag (4): the pinned plane is visible and projected,
            // and the pin carries a tap point to compare against.
            if let pinned, pinned.isVisible, let pos = pinned.screenPosition,
               let px = pin.x, let py = pin.y {
                let offset = hypot(pos.x - CGFloat(px), pos.y - CGFloat(py))
                if offset > FailureModeThresholds.offsetPx {
                    findings.append(.init(mode: .spatialOffset, tickIndex: i,
                        timestamp: tick.timestamp, icao24: pin.icao,
                        detail: String(format: "%.0f px off pin", offset)))
                    if let prev = lastOffset[pin.icao],
                       offset - prev > FailureModeThresholds.lagGrowthPx {
                        findings.append(.init(mode: .lag, tickIndex: i,
                            timestamp: tick.timestamp, icao24: pin.icao,
                            detail: String(format: "offset grew %.0f→%.0f px", prev, offset)))
                    }
                }
                lastOffset[pin.icao] = offset
            }

            // Mis-association (5): the pinned plane (ground truth) is visible,
            // but the app's center-driven auto-pick — what the ambient/lock
            // path chooses *without* the pin — is a different visible plane.
            // The pin overrides the lock live, so we compare against the
            // auto-pick, not the pin-following lock state.
            if let pinned, pinned.isVisible,
               let appPick = tick.closestToCenterIcao24,
               appPick != pin.icao, visible.contains(appPick) {
                findings.append(.init(mode: .misAssociation, tickIndex: i,
                    timestamp: tick.timestamp, icao24: appPick,
                    detail: "center-pick \(appPick), expected \(pin.icao)"))
            }
        }

        return FailureModeReport(findings: findings)
    }

    /// The pinned icao + tap point active at each tick, in tick order.
    /// Walks events in the same timestamp order `analyze` uses, so index i
    /// aligns with `report.ticks[i]`.
    private static func pinStatePerTick(_ events: [ReplayEvent]) -> [(icao: String, x: Double?, y: Double?)?] {
        let ordered = events.sorted { eventTimestamp($0) < eventTimestamp($1) }
        var current: (icao: String, x: Double?, y: Double?)?
        var perTick: [(icao: String, x: Double?, y: Double?)?] = []
        for event in ordered {
            switch event {
            case .tapPin(let p): current = (p.icao24, p.x, p.y)
            case .unpin:         current = nil
            case .tick:          perTick.append(current)
            default:             break
            }
        }
        return perTick
    }

    /// Committed lock only — excludes the sticky grace period.
    private static func committedLockIcao(_ state: LockOnEngine.State) -> String? {
        if case .locked(let icao, _) = state { return icao }
        return nil
    }

    private static func eventTimestamp(_ event: ReplayEvent) -> Date {
        switch event {
        case .sessionStart(let s): return s.timestamp
        case .tick(let t):         return t.timestamp
        case .tapPin(let p):       return p.timestamp
        case .unpin(let u):        return u.timestamp
        case .emptyTap(let e):     return e.timestamp
        }
    }
}
