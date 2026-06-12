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
    ///   747  (NASA SCA trace)    ~1.04   (wide swept stabilizer in the span)
    ///   Citation slot (Learjet)  ~0.90
    ///   C172 (Cessna trace)       1.34   (span EXCEEDS length — the GA tell)
    ///   Heli  rotor disc ~10 m, fuselage+boom ~12 m → ~0.83
    var aspect: CGFloat {
        switch self {
        case .a320:     return 0.996
        case .b747:     return 1.043
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
/// Source: commons.wikimedia.org/wiki/File:Boeing_KC-46_Pegasus_plan_view_silhouette_drawing.jpg
/// License: Public domain (US Air Force / Philip Bryant). See tools/cards/SOURCES.md.
nonisolated struct A320Silhouette: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let m = PlanFormMap(rect: rect, aspect: 0.9960)
        var p = Path()
        p.move(to: m.pt(-0.0172, 0.9897))
        p.addCurve(to: m.pt(-0.0899, 0.9078), control1: m.pt(-0.0548, 0.9676), control2: m.pt(-0.0822, 0.9368))
        p.addCurve(to: m.pt(-0.1023, 0.7333), control1: m.pt(-0.0964, 0.8828), control2: m.pt(-0.1002, 0.8318))
        p.addCurve(to: m.pt(-0.1084, 0.6660), control1: m.pt(-0.1038, 0.6698), control2: m.pt(-0.1038, 0.6698))
        p.addCurve(to: m.pt(-0.2513, 0.6124), control1: m.pt(-0.1181, 0.6581), control2: m.pt(-0.1313, 0.6532))
        p.addCurve(to: m.pt(-0.2749, 0.6350), control1: m.pt(-0.2762, 0.6039), control2: m.pt(-0.2741, 0.6019))
        p.addCurve(to: m.pt(-0.3292, 0.6737), control1: m.pt(-0.2761, 0.6752), control2: m.pt(-0.2741, 0.6737))
        p.addCurve(to: m.pt(-0.3852, 0.6357), control1: m.pt(-0.3859, 0.6737), control2: m.pt(-0.3852, 0.6742))
        p.addCurve(to: m.pt(-0.3712, 0.5828), control1: m.pt(-0.3852, 0.6050), control2: m.pt(-0.3836, 0.5991))
        p.addCurve(to: m.pt(-0.3669, 0.5744), control1: m.pt(-0.3682, 0.5788), control2: m.pt(-0.3665, 0.5753))
        p.addCurve(to: m.pt(-0.5338, 0.5164), control1: m.pt(-0.3676, 0.5729), control2: m.pt(-0.3824, 0.5677))
        p.addCurve(to: m.pt(-0.6223, 0.4865), control1: m.pt(-0.5434, 0.5132), control2: m.pt(-0.5831, 0.4997))
        p.addCurve(to: m.pt(-0.7180, 0.4541), control1: m.pt(-0.6613, 0.4733), control2: m.pt(-0.7044, 0.4587))
        p.addCurve(to: m.pt(-0.8277, 0.4173), control1: m.pt(-0.8013, 0.4258), control2: m.pt(-0.8254, 0.4177))
        p.addCurve(to: m.pt(-0.8357, 0.4229), control1: m.pt(-0.8317, 0.4165), control2: m.pt(-0.8336, 0.4179))
        p.addCurve(to: m.pt(-0.8608, 0.4149), control1: m.pt(-0.8431, 0.4404), control2: m.pt(-0.8583, 0.4355))
        p.addCurve(to: m.pt(-0.9218, 0.3851), control1: m.pt(-0.8621, 0.4045), control2: m.pt(-0.8570, 0.4070))
        p.addCurve(to: m.pt(-0.9984, 0.3343), control1: m.pt(-0.9964, 0.3600), control2: m.pt(-1.0000, 0.3575))
        p.addCurve(to: m.pt(-0.9476, 0.3233), control1: m.pt(-0.9970, 0.3146), control2: m.pt(-0.9946, 0.3141))
        p.addCurve(to: m.pt(-0.8550, 0.3327), control1: m.pt(-0.8535, 0.3420), control2: m.pt(-0.8579, 0.3416))
        p.addCurve(to: m.pt(-0.8383, 0.3365), control1: m.pt(-0.8506, 0.3192), control2: m.pt(-0.8409, 0.3214))
        p.addCurve(to: m.pt(-0.7481, 0.3615), control1: m.pt(-0.8367, 0.3456), control2: m.pt(-0.8457, 0.3431))
        p.addCurve(to: m.pt(-0.6657, 0.3752), control1: m.pt(-0.6734, 0.3755), control2: m.pt(-0.6705, 0.3760))
        p.addCurve(to: m.pt(-0.6552, 0.3772), control1: m.pt(-0.6607, 0.3743), control2: m.pt(-0.6605, 0.3743))
        p.addCurve(to: m.pt(-0.5730, 0.3945), control1: m.pt(-0.6502, 0.3799), control2: m.pt(-0.6459, 0.3808))
        p.addCurve(to: m.pt(-0.4852, 0.4081), control1: m.pt(-0.4990, 0.4083), control2: m.pt(-0.4900, 0.4097))
        p.addCurve(to: m.pt(-0.4780, 0.4103), control1: m.pt(-0.4836, 0.4075), control2: m.pt(-0.4819, 0.4080))
        p.addCurve(to: m.pt(-0.3460, 0.4362), control1: m.pt(-0.4726, 0.4134), control2: m.pt(-0.3736, 0.4328))
        p.addCurve(to: m.pt(-0.2655, 0.4406), control1: m.pt(-0.3118, 0.4404), control2: m.pt(-0.2709, 0.4426))
        p.addCurve(to: m.pt(-0.2565, 0.4411), control1: m.pt(-0.2614, 0.4390), control2: m.pt(-0.2614, 0.4390))
        p.addCurve(to: m.pt(-0.2510, 0.4433), control1: m.pt(-0.2539, 0.4424), control2: m.pt(-0.2513, 0.4433))
        p.addCurve(to: m.pt(-0.2195, 0.4447), control1: m.pt(-0.2506, 0.4433), control2: m.pt(-0.2365, 0.4439))
        p.addCurve(to: m.pt(-0.1012, 0.4471), control1: m.pt(-0.1435, 0.4482), control2: m.pt(-0.1032, 0.4490))
        p.addCurve(to: m.pt(-0.0988, 0.3478), control1: m.pt(-0.1004, 0.4464), control2: m.pt(-0.0994, 0.4037))
        p.addCurve(to: m.pt(-0.0920, 0.2146), control1: m.pt(-0.0978, 0.2497), control2: m.pt(-0.0974, 0.2396))
        p.addCurve(to: m.pt(-0.0791, 0.1707), control1: m.pt(-0.0887, 0.1987), control2: m.pt(-0.0832, 0.1797))
        p.addCurve(to: m.pt(-0.0756, 0.1599), control1: m.pt(-0.0768, 0.1655), control2: m.pt(-0.0752, 0.1607))
        p.addCurve(to: m.pt(-0.2700, 0.0795), control1: m.pt(-0.0787, 0.1553), control2: m.pt(-0.0809, 0.1543))
        p.addCurve(to: m.pt(-0.3847, 0.0237), control1: m.pt(-0.3930, 0.0308), control2: m.pt(-0.3836, 0.0355))
        p.addCurve(to: m.pt(-0.3630, 0.0035), control1: m.pt(-0.3865, 0.0040), control2: m.pt(-0.3823, 0.0000))
        p.addCurve(to: m.pt(-0.2234, 0.0211), control1: m.pt(-0.3596, 0.0042), control2: m.pt(-0.2968, 0.0121))
        p.addCurve(to: m.pt(-0.0849, 0.0500), control1: m.pt(-0.0682, 0.0403), control2: m.pt(-0.0849, 0.0369))
        p.addCurve(to: m.pt(0.0101, 0.0621), control1: m.pt(-0.0849, 0.0636), control2: m.pt(-0.0965, 0.0621))
        p.addCurve(to: m.pt(0.1051, 0.0491), control1: m.pt(0.1171, 0.0621), control2: m.pt(0.1051, 0.0637))
        p.addCurve(to: m.pt(0.1119, 0.0357), control1: m.pt(0.1051, 0.0382), control2: m.pt(0.1058, 0.0369))
        p.addCurve(to: m.pt(0.3781, 0.0027), control1: m.pt(0.1189, 0.0342), control2: m.pt(0.3709, 0.0031))
        p.addCurve(to: m.pt(0.3870, 0.0162), control1: m.pt(0.3859, 0.0023), control2: m.pt(0.3857, 0.0020))
        p.addCurve(to: m.pt(0.3483, 0.0497), control1: m.pt(0.3888, 0.0333), control2: m.pt(0.3878, 0.0342))
        p.addCurve(to: m.pt(0.0859, 0.1540), control1: m.pt(0.2411, 0.0918), control2: m.pt(0.0917, 0.1513))
        p.addCurve(to: m.pt(0.0823, 0.1747), control1: m.pt(0.0765, 0.1585), control2: m.pt(0.0764, 0.1592))
        p.addCurve(to: m.pt(0.0977, 0.2376), control1: m.pt(0.0891, 0.1921), control2: m.pt(0.0942, 0.2130))
        p.addCurve(to: m.pt(0.1002, 0.3470), control1: m.pt(0.0986, 0.2431), control2: m.pt(0.0996, 0.2924))
        p.addCurve(to: m.pt(0.1148, 0.4487), control1: m.pt(0.1013, 0.4607), control2: m.pt(0.0997, 0.4493))
        p.addCurve(to: m.pt(0.1595, 0.4472), control1: m.pt(0.1194, 0.4485), control2: m.pt(0.1396, 0.4478))
        p.addCurve(to: m.pt(0.2234, 0.4448), control1: m.pt(0.1795, 0.4465), control2: m.pt(0.2082, 0.4455))
        p.addCurve(to: m.pt(0.2612, 0.4401), control1: m.pt(0.2516, 0.4436), control2: m.pt(0.2517, 0.4435))
        p.addCurve(to: m.pt(0.2658, 0.4406), control1: m.pt(0.2625, 0.4396), control2: m.pt(0.2639, 0.4398))
        p.addCurve(to: m.pt(0.3067, 0.4401), control1: m.pt(0.2696, 0.4423), control2: m.pt(0.2780, 0.4422))
        p.addCurve(to: m.pt(0.4177, 0.4240), control1: m.pt(0.3486, 0.4370), control2: m.pt(0.3457, 0.4374))
        p.addCurve(to: m.pt(0.4794, 0.4105), control1: m.pt(0.4799, 0.4125), control2: m.pt(0.4758, 0.4134))
        p.addCurve(to: m.pt(0.4857, 0.4085), control1: m.pt(0.4819, 0.4085), control2: m.pt(0.4832, 0.4081))
        p.addCurve(to: m.pt(0.4918, 0.4093), control1: m.pt(0.4873, 0.4088), control2: m.pt(0.4902, 0.4091))
        p.addCurve(to: m.pt(0.5476, 0.3999), control1: m.pt(0.4938, 0.4095), control2: m.pt(0.5151, 0.4059))
        p.addCurve(to: m.pt(0.6571, 0.3775), control1: m.pt(0.6578, 0.3793), control2: m.pt(0.6522, 0.3805))
        p.addCurve(to: m.pt(0.6661, 0.3757), control1: m.pt(0.6615, 0.3749), control2: m.pt(0.6619, 0.3749))
        p.addCurve(to: m.pt(0.6739, 0.3762), control1: m.pt(0.6686, 0.3762), control2: m.pt(0.6721, 0.3765))
        p.addCurve(to: m.pt(0.8288, 0.3470), control1: m.pt(0.6795, 0.3753), control2: m.pt(0.8215, 0.3486))
        p.addCurve(to: m.pt(0.8396, 0.3370), control1: m.pt(0.8370, 0.3453), control2: m.pt(0.8384, 0.3439))
        p.addCurve(to: m.pt(0.8551, 0.3305), control1: m.pt(0.8420, 0.3235), control2: m.pt(0.8506, 0.3200))
        p.addCurve(to: m.pt(0.8635, 0.3399), control1: m.pt(0.8590, 0.3398), control2: m.pt(0.8590, 0.3399))
        p.addCurve(to: m.pt(0.9649, 0.3210), control1: m.pt(0.8671, 0.3399), control2: m.pt(0.9237, 0.3294))
        p.addCurve(to: m.pt(1.0000, 0.3378), control1: m.pt(0.9943, 0.3150), control2: m.pt(1.0000, 0.3177))
        p.addCurve(to: m.pt(0.9516, 0.3763), control1: m.pt(1.0000, 0.3565), control2: m.pt(0.9923, 0.3626))
        p.addCurve(to: m.pt(0.8616, 0.4164), control1: m.pt(0.8522, 0.4097), control2: m.pt(0.8629, 0.4050))
        p.addCurve(to: m.pt(0.8376, 0.4247), control1: m.pt(0.8596, 0.4355), control2: m.pt(0.8435, 0.4410))
        p.addCurve(to: m.pt(0.8097, 0.4241), control1: m.pt(0.8344, 0.4163), control2: m.pt(0.8331, 0.4163))
        p.addCurve(to: m.pt(0.6388, 0.4817), control1: m.pt(0.7903, 0.4307), control2: m.pt(0.6634, 0.4734))
        p.addCurve(to: m.pt(0.5003, 0.5285), control1: m.pt(0.6062, 0.4927), control2: m.pt(0.5887, 0.4986))
        p.addCurve(to: m.pt(0.3884, 0.5663), control1: m.pt(0.4501, 0.5454), control2: m.pt(0.3997, 0.5625))
        p.addCurve(to: m.pt(0.3712, 0.5825), control1: m.pt(0.3641, 0.5745), control2: m.pt(0.3647, 0.5740))
        p.addCurve(to: m.pt(0.3852, 0.6525), control1: m.pt(0.3840, 0.5988), control2: m.pt(0.3884, 0.6208))
        p.addCurve(to: m.pt(0.3306, 0.6744), control1: m.pt(0.3831, 0.6730), control2: m.pt(0.3798, 0.6744))
        p.addCurve(to: m.pt(0.2752, 0.6357), control1: m.pt(0.2748, 0.6744), control2: m.pt(0.2758, 0.6751))
        p.addCurve(to: m.pt(0.2749, 0.6079), control1: m.pt(0.2751, 0.6209), control2: m.pt(0.2749, 0.6083))
        p.addCurve(to: m.pt(0.1535, 0.6462), control1: m.pt(0.2746, 0.6047), control2: m.pt(0.2622, 0.6087))
        p.addCurve(to: m.pt(0.1029, 0.7089), control1: m.pt(0.1010, 0.6642), control2: m.pt(0.1041, 0.6605))
        p.addCurve(to: m.pt(0.0436, 0.9709), control1: m.pt(0.0984, 0.9068), control2: m.pt(0.0930, 0.9305))
        p.addCurve(to: m.pt(-0.0172, 0.9897), control1: m.pt(0.0125, 0.9962), control2: m.pt(0.0004, 1.0000))
        p.closeSubpath()
        return p
    }
}

