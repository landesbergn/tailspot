//
//  CardSilhouettes.swift
//  Tailspot
//
//  STAGE-2b CARD-STYLE SPIKE (feat/card-style-spike).
//
//  Five top-down PLAN-FORM aircraft silhouettes as SwiftUI `Shape`s.
//  Plan-form = the spotter-recognizable view looking straight down (or
//  straight up at a plane passing overhead) — the view where wing span,
//  sweep, engine count, and tail layout are all legible at once. These
//  are the procedural, fully-owned card-art primitives Track 2 §4 calls
//  for: no commissioned illustration, no photo, no ML-generated art.
//
//  HOW THESE SHAPES WERE MADE — the second attempt. The first round
//  hand-drew Béziers from proportion notes and didn't resemble the real
//  airframes. This round TRACES license-clean reference imagery (the
//  approach the program spec sanctions: "traced from license-free
//  references"). Per aircraft:
//
//    reference image (PD or CC0, see tools/cards/SOURCES.md)
//      -> ImageMagick: crop the plan/top-view panel, threshold, flood-fill
//         the exterior so the airframe becomes a solid black silhouette
//      -> potrace -s: vectorize to an SVG of cubic Béziers
//      -> tools/cards/svg2swift.py: emit the SwiftUI `Path` below, with each
//         potrace cubic mapped 1:1 onto `addCurve`, normalized into the unit
//         design space this file's PlanFormMap consumes.
//
//  Four of the five are literal traces of real airframes; the helicopter is
//  a reference-PROPORTIONED procedural redraw (the dimensioned Bell drawing
//  doesn't isolate cleanly via flood-fill — rotor blades and dimension lines
//  bridge interior to exterior — so its body is hand-built to the measured
//  Bell 206 proportions, and its disc + rotor blades stay procedural). Each
//  traced shape's doc-comment names its exact source and license.
//
//  Conventions:
//    - Every shape draws NOSE-UP (nose at small y, tail at large y) inside
//      whatever rect it's hosted in. The drawing maps a normalized
//      design space onto `rect` so the silhouette fills its slot while
//      preserving the real-world span:length aspect of the airframe.
//    - `aspect` (span ÷ length) per type lets the host letterbox the
//      shape so a Cessna (span 1.34× length) and a 747 (span ~1.0× length
//      as traced) both sit centered without distortion. The per-type aspect
//      is the MEASURED span:length of the trace, so the normalized shape
//      renders undistorted.
//    - Shapes are pure geometry. Fill / stroke / color is the STYLE
//      layer's job (see SilhouetteCardSpike.swift) — the same A320 path
//      renders as a blueprint outline, a solid fill, or a duotone body.
//

import SwiftUI

// MARK: - Silhouette kinds

/// The five spike samples spanning the recognizable visual range:
/// narrowbody, widebody jumbo, bizjet, GA prop, helicopter.
nonisolated enum SilhouetteKind: String, CaseIterable, Sendable {
    case a320          // narrowbody twin   (traced from KC-46 plan, PD)
    case b747          // widebody quad     (traced from NASA SCA 747 plan, PD)
    case citation      // T-tail bizjet     (traced from Learjet 24 plan, PD)
    case c172          // high-wing GA      (traced from Cessna 172, CC0)
    case heli          // light helicopter  (procedural, Bell 206 proportions)

    /// span ÷ length, used by the host to letterbox without distortion.
    /// These are the MEASURED span:length of each trace's bounding box (so
    /// the normalized path renders undistorted), which track the real
    /// airframes:
    ///   A320 slot (KC-46 trace)  ~1.00
    ///   747  (procedural, 747-400 measured proportions)  ~0.91
    ///   Citation slot (Learjet)  ~0.90
    ///   C172 (Cessna trace)       1.34   (span EXCEEDS length — the GA tell)
    ///   Heli  rotor disc ~10 m, fuselage+boom ~12 m → ~0.83
    var aspect: CGFloat {
        switch self {
        case .a320:     return 0.996
        case .b747:     return 0.910
        case .citation: return 0.902
        case .c172:     return 1.339
        case .heli:     return 0.83
        }
    }

    /// Human label for contact-sheet captions and check renders.
    var label: String {
        switch self {
        case .a320:     return "A320 — narrowbody twin"
        case .b747:     return "747 — widebody quad"
        case .citation: return "Citation — bizjet (T-tail)"
        case .c172:     return "Cessna 172 — GA high-wing"
        case .heli:     return "Bell 206 — light helicopter"
        }
    }

    /// The matching Shape, type-erased for storage in arrays / ForEach.
    var shape: AnyShape {
        switch self {
        case .a320:     return AnyShape(A320Silhouette())
        case .b747:     return AnyShape(B747Silhouette())
        case .citation: return AnyShape(CitationSilhouette())
        case .c172:     return AnyShape(C172Silhouette())
        case .heli:     return AnyShape(HeliSilhouette())
        }
    }
}

// MARK: - Normalized drawing space

/// Helper that maps a normalized design point — x ∈ [-1, 1] (centerline
/// at 0, +x = right wing), y ∈ [0, 1] (0 = nose, 1 = tail) — onto an
/// actual `CGRect`. The airframe's real span:length aspect is honored
/// by the caller via `SilhouetteKind.aspect`, so here we just letterbox
/// into the largest centered box of that aspect inside `rect`.
///
/// The traced shapes emitted by svg2swift.py already fill x ∈ [-1, 1] and
/// y ∈ [0, 1]; passing the trace's measured span:length as `aspect` makes
/// PlanFormMap render the silhouette with no distortion.
nonisolated struct PlanFormMap {
    let rect: CGRect
    let aspect: CGFloat   // span ÷ length

    /// The drawable box: as tall as possible, width = height × aspect,
    /// centered. Length runs vertically; span runs horizontally.
    private var box: CGRect {
        // Try full height first.
        var h = rect.height
        var w = h * aspect
        if w > rect.width {       // span-limited → clamp to width
            w = rect.width
            h = w / aspect
        }
        let x = rect.midX - w / 2
        let y = rect.midY - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Map normalized (nx ∈ [-1,1], ny ∈ [0,1]) → device point.
    func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
        let b = box
        return CGPoint(
            x: b.midX + (nx / 2) * b.width,   // nx/2 because span runs -1…1 (width = 2)
            y: b.minY + ny * b.height
        )
    }
}

// =============================================================================
// MARK: - TRACED SHAPES
//
// The four fixed-wing silhouettes below are generated by tools/cards/svg2swift.py
// from potrace SVGs. To regenerate after re-tracing a reference, re-run that
// script (commands documented in tools/cards/SOURCES.md) and paste its output
// over the corresponding struct — the type names here are load-bearing (the
// spike harness in SilhouetteCardSpike.swift / SilhouetteSpikeRenderTests.swift
// references them by name).
// =============================================================================

// MARK: - A320 (traced)

