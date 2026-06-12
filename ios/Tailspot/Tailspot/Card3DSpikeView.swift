//
//  Card3DSpikeView.swift
//  Tailspot
//
//  SPIKE — NOT shipped to production. Reachable only from the debug
//  overlay's TOOLS section (wrench → "3D card spike"). Explores a new
//  card-art direction: instead of a flat illustrated photo slot, the
//  catch card holds an interactive, "alive"-feeling 3D aircraft model
//  with presence in the frame (Noah's reference is Pokémon GO — the
//  creature has presence and feels alive without needing animation).
//
//  This file is deliberately self-contained. It does NOT modify
//  CatchCardView; it re-creates just enough of that card's visual
//  language (rarity rail, border, holo, badges, footer) around a
//  SceneKit viewport that replaces the photo slot. If the spike graduates,
//  the viewport gets folded into CatchCardView as an alternative
//  `photoView`.
//
//  ── How the "alive" feeling is built ────────────────────────────────
//  SceneKit gives us three levers and the spike leans on all three:
//    1. Lighting — a 3-point rig (ambient fill + key directional + cool
//       rim) so flat low-poly facets catch light and read as a solid
//       object, not a sticker. This is where most of the "presence"
//       comes from.
//    2. Hero framing — the camera sits slightly below and in front, so
//       the plane looms a touch (a dead-side orthographic view feels
//       like a blueprint, not a collectible).
//    3. Interaction — drag to orbit (yaw free, pitch clamped), pinch to
//       zoom, and a gentle idle yaw that the user can interrupt. Holding
//       and turning the model is what sells "it's really in there."
//
//  ── SceneKit / SwiftUI bridging notes (Noah's iOS learning) ──────────
//  SceneKit is UIKit-era, so we bridge it into SwiftUI with
//  `UIViewRepresentable` — the standard "wrap a UIView in a SwiftUI
//  View" protocol. `makeUIView` builds the SCNView once; `updateUIView`
//  is called whenever SwiftUI state changes (we don't need it here — the
//  gesture + idle animation drive everything imperatively inside the
//  view). A `Coordinator` object holds the mutable scene/gesture state
//  because a SwiftUI `View` is a value type and can't own long-lived
//  references.
//
//  Per repo convention (MainActor default isolation, Xcode 26): UI types
//  stay MainActor. SCNView, gesture handlers, and the coordinator all
//  touch UIKit, so they're all implicitly MainActor — correct here.
//

import SwiftUI
import SceneKit

// MARK: - Spike tuning constants

private enum Spike {
    /// Idle auto-rotation rate. ~12 s per full revolution (gentle).
    /// Set to 0 to disable the idle spin entirely (Noah: animation is
    /// optional — flip this to 0 to judge the static hero pose).
    static let idleYawRadiansPerSecond: CGFloat = (2 * .pi) / 12.0

    /// How long after the user lifts their finger before the idle spin
    /// resumes.
    static let idleResumeDelay: TimeInterval = 2.0

    /// Pitch clamp for drag-to-orbit. The user can tilt the nose up/down
    /// this far but no further — keeps the plane from flipping belly-up.
    static let maxPitchRadians: CGFloat = .pi / 6   // ±30°

    /// Pinch-zoom clamp, expressed as a camera-distance multiplier
    /// (smaller = closer). 0.8 = 25% closer, 1.5 = 50% further.
    static let minZoom: CGFloat = 0.8
    static let maxZoom: CGFloat = 1.5

    /// Drag sensitivity: screen points → radians of model rotation.
    static let dragRadiansPerPoint: CGFloat = 0.01

    /// Resting camera distance from the model (model is normalized to
    /// ~2 units across, centered at origin).
    static let baseCameraDistance: CGFloat = 4.2
}

// MARK: - SceneKit viewport (the "photo slot" replacement)

/// Renders the bundled low-poly aircraft with a flattering 3-point light
/// rig and constrained orbit/zoom gestures. Transparent background so the
/// card's own gradient shows through and the plane reads as embedded in
/// the card, not pasted on a gray box.
private struct Aircraft3DViewport: UIViewRepresentable {
    /// Rarity tint drives the rim light color so rare/epic/legendary
    /// planes get a subtly different glow — cheap way to make the tier
    /// feel like it changes the object, not just the frame.
    let rarityTint: UIColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView(frame: .zero)
        scnView.backgroundColor = .clear          // card shows through
        scnView.antialiasingMode = .multisampling4X
        scnView.isOpaque = false
        scnView.rendersContinuously = true         // drive the idle spin
        // allowsCameraControl is intentionally OFF — the built-in
        // controller is unconstrained (rolls, flips, unbounded zoom) and
        // feels cheap. We supply our own clamped gestures below.
        scnView.allowsCameraControl = false