// MARK: - B747 (traced)

/// Boeing 747 widebody-quad slot. Traced from the PUBLIC-DOMAIN NASA
/// Shuttle Carrier Aircraft 3-view (top panel) — a true orthographic 747 plan.
/// The orbiter sits on the spine and largely disappears into the fuselage
/// outline from directly above; the four underwing engines, heavy wing sweep,
/// and swept horizontal stabilizer all read true.
/// Source: commons.wikimedia.org/wiki/File:Shuttle_Carrier_Aircraft_diagram.gif
/// License: Public domain (NASA). See tools/cards/SOURCES.md.
nonisolated struct B747Silhouette: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let m = PlanFormMap(rect: rect, aspect: 1.0430)
        var p = Path()
        p.move(to: m.pt(-0.0451, 0.9892))
        p.addCurve(to: m.pt(-0.0732, 0.9489), control1: m.pt(-0.0567, 0.9745), control2: m.pt(-0.0682, 0.9579))
        p.addCurve(to: m.pt(-0.0924, 0.9114), control1: m.pt(-0.0826, 0.9317), control2: m.pt(-0.0899, 0.9173))
        p.addCurve(to: m.pt(-0.1002, 0.8942), control1: m.pt(-0.0937, 0.9080), control2: m.pt(-0.0972, 0.9002))
        p.addCurve(to: m.pt(-0.1092, 0.8721), control1: m.pt(-0.1032, 0.8881), control2: m.pt(-0.1072, 0.8782))
        p.addCurve(to: m.pt(-0.1161, 0.8593), control1: m.pt(-0.1123, 0.8632), control2: m.pt(-0.1135, 0.8608))
        p.addCurve(to: m.pt(-0.1193, 0.8557), control1: m.pt(-0.1179, 0.8583), control2: m.pt(-0.1193, 0.8567))
        p.addCurve(to: m.pt(-0.1374, 0.8397), control1: m.pt(-0.1193, 0.8523), control2: m.pt(-0.1276, 0.8450))
        p.addCurve(to: m.pt(-0.3332, 0.7532), control1: m.pt(-0.1517, 0.8321), control2: m.pt(-0.3301, 0.7532))
        p.addCurve(to: m.pt(-0.3360, 0.7702), control1: m.pt(-0.3358, 0.7532), control2: m.pt(-0.3359, 0.7537))
        p.addCurve(to: m.pt(-0.3417, 0.7914), control1: m.pt(-0.3360, 0.7888), control2: m.pt(-0.3364, 0.7900))
        p.addCurve(to: m.pt(-0.4240, 0.7920), control1: m.pt(-0.3470, 0.7929), control2: m.pt(-0.4196, 0.7934))
        p.addCurve(to: m.pt(-0.4276, 0.7457), control1: m.pt(-0.4310, 0.7899), control2: m.pt(-0.4341, 0.7502))
        p.addCurve(to: m.pt(-0.4264, 0.7115), control1: m.pt(-0.4243, 0.7434), control2: m.pt(-0.4233, 0.7173))
        p.addCurve(to: m.pt(-0.6396, 0.6162), control1: m.pt(-0.4270, 0.7105), control2: m.pt(-0.6345, 0.6178))
        p.addCurve(to: m.pt(-0.6441, 0.6350), control1: m.pt(-0.6442, 0.6149), control2: m.pt(-0.6445, 0.6164))
        p.addCurve(to: m.pt(-0.6998, 0.6576), control1: m.pt(-0.6434, 0.6593), control2: m.pt(-0.6388, 0.6574))
        p.addCurve(to: m.pt(-0.7358, 0.6541), control1: m.pt(-0.7299, 0.6576), control2: m.pt(-0.7335, 0.6573))
        p.addCurve(to: m.pt(-0.7351, 0.6102), control1: m.pt(-0.7395, 0.6490), control2: m.pt(-0.7389, 0.6137))
        p.addCurve(to: m.pt(-0.7326, 0.5906), control1: m.pt(-0.7315, 0.6068), control2: m.pt(-0.7315, 0.6068))
        p.addCurve(to: m.pt(-0.7459, 0.5688), control1: m.pt(-0.7335, 0.5744), control2: m.pt(-0.7335, 0.5744))
        p.addCurve(to: m.pt(-0.8722, 0.5126), control1: m.pt(-0.7527, 0.5657), control2: m.pt(-0.8095, 0.5404))
        p.addCurve(to: m.pt(-0.9946, 0.4535), control1: m.pt(-0.9879, 0.4611), control2: m.pt(-0.9906, 0.4599))
        p.addCurve(to: m.pt(-0.9930, 0.3900), control1: m.pt(-1.0000, 0.4449), control2: m.pt(-0.9987, 0.3915))
        p.addCurve(to: m.pt(-0.7055, 0.4719), control1: m.pt(-0.9850, 0.3881), control2: m.pt(-0.9891, 0.3869))
        p.addCurve(to: m.pt(-0.4283, 0.5543), control1: m.pt(-0.5556, 0.5168), control2: m.pt(-0.4309, 0.5538))
        p.addCurve(to: m.pt(-0.3838, 0.5555), control1: m.pt(-0.4221, 0.5555), control2: m.pt(-0.3838, 0.5565))
        p.addCurve(to: m.pt(-0.3877, 0.5502), control1: m.pt(-0.3838, 0.5551), control2: m.pt(-0.3855, 0.5528))
        p.addCurve(to: m.pt(-0.4067, 0.4973), control1: m.pt(-0.3950, 0.5418), control2: m.pt(-0.4067, 0.5092))
        p.addCurve(to: m.pt(-0.2556, 0.4714), control1: m.pt(-0.4067, 0.4856), control2: m.pt(-0.4128, 0.4866))
        p.addCurve(to: m.pt(-0.1265, 0.4583), control1: m.pt(-0.1863, 0.4648), control2: m.pt(-0.1281, 0.4588))
        p.addCurve(to: m.pt(-0.1243, 0.4401), control1: m.pt(-0.1237, 0.4574), control2: m.pt(-0.1237, 0.4572))
        p.addCurve(to: m.pt(-0.1197, 0.3936), control1: m.pt(-0.1251, 0.4211), control2: m.pt(-0.1233, 0.4023))
        p.addCurve(to: m.pt(-0.1176, 0.3841), control1: m.pt(-0.1185, 0.3905), control2: m.pt(-0.1175, 0.3863))
        p.addCurve(to: m.pt(-0.0956, 0.2180), control1: m.pt(-0.1179, 0.3189), control2: m.pt(-0.1095, 0.2556))
        p.addCurve(to: m.pt(-0.0965, 0.1900), control1: m.pt(-0.0910, 0.2056), control2: m.pt(-0.0913, 0.1952))
        p.addCurve(to: m.pt(-0.3702, 0.0609), control1: m.pt(-0.0998, 0.1867), control2: m.pt(-0.3665, 0.0609))
        p.addCurve(to: m.pt(-0.3738, 0.0637), control1: m.pt(-0.3710, 0.0609), control2: m.pt(-0.3726, 0.0622))
        p.addCurve(to: m.pt(-0.3862, 0.0673), control1: m.pt(-0.3762, 0.0671), control2: m.pt(-0.3807, 0.0683))
        p.addCurve(to: m.pt(-0.3939, 0.0395), control1: m.pt(-0.3927, 0.0661), control2: m.pt(-0.3931, 0.0648))
        p.addCurve(to: m.pt(-0.3953, 0.0093), control1: m.pt(-0.3943, 0.0265), control2: m.pt(-0.3950, 0.0129))
        p.addCurve(to: m.pt(-0.3927, 0.0027), control1: m.pt(-0.3959, 0.0027), control2: m.pt(-0.3959, 0.0027))
        p.addCurve(to: m.pt(-0.3872, 0.0379), control1: m.pt(-0.3885, 0.0027), control2: m.pt(-0.3882, 0.0045))
        p.addCurve(to: m.pt(-0.3816, 0.0635), control1: m.pt(-0.3865, 0.0625), control2: m.pt(-0.3861, 0.0644))
        p.addCurve(to: m.pt(-0.3804, 0.0329), control1: m.pt(-0.3796, 0.0631), control2: m.pt(-0.3795, 0.0608))
        p.addCurve(to: m.pt(-0.3779, 0.0027), control1: m.pt(-0.3814, 0.0027), control2: m.pt(-0.3814, 0.0027))
        p.addCurve(to: m.pt(-0.3744, 0.0043), control1: m.pt(-0.3752, 0.0027), control2: m.pt(-0.3744, 0.0031))
        p.addCurve(to: m.pt(-0.3731, 0.0068), control1: m.pt(-0.3744, 0.0052), control2: m.pt(-0.3738, 0.0063))
        p.addCurve(to: m.pt(-0.0570, 0.0492), control1: m.pt(-0.3718, 0.0080), control2: m.pt(-0.0604, 0.0497))
        p.addCurve(to: m.pt(-0.0343, 0.0274), control1: m.pt(-0.0497, 0.0479), control2: m.pt(-0.0343, 0.0332))
        p.addCurve(to: m.pt(-0.0323, 0.0137), control1: m.pt(-0.0343, 0.0254), control2: m.pt(-0.0334, 0.0192))
        p.addCurve(to: m.pt(-0.0303, 0.0033), control1: m.pt(-0.0312, 0.0082), control2: m.pt(-0.0303, 0.0036))
        p.addCurve(to: m.pt(-0.0268, 0.0027), control1: m.pt(-0.0303, 0.0029), control2: m.pt(-0.0287, 0.0027))
        p.addCurve(to: m.pt(-0.0239, 0.0057), control1: m.pt(-0.0233, 0.0027), control2: m.pt(-0.0233, 0.0028))
        p.addCurve(to: m.pt(-0.0211, 0.0433), control1: m.pt(-0.0289, 0.0246), control2: m.pt(-0.0281, 0.0361))
        p.addCurve(to: m.pt(-0.0044, 0.0142), control1: m.pt(-0.0084, 0.0563), control2: m.pt(0.0009, 0.0403))
        p.addCurve(to: m.pt(-0.0033, 0.0028), control1: m.pt(-0.0068, 0.0026), control2: m.pt(-0.0068, 0.0026))
        p.addCurve(to: m.pt(0.0025, 0.0162), control1: m.pt(0.0001, 0.0031), control2: m.pt(0.0001, 0.0031))
        p.addCurve(to: m.pt(0.0156, 0.0441), control1: m.pt(0.0056, 0.0327), control2: m.pt(0.0079, 0.0378))
        p.addCurve(to: m.pt(0.1818, 0.0272), control1: m.pt(0.0237, 0.0509), control2: m.pt(0.0059, 0.0526))
        p.addCurve(to: m.pt(0.3395, 0.0037), control1: m.pt(0.2674, 0.0148), control2: m.pt(0.3383, 0.0043))
        p.addCurve(to: m.pt(0.3475, 0.0311), control1: m.pt(0.3475, 0.0000), control2: m.pt(0.3475, 0.0001))
        p.addCurve(to: m.pt(0.3495, 0.0600), control1: m.pt(0.3475, 0.0558), control2: m.pt(0.3478, 0.0596))
        p.addCurve(to: m.pt(0.3556, 0.0307), control1: m.pt(0.3553, 0.0612), control2: m.pt(0.3556, 0.0602))
        p.addCurve(to: m.pt(0.3590, 0.0027), control1: m.pt(0.3556, 0.0027), control2: m.pt(0.3556, 0.0027))
        p.addCurve(to: m.pt(0.3598, 0.0614), control1: m.pt(0.3637, 0.0027), control2: m.pt(0.3644, 0.0574))
        p.addCurve(to: m.pt(0.3418, 0.0604), control1: m.pt(0.3549, 0.0656), control2: m.pt(0.3451, 0.0651))
        p.addCurve(to: m.pt(0.3378, 0.0582), control1: m.pt(0.3408, 0.0588), control2: m.pt(0.3394, 0.0581))
        p.addCurve(to: m.pt(0.0697, 0.1892), control1: m.pt(0.3335, 0.0587), control2: m.pt(0.0732, 0.1858))
        p.addCurve(to: m.pt(0.0686, 0.2151), control1: m.pt(0.0646, 0.1943), control2: m.pt(0.0642, 0.2046))
        p.addCurve(to: m.pt(0.0965, 0.3639), control1: m.pt(0.0835, 0.2499), control2: m.pt(0.0930, 0.3014))
        p.addCurve(to: m.pt(0.0992, 0.3898), control1: m.pt(0.0972, 0.3768), control2: m.pt(0.0984, 0.3885))
        p.addCurve(to: m.pt(0.1056, 0.4322), control1: m.pt(0.1030, 0.3967), control2: m.pt(0.1049, 0.4088))
        p.addCurve(to: m.pt(0.1080, 0.4573), control1: m.pt(0.1061, 0.4509), control2: m.pt(0.1067, 0.4567))
        p.addCurve(to: m.pt(0.2393, 0.4694), control1: m.pt(0.1091, 0.4577), control2: m.pt(0.1680, 0.4632))
        p.addCurve(to: m.pt(0.3907, 0.4949), control1: m.pt(0.4007, 0.4834), control2: m.pt(0.3907, 0.4817))
        p.addCurve(to: m.pt(0.3738, 0.5467), control1: m.pt(0.3907, 0.5073), control2: m.pt(0.3803, 0.5392))
        p.addCurve(to: m.pt(0.3858, 0.5522), control1: m.pt(0.3684, 0.5529), control2: m.pt(0.3681, 0.5528))
        p.addCurve(to: m.pt(0.4086, 0.5511), control1: m.pt(0.3942, 0.5519), control2: m.pt(0.4046, 0.5514))
        p.addCurve(to: m.pt(0.6810, 0.4675), control1: m.pt(0.4152, 0.5505), control2: m.pt(0.4478, 0.5406))
        p.addCurve(to: m.pt(0.9748, 0.3812), control1: m.pt(1.0000, 0.3677), control2: m.pt(0.9665, 0.3775))
        p.addCurve(to: m.pt(0.9749, 0.4470), control1: m.pt(0.9796, 0.3833), control2: m.pt(0.9798, 0.4409))
        p.addCurve(to: m.pt(0.8481, 0.5082), control1: m.pt(0.9715, 0.4512), control2: m.pt(0.9699, 0.4520))
        p.addCurve(to: m.pt(0.7223, 0.5668), control1: m.pt(0.7802, 0.5396), control2: m.pt(0.7235, 0.5659))
        p.addCurve(to: m.pt(0.7233, 0.6033), control1: m.pt(0.7180, 0.5695), control2: m.pt(0.7188, 0.5994))
        p.addCurve(to: m.pt(0.7253, 0.6473), control1: m.pt(0.7269, 0.6063), control2: m.pt(0.7285, 0.6428))
        p.addCurve(to: m.pt(0.6796, 0.6512), control1: m.pt(0.7227, 0.6509), control2: m.pt(0.7192, 0.6512))
        p.addCurve(to: m.pt(0.6322, 0.6285), control1: m.pt(0.6290, 0.6512), control2: m.pt(0.6331, 0.6532))
        p.addCurve(to: m.pt(0.6292, 0.6104), control1: m.pt(0.6315, 0.6119), control2: m.pt(0.6312, 0.6104))
        p.addCurve(to: m.pt(0.4220, 0.7051), control1: m.pt(0.6275, 0.6104), control2: m.pt(0.4452, 0.6936))
        p.addCurve(to: m.pt(0.4210, 0.7418), control1: m.pt(0.4159, 0.7081), control2: m.pt(0.4152, 0.7368))
        p.addCurve(to: m.pt(0.4229, 0.7857), control1: m.pt(0.4248, 0.7450), control2: m.pt(0.4264, 0.7817))
        p.addCurve(to: m.pt(0.3772, 0.7890), control1: m.pt(0.4202, 0.7888), control2: m.pt(0.4171, 0.7890))
        p.addCurve(to: m.pt(0.3300, 0.7677), control1: m.pt(0.3260, 0.7890), control2: m.pt(0.3309, 0.7912))
        p.addCurve(to: m.pt(0.3270, 0.7501), control1: m.pt(0.3293, 0.7520), control2: m.pt(0.3290, 0.7503))
        p.addCurve(to: m.pt(0.2369, 0.7905), control1: m.pt(0.3255, 0.7500), control2: m.pt(0.2931, 0.7644))
        p.addCurve(to: m.pt(0.1467, 0.8308), control1: m.pt(0.1817, 0.8159), control2: m.pt(0.1481, 0.8309))
        p.addCurve(to: m.pt(0.1440, 0.7738), control1: m.pt(0.1446, 0.8306), control2: m.pt(0.1444, 0.8263))
        p.addCurve(to: m.pt(0.1423, 0.7161), control1: m.pt(0.1439, 0.7333), control2: m.pt(0.1434, 0.7168))
        p.addCurve(to: m.pt(0.0833, 0.7160), control1: m.pt(0.1403, 0.7148), control2: m.pt(0.0857, 0.7147))
        p.addCurve(to: m.pt(0.0817, 0.8241), control1: m.pt(0.0821, 0.7167), control2: m.pt(0.0817, 0.7417))
        p.addCurve(to: m.pt(0.0484, 0.9872), control1: m.pt(0.0817, 0.9499), control2: m.pt(0.0840, 0.9389))
        p.addCurve(to: m.pt(0.0013, 0.9999), control1: m.pt(0.0392, 0.9996), control2: m.pt(0.0392, 0.9996))
        p.addCurve(to: m.pt(-0.0451, 0.9892), control1: m.pt(-0.0365, 1.0000), control2: m.pt(-0.0365, 1.0000))
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
/// Source: commons.wikimedia.org/wiki/File:Learjet_24_3-View_line_art.gif
/// License: Public domain (NASA). See tools/cards/SOURCES.md.
nonisolated struct CitationSilhouette: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let m = PlanFormMap(rect: rect, aspect: 0.9020)
        var p = Path()
        p.move(to: m.pt(-0.0970, 0.9992))
        p.addCurve(to: m.pt(-0.1429, 0.8940), control1: m.pt(-0.1071, 0.9860), control2: m.pt(-0.1322, 0.9286))
        p.addCurve(to: m.pt(-0.1495, 0.6732), control1: m.pt(-0.1541, 0.8571), control2: m.pt(-0.1589, 0.7016))
        p.addCurve(to: m.pt(-0.4880, 0.6267), control1: m.pt(-0.1478, 0.6682), control2: m.pt(-0.1251, 0.6713))
        p.addCurve(to: m.pt(-0.8251, 0.5859), control1: m.pt(-0.6707, 0.6043), control2: m.pt(-0.8224, 0.5859))
        p.addCurve(to: m.pt(-0.8331, 0.6038), control1: m.pt(-0.8322, 0.5859), control2: m.pt(-0.8331, 0.5880))
        p.addCurve(to: m.pt(-0.8408, 0.6876), control1: m.pt(-0.8331, 0.6275), control2: m.pt(-0.8368, 0.6680))
        p.addCurve(to: m.pt(-0.9105, 0.7373), control1: m.pt(-0.8486, 0.7269), control2: m.pt(-0.8847, 0.7526))
        p.addCurve(to: m.pt(-0.9442, 0.5389), control1: m.pt(-0.9432, 0.7181), control2: m.pt(-0.9565, 0.6386))
        p.addCurve(to: m.pt(-0.9457, 0.5222), control1: m.pt(-0.9427, 0.5268), control2: m.pt(-0.9429, 0.5260))
        p.addCurve(to: m.pt(-0.9442, 0.5069), control1: m.pt(-0.9504, 0.5162), control2: m.pt(-0.9499, 0.5117))
        p.addCurve(to: m.pt(-0.9367, 0.4867), control1: m.pt(-0.9398, 0.5032), control2: m.pt(-0.9395, 0.5025))
        p.addCurve(to: m.pt(-0.9245, 0.4279), control1: m.pt(-0.9341, 0.4722), control2: m.pt(-0.9302, 0.4534))
        p.addCurve(to: m.pt(-0.9245, 0.4182), control1: m.pt(-0.9233, 0.4219), control2: m.pt(-0.9233, 0.4195))
        p.addCurve(to: m.pt(-0.9976, 0.3751), control1: m.pt(-0.9265, 0.4163), control2: m.pt(-0.9941, 0.3765))
        p.addCurve(to: m.pt(-1.0000, 0.3635), control1: m.pt(-0.9995, 0.3744), control2: m.pt(-1.0000, 0.3724))
        p.addCurve(to: m.pt(-0.9432, 0.3528), control1: m.pt(-1.0000, 0.3528), control2: m.pt(-1.0000, 0.3528))
        p.addCurve(to: m.pt(-0.8848, 0.3533), control1: m.pt(-0.9120, 0.3528), control2: m.pt(-0.8857, 0.3530))
        p.addCurve(to: m.pt(-0.8677, 0.3917), control1: m.pt(-0.8795, 0.3549), control2: m.pt(-0.8753, 0.3644))
        p.addCurve(to: m.pt(-0.8520, 0.4405), control1: m.pt(-0.8580, 0.4261), control2: m.pt(-0.8538, 0.4394))
        p.addCurve(to: m.pt(-0.2738, 0.4409), control1: m.pt(-0.8492, 0.4424), control2: m.pt(-0.2779, 0.4428))
        p.addCurve(to: m.pt(-0.2701, 0.4347), control1: m.pt(-0.2719, 0.4401), control2: m.pt(-0.2707, 0.4382))
        p.addCurve(to: m.pt(-0.2226, 0.3170), control1: m.pt(-0.2559, 0.3646), control2: m.pt(-0.2382, 0.3206))
        p.addCurve(to: m.pt(-0.1777, 0.3176), control1: m.pt(-0.2182, 0.3160), control2: m.pt(-0.1862, 0.3164))
        p.addCurve(to: m.pt(-0.1656, 0.3258), control1: m.pt(-0.1726, 0.3183), control2: m.pt(-0.1692, 0.3206))
        p.addCurve(to: m.pt(-0.1397, 0.3304), control1: m.pt(-0.1626, 0.3299), control2: m.pt(-0.1597, 0.3304))
        p.addCurve(to: m.pt(-0.1152, 0.3204), control1: m.pt(-0.1173, 0.3304), control2: m.pt(-0.1167, 0.3302))
        p.addCurve(to: m.pt(-0.0767, 0.1749), control1: m.pt(-0.1089, 0.2794), control2: m.pt(-0.0895, 0.2061))
        p.addCurve(to: m.pt(-0.0777, 0.1611), control1: m.pt(-0.0725, 0.1646), control2: m.pt(-0.0726, 0.1627))
        p.addCurve(to: m.pt(-0.4072, 0.0766), control1: m.pt(-0.0829, 0.1595), control2: m.pt(-0.3919, 0.0802))
        p.addCurve(to: m.pt(-0.4459, 0.0535), control1: m.pt(-0.4260, 0.0722), control2: m.pt(-0.4394, 0.0642))
        p.addCurve(to: m.pt(-0.4508, 0.0039), control1: m.pt(-0.4490, 0.0483), control2: m.pt(-0.4534, 0.0053))
        p.addCurve(to: m.pt(-0.2444, 0.0203), control1: m.pt(-0.4480, 0.0024), control2: m.pt(-0.4426, 0.0028))
        p.addCurve(to: m.pt(-0.0403, 0.0377), control1: m.pt(-0.0498, 0.0375), control2: m.pt(-0.0451, 0.0378))
        p.addCurve(to: m.pt(-0.0143, 0.0161), control1: m.pt(-0.0335, 0.0375), control2: m.pt(-0.0185, 0.0250))
        p.addCurve(to: m.pt(-0.0107, 0.0088), control1: m.pt(-0.0129, 0.0132), control2: m.pt(-0.0113, 0.0100))
        p.addCurve(to: m.pt(0.0068, 0.0096), control1: m.pt(-0.0081, 0.0038), control2: m.pt(0.0048, 0.0044))
        p.addCurve(to: m.pt(0.0335, 0.0368), control1: m.pt(0.0108, 0.0202), control2: m.pt(0.0254, 0.0350))
        p.addCurve(to: m.pt(0.4430, 0.0005), control1: m.pt(0.0370, 0.0375), control2: m.pt(0.3956, 0.0058))
        p.addCurve(to: m.pt(0.4465, 0.0232), control1: m.pt(0.4480, 0.0000), control2: m.pt(0.4481, 0.0009))
        p.addCurve(to: m.pt(0.4060, 0.0745), control1: m.pt(0.4441, 0.0569), control2: m.pt(0.4358, 0.0674))
        p.addCurve(to: m.pt(0.0875, 0.1571), control1: m.pt(0.3973, 0.0766), control2: m.pt(0.1141, 0.1501))
        p.addCurve(to: m.pt(0.0765, 0.1801), control1: m.pt(0.0684, 0.1622), control2: m.pt(0.0690, 0.1608))
        p.addCurve(to: m.pt(0.1120, 0.3063), control1: m.pt(0.0901, 0.2150), control2: m.pt(0.1020, 0.2575))
        p.addCurve(to: m.pt(0.1158, 0.3254), control1: m.pt(0.1141, 0.3163), control2: m.pt(0.1158, 0.3249))
        p.addCurve(to: m.pt(0.1395, 0.3290), control1: m.pt(0.1158, 0.3282), control2: m.pt(0.1212, 0.3290))
        p.addCurve(to: m.pt(0.1666, 0.3231), control1: m.pt(0.1606, 0.3290), control2: m.pt(0.1621, 0.3287))
        p.addCurve(to: m.pt(0.1842, 0.3162), control1: m.pt(0.1714, 0.3172), control2: m.pt(0.1723, 0.3168))
        p.addCurve(to: m.pt(0.2245, 0.3168), control1: m.pt(0.2038, 0.3150), control2: m.pt(0.2202, 0.3153))
        p.addCurve(to: m.pt(0.2677, 0.4185), control1: m.pt(0.2373, 0.3214), control2: m.pt(0.2565, 0.3668))
        p.addCurve(to: m.pt(0.2761, 0.4400), control1: m.pt(0.2722, 0.4394), control2: m.pt(0.2719, 0.4387))
        p.addCurve(to: m.pt(0.4914, 0.4403), control1: m.pt(0.2797, 0.4410), control2: m.pt(0.2959, 0.4410))
        p.addCurve(to: m.pt(0.7761, 0.4395), control1: m.pt(0.6078, 0.4399), control2: m.pt(0.7359, 0.4395))
        p.addCurve(to: m.pt(0.8517, 0.4382), control1: m.pt(0.8465, 0.4395), control2: m.pt(0.8493, 0.4394))
        p.addCurve(to: m.pt(0.8662, 0.3961), control1: m.pt(0.8550, 0.4366), control2: m.pt(0.8564, 0.4327))
        p.addCurve(to: m.pt(0.8848, 0.3506), control1: m.pt(0.8755, 0.3616), control2: m.pt(0.8792, 0.3522))
        p.addCurve(to: m.pt(0.9433, 0.3501), control1: m.pt(0.8857, 0.3503), control2: m.pt(0.9120, 0.3501))
        p.addCurve(to: m.pt(1.0000, 0.3607), control1: m.pt(1.0000, 0.3501), control2: m.pt(1.0000, 0.3501))
        p.addCurve(to: m.pt(0.9956, 0.3734), control1: m.pt(1.0000, 0.3713), control2: m.pt(1.0000, 0.3713))
        p.addCurve(to: m.pt(0.9253, 0.4152), control1: m.pt(0.9895, 0.3763), control2: m.pt(0.9277, 0.4131))
        p.addCurve(to: m.pt(0.9277, 0.4352), control1: m.pt(0.9236, 0.4167), control2: m.pt(0.9239, 0.4196))
        p.addCurve(to: m.pt(0.9359, 0.4727), control1: m.pt(0.9302, 0.4452), control2: m.pt(0.9340, 0.4621))
        p.addCurve(to: m.pt(0.9408, 0.4964), control1: m.pt(0.9380, 0.4834), control2: m.pt(0.9402, 0.4940))
        p.addCurve(to: m.pt(0.9456, 0.5036), control1: m.pt(0.9414, 0.4996), control2: m.pt(0.9427, 0.5016))
        p.addCurve(to: m.pt(0.9478, 0.5198), control1: m.pt(0.9510, 0.5072), control2: m.pt(0.9520, 0.5148))
        p.addCurve(to: m.pt(0.9468, 0.5381), control1: m.pt(0.9451, 0.5231), control2: m.pt(0.9450, 0.5240))
        p.addCurve(to: m.pt(0.9332, 0.7159), control1: m.pt(0.9565, 0.6160), control2: m.pt(0.9511, 0.6879))
        p.addCurve(to: m.pt(0.8665, 0.7244), control1: m.pt(0.9156, 0.7433), control2: m.pt(0.8878, 0.7469))
        p.addCurve(to: m.pt(0.8356, 0.5943), control1: m.pt(0.8456, 0.7022), control2: m.pt(0.8391, 0.6748))
        p.addCurve(to: m.pt(0.8278, 0.5832), control1: m.pt(0.8353, 0.5848), control2: m.pt(0.8341, 0.5832))
        p.addCurve(to: m.pt(0.1666, 0.6659), control1: m.pt(0.8251, 0.5832), control2: m.pt(0.2077, 0.6605))
        p.addCurve(to: m.pt(0.1540, 0.6753), control1: m.pt(0.1540, 0.6676), control2: m.pt(0.1528, 0.6685))
        p.addCurve(to: m.pt(0.1534, 0.8773), control1: m.pt(0.1618, 0.7198), control2: m.pt(0.1615, 0.8260))
        p.addCurve(to: m.pt(0.1081, 0.9938), control1: m.pt(0.1495, 0.9021), control2: m.pt(0.1281, 0.9570))
        p.addCurve(to: m.pt(0.0042, 1.0000), control1: m.pt(0.1047, 1.0000), control2: m.pt(0.1047, 1.0000))
        p.addCurve(to: m.pt(-0.0970, 0.9992), control1: m.pt(-0.0749, 1.0000), control2: m.pt(-0.0965, 0.9998))
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