/// Airbus A320 narrowbody-twin slot. Traced from a license-clean
/// PUBLIC-DOMAIN plan-view silhouette of the Boeing KC-46 Pegasus (a USAF
/// 767-family tanker) — the closest license-clean true top-down twin-jet
/// plan-form available (no clean-licensed A320/737 plan exists on Commons;
/// the A320 4-views are CC-BY-SA, which we cannot ship). The refueling boom
/// was masked off so the silhouette reads as a generic narrowbody twin:
/// two underwing engines, swept wing + winglets, swept tailplane, single fin.
/// The KC-46 reference is entered nose-down in the plan-view image; traced
/// with --no-flip so y increases nose→tail as the design-space spec requires.
/// Source: commons.wikimedia.org/wiki/File:Boeing_KC-46_Pegasus_plan_view_silhouette_drawing.jpg
/// License: Public domain (US Air Force / Philip Bryant). See tools/cards/SOURCES.md.
nonisolated struct A320Silhouette: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let m = PlanFormMap(rect: rect, aspect: 0.9960)
        var p = Path()
        p.move(to: m.pt(-0.0172, 0.0103))
        p.addCurve(to: m.pt(-0.0899, 0.0922), control1: m.pt(-0.0548, 0.0324), control2: m.pt(-0.0822, 0.0632))
        p.addCurve(to: m.pt(-0.1023, 0.2667), control1: m.pt(-0.0964, 0.1172), control2: m.pt(-0.1002, 0.1682))
        p.addCurve(to: m.pt(-0.1084, 0.3340), control1: m.pt(-0.1038, 0.3302), control2: m.pt(-0.1038, 0.3302))
        p.addCurve(to: m.pt(-0.2513, 0.3876), control1: m.pt(-0.1181, 0.3419), control2: m.pt(-0.1313, 0.3468))
        p.addCurve(to: m.pt(-0.2749, 0.3650), control1: m.pt(-0.2762, 0.3961), control2: m.pt(-0.2741, 0.3981))
        p.addCurve(to: m.pt(-0.3292, 0.3263), control1: m.pt(-0.2761, 0.3248), control2: m.pt(-0.2741, 0.3263))
        p.addCurve(to: m.pt(-0.3852, 0.3643), control1: m.pt(-0.3859, 0.3263), control2: m.pt(-0.3852, 0.3258))
        p.addCurve(to: m.pt(-0.3712, 0.4172), control1: m.pt(-0.3852, 0.3950), control2: m.pt(-0.3836, 0.4009))
        p.addCurve(to: m.pt(-0.3669, 0.4256), control1: m.pt(-0.3682, 0.4212), control2: m.pt(-0.3665, 0.4247))
        p.addCurve(to: m.pt(-0.5338, 0.4836), control1: m.pt(-0.3676, 0.4271), control2: m.pt(-0.3824, 0.4323))
        p.addCurve(to: m.pt(-0.6223, 0.5135), control1: m.pt(-0.5434, 0.4868), control2: m.pt(-0.5831, 0.5003))
        p.addCurve(to: m.pt(-0.7180, 0.5459), control1: m.pt(-0.6613, 0.5267), control2: m.pt(-0.7044, 0.5413))
        p.addCurve(to: m.pt(-0.8277, 0.5827), control1: m.pt(-0.8013, 0.5742), control2: m.pt(-0.8254, 0.5823))
        p.addCurve(to: m.pt(-0.8357, 0.5771), control1: m.pt(-0.8317, 0.5835), control2: m.pt(-0.8336, 0.5821))
        p.addCurve(to: m.pt(-0.8608, 0.5851), control1: m.pt(-0.8431, 0.5596), control2: m.pt(-0.8583, 0.5645))
        p.addCurve(to: m.pt(-0.9218, 0.6149), control1: m.pt(-0.8621, 0.5955), control2: m.pt(-0.8570, 0.5930))
        p.addCurve(to: m.pt(-0.9984, 0.6657), control1: m.pt(-0.9964, 0.6400), control2: m.pt(-1.0000, 0.6425))
        p.addCurve(to: m.pt(-0.9476, 0.6767), control1: m.pt(-0.9970, 0.6854), control2: m.pt(-0.9946, 0.6859))
        p.addCurve(to: m.pt(-0.8550, 0.6673), control1: m.pt(-0.8535, 0.6580), control2: m.pt(-0.8579, 0.6584))
        p.addCurve(to: m.pt(-0.8383, 0.6635), control1: m.pt(-0.8506, 0.6808), control2: m.pt(-0.8409, 0.6786))
        p.addCurve(to: m.pt(-0.7481, 0.6385), control1: m.pt(-0.8367, 0.6544), control2: m.pt(-0.8457, 0.6569))
        p.addCurve(to: m.pt(-0.6657, 0.6248), control1: m.pt(-0.6734, 0.6245), control2: m.pt(-0.6705, 0.6240))
        p.addCurve(to: m.pt(-0.6552, 0.6228), control1: m.pt(-0.6607, 0.6257), control2: m.pt(-0.6605, 0.6257))
        p.addCurve(to: m.pt(-0.5730, 0.6055), control1: m.pt(-0.6502, 0.6201), control2: m.pt(-0.6459, 0.6192))
        p.addCurve(to: m.pt(-0.4852, 0.5919), control1: m.pt(-0.4990, 0.5917), control2: m.pt(-0.4900, 0.5903))
        p.addCurve(to: m.pt(-0.4780, 0.5897), control1: m.pt(-0.4836, 0.5925), control2: m.pt(-0.4819, 0.5920))
        p.addCurve(to: m.pt(-0.3460, 0.5638), control1: m.pt(-0.4726, 0.5866), control2: m.pt(-0.3736, 0.5672))
        p.addCurve(to: m.pt(-0.2655, 0.5594), control1: m.pt(-0.3118, 0.5596), control2: m.pt(-0.2709, 0.5574))
        p.addCurve(to: m.pt(-0.2565, 0.5589), control1: m.pt(-0.2614, 0.5610), control2: m.pt(-0.2614, 0.5610))
        p.addCurve(to: m.pt(-0.2510, 0.5567), control1: m.pt(-0.2539, 0.5576), control2: m.pt(-0.2513, 0.5567))
        p.addCurve(to: m.pt(-0.2195, 0.5553), control1: m.pt(-0.2506, 0.5567), control2: m.pt(-0.2365, 0.5561))
        p.addCurve(to: m.pt(-0.1012, 0.5529), control1: m.pt(-0.1435, 0.5518), control2: m.pt(-0.1032, 0.5510))
        p.addCurve(to: m.pt(-0.0988, 0.6522), control1: m.pt(-0.1004, 0.5536), control2: m.pt(-0.0994, 0.5963))
        p.addCurve(to: m.pt(-0.0920, 0.7854), control1: m.pt(-0.0978, 0.7503), control2: m.pt(-0.0974, 0.7604))
        p.addCurve(to: m.pt(-0.0791, 0.8293), control1: m.pt(-0.0887, 0.8013), control2: m.pt(-0.0832, 0.8203))
        p.addCurve(to: m.pt(-0.0756, 0.8401), control1: m.pt(-0.0768, 0.8345), control2: m.pt(-0.0752, 0.8393))
        p.addCurve(to: m.pt(-0.2700, 0.9205), control1: m.pt(-0.0787, 0.8447), control2: m.pt(-0.0809, 0.8457))
        p.addCurve(to: m.pt(-0.3847, 0.9763), control1: m.pt(-0.3930, 0.9692), control2: m.pt(-0.3836, 0.9645))
        p.addCurve(to: m.pt(-0.3630, 0.9965), control1: m.pt(-0.3865, 0.9960), control2: m.pt(-0.3823, 1.0000))
        p.addCurve(to: m.pt(-0.2234, 0.9789), control1: m.pt(-0.3596, 0.9958), control2: m.pt(-0.2968, 0.9879))
        p.addCurve(to: m.pt(-0.0849, 0.9500), control1: m.pt(-0.0682, 0.9597), control2: m.pt(-0.0849, 0.9631))
        p.addCurve(to: m.pt(0.0101, 0.9379), control1: m.pt(-0.0849, 0.9364), control2: m.pt(-0.0965, 0.9379))
        p.addCurve(to: m.pt(0.1051, 0.9509), control1: m.pt(0.1171, 0.9379), control2: m.pt(0.1051, 0.9363))
        p.addCurve(to: m.pt(0.1119, 0.9643), control1: m.pt(0.1051, 0.9618), control2: m.pt(0.1058, 0.9631))
        p.addCurve(to: m.pt(0.3781, 0.9973), control1: m.pt(0.1189, 0.9658), control2: m.pt(0.3709, 0.9969))
        p.addCurve(to: m.pt(0.3870, 0.9838), control1: m.pt(0.3859, 0.9977), control2: m.pt(0.3857, 0.9980))
        p.addCurve(to: m.pt(0.3483, 0.9503), control1: m.pt(0.3888, 0.9667), control2: m.pt(0.3878, 0.9658))
        p.addCurve(to: m.pt(0.0859, 0.8460), control1: m.pt(0.2411, 0.9082), control2: m.pt(0.0917, 0.8487))
        p.addCurve(to: m.pt(0.0823, 0.8253), control1: m.pt(0.0765, 0.8415), control2: m.pt(0.0764, 0.8408))
        p.addCurve(to: m.pt(0.0977, 0.7624), control1: m.pt(0.0891, 0.8079), control2: m.pt(0.0942, 0.7870))
        p.addCurve(to: m.pt(0.1002, 0.6530), control1: m.pt(0.0986, 0.7569), control2: m.pt(0.0996, 0.7076))
        p.addCurve(to: m.pt(0.1148, 0.5513), control1: m.pt(0.1013, 0.5393), control2: m.pt(0.0997, 0.5507))
        p.addCurve(to: m.pt(0.1595, 0.5528), control1: m.pt(0.1194, 0.5515), control2: m.pt(0.1396, 0.5522))
        p.addCurve(to: m.pt(0.2234, 0.5552), control1: m.pt(0.1795, 0.5535), control2: m.pt(0.2082, 0.5545))
        p.addCurve(to: m.pt(0.2612, 0.5599), control1: m.pt(0.2516, 0.5564), control2: m.pt(0.2517, 0.5565))
        p.addCurve(to: m.pt(0.2658, 0.5594), control1: m.pt(0.2625, 0.5604), control2: m.pt(0.2639, 0.5602))
        p.addCurve(to: m.pt(0.3067, 0.5599), control1: m.pt(0.2696, 0.5577), control2: m.pt(0.2780, 0.5578))
        p.addCurve(to: m.pt(0.4177, 0.5760), control1: m.pt(0.3486, 0.5630), control2: m.pt(0.3457, 0.5626))
        p.addCurve(to: m.pt(0.4794, 0.5895), control1: m.pt(0.4799, 0.5875), control2: m.pt(0.4758, 0.5866))
        p.addCurve(to: m.pt(0.4857, 0.5915), control1: m.pt(0.4819, 0.5915), control2: m.pt(0.4832, 0.5919))
        p.addCurve(to: m.pt(0.4918, 0.5907), control1: m.pt(0.4873, 0.5912), control2: m.pt(0.4902, 0.5909))
        p.addCurve(to: m.pt(0.5476, 0.6001), control1: m.pt(0.4938, 0.5905), control2: m.pt(0.5151, 0.5941))
        p.addCurve(to: m.pt(0.6571, 0.6225), control1: m.pt(0.6578, 0.6207), control2: m.pt(0.6522, 0.6195))
        p.addCurve(to: m.pt(0.6661, 0.6243), control1: m.pt(0.6615, 0.6251), control2: m.pt(0.6619, 0.6251))
        p.addCurve(to: m.pt(0.6739, 0.6238), control1: m.pt(0.6686, 0.6238), control2: m.pt(0.6721, 0.6235))
        p.addCurve(to: m.pt(0.8288, 0.6530), control1: m.pt(0.6795, 0.6247), control2: m.pt(0.8215, 0.6514))
        p.addCurve(to: m.pt(0.8396, 0.6630), control1: m.pt(0.8370, 0.6547), control2: m.pt(0.8384, 0.6561))
        p.addCurve(to: m.pt(0.8551, 0.6695), control1: m.pt(0.8420, 0.6765), control2: m.pt(0.8506, 0.6800))
        p.addCurve(to: m.pt(0.8635, 0.6601), control1: m.pt(0.8590, 0.6602), control2: m.pt(0.8590, 0.6601))
        p.addCurve(to: m.pt(0.9649, 0.6790), control1: m.pt(0.8671, 0.6601), control2: m.pt(0.9237, 0.6706))
        p.addCurve(to: m.pt(1.0000, 0.6622), control1: m.pt(0.9943, 0.6850), control2: m.pt(1.0000, 0.6823))
        p.addCurve(to: m.pt(0.9516, 0.6237), control1: m.pt(1.0000, 0.6435), control2: m.pt(0.9923, 0.6374))
        p.addCurve(to: m.pt(0.8616, 0.5836), control1: m.pt(0.8522, 0.5903), control2: m.pt(0.8629, 0.5950))
        p.addCurve(to: m.pt(0.8376, 0.5753), control1: m.pt(0.8596, 0.5645), control2: m.pt(0.8435, 0.5590))
        p.addCurve(to: m.pt(0.8097, 0.5759), control1: m.pt(0.8344, 0.5837), control2: m.pt(0.8331, 0.5837))
        p.addCurve(to: m.pt(0.6388, 0.5183), control1: m.pt(0.7903, 0.5693), control2: m.pt(0.6634, 0.5266))
        p.addCurve(to: m.pt(0.5003, 0.4715), control1: m.pt(0.6062, 0.5073), control2: m.pt(0.5887, 0.5014))
        p.addCurve(to: m.pt(0.3884, 0.4337), control1: m.pt(0.4501, 0.4546), control2: m.pt(0.3997, 0.4375))
        p.addCurve(to: m.pt(0.3712, 0.4175), control1: m.pt(0.3641, 0.4255), control2: m.pt(0.3647, 0.4260))
        p.addCurve(to: m.pt(0.3852, 0.3475), control1: m.pt(0.3840, 0.4012), control2: m.pt(0.3884, 0.3792))
        p.addCurve(to: m.pt(0.3306, 0.3256), control1: m.pt(0.3831, 0.3270), control2: m.pt(0.3798, 0.3256))
        p.addCurve(to: m.pt(0.2752, 0.3643), control1: m.pt(0.2748, 0.3256), control2: m.pt(0.2758, 0.3249))
        p.addCurve(to: m.pt(0.2749, 0.3921), control1: m.pt(0.2751, 0.3791), control2: m.pt(0.2749, 0.3917))
        p.addCurve(to: m.pt(0.1535, 0.3538), control1: m.pt(0.2746, 0.3953), control2: m.pt(0.2622, 0.3913))
        p.addCurve(to: m.pt(0.1029, 0.2911), control1: m.pt(0.1010, 0.3358), control2: m.pt(0.1041, 0.3395))
        p.addCurve(to: m.pt(0.0436, 0.0291), control1: m.pt(0.0984, 0.0932), control2: m.pt(0.0930, 0.0695))
        p.addCurve(to: m.pt(-0.0172, 0.0103), control1: m.pt(0.0125, 0.0038), control2: m.pt(0.0004, 0.0000))
        p.closeSubpath()
        return p
    }
}
// MARK: - B747 (procedural)