        let scene = buildScene()
        scnView.scene = scene
        context.coordinator.configure(scnView: scnView, tint: rarityTint)

        // Gestures: pan to orbit, pinch to zoom. Both routed through the
        // coordinator so they can share the "user is interacting" flag
        // that pauses the idle spin.
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:)))
        scnView.addGestureRecognizer(pan)
        scnView.addGestureRecognizer(pinch)

        // Per-frame hook: SceneKit calls this on its render thread, but
        // we only read the clock and nudge a node's eulerAngles, which is
        // safe. Drives the idle yaw.
        scnView.delegate = context.coordinator

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // No SwiftUI-state-driven updates needed; the coordinator owns
        // all mutable interaction state. (If rarityTint could change live
        // we'd re-tint the rim here — it can't in the spike.)
    }

    // MARK: Scene construction

    /// Builds the full scene graph: model node (loaded from the bundled
    /// OBJ, re-materialized in code), camera, and the 3-point light rig.
    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        // ── Model ────────────────────────────────────────────────────
        // The OBJ ships in the app bundle (synchronized folder). We load
        // it via SCNScene(url:) and lift its content into a container
        // node so we can rotate the plane independently of the camera.
        let modelContainer = SCNNode()
        modelContainer.name = "modelContainer"
        if let url = Bundle.main.url(forResource: "Boeing747", withExtension: "obj"),
           let loaded = try? SCNScene(url: url, options: [
               .createNormalsIfAbsent: true
           ]) {
            for child in loaded.rootNode.childNodes {
                modelContainer.addChildNode(child)
            }
            applyMaterials(to: modelContainer)
        } else {
            // Defensive: if the asset is missing, drop in a placeholder
            // box so the viewport isn't an empty void (visible signal
            // that the bundle resource didn't ship).
            let box = SCNNode(geometry: SCNBox(width: 1.4, height: 0.3, length: 1.4, chamferRadius: 0.05))
            box.geometry?.firstMaterial?.diffuse.contents = UIColor.systemTeal
            modelContainer.addChildNode(box)
        }

        // Hero pose: nose toward the viewer's left-front, a slight bank
        // and a touch of nose-up so it reads as "in flight," not parked.
        modelContainer.eulerAngles = SCNVector3(
            x: -0.12,                 // gentle nose-up
            y: Float.pi * 0.78,       // three-quarter front view
            z: 0.05                   // barely-there bank
        )
        scene.rootNode.addChildNode(modelContainer)

        // ── Camera ───────────────────────────────────────────────────
        // Slightly below and in front of the model (hero angle). A modest
        // FOV keeps perspective foreshortening tasteful, not fisheye.
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 0.05
        camera.zFar = 100
        camera.wantsHDR = false
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, -0.55, Float(Spike.baseCameraDistance))
        // Aim at the model's mid-body, slightly above center, so the
        // plane sits in the upper-middle of the slot with headroom.
        cameraNode.look(at: SCNVector3(0, 0.05, 0))
        scene.rootNode.addChildNode(cameraNode)

        // ── 3-point light rig ────────────────────────────────────────
        // This is where "alive" lives. Flat low-poly facets need directional
        // light to differentiate faces; ambient alone looks like a decal.
        addLights(to: scene, tint: rarityTint)

        return scene
    }

    /// Re-materialize the loaded model in code. The OBJ's named groups
    /// (body / trim / glass) come through as separate geometries, but we
    /// don't depend on MTL parsing — we assign flat physically-based
    /// materials directly so the look is identical regardless of how
    /// SceneKit interpreted the sidecar MTL. The model carries 3 meshes;
    /// we tint by mesh order (largest = body) with a generic fallback.
    private func applyMaterials(to container: SCNNode) {
        // Collect every geometry-bearing node, sorted by triangle count
        // descending so index 0 is the fuselage (body), then trim, then
        // glass — matches the OBJ's authoring order but is robust to it.
        var geoNodes: [SCNNode] = []
        container.enumerateChildNodes { node, _ in
            if node.geometry != nil { geoNodes.append(node) }
        }
        geoNodes.sort { (a, b) in
            (a.geometry?.elements.first?.primitiveCount ?? 0) >
            (b.geometry?.elements.first?.primitiveCount ?? 0)
        }

        for (i, node) in geoNodes.enumerated() {
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            switch i {
            case 0:     // body — bright near-white, slightly glossy
                mat.diffuse.contents  = UIColor(white: 0.97, alpha: 1.0)
                mat.metalness.contents = 0.12
                mat.roughness.contents = 0.45
            case 1:     // trim — mid gray
                mat.diffuse.contents  = UIColor(white: 0.34, alpha: 1.0)
                mat.metalness.contents = 0.25
                mat.roughness.contents = 0.4
            default:    // glass — translucent cool tint
                mat.diffuse.contents  = UIColor(red: 0.55, green: 0.72, blue: 0.78, alpha: 1.0)
                mat.metalness.contents = 0.0
                mat.roughness.contents = 0.1
                mat.transparency = 0.55
            }
            // A faint specular sheen flatters the facets under the key light.
            mat.isDoubleSided = true
            node.geometry?.materials = [mat]
        }
    }

    /// Three-point lighting: ambient fill (so shadows aren't black), a
    /// warm key from upper-front-right (defines form), and a cool tinted
    /// rim from behind (separates the silhouette from the dark card).
    private func addLights(to scene: SCNScene, tint: UIColor) {
        // Ambient — low, just lifts the shadow side off pure black.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(white: 0.32, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // Key — the main shaping light, warm, upper-front-right.
        let key = SCNLight()
        key.type = .directional
        key.color = UIColor(red: 1.0, green: 0.97, blue: 0.9, alpha: 1.0)
        key.intensity = 950
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(3, 4, 4)
        keyNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(keyNode)

        // Fill — soft, opposite the key, low intensity, cool, kills the
        // dead-flat shadow side without flattening the form.
        let fill = SCNLight()
        fill.type = .directional
        fill.color = UIColor(red: 0.8, green: 0.88, blue: 1.0, alpha: 1.0)
        fill.intensity = 320
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.position = SCNVector3(-4, 1, 2)
        fillNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(fillNode)

        // Rim — behind + above, tinted by rarity, gives the "alive" glow
        // along the top edge of the fuselage so it pops off the dark card.
        let rim = SCNLight()
        rim.type = .directional
        rim.color = tint
        rim.intensity = 700
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.position = SCNVector3(-2, 5, -5)
        rimNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(rimNode)
    }

    // MARK: Coordinator (mutable interaction state)

    /// Holds the SCNView reference and all gesture/idle state. SceneKit
    /// render-loop callback + UIKit gesture targets both need an object
    /// (not the value-type SwiftUI View), so this is where the spike's
    /// interactivity actually lives.
    @MainActor
    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        private weak var scnView: SCNView?
        private var modelNode: SCNNode?
        private var cameraNode: SCNNode?

        /// Current accumulated orbit, in radians. Yaw wraps freely; pitch
        /// is clamped in handlePan.
        private var yaw: CGFloat = Float.pi.cgFloat * 0.78
        private var pitch: CGFloat = -0.12

        /// Camera-distance multiplier from pinch (clamped minZoom…maxZoom).
        private var zoom: CGFloat = 1.0
        private var pinchStartZoom: CGFloat = 1.0

        /// Idle-spin bookkeeping. While the user touches we freeze the
        /// auto-rotation; `idleResumeAt` is the clock time it may restart.
        private var isInteracting = false
        private var idleResumeAt: TimeInterval = 0
        private var lastFrameTime: TimeInterval = 0

        func configure(scnView: SCNView, tint: UIColor) {
            self.scnView = scnView
            self.modelNode = scnView.scene?.rootNode.childNode(withName: "modelContainer", recursively: false)
            self.cameraNode = scnView.scene?.rootNode.childNode(withName: "camera", recursively: false)
            applyTransform()
        }

        // ── Gestures ─────────────────────────────────────────────────

        @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            guard let view = scnView else { return }
            switch gr.state {
            case .began:
                isInteracting = true
            case .changed:
                let t = gr.translation(in: view)
                // Horizontal drag → yaw (free), vertical drag → pitch
                // (clamped). Reset the translation each step so we
                // accumulate deltas rather than absolute offsets.
                yaw += t.x * Spike.dragRadiansPerPoint
                pitch -= t.y * Spike.dragRadiansPerPoint
                pitch = max(-Spike.maxPitchRadians, min(Spike.maxPitchRadians, pitch))
                gr.setTranslation(.zero, in: view)
                applyTransform()
            case .ended, .cancelled, .failed:
                isInteracting = false
                idleResumeAt = CACurrentMediaTime() + Spike.idleResumeDelay
            default:
                break
            }
        }

        @objc func handlePinch(_ gr: UIPinchGestureRecognizer) {
            switch gr.state {
            case .began:
                isInteracting = true
                pinchStartZoom = zoom
            case .changed:
                // Pinch out (scale > 1) brings the plane closer → smaller
                // distance multiplier. Invert and clamp.
                let proposed = pinchStartZoom / gr.scale
                zoom = max(Spike.minZoom, min(Spike.maxZoom, proposed))
                applyCameraDistance()
            case .ended, .cancelled, .failed:
                isInteracting = false
                idleResumeAt = CACurrentMediaTime() + Spike.idleResumeDelay
            default:
                break
            }
        }

        // ── Transform application ────────────────────────────────────

        private func applyTransform() {
            modelNode?.eulerAngles = SCNVector3(Float(pitch), Float(yaw), 0.05)
            applyCameraDistance()
        }

        private func applyCameraDistance() {
            guard let cam = cameraNode else { return }
            let d = Spike.baseCameraDistance * zoom
            cam.position = SCNVector3(0, -0.55, Float(d))
            cam.look(at: SCNVector3(0, 0.05, 0))
        }

        // ── Idle spin (render-loop driven) ───────────────────────────

        nonisolated func renderer(_ renderer: SCNSceneRenderer,
                                  updateAtTime time: TimeInterval) {
            // SceneKit calls this off the main actor on its render thread.
            // Hop to the main actor to touch our state + the node.
            Task { @MainActor in
                self.advanceIdle(time)
            }
        }

        private func advanceIdle(_ time: TimeInterval) {
            defer { lastFrameTime = time }
            guard lastFrameTime != 0 else { return }   // skip first frame
            let dt = time - lastFrameTime
            guard !isInteracting,
                  time >= idleResumeAt,
                  Spike.idleYawRadiansPerSecond != 0 else { return }
            yaw += Spike.idleYawRadiansPerSecond * CGFloat(dt)
            modelNode?.eulerAngles = SCNVector3(Float(pitch), Float(yaw), 0.05)
        }
    }
}

