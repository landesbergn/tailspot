//
//  GuidedCatchOverlay.swift
//  Tailspot
//
//  Viewfinder chrome for the guided first-catch mode (plan U2): the step
//  banner, the edge steering chevron + tag, and the capture pulse ring.
//  All display-only (`allowsHitTesting(false)` at the mount) — the engine
//  in GuidedCatch.swift owns every decision; this file just draws it.
//
//  Renders inside ContentView's 30 Hz TimelineView ZStack, so nothing
//  here adds a body chain link (the type-check-budget rule). Error-wins:
//  ContentView derives no step at all while `adsb.lastError` is set, so
//  none of this can steer on stale extrapolated positions.
//

import SwiftUI

/// Cross-frame steering-target memory for the engine's hysteresis.
/// Reference type held in `@State` so per-frame writes from the render
/// closure don't invalidate the view (the `visualConfirm.updateTarget`
/// precedent).
final class GuidedTargetHolder {
    var icao24: String?
}

struct GuidedCatchChrome: View {
    let step: GuidedCatchStep
    let screenSize: CGSize
    /// Debug forced-mode badge (R10) — visibly marks a lying screen.
    var forced: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            if let line = bannerLine {
                GuidedBanner(text: line.0, subtext: line.1, forced: forced)
            }
            if case .find(let steer?) = step {
                GuidedSteeringCue(steer: steer, screenSize: screenSize)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height, alignment: .top)
    }

    /// Coaching copy per step, dried voice. `nil` renders no banner:
    /// `.scanning` defers to the existing SCANNING SKY… pill, and
    /// `.calibrate` defers to the existing tappable compass-caution badge
    /// (one surface per condition — KD5/KTD5; the badge is the tested
    /// calibration affordance, so the guided banner yields to it).
    private var bannerLine: (String, String?)? {
        switch step {
        case .scanning, .calibrate:
            return nil
        case .goOutside:
            return ("Go outside for your first catch.", "Planes need open sky.")
        case .quietSky:
            return ("Quiet sky — nothing catchable in range.",
                    "The app's working. Come back when you hear one.")
        case .find(let steer):
            if let steer, steer.isBehind {
                return ("A plane's behind you — turn around.", nil)
            }
            return ("A plane's in range — turn until it's in view.", nil)
        case .center:
            return ("There it is. Center it in your frame.", nil)
        case .capture:
            return ("Locked. Tap CAPTURE.", nil)
        }
    }
}

/// The coaching capsule. Mirrors `indoorHintBanner`'s shape (mono 12
/// semibold on `bgElevated`) with a cyan border for guided identity;
/// sits in the same top slot (`.padding(.top, 60)`, below the compass /
/// zoom affordances).
private struct GuidedBanner: View {
    let text: String
    let subtext: String?
    let forced: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                if forced {
                    Text("FORCED")
                        .font(Brand.Font.mono(size: 9, weight: .bold))
                        .tracking(0.8)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Brand.Color.alertAdvisory, in: .capsule)
                        .foregroundStyle(Brand.Color.bgPrimary)
                }
                Text(text)
                    .font(Brand.Font.mono(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
            }
            if let subtext {
                Text(subtext)
                    .font(Brand.Font.mono(size: 10))
                    .foregroundStyle(Brand.Color.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Brand.Color.bgElevated.opacity(0.92), in: .rect(cornerRadius: Brand.Radius.row))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.row)
                .strokeBorder(Brand.Color.cyan.opacity(0.45), lineWidth: 1)
        )
        .padding(.top, 60)
        .padding(.horizontal, 24)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Edge chevron + compact tag pointing at the off-frame target. Mostly a
/// horizontal cue (left/right edge at ~40% height); a nearly-aimed target
/// that sits above the frame gets a top-center TILT UP cue instead.
private struct GuidedSteeringCue: View {
    let steer: GuidedSteering
    let screenSize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var needsTiltUp: Bool {
        abs(steer.turnDeg) < 20 && steer.elevationDeltaDeg > 10
    }
    private var pointsRight: Bool { steer.turnDeg > 0 }

    private var tagText: String {
        var parts: [String] = []
        if let name = steer.displayName, !name.isEmpty {
            parts.append(name.uppercased())
        }
        let km = steer.distanceMeters / 1_000
        parts.append(km >= 10 ? "\(Int(km.rounded())) KM" : String(format: "%.1f KM", km))
        if needsTiltUp {
            parts.append("TILT UP")
        } else if steer.isBehind {
            parts.append("BEHIND YOU")
        } else {
            parts.append(pointsRight ? "TURN RIGHT" : "TURN LEFT")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        // Edge-aligned inside the frame (never `.position` off-center: a
        // wide tag would clip past the screen edge — caught in the U2
        // visual pass). Chevron and tag share the turn-side edge; TILT UP
        // centers near the top.
        let chevron = needsTiltUp ? "chevron.up.2" : (pointsRight ? "chevron.right.2" : "chevron.left.2")
        let hAlign: HorizontalAlignment = needsTiltUp ? .center : (pointsRight ? .trailing : .leading)
        let frameAlign: Alignment = needsTiltUp ? .center : (pointsRight ? .trailing : .leading)
        VStack(alignment: hAlign, spacing: 6) {
            Image(systemName: chevron)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Brand.Color.cyan)
                .modifier(EmptyStepPulse(active: !reduceMotion))
            Text(tagText)
                .font(Brand.Font.mono(size: 10, weight: .bold))
                .tracking(0.6)
                .lineLimit(1)
                .foregroundStyle(Brand.Color.cyan)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Brand.Color.bgPrimary.opacity(0.7), in: .capsule)
                .frame(maxWidth: screenSize.width * 0.72)
        }
        .padding(.horizontal, 16)
        .frame(width: screenSize.width, alignment: frameAlign)
        .position(
            x: screenSize.width / 2,
            y: screenSize.height * (needsTiltUp ? 0.22 : 0.40)
        )
        .transition(.opacity)
    }
}

/// Slow breathing for the steering chevron — quieter than a capture-grade
/// pulse; suppressed under Reduce Motion.
private struct EmptyStepPulse: ViewModifier {
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = (cos(t * 3.5) + 1) / 2
                content.opacity(0.55 + 0.45 * phase)
            }
        } else {
            content
        }
    }
}

/// The capture-loud moment (R4, guided mode only this round — plan A1):
/// two expanding rings breathing behind the capture button so enablement
/// is unmissable, replacing nothing — the opacity change stays. Static
/// ring under Reduce Motion.
struct CapturePulseRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Circle()
                .strokeBorder(Brand.Color.cyan.opacity(0.5), lineWidth: 3)
                .frame(width: 88, height: 88)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ring(t: t, phaseOffset: 0)
                    ring(t: t, phaseOffset: 0.5)
                }
            }
        }
    }

    private func ring(t: TimeInterval, phaseOffset: Double) -> some View {
        // Each ring expands 72 → 116 pt over ~1.6 s while fading out.
        let phase = ((t / 1.6) + phaseOffset).truncatingRemainder(dividingBy: 1)
        return Circle()
            .strokeBorder(Brand.Color.cyan.opacity(0.55 * (1 - phase)), lineWidth: 2.5)
            .frame(width: 72 + 44 * phase, height: 72 + 44 * phase)
    }
}