/// Boeing 747 widebody-quad slot. Reference-proportioned procedural redraw
/// based on the NASA Dryden Space Shuttle Carrier Aircraft (SCA) 3-view
/// (commons.wikimedia.org/wiki/File:Shuttle_Carrier_Aircraft_diagram.gif,
/// Public Domain / NASA), measured before the Space Shuttle's delta-wing
/// contaminated the trace. The SCA is a 747-100/200 airframe; the key
/// 747-class diagnostics — four underwing engines (two per wing), heavily
/// swept wing, long wide-body fuselage, swept horizontal stabilizer
/// (~34 % of wingspan), characteristic upper-deck nose hump — are all
/// reproduced to the SCA plan-view proportions.
///
/// A literal trace was not viable: the Shuttle orbiter's delta wing (which
/// sits on the 747's spine) merges with the 747's own wing in the plan view,
/// making the stabilizer span appear ≈ the wing span in any flood-fill trace.
/// No other clean public-domain 747 plan view exists on Wikimedia Commons
/// (all 747 3-view drawings there are CC-BY-SA, which we cannot ship).
/// This procedural redraw is therefore the correct approach, documented
/// identically to HeliSilhouette. Source and license: see tools/cards/SOURCES.md.
nonisolated struct B747Silhouette: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let m = PlanFormMap(rect: rect, aspect: 0.910)
        var p = Path()

        // ── Fuselage half-widths (all in the normalized -1…1 / 0…1 space) ──
        // The 747 is a widebody: fuselage ≈ 6.5 m wide, span ≈ 64 m → 0.102
        // Upper-deck hump widens the nose section slightly (characteristic 747 read).
        let fuse:  CGFloat = 0.090   // standard fuselage half-width
        let hump:  CGFloat = 0.108   // upper-deck / cockpit hump half-width (wider)
        let humpEnd: CGFloat = 0.24  // hump ends at ~24% of fuselage length

        // ── Wing geometry ──
        // 747-400: sweep 37.5° at quarter-chord; root chord ≈ 53% of fuselage length
        // Wing root LE at ny ≈ 0.28 (28% back from nose)
        // Wing root TE at ny ≈ 0.61
        // Wing tip LE at ny ≈ 0.39, at x ≈ ±1.0
        // Wing tip TE at ny ≈ 0.56, at x ≈ ±1.0
        let wingRootLE:  CGFloat = 0.28
        let wingRootTE:  CGFloat = 0.61
        let wingTipLE:   CGFloat = 0.39   // tip is swept back from root LE
        let wingTipTE:   CGFloat = 0.56

        // ── Engine nacelles ──
        // Two per wing; inner at ~34% half-span, outer at ~60% half-span.
        // Visible from above as small rectangular bumps along the leading edge.
        let eng1X:   CGFloat = 0.36   // inner engine x (half-span fraction)
        let eng2X:   CGFloat = 0.62   // outer engine x
        // LE position interpolated on sweep line between root and tip
        let sweepFrac1: CGFloat = (eng1X - 0.0) / 1.0
        let sweepFrac2: CGFloat = (eng2X - 0.0) / 1.0
        let eng1LE: CGFloat = wingRootLE + sweepFrac1 * (wingTipLE - wingRootLE)
        let eng2LE: CGFloat = wingRootLE + sweepFrac2 * (wingTipLE - wingRootLE)
        let nacW: CGFloat = 0.055   // nacelle half-width (diameter/span)
        let nacL: CGFloat = 0.10    // nacelle length (chord depth)

        // ── Horizontal stabilizer ──
        // Span ≈ 34 % of wing span → x ≈ ±0.34; swept ~35°
        let hstabX:  CGFloat = 0.34
        let hstabLE: CGFloat = 0.88
        let hstabTE: CGFloat = 0.97
        let hstabTipLE: CGFloat = 0.91   // tip swept back
        let hstabTipTE: CGFloat = 0.99

        // ──────────────────────────────────────────────────────
        // TRACE (clockwise from nose tip, left side then right):
        // Start at nose tip, go down left fuselage, right wing,
        // across to left wing, back up right fuselage, close.
        // ──────────────────────────────────────────────────────

        // Nose tip (the upper-deck hump creates a slightly wider forward section)
        p.move(to: m.pt(0.0, 0.0))

        // ── Left fuselage & nose section ──
        // Nose tapers quickly to hump width
        p.addCurve(to: m.pt(-hump, 0.06),
                   control1: m.pt(-fuse * 0.4, 0.01),
                   control2: m.pt(-hump, 0.03))
        // Upper deck runs forward-third of fuselage, then steps in slightly
        p.addLine(to: m.pt(-hump, humpEnd))
        p.addCurve(to: m.pt(-fuse, humpEnd + 0.04),
                   control1: m.pt(-hump, humpEnd + 0.02),
                   control2: m.pt(-fuse, humpEnd + 0.02))
        // Left fuselage runs straight-ish to wing root
        p.addLine(to: m.pt(-fuse, wingRootLE - 0.02))

        // ── Left wing ──
        // Root leading edge → wing tip
        p.addCurve(to: m.pt(-1.0, wingTipLE),
                   control1: m.pt(-fuse, wingRootLE + 0.02),
                   control2: m.pt(-0.85, wingTipLE - 0.04))

        // Insert left outer engine nacelle (as a small convex bump)
        // Wing tip trailing edge → outer nacelle region
        p.addLine(to: m.pt(-1.0, wingTipTE))
        // Sweep inboard along trailing edge, passing outer then inner nacelle
        // Left outer engine (outer nacelle bump on trailing edge side)
        p.addCurve(to: m.pt(-(eng2X + nacW), wingTipTE + 0.01),
                   control1: m.pt(-1.0, wingTipTE + 0.01),
                   control2: m.pt(-(eng2X + nacW + 0.04), wingTipTE + 0.01))
        p.addLine(to: m.pt(-(eng2X + nacW), eng2LE + nacL))
        p.addLine(to: m.pt(-(eng2X - nacW), eng2LE + nacL))
        p.addLine(to: m.pt(-(eng2X - nacW), wingTipTE + 0.01))

        // Left inner engine nacelle bump
        p.addCurve(to: m.pt(-(eng1X + nacW), wingTipTE + 0.015),
                   control1: m.pt(-(eng1X + nacW + 0.06), wingTipTE + 0.01),
                   control2: m.pt(-(eng1X + nacW + 0.02), wingTipTE + 0.015))
        p.addLine(to: m.pt(-(eng1X + nacW), eng1LE + nacL))
        p.addLine(to: m.pt(-(eng1X - nacW), eng1LE + nacL))
        p.addLine(to: m.pt(-(eng1X - nacW), wingRootTE))

        // Wing root trailing edge back to fuselage
        p.addCurve(to: m.pt(-fuse, wingRootTE),
                   control1: m.pt(-(eng1X - nacW - 0.04), wingRootTE),
                   control2: m.pt(-fuse * 1.4, wingRootTE))

        // ── Left aft fuselage to horizontal stabilizer ──
        p.addLine(to: m.pt(-fuse, hstabLE - 0.03))
        p.addCurve(to: m.pt(-fuse * 0.7, hstabLE),
                   control1: m.pt(-fuse, hstabLE),
                   control2: m.pt(-fuse * 0.8, hstabLE))

        // Left horizontal stabilizer
        p.addCurve(to: m.pt(-hstabX, hstabTipLE),
                   control1: m.pt(-fuse * 0.4, hstabLE),
                   control2: m.pt(-hstabX + 0.05, hstabTipLE))
        p.addLine(to: m.pt(-hstabX, hstabTipTE))
        p.addCurve(to: m.pt(-fuse * 0.7, hstabTE),
                   control1: m.pt(-hstabX + 0.04, hstabTipTE),
                   control2: m.pt(-fuse * 0.5, hstabTE))

        // ── Tail cone ──
        p.addCurve(to: m.pt(0.0, 1.0),
                   control1: m.pt(-fuse * 0.5, hstabTE + 0.01),
                   control2: m.pt(-fuse * 0.3, 0.995))

        // ── Right side (mirror) ──
        p.addCurve(to: m.pt(fuse * 0.7, hstabTE),
                   control1: m.pt(fuse * 0.3, 0.995),
                   control2: m.pt(fuse * 0.5, hstabTE + 0.01))

        // Right horizontal stabilizer
        p.addCurve(to: m.pt(hstabX, hstabTipTE),
                   control1: m.pt(fuse * 0.5, hstabTE),
                   control2: m.pt(hstabX - 0.04, hstabTipTE))
        p.addLine(to: m.pt(hstabX, hstabTipLE))
        p.addCurve(to: m.pt(fuse * 0.7, hstabLE),
                   control1: m.pt(hstabX - 0.05, hstabTipLE),
                   control2: m.pt(fuse * 0.4, hstabLE))
        p.addCurve(to: m.pt(fuse, hstabLE - 0.03),
                   control1: m.pt(fuse * 0.8, hstabLE),
                   control2: m.pt(fuse, hstabLE))

        // ── Right aft fuselage ──
        p.addLine(to: m.pt(fuse, wingRootTE))

        // Right wing root trailing edge
        p.addCurve(to: m.pt((eng1X - nacW), wingRootTE),
                   control1: m.pt(fuse * 1.4, wingRootTE),
                   control2: m.pt((eng1X - nacW + 0.04), wingRootTE))
        p.addLine(to: m.pt((eng1X - nacW), eng1LE + nacL))
        p.addLine(to: m.pt((eng1X + nacW), eng1LE + nacL))
        p.addLine(to: m.pt((eng1X + nacW), wingTipTE + 0.015))

        p.addCurve(to: m.pt((eng2X - nacW), wingTipTE + 0.01),
                   control1: m.pt((eng2X - nacW + 0.02), wingTipTE + 0.015),
                   control2: m.pt((eng2X - nacW + 0.06), wingTipTE + 0.01))
        p.addLine(to: m.pt((eng2X - nacW), eng2LE + nacL))
        p.addLine(to: m.pt((eng2X + nacW), eng2LE + nacL))
        p.addLine(to: m.pt((eng2X + nacW), wingTipTE + 0.01))

        p.addCurve(to: m.pt(1.0, wingTipTE),
                   control1: m.pt((eng2X + nacW + 0.04), wingTipTE + 0.01),
                   control2: m.pt(1.0, wingTipTE + 0.01))

        // Right wing tip trailing edge → leading edge
        p.addLine(to: m.pt(1.0, wingTipLE))

        // Right wing leading edge back to fuselage
        p.addCurve(to: m.pt(fuse, wingRootLE - 0.02),
                   control1: m.pt(0.85, wingTipLE - 0.04),
                   control2: m.pt(fuse, wingRootLE + 0.02))

        // Right forward fuselage back to nose
        p.addLine(to: m.pt(fuse, humpEnd + 0.04))
        p.addCurve(to: m.pt(hump, humpEnd),
                   control1: m.pt(fuse, humpEnd + 0.02),
                   control2: m.pt(hump, humpEnd + 0.02))
        p.addLine(to: m.pt(hump, 0.06))
        p.addCurve(to: m.pt(0.0, 0.0),
                   control1: m.pt(hump, 0.03),
                   control2: m.pt(fuse * 0.4, 0.01))

        p.closeSubpath()
        return p
    }
}
// MARK: - Citation (traced)