private extension Float {
    var cgFloat: CGFloat { CGFloat(self) }
}

// MARK: - The spike card

/// A catch card whose photo slot is replaced by the interactive 3D
/// viewport. Re-creates CatchCardView's md visual language (rarity rail,
/// border, holo for rare+, badges, footer) so the 3D treatment can be
/// judged in context — not floating on its own.
struct Card3DSpikeCard: View {
    let plane: CardPlane
    var holoIntensity: Double = 0.85

    // md dimensions, copied from CatchCardView.CardSize.md so the spike
    // reads at the same scale as a real card.
    private let width: CGFloat = 260
    private let height: CGFloat = 380
    private let viewportHeight: CGFloat = 180
    private let cornerRadius: CGFloat = 16

    private var showsHolo: Bool {
        holoIntensity > 0 && plane.rarity.ordinal >= Rarity.rare.ordinal
    }
    private var isLegendary: Bool { plane.rarity == .legendary }

    var body: some View {
        ZStack {
            // Card base gradient
            LinearGradient(
                colors: [Brand.Color.bgElevated, Brand.Color.bgSurface],
                startPoint: .top, endPoint: .bottom
            )

            // Rarity rail (5pt top stripe)
            VStack(spacing: 0) {
                Rectangle().fill(plane.rarity.tint).frame(height: 5)
                Spacer()
            }

            // Holo wash (rare+ only) — behind content, blended overlay.
            if showsHolo {
                holoLayer
            }
            if isLegendary {
                goldDust
            }

            content
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(plane.rarity.tint, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.55), radius: 20, x: 0, y: 14)
        .shadow(color: plane.rarity.tint.opacity(0.3), radius: 22, x: 0, y: 0)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — callsign + rarity badge
            HStack {
                Text(plane.callsign ?? "—")
                    .font(Brand.Font.mono(size: 13, weight: .bold))
                    .foregroundStyle(Brand.Color.cyan)
                    .lineLimit(1)
                Spacer(minLength: 4)
                RarityBadge(rarity: plane.rarity, size: .md)
            }
            .padding(.top, 10)

            // 3D viewport — the spike's whole point. A subtle inner
            // vignette ring frames it like the photo slot did, but the
            // model spills slightly past it (transparent bg) so it feels
            // embedded in the card rather than boxed.
            ZStack {
                // Faint radial floor-glow under the plane to ground it.
                RadialGradient(
                    colors: [plane.rarity.tint.opacity(0.18), .clear],
                    center: .init(x: 0.5, y: 0.62),
                    startRadius: 4, endRadius: viewportHeight * 0.7
                )
                Aircraft3DViewport(rarityTint: UIColor(plane.rarity.tint))
            }
            .frame(height: viewportHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.06), lineWidth: 0.5)
            )

            // Title block
            VStack(alignment: .leading, spacing: 2) {
                Text(plane.model ?? "Unknown aircraft")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .lineLimit(1)
                if let carrier = plane.carrier {
                    Text(carrier)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Footer — type chip + points
            HStack {
                TypeBadge(type: plane.type, size: .md)
                Spacer(minLength: 4)
                Text("+\(plane.rarity.basePoints) pt")
                    .font(Brand.Font.mono(size: 14, weight: .bold))
                    .foregroundStyle(plane.rarity.tint)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, width * 0.06)
        .padding(.bottom, 12)
    }

    // Holo + gold-dust mirror CatchCardView (kept local to the spike).
    private var holoLayer: some View {
        let stops: [Color] = [
            Color(red: 1.00, green: 0.39, blue: 0.78),
            Color(red: 0.39, green: 0.78, blue: 1.00),
            Color(red: 1.00, green: 0.86, blue: 0.39),
            Color(red: 0.39, green: 1.00, blue: 0.71),
            Color(red: 0.71, green: 0.55, blue: 1.00),
            Color(red: 1.00, green: 0.39, blue: 0.78),
        ]
        return AngularGradient(colors: stops, center: .center,
                               startAngle: .degrees(45), endAngle: .degrees(405))
            .blendMode(.overlay)
            .opacity(holoIntensity * (isLegendary ? 1.4 : 1.0))
            .allowsHitTesting(false)
    }

    private var goldDust: some View {
        let dust = Color(red: 1.0, green: 0.78, blue: 0.29)
        let pts: [CGPoint] = [.init(x: 0.2, y: 0.3), .init(x: 0.7, y: 0.7),
                              .init(x: 0.45, y: 0.15), .init(x: 0.85, y: 0.35)]
        return ZStack {
            ForEach(pts, id: \.x) { p in
                RadialGradient(
                    gradient: Gradient(colors: [dust.opacity(0.42), .clear]),
                    center: UnitPoint(x: p.x, y: p.y),
                    startRadius: 0, endRadius: 36)
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

// MARK: - Spike host screen (the sheet)

/// Full-screen host presented from the debug TOOLS row. Lets Noah swap
/// rarity tiers to feel how the rim-light tint + holo treatment change
/// the model's presence, with a one-line instruction.
struct Card3DSpikeView: View {
    @Environment(\.dismiss) private var dismiss

    /// Rarity the card renders at — cycled via the segmented control so
    /// the rim glow + holo can be judged across tiers.
    @State private var rarity: Rarity = .epic

    private let demoPlane: (Rarity) -> CardPlane = { r in
        CardPlane(
            callsign: "BAW286",
            model: "Boeing 747-400",
            carrier: "Spike Airways",
            rarity: r,
            type: .wide,
            altText: "FL360",
            speedText: "488 kt",
            distText: "9 km"
        )
    }

    var body: some View {
        ZStack {
            Brand.Color.bgPrimary.ignoresSafeArea()

            VStack(spacing: 24) {
                Text("3D CARD SPIKE")
                    .font(Brand.Font.mono(size: 12, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.Color.textTertiary)

                Card3DSpikeCard(plane: demoPlane(rarity))

                Text("Drag to orbit · pinch to zoom · let go and it drifts")
                    .font(Brand.Font.mono(size: 11))
                    .foregroundStyle(Brand.Color.textSecondary)
                    .multilineTextAlignment(.center)

                Picker("Rarity", selection: $rarity) {
                    ForEach(Rarity.allCases, id: \.self) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
            }
            .padding()

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Brand.Color.textTertiary)
                            .padding()
                    }
                }
                Spacer()
            }
        }
    }
}

#Preview {
    Card3DSpikeView()
}