/// Citation-class bizjet slot. Traced from the PUBLIC-DOMAIN NASA
/// Learjet 24 3-view (top panel). The Learjet is the documented license-clean
/// stand-in for a Citation: same class (T-tail business jet, two aft-fuselage
/// engines, low swept wing) — the diagnostic bizjet read. The Learjet's
/// wingtip fuel tanks are visible at the wingtips (a Learjet signature).
/// The 3-view reference was entered nose-down; traced with --no-flip so the
/// normalized y axis increases nose→tail as the design-space spec requires.
/// Source: commons.wikimedia.org/wiki/File:Learjet_24_3-View_line_art.gif
/// License: Public domain (NASA). See tools/cards/SOURCES.md.
nonisolated struct CitationSilhouette: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let m = PlanFormMap(rect: rect, aspect: 0.9020)
        var p = Path()
        p.move(to: m.pt(-0.0970, 0.0008))
        p.addCurve(to: m.pt(-0.1429, 0.1060), control1: m.pt(-0.1071, 0.0140), control2: m.pt(-0.1322, 0.0714))
        p.addCurve(to: m.pt(-0.1495, 0.3268), control1: m.pt(-0.1541, 0.1429), control2: m.pt(-0.1589, 0.2984))
        p.addCurve(to: m.pt(-0.4880, 0.3733), control1: m.pt(-0.1478, 0.3318), control2: m.pt(-0.1251, 0.3287))
        p.addCurve(to: m.pt(-0.8251, 0.4141), control1: m.pt(-0.6707, 0.3957), control2: m.pt(-0.8224, 0.4141))
        p.addCurve(to: m.pt(-0.8331, 0.3962), control1: m.pt(-0.8322, 0.4141), control2: m.pt(-0.8331, 0.4120))
        p.addCurve(to: m.pt(-0.8408, 0.3124), control1: m.pt(-0.8331, 0.3725), control2: m.pt(-0.8368, 0.3320))
        p.addCurve(to: m.pt(-0.9105, 0.2627), control1: m.pt(-0.8486, 0.2731), control2: m.pt(-0.8847, 0.2474))
        p.addCurve(to: m.pt(-0.9442, 0.4611), control1: m.pt(-0.9432, 0.2819), control2: m.pt(-0.9565, 0.3614))
        p.addCurve(to: m.pt(-0.9457, 0.4778), control1: m.pt(-0.9427, 0.4732), control2: m.pt(-0.9429, 0.4740))
        p.addCurve(to: m.pt(-0.9442, 0.4931), control1: m.pt(-0.9504, 0.4838), control2: m.pt(-0.9499, 0.4883))
        p.addCurve(to: m.pt(-0.9367, 0.5133), control1: m.pt(-0.9398, 0.4968), control2: m.pt(-0.9395, 0.4975))
        p.addCurve(to: m.pt(-0.9245, 0.5721), control1: m.pt(-0.9341, 0.5278), control2: m.pt(-0.9302, 0.5466))
        p.addCurve(to: m.pt(-0.9245, 0.5818), control1: m.pt(-0.9233, 0.5781), control2: m.pt(-0.9233, 0.5805))
        p.addCurve(to: m.pt(-0.9976, 0.6249), control1: m.pt(-0.9265, 0.5837), control2: m.pt(-0.9941, 0.6235))
        p.addCurve(to: m.pt(-1.0000, 0.6365), control1: m.pt(-0.9995, 0.6256), control2: m.pt(-1.0000, 0.6276))
        p.addCurve(to: m.pt(-0.9432, 0.6472), control1: m.pt(-1.0000, 0.6472), control2: m.pt(-1.0000, 0.6472))
        p.addCurve(to: m.pt(-0.8848, 0.6467), control1: m.pt(-0.9120, 0.6472), control2: m.pt(-0.8857, 0.6470))
        p.addCurve(to: m.pt(-0.8677, 0.6083), control1: m.pt(-0.8795, 0.6451), control2: m.pt(-0.8753, 0.6356))
        p.addCurve(to: m.pt(-0.8520, 0.5595), control1: m.pt(-0.8580, 0.5739), control2: m.pt(-0.8538, 0.5606))
        p.addCurve(to: m.pt(-0.2738, 0.5591), control1: m.pt(-0.8492, 0.5576), control2: m.pt(-0.2779, 0.5572))
        p.addCurve(to: m.pt(-0.2701, 0.5653), control1: m.pt(-0.2719, 0.5599), control2: m.pt(-0.2707, 0.5618))
        p.addCurve(to: m.pt(-0.2226, 0.6830), control1: m.pt(-0.2559, 0.6354), control2: m.pt(-0.2382, 0.6794))
        p.addCurve(to: m.pt(-0.1777, 0.6824), control1: m.pt(-0.2182, 0.6840), control2: m.pt(-0.1862, 0.6836))
        p.addCurve(to: m.pt(-0.1656, 0.6742), control1: m.pt(-0.1726, 0.6817), control2: m.pt(-0.1692, 0.6794))
        p.addCurve(to: m.pt(-0.1397, 0.6696), control1: m.pt(-0.1626, 0.6701), control2: m.pt(-0.1597, 0.6696))
        p.addCurve(to: m.pt(-0.1152, 0.6796), control1: m.pt(-0.1173, 0.6696), control2: m.pt(-0.1167, 0.6698))
        p.addCurve(to: m.pt(-0.0767, 0.8251), control1: m.pt(-0.1089, 0.7206), control2: m.pt(-0.0895, 0.7939))
        p.addCurve(to: m.pt(-0.0777, 0.8389), control1: m.pt(-0.0725, 0.8354), control2: m.pt(-0.0726, 0.8373))
        p.addCurve(to: m.pt(-0.4072, 0.9234), control1: m.pt(-0.0829, 0.8405), control2: m.pt(-0.3919, 0.9198))
        p.addCurve(to: m.pt(-0.4459, 0.9465), control1: m.pt(-0.4260, 0.9278), control2: m.pt(-0.4394, 0.9358))
        p.addCurve(to: m.pt(-0.4508, 0.9961), control1: m.pt(-0.4490, 0.9517), control2: m.pt(-0.4534, 0.9947))
        p.addCurve(to: m.pt(-0.2444, 0.9797), control1: m.pt(-0.4480, 0.9976), control2: m.pt(-0.4426, 0.9972))
        p.addCurve(to: m.pt(-0.0403, 0.9623), control1: m.pt(-0.0498, 0.9625), control2: m.pt(-0.0451, 0.9622))
        p.addCurve(to: m.pt(-0.0143, 0.9839), control1: m.pt(-0.0335, 0.9625), control2: m.pt(-0.0185, 0.9750))
        p.addCurve(to: m.pt(-0.0107, 0.9912), control1: m.pt(-0.0129, 0.9868), control2: m.pt(-0.0113, 0.9900))
        p.addCurve(to: m.pt(0.0068, 0.9904), control1: m.pt(-0.0081, 0.9962), control2: m.pt(0.0048, 0.9956))
        p.addCurve(to: m.pt(0.0335, 0.9632), control1: m.pt(0.0108, 0.9798), control2: m.pt(0.0254, 0.9650))
        p.addCurve(to: m.pt(0.4430, 0.9995), control1: m.pt(0.0370, 0.9625), control2: m.pt(0.3956, 0.9942))
        p.addCurve(to: m.pt(0.4465, 0.9768), control1: m.pt(0.4480, 1.0000), control2: m.pt(0.4481, 0.9991))
        p.addCurve(to: m.pt(0.4060, 0.9255), control1: m.pt(0.4441, 0.9431), control2: m.pt(0.4358, 0.9326))
        p.addCurve(to: m.pt(0.0875, 0.8429), control1: m.pt(0.3973, 0.9234), control2: m.pt(0.1141, 0.8499))
        p.addCurve(to: m.pt(0.0765, 0.8199), control1: m.pt(0.0684, 0.8378), control2: m.pt(0.0690, 0.8392))
        p.addCurve(to: m.pt(0.1120, 0.6937), control1: m.pt(0.0901, 0.7850), control2: m.pt(0.1020, 0.7425))
        p.addCurve(to: m.pt(0.1158, 0.6746), control1: m.pt(0.1141, 0.6837), control2: m.pt(0.1158, 0.6751))
        p.addCurve(to: m.pt(0.1395, 0.6710), control1: m.pt(0.1158, 0.6718), control2: m.pt(0.1212, 0.6710))
        p.addCurve(to: m.pt(0.1666, 0.6769), control1: m.pt(0.1606, 0.6710), control2: m.pt(0.1621, 0.6713))
        p.addCurve(to: m.pt(0.1842, 0.6838), control1: m.pt(0.1714, 0.6828), control2: m.pt(0.1723, 0.6832))
        p.addCurve(to: m.pt(0.2245, 0.6832), control1: m.pt(0.2038, 0.6850), control2: m.pt(0.2202, 0.6847))
        p.addCurve(to: m.pt(0.2677, 0.5815), control1: m.pt(0.2373, 0.6786), control2: m.pt(0.2565, 0.6332))
        p.addCurve(to: m.pt(0.2761, 0.5600), control1: m.pt(0.2722, 0.5606), control2: m.pt(0.2719, 0.5613))
        p.addCurve(to: m.pt(0.4914, 0.5597), control1: m.pt(0.2797, 0.5590), control2: m.pt(0.2959, 0.5590))
        p.addCurve(to: m.pt(0.7761, 0.5605), control1: m.pt(0.6078, 0.5601), control2: m.pt(0.7359, 0.5605))
        p.addCurve(to: m.pt(0.8517, 0.5618), control1: m.pt(0.8465, 0.5605), control2: m.pt(0.8493, 0.5606))
        p.addCurve(to: m.pt(0.8662, 0.6039), control1: m.pt(0.8550, 0.5634), control2: m.pt(0.8564, 0.5673))
        p.addCurve(to: m.pt(0.8848, 0.6494), control1: m.pt(0.8755, 0.6384), control2: m.pt(0.8792, 0.6478))
        p.addCurve(to: m.pt(0.9433, 0.6499), control1: m.pt(0.8857, 0.6497), control2: m.pt(0.9120, 0.6499))
        p.addCurve(to: m.pt(1.0000, 0.6393), control1: m.pt(1.0000, 0.6499), control2: m.pt(1.0000, 0.6499))
        p.addCurve(to: m.pt(0.9956, 0.6266), control1: m.pt(1.0000, 0.6287), control2: m.pt(1.0000, 0.6287))
        p.addCurve(to: m.pt(0.9253, 0.5848), control1: m.pt(0.9895, 0.6237), control2: m.pt(0.9277, 0.5869))
        p.addCurve(to: m.pt(0.9277, 0.5648), control1: m.pt(0.9236, 0.5833), control2: m.pt(0.9239, 0.5804))
        p.addCurve(to: m.pt(0.9359, 0.5273), control1: m.pt(0.9302, 0.5548), control2: m.pt(0.9340, 0.5379))
        p.addCurve(to: m.pt(0.9408, 0.5036), control1: m.pt(0.9380, 0.5166), control2: m.pt(0.9402, 0.5060))
        p.addCurve(to: m.pt(0.9456, 0.4964), control1: m.pt(0.9414, 0.5004), control2: m.pt(0.9427, 0.4984))
        p.addCurve(to: m.pt(0.9478, 0.4802), control1: m.pt(0.9510, 0.4928), control2: m.pt(0.9520, 0.4852))
        p.addCurve(to: m.pt(0.9468, 0.4619), control1: m.pt(0.9451, 0.4769), control2: m.pt(0.9450, 0.4760))
        p.addCurve(to: m.pt(0.9332, 0.2841), control1: m.pt(0.9565, 0.3840), control2: m.pt(0.9511, 0.3121))
        p.addCurve(to: m.pt(0.8665, 0.2756), control1: m.pt(0.9156, 0.2567), control2: m.pt(0.8878, 0.2531))
        p.addCurve(to: m.pt(0.8356, 0.4057), control1: m.pt(0.8456, 0.2978), control2: m.pt(0.8391, 0.3252))
        p.addCurve(to: m.pt(0.8278, 0.4168), control1: m.pt(0.8353, 0.4152), control2: m.pt(0.8341, 0.4168))
        p.addCurve(to: m.pt(0.1666, 0.3341), control1: m.pt(0.8251, 0.4168), control2: m.pt(0.2077, 0.3395))
        p.addCurve(to: m.pt(0.1540, 0.3247), control1: m.pt(0.1540, 0.3324), control2: m.pt(0.1528, 0.3315))
        p.addCurve(to: m.pt(0.1534, 0.1227), control1: m.pt(0.1618, 0.2802), control2: m.pt(0.1615, 0.1740))
        p.addCurve(to: m.pt(0.1081, 0.0062), control1: m.pt(0.1495, 0.0979), control2: m.pt(0.1281, 0.0430))
        p.addCurve(to: m.pt(0.0042, 0.0000), control1: m.pt(0.1047, 0.0000), control2: m.pt(0.1047, 0.0000))
        p.addCurve(to: m.pt(-0.0970, 0.0008), control1: m.pt(-0.0749, 0.0000), control2: m.pt(-0.0965, 0.0002))
        p.closeSubpath()
        return p
    }
}
// MARK: - Cessna 172 (traced)

/// Cessna 172 GA-high-wing slot. Traced from the CC0 Marek Cel
/// 3-view (top panel), left half mirrored about the detected fuselage
/// centerline for a clean symmetric outline. High straight constant-chord
/// wing (span 1.34× length — the GA tell), nose tractor prop, conventional tail.
/// Source: commons.wikimedia.org/wiki/File:Cessna_172.svg
/// License: CC0 (Marek Cel). See tools/cards/SOURCES.md.
nonisolated struct C172Silhouette: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let m = PlanFormMap(rect: rect, aspect: 1.3390)
        var p = Path()
        p.move(to: m.pt(-0.0021, 0.9959))
        p.addCurve(to: m.pt(-0.0258, 0.9499), control1: m.pt(-0.0084, 0.9906), control2: m.pt(-0.0205, 0.9670))
        p.addCurve(to: m.pt(-0.0435, 0.9465), control1: m.pt(-0.0265, 0.9476), control2: m.pt(-0.0302, 0.9469))
        p.addCurve(to: m.pt(-0.0715, 0.9370), control1: m.pt(-0.0599, 0.9459), control2: m.pt(-0.0668, 0.9437))
        p.addCurve(to: m.pt(-0.0962, 0.8286), control1: m.pt(-0.0777, 0.9282), control2: m.pt(-0.0930, 0.8609))
        p.addCurve(to: m.pt(-0.1000, 0.7697), control1: m.pt(-0.0986, 0.8024), control2: m.pt(-0.1000, 0.7817))
        p.addCurve(to: m.pt(-0.1015, 0.7551), control1: m.pt(-0.1000, 0.7568), control2: m.pt(-0.1001, 0.7560))
        p.addCurve(to: m.pt(-0.2883, 0.7540), control1: m.pt(-0.1031, 0.7540), control2: m.pt(-0.1041, 0.7540))
        p.addCurve(to: m.pt(-0.7196, 0.7440), control1: m.pt(-0.4735, 0.7540), control2: m.pt(-0.4735, 0.7540))
        p.addCurve(to: m.pt(-0.9700, 0.7338), control1: m.pt(-0.8550, 0.7385), control2: m.pt(-0.9677, 0.7339))
        p.addCurve(to: m.pt(-0.9951, 0.7195), control1: m.pt(-0.9801, 0.7333), control2: m.pt(-0.9909, 0.7271))
        p.addCurve(to: m.pt(-0.9982, 0.7144), control1: m.pt(-0.9958, 0.7182), control2: m.pt(-0.9972, 0.7159))
        p.addCurve(to: m.pt(-1.0000, 0.6522), control1: m.pt(-1.0000, 0.7116), control2: m.pt(-1.0000, 0.7116))
        p.addLine(to: m.pt(-1.0000, 0.5928))
        p.addLine(to: m.pt(-0.9802, 0.5919))
        p.addCurve(to: m.pt(-0.7185, 0.5694), control1: m.pt(-0.9634, 0.5911), control2: m.pt(-0.9242, 0.5878))
        p.addCurve(to: m.pt(-0.2900, 0.5477), control1: m.pt(-0.4767, 0.5477), control2: m.pt(-0.4767, 0.5477))
        p.addCurve(to: m.pt(-0.1017, 0.5468), control1: m.pt(-0.1132, 0.5477), control2: m.pt(-0.1032, 0.5476))
        p.addCurve(to: m.pt(-0.0831, 0.4517), control1: m.pt(-0.1002, 0.5459), control2: m.pt(-0.0987, 0.5382))
        p.addCurve(to: m.pt(-0.0522, 0.2850), control1: m.pt(-0.0738, 0.3999), control2: m.pt(-0.0598, 0.3249))
        p.addCurve(to: m.pt(-0.0398, 0.2112), control1: m.pt(-0.0382, 0.2123), control2: m.pt(-0.0382, 0.2123))
        p.addCurve(to: m.pt(-0.1674, 0.1958), control1: m.pt(-0.0411, 0.2104), control2: m.pt(-0.0599, 0.2081))
        p.addCurve(to: m.pt(-0.2976, 0.1809), control1: m.pt(-0.2367, 0.1879), control2: m.pt(-0.2953, 0.1812))
        p.addCurve(to: m.pt(-0.3150, 0.1105), control1: m.pt(-0.3154, 0.1784), control2: m.pt(-0.3196, 0.1612))
        p.addCurve(to: m.pt(-0.3071, 0.0788), control1: m.pt(-0.3127, 0.0855), control2: m.pt(-0.3113, 0.0800))
        p.addCurve(to: m.pt(-0.0416, 0.0478), control1: m.pt(-0.3023, 0.0776), control2: m.pt(-0.0431, 0.0473))
        p.addCurve(to: m.pt(-0.0299, 0.0695), control1: m.pt(-0.0398, 0.0484), control2: m.pt(-0.0407, 0.0468))
        p.addCurve(to: m.pt(-0.0170, 0.0932), control1: m.pt(-0.0187, 0.0932), control2: m.pt(-0.0187, 0.0932))
        p.addCurve(to: m.pt(-0.0138, 0.0670), control1: m.pt(-0.0141, 0.0932), control2: m.pt(-0.0138, 0.0914))
        p.addCurve(to: m.pt(-0.0031, 0.0019), control1: m.pt(-0.0138, 0.0295), control2: m.pt(-0.0101, 0.0070))
        p.addCurve(to: m.pt(0.0031, 0.0019), control1: m.pt(-0.0004, 0.0000), control2: m.pt(0.0004, 0.0000))
        p.addCurve(to: m.pt(0.0138, 0.0670), control1: m.pt(0.0101, 0.0070), control2: m.pt(0.0138, 0.0295))
        p.addCurve(to: m.pt(0.0170, 0.0932), control1: m.pt(0.0138, 0.0914), control2: m.pt(0.0141, 0.0932))
        p.addCurve(to: m.pt(0.0299, 0.0695), control1: m.pt(0.0187, 0.0932), control2: m.pt(0.0187, 0.0932))
        p.addCurve(to: m.pt(0.0416, 0.0478), control1: m.pt(0.0407, 0.0468), control2: m.pt(0.0398, 0.0484))
        p.addCurve(to: m.pt(0.3071, 0.0788), control1: m.pt(0.0431, 0.0473), control2: m.pt(0.3023, 0.0776))
        p.addCurve(to: m.pt(0.3150, 0.1105), control1: m.pt(0.3113, 0.0800), control2: m.pt(0.3127, 0.0855))
        p.addCurve(to: m.pt(0.2976, 0.1809), control1: m.pt(0.3196, 0.1612), control2: m.pt(0.3154, 0.1784))
        p.addCurve(to: m.pt(0.1674, 0.1958), control1: m.pt(0.2953, 0.1812), control2: m.pt(0.2367, 0.1879))
        p.addCurve(to: m.pt(0.0398, 0.2112), control1: m.pt(0.0599, 0.2081), control2: m.pt(0.0411, 0.2104))
        p.addCurve(to: m.pt(0.0522, 0.2850), control1: m.pt(0.0382, 0.2123), control2: m.pt(0.0382, 0.2123))
        p.addCurve(to: m.pt(0.0831, 0.4517), control1: m.pt(0.0598, 0.3249), control2: m.pt(0.0738, 0.3999))
        p.addCurve(to: m.pt(0.1017, 0.5468), control1: m.pt(0.0987, 0.5382), control2: m.pt(0.1002, 0.5459))
        p.addCurve(to: m.pt(0.2900, 0.5477), control1: m.pt(0.1032, 0.5476), control2: m.pt(0.1132, 0.5477))
        p.addCurve(to: m.pt(0.7185, 0.5694), control1: m.pt(0.4767, 0.5477), control2: m.pt(0.4767, 0.5477))
        p.addCurve(to: m.pt(0.9802, 0.5919), control1: m.pt(0.9242, 0.5878), control2: m.pt(0.9634, 0.5911))
        p.addLine(to: m.pt(1.0000, 0.5928))
        p.addLine(to: m.pt(1.0000, 0.6522))
        p.addCurve(to: m.pt(0.9982, 0.7144), control1: m.pt(1.0000, 0.7116), control2: m.pt(1.0000, 0.7116))
        p.addCurve(to: m.pt(0.9951, 0.7195), control1: m.pt(0.9972, 0.7159), control2: m.pt(0.9958, 0.7182))
        p.addCurve(to: m.pt(0.9700, 0.7338), control1: m.pt(0.9909, 0.7271), control2: m.pt(0.9801, 0.7333))
        p.addCurve(to: m.pt(0.7196, 0.7440), control1: m.pt(0.9677, 0.7339), control2: m.pt(0.8550, 0.7385))
        p.addCurve(to: m.pt(0.2883, 0.7540), control1: m.pt(0.4735, 0.7540), control2: m.pt(0.4735, 0.7540))
        p.addCurve(to: m.pt(0.1015, 0.7551), control1: m.pt(0.1041, 0.7540), control2: m.pt(0.1031, 0.7540))
        p.addCurve(to: m.pt(0.1000, 0.7697), control1: m.pt(0.1001, 0.7560), control2: m.pt(0.1000, 0.7568))
        p.addCurve(to: m.pt(0.0962, 0.8286), control1: m.pt(0.1000, 0.7817), control2: m.pt(0.0986, 0.8024))
        p.addCurve(to: m.pt(0.0715, 0.9370), control1: m.pt(0.0930, 0.8609), control2: m.pt(0.0777, 0.9282))
        p.addCurve(to: m.pt(0.0435, 0.9465), control1: m.pt(0.0668, 0.9437), control2: m.pt(0.0599, 0.9459))
        p.addCurve(to: m.pt(0.0258, 0.9499), control1: m.pt(0.0302, 0.9469), control2: m.pt(0.0265, 0.9476))
        p.addCurve(to: m.pt(-0.0021, 0.9959), control1: m.pt(0.0181, 0.9748), control2: m.pt(0.0028, 1.0000))
        p.closeSubpath()
        return p
    }
}

// =============================================================================
// MARK: - PROCEDURAL HELICOPTER (Bell 206 proportions)
//
// The one shape NOT a literal trace. The PD Bell OH-58A Kiowa plan-view
// (the military Bell 206; tools/cards/SOURCES.md) is a dimensioned
// engineering drawing — its rotor blades and dimension/leader lines bridge
// the airframe interior to the page exterior, so a flood-fill silhouette
// leaks and won't isolate. Instead this body is hand-built to the MEASURED
// Bell 206 plan proportions (cabin in the forward third, thin tail boom ~half
// the length, tail rotor + horizontal stabilizer at the rear, skids), and the
// disc + crossed main-rotor blades stay procedural — the disc is a separate
// HeliRotorDisc the host strokes faintly underneath. The disc + two crossed
// blades + thin boom + tail rotor are what make a helicopter read from above.
// =============================================================================

/// Light helicopter (Bell 206 class). Teardrop cabin in the forward third,
/// thin tail boom, small tail rotor + horizontal stabilizer, landing skids,
/// and two crossed main-rotor blades through the hub. The faint rotor disc is
/// drawn separately by the host (HeliRotorDisc) so it doesn't even-odd against
/// the body fill. This is the one silhouette where the DISC, not a wing, is the
/// dominant read.
nonisolated struct HeliSilhouette: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let m = PlanFormMap(rect: rect, aspect: 0.83)
        var p = Path()

        // Rotor-hub center sits over the cabin, ~one-third back from the nose.
        let hubY: CGFloat = 0.33
        let discR: CGFloat = 1.0          // disc radius in normalized span units (fills ±1)

        // --- Cabin (teardrop) + thin tail boom + tail-rotor stub ---
        let body: CGFloat = 0.135         // cabin half-width (Bell 206 cabin is broad)
        let boom: CGFloat = 0.026         // tail-boom half-width (thin)
        p.move(to: m.pt(0.0, 0.085))                       // nose of the cabin (rounded chin)
        // right side of the cabin: nose → widest point near the hub → taper into boom
        p.addCurve(to: m.pt(body, hubY),
                   control1: m.pt(body * 0.85, 0.115),
                   control2: m.pt(body, hubY - 0.10))
        p.addCurve(to: m.pt(boom, 0.55),
                   control1: m.pt(body, hubY + 0.12),
                   control2: m.pt(body * 0.45, 0.49))
        p.addLine(to: m.pt(boom, 0.86))                    // straight thin tail boom
        // small horizontal stabilizer to the right at the boom end
        p.addLine(to: m.pt(0.135, 0.875))
        p.addLine(to: m.pt(0.135, 0.915))
        p.addLine(to: m.pt(boom, 0.905))
        // tail-rotor stub off the very end (right side)
        p.addLine(to: m.pt(boom, 0.945))
        p.addLine(to: m.pt(0.075, 0.965))
        p.addLine(to: m.pt(0.075, 0.985))
        p.addLine(to: m.pt(0.0, 0.985))                    // boom tip / tail-rotor centerline
        // --- mirror back up the left side ---
        p.addLine(to: m.pt(-0.075, 0.985))
        p.addLine(to: m.pt(-0.075, 0.965))
        p.addLine(to: m.pt(-boom, 0.945))
        p.addLine(to: m.pt(-boom, 0.905))
        p.addLine(to: m.pt(-0.135, 0.915))
        p.addLine(to: m.pt(-0.135, 0.875))
        p.addLine(to: m.pt(-boom, 0.86))
        p.addLine(to: m.pt(-boom, 0.55))
        p.addCurve(to: m.pt(-body, hubY),
                   control1: m.pt(-body * 0.45, 0.49),
                   control2: m.pt(-body, hubY + 0.12))
        p.addCurve(to: m.pt(0.0, 0.085),
                   control1: m.pt(-body, hubY - 0.10),
                   control2: m.pt(-body * 0.85, 0.115))
        p.closeSubpath()

        // Landing skids are intentionally OMITTED. From directly above, the
        // disc + two crossed main-rotor blades + thin boom + tail rotor already
        // read unambiguously as a helicopter; adding skid rails under the cabin
        // only fought the even-odd fill (the rails, struts, and crossing blades
        // enclosed regions that hollowed out), so the cleaner read wins.

        // --- Two crossed main-rotor blades through the hub (thin rectangles) ---
        let hub = m.pt(0.0, hubY)
        let bladeHalfLen = (m.pt(discR, 0).x - m.pt(0, 0).x) * 0.97
        let bladeHalfW: CGFloat = (m.pt(0.028, 0).x - m.pt(0, 0).x)
        for angle in [CGFloat(0.42), CGFloat(-0.42)] {     // ~±24° from horizontal
            let dx = cos(angle), dy = sin(angle)
            let px = -dy, py = dx                            // perpendicular for width
            var blade = Path()
            blade.move(to: CGPoint(x: hub.x - dx * bladeHalfLen + px * bladeHalfW,
                                   y: hub.y - dy * bladeHalfLen + py * bladeHalfW))
            blade.addLine(to: CGPoint(x: hub.x + dx * bladeHalfLen + px * bladeHalfW,
                                      y: hub.y + dy * bladeHalfLen + py * bladeHalfW))
            blade.addLine(to: CGPoint(x: hub.x + dx * bladeHalfLen - px * bladeHalfW,
                                      y: hub.y + dy * bladeHalfLen - py * bladeHalfW))
            blade.addLine(to: CGPoint(x: hub.x - dx * bladeHalfLen - px * bladeHalfW,
                                      y: hub.y - dy * bladeHalfLen - py * bladeHalfW))
            blade.closeSubpath()
            p.addPath(blade)
        }
        return p
    }
}

// MARK: - Faint rotor-disc ring (helicopter only, drawn by the host)

/// The translucent rotor disc for the helicopter. Kept separate from the
/// solid body Shape so the host can stroke it faintly under the blades
/// without it joining the even-odd fill of the fuselage. Returns a
/// circle centered on the rotor hub.
nonisolated struct HeliRotorDisc: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let m = PlanFormMap(rect: rect, aspect: 0.83)
        let hub = m.pt(0.0, 0.33)
        let r = (m.pt(1.0, 0).x - m.pt(0, 0).x)
        return Path(ellipseIn: CGRect(x: hub.x - r, y: hub.y - r, width: r * 2, height: r * 2))
    }
}
