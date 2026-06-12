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
//    3. Interaction — arcball/trackball drag (full free tumble, no axis
//       locked), pinch to zoom, flick-momentum that decays naturally, and
//       a gentle idle yaw that blends back in after the model settles.
//       Holding and turning the model is what sells "it's really in there";
//       flicking it mid-spin and grabbing it back seals the deal.
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
    static let idleYawRadiansPerSecond: Float = Float(2 * Double.pi) / 12.0

    /// How long after the user lifts their finger (AND momentum decays)
    /// before the idle spin resumes.
    static let idleResumeDelay: TimeInterval = 2.0

    /// How long idle spin ramps up from 0 to full speed (smooth blend-in).
    static let idleRampDuration: TimeInterval = 1.0

    /// Pinch-zoom range (camera-distance multiplier). Wider than the old
    /// 0.8–1.5 range — no rubber-band needed at these extents.
    static let minZoom: CGFloat = 0.5
    static let maxZoom: CGFloat = 2.5

    /// Arcball drag sensitivity: screen points → radians of rotation.
    /// Controls how fast the plane spins as you drag across it.
    static let dragRadiansPerPoint: Float = 0.013

    /// Momentum damping rate (natural units: 1/s). Higher = stops faster.
    /// 2.5/s gives a ~400 ms half-life — snappy enough to feel responsive,
    /// slow enough to feel weighty. Flick-and-grab will demonstrate this.
    static let momentumDamping: Float = 2.5

    /// Angular velocity below which momentum is considered "fully decayed"
    /// and the idle-resume timer may begin.
    static let momentumStopThreshold: Float = 0.05  // rad/s

    /// Resting camera distance from the model (model is ~2 units across).
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

    /// Which family's model to load. Drives resource name + orientation
    /// adjustments via `CardModelRegistry`.
    let family: AircraftFamily

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView(frame: .zero)
        scnView.backgroundColor = .clear          // card shows through
        scnView.antialiasingMode = .multisampling4X
        scnView.isOpaque = false
        scnView.rendersContinuously = true         // drive the idle spin
        // allowsCameraControl is intentionally OFF — the built-in controller
        // competes with our arcball gestures and ignores our momentum/idle
        // system. We own all gesture handling in the Coordinator.
        scnView.allowsCameraControl = false

        let scene = buildScene(family: family)
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
        // Family or tint could change when the user swaps via the picker.
        // Rebuild the scene in-place: replace the SceneKit scene entirely.
        // The coordinator re-links its node references via configure().
        let newScene = buildScene(family: family)
        uiView.scene = newScene
        context.coordinator.configure(scnView: uiView, tint: rarityTint)
    }

    // MARK: Scene construction

    /// Builds the full scene graph: model node (loaded from the bundled
    /// OBJ via `CardModelRegistry`), camera, and the 3-point light rig.
    ///
    /// - Parameter family: which aircraft family's OBJ to load.
    ///   If the family is unavailable (no bundled OBJ yet), renders a
    ///   placeholder geometry so the viewport isn't an empty void.
    private func buildScene(family: AircraftFamily) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        let config = CardModelRegistry.config(for: family)

        // ── Model ────────────────────────────────────────────────────
        // The OBJ ships in the app bundle (synchronized folder). We load
        // it via SCNScene(url:) and lift its content into a container
        // node so we can rotate the plane independently of the camera.
        let modelContainer = SCNNode()
        modelContainer.name = "modelContainer"

        if config.isAvailable,
           let resourceName = config.resourceName,
           let url = Bundle.main.url(forResource: resourceName, withExtension: "obj"),
           let loaded = try? SCNScene(url: url, options: [
               .createNormalsIfAbsent: true
           ]) {
            for child in loaded.rootNode.childNodes {
                modelContainer.addChildNode(child)
            }
            // Apply per-model orientation fix before the hero pose.
            let adj = config.orientationAdjustment
            if adj.x != 0 || adj.y != 0 || adj.z != 0 {
                modelContainer.eulerAngles = adj
            }
            // Per-model scale adjustment on top of the normalized 2.0-unit scale.
            if config.sceneKitScale != 1.0 {
                modelContainer.scale = SCNVector3(
                    config.sceneKitScale, config.sceneKitScale, config.sceneKitScale)
            }
            applyMaterials(to: modelContainer)
        } else {
            // Unavailable family: lock icon placeholder — a dashed-edge box
            // with the family name label to signal "model coming soon."
            let box = SCNNode(geometry: SCNBox(width: 1.4, height: 0.5, length: 1.4, chamferRadius: 0.08))
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = UIColor(white: 0.18, alpha: 1.0)
            mat.emission.contents = UIColor(white: 0.22, alpha: 1.0)
            box.geometry?.firstMaterial = mat
            modelContainer.addChildNode(box)

            // Small floating text node — family chip label.
            let text = SCNText(string: family.chipLabel, extrusionDepth: 0.04)
            text.font = UIFont.monospacedSystemFont(ofSize: 0.22, weight: .bold)
            text.flatness = 0.3
            let textNode = SCNNode(geometry: text)
            let tMat = SCNMaterial()
            tMat.lightingModel = .constant
            tMat.diffuse.contents = UIColor(white: 0.45, alpha: 1.0)
            text.firstMaterial = tMat
            // Center text above the box.
            let (tMin, tMax) = (text.boundingBox.min, text.boundingBox.max)
            let tW = tMax.x - tMin.x
            textNode.position = SCNVector3(-tW / 2, 0.42, 0)
            modelContainer.addChildNode(textNode)
        }

        // Hero pose: wrap the modelContainer in an outer "poseNode" so the
        // per-model orientationAdjustment (applied directly on modelContainer)
        // doesn't conflict with the hero pose euler angles. The coordinator's
        // arcball rotation drives poseNode's simdOrientation, not modelContainer.
        //
        // Nose toward the viewer's left-front, a slight bank and a touch of
        // nose-up so it reads as "in flight," not parked.
        let poseNode = SCNNode()
        poseNode.name = "modelContainer"   // coordinator looks up by this name
        let heroPose = simd_quatf(angle: -0.12, axis: simd_float3(1, 0, 0))   // nose-up
            * simd_quatf(angle: Float.pi * 0.78, axis: simd_float3(0, 1, 0)) // 3/4 front
            * simd_quatf(angle: 0.05, axis: simd_float3(0, 0, 1))            // bank
        poseNode.simdOrientation = simd_normalize(heroPose)
        modelContainer.name = "modelMesh"  // distinguish from poseNode
        poseNode.addChildNode(modelContainer)
        scene.rootNode.addChildNode(poseNode)

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

    /// Holds the SCNView reference and all gesture/idle/momentum state.
    ///
    /// ── Arcball rotation (Noah's iOS learning) ───────────────────────
    /// Instead of mapping dx → yaw and dy → pitch (euler decomposition),
    /// we use quaternion-based trackball rotation. The idea: imagine a
    /// virtual sphere filling the viewport. When you drag your finger, you
    /// rotate that sphere about the axis perpendicular to the drag direction.
    ///
    ///   drag vector (dx, dy) in screen space
    ///   → rotation axis in view space = normalize(dy, dx, 0)
    ///     (note the swap: dragging RIGHT rotates about the Y axis, which
    ///      is the intuitive "yaw"; dragging UP rotates about the X axis)
    ///   → angle = drag_distance * sensitivity
    ///   → quaternion q = simd_quatf(angle: angle, axis: axis)
    ///   → new orientation = q * current_orientation  (left-multiply so
    ///     the rotation is always in view space, not model space — this
    ///     is what prevents gimbal lock)
    ///
    /// Because the axis is always perpendicular to the drag, every drag
    /// direction works uniformly — there's no "dead zone" at the poles,
    /// no locked axis, no flip. It feels like spinning a physical ball.
    ///
    /// ── Momentum ─────────────────────────────────────────────────────
    /// On pan-end we record velocity (pts/s from UIKit) → convert to an
    /// angular velocity (rad/s). Each render frame we apply that rotation
    /// and decay it: ω *= exp(-damping * dt). When ω < threshold we stop
    /// and start the idle-resume timer. Touch-down clears ω immediately.
    @MainActor
    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        private weak var scnView: SCNView?
        private var modelNode: SCNNode?
        private var cameraNode: SCNNode?

        /// Accumulated rotation as a unit quaternion. Starts at the hero
        /// pose set in buildScene() and drifts as the user interacts.
        /// Reset to the hero pose each time `configure()` is called so a
        /// family swap snaps back to a clean hero angle.
        private var orientation: simd_quatf = Coordinator.heroOrientation

        /// Hero pose quaternion — composited the same way buildScene()
        /// does it so they stay in sync. Left-multiply order (X then Y then Z).
        private static let heroOrientation: simd_quatf = {
            let qx = simd_quatf(angle: -0.12, axis: simd_float3(1, 0, 0))
            let qy = simd_quatf(angle: Float.pi * 0.78, axis: simd_float3(0, 1, 0))
            let qz = simd_quatf(angle: 0.05, axis: simd_float3(0, 0, 1))
            return simd_normalize(qx * qy * qz)
        }()

        /// Momentum: current angular velocity in rad/s, and the axis it
        /// rotates about (already in view space, ready to compose into a
        /// quaternion each frame).
        private var momentumAngularVelocity: Float = 0
        private var momentumAxis: simd_float3 = simd_float3(0, 1, 0)

        /// Camera-distance multiplier from pinch (clamped minZoom…maxZoom).
        private var zoom: CGFloat = 1.0
        private var pinchStartZoom: CGFloat = 1.0

        /// Interaction / idle bookkeeping.
        /// `isInteracting` is true while a finger is down — suppresses
        /// momentum and idle.
        /// `interactionEndedAt` is stamped when the finger lifts so we
        /// can start the idle countdown only after momentum decays too.
        private var isInteracting = false
        private var interactionEndedAt: TimeInterval = 0
        private var lastFrameTime: TimeInterval = 0

        /// How far along the idle ramp we are [0…1]. Ramps up from 0 over
        /// `idleRampDuration` once both idle-resume-delay AND momentum-
        /// decay conditions are satisfied.
        private var idleRampProgress: Double = 0

        func configure(scnView: SCNView, tint: UIColor) {
            self.scnView = scnView
            self.modelNode = scnView.scene?.rootNode.childNode(
                withName: "modelContainer", recursively: false)
            self.cameraNode = scnView.scene?.rootNode.childNode(
                withName: "camera", recursively: false)
            // Reset to hero pose so family swaps start from a clean angle.
            orientation = Coordinator.heroOrientation
            momentumAngularVelocity = 0
            idleRampProgress = 0
            zoom = 1.0
            applyOrientation()
        }

        // ── Gestures ─────────────────────────────────────────────────

        @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            guard let view = scnView else { return }
            switch gr.state {
            case .began:
                isInteracting = true
                // Grab the ball mid-spin: zero out momentum immediately.
                momentumAngularVelocity = 0
                idleRampProgress = 0
            case .changed:
                let t = gr.translation(in: view)
                gr.setTranslation(.zero, in: view)

                // Compute the arcball rotation for this drag delta.
                let dx = Float(t.x)
                let dy = Float(t.y)
                let dist = sqrt(dx * dx + dy * dy)
                guard dist > 1e-4 else { break }

                // Axis perpendicular to drag, in view space.
                // Dragging right → rotate around +Y (yaw right).
                // Dragging up   → rotate around +X (pitch up).
                let axis = simd_normalize(simd_float3(dy, dx, 0))
                let angle = dist * Spike.dragRadiansPerPoint

                // Left-multiply so the delta is always in camera/view space,
                // not the accumulated model space — this is the key that
                // makes trackball feel natural at any orientation.
                let delta = simd_quatf(angle: angle, axis: axis)
                orientation = simd_normalize(delta * orientation)
                applyOrientation()

            case .ended, .cancelled, .failed:
                isInteracting = false
                interactionEndedAt = CACurrentMediaTime()

                // Seed momentum from UIKit's velocity.
                let vel = gr.velocity(in: view)
                let vx = Float(vel.x)
                let vy = Float(vel.y)
                let speed = sqrt(vx * vx + vy * vy)
                if speed > 10 {
                    // Convert px/s to rad/s using the same sensitivity factor.
                    momentumAngularVelocity = speed * Spike.dragRadiansPerPoint
                    momentumAxis = simd_normalize(simd_float3(vy, vx, 0))
                } else {
                    momentumAngularVelocity = 0
                }
            default:
                break
            }
        }

        @objc func handlePinch(_ gr: UIPinchGestureRecognizer) {
            switch gr.state {
            case .began:
                isInteracting = true
                pinchStartZoom = zoom
                momentumAngularVelocity = 0
                idleRampProgress = 0
            case .changed:
                // Pinch out (scale > 1) brings the camera closer → smaller
                // distance multiplier. Clamp without rubber-band.
                let proposed = pinchStartZoom / gr.scale
                zoom = max(Spike.minZoom, min(Spike.maxZoom, proposed))
                applyCameraDistance()
            case .ended, .cancelled, .failed:
                isInteracting = false
                interactionEndedAt = CACurrentMediaTime()
            default:
                break
            }
        }

        // ── Transform application ────────────────────────────────────

        /// Push the current quaternion orientation into the SceneKit node.
        /// SceneKit accepts simdOrientation (a simd_quatf) directly —
        /// no Euler decomposition needed, no gimbal lock possible.
        private func applyOrientation() {
            modelNode?.simdOrientation = orientation
            applyCameraDistance()
        }

        private func applyCameraDistance() {
            guard let cam = cameraNode else { return }
            let d = Spike.baseCameraDistance * zoom
            cam.position = SCNVector3(0, -0.55, Float(d))
            cam.look(at: SCNVector3(0, 0.05, 0))
        }

        // ── Render-loop: momentum + idle spin ────────────────────────

        nonisolated func renderer(_ renderer: SCNSceneRenderer,
                                  updateAtTime time: TimeInterval) {
            // SceneKit calls this on its render thread; hop to MainActor
            // before touching any mutable state or the node.
            Task { @MainActor in
                self.advanceFrame(time)
            }
        }

        private func advanceFrame(_ time: TimeInterval) {
            defer { lastFrameTime = time }
            guard lastFrameTime != 0 else { return }   // skip first frame
            let dt = Float(time - lastFrameTime)
            guard dt > 0 else { return }

            if isInteracting { return }

            var dirty = false

            // ── Momentum decay ───────────────────────────────────────
            // Apply and exponentially decay the angular velocity seeded
            // at pan-end. exp(-k*dt) is the continuous-time decay factor
            // for a first-order system with rate constant k (= damping).
            if momentumAngularVelocity > Spike.momentumStopThreshold {
                let angle = momentumAngularVelocity * dt
                let q = simd_quatf(angle: angle, axis: momentumAxis)
                orientation = simd_normalize(q * orientation)
                momentumAngularVelocity *= exp(-Spike.momentumDamping * dt)
                if momentumAngularVelocity <= Spike.momentumStopThreshold {
                    momentumAngularVelocity = 0
                }
                dirty = true
            }

            // ── Idle yaw (resumes only after delay AND momentum gone) ─
            // The idle-ramp prevents a jarring snap: speed ramps from 0
            // to full over `idleRampDuration` seconds once conditions met.
            if Spike.idleYawRadiansPerSecond > 0 &&
               momentumAngularVelocity == 0 &&
               time >= interactionEndedAt + Spike.idleResumeDelay {

                // Advance the ramp toward 1.0.
                idleRampProgress = min(1.0,
                    idleRampProgress + Double(dt) / Spike.idleRampDuration)

                let effectiveRate = Spike.idleYawRadiansPerSecond
                    * Float(idleRampProgress)
                let angle = effectiveRate * dt
                // Idle always rotates about world-up (Y axis). Left-multiply
                // so it spins in view space (looks like a turntable).
                let q = simd_quatf(angle: angle, axis: simd_float3(0, 1, 0))
                orientation = simd_normalize(q * orientation)
                dirty = true
            } else if isInteracting || momentumAngularVelocity > 0 {
                // Reset ramp when the user re-grabs or new momentum starts.
                idleRampProgress = 0
            }

            if dirty { applyOrientation() }
        }
    }
}

// (No Float extension needed — the coordinator works in simd_float3/simd_quatf
// directly, so no CGFloat↔Float bridging helpers are required.)

// MARK: - The spike card

/// A catch card whose photo slot is replaced by the interactive 3D
/// viewport. Re-creates CatchCardView's md visual language (rarity rail,
/// border, holo for rare+, badges, footer) so the 3D treatment can be
/// judged in context — not floating on its own.
struct Card3DSpikeCard: View {
    let plane: CardPlane
    /// Which aircraft family model to render in the 3D viewport.
    var family: AircraftFamily = .jumbo
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
                Aircraft3DViewport(rarityTint: UIColor(plane.rarity.tint), family: family)
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

/// Full-screen host presented from the debug TOOLS row. Lets Noah review
/// the entire fleet's model coherence in one sitting: a family picker swaps
/// the model in the card viewport; a rarity picker cycles the rim-light tint
/// and holo treatment.
///
/// Unavailable families show the locked placeholder treatment (gray box +
/// chip label) so the selector still renders something useful.
struct Card3DSpikeView: View {
    @Environment(\.dismiss) private var dismiss

    /// Rarity the card renders at — cycled via the segmented control so
    /// the rim glow + holo can be judged across tiers.
    @State private var rarity: Rarity = .epic

    /// Which aircraft family model is currently showing.
    @State private var family: AircraftFamily = .jumbo

    /// Per-family demo plane metadata (callsign / model / carrier / type).
    private func demoPlane(rarity: Rarity, family: AircraftFamily) -> CardPlane {
        switch family {
        case .jumbo:
            return CardPlane(callsign: "BAW286", model: "Boeing 747-400",
                             carrier: "British Airways", rarity: rarity, type: .wide,
                             altText: "FL360", speedText: "488 kt", distText: "9 km")
        case .narrowbody:
            return CardPlane(callsign: "UAL482", model: "Airbus A320-200",
                             carrier: "United Airlines", rarity: rarity, type: .narrow,
                             altText: "FL280", speedText: "440 kt", distText: "6 km")
        case .widebody:
            return CardPlane(callsign: "ANA12", model: "Boeing 787-9 Dreamliner",
                             carrier: "ANA", rarity: rarity, type: .wide,
                             altText: "FL340", speedText: "465 kt", distText: "11 km")
        case .gaProp:
            return CardPlane(callsign: "N12345", model: "Cessna 172",
                             carrier: nil, rarity: rarity, type: .ga,
                             altText: "3,500 ft", speedText: "110 kt", distText: "2 km")
        case .helicopter:
            return CardPlane(callsign: "N456HX", model: "Bell 206",
                             carrier: nil, rarity: rarity, type: .ga,
                             altText: "1,200 ft", speedText: "90 kt", distText: "1 km")
        case .regionalJet:
            return CardPlane(callsign: "SKW4501", model: "Embraer E175",
                             carrier: "SkyWest", rarity: rarity, type: .regional,
                             altText: "FL240", speedText: "415 kt", distText: "5 km")
        case .bizjet:
            return CardPlane(callsign: "N88BJ", model: "Gulfstream G550",
                             carrier: nil, rarity: rarity, type: .biz,
                             altText: "FL450", speedText: "476 kt", distText: "14 km")
        case .turboprop:
            return CardPlane(callsign: "N22TP", model: "Beechcraft King Air 350",
                             carrier: nil, rarity: rarity, type: .ga,
                             altText: "FL250", speedText: "310 kt", distText: "7 km")
        case .militaryFighter:
            return CardPlane(callsign: "VIPER1", model: "F-16C Fighting Falcon",
                             carrier: "USAF", rarity: rarity, type: .mil,
                             altText: "20,000 ft", speedText: "800 kt", distText: "8 km")
        case .militaryTransport:
            return CardPlane(callsign: "REACH99", model: "C-17 Globemaster",
                             carrier: "USAF", rarity: rarity, type: .mil,
                             altText: "28,000 ft", speedText: "450 kt", distText: "12 km")
        }
    }

    var body: some View {
        ZStack {
            Brand.Color.bgPrimary.ignoresSafeArea()

            VStack(spacing: 20) {
                Text("3D CARD SPIKE")
                    .font(Brand.Font.mono(size: 12, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.Color.textTertiary)

                // Family picker — horizontal scrolling chip row.
                // Available families are full-opacity; unavailable (no model
                // yet) are dimmed so Noah can see what's missing at a glance.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AircraftFamily.allCases) { f in
                            let config = CardModelRegistry.config(for: f)
                            let isSelected = f == family
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    family = f
                                }
                            } label: {
                                Text(f.chipLabel)
                                    .font(Brand.Font.mono(size: 11, weight: .bold))
                                    .tracking(0.8)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        isSelected
                                        ? Brand.Color.cyan.opacity(0.25)
                                        : Color.white.opacity(0.06)
                                    )
                                    .foregroundStyle(
                                        isSelected
                                        ? Brand.Color.cyan
                                        : (config.isAvailable
                                           ? Brand.Color.textSecondary
                                           : Brand.Color.textTertiary)
                                    )
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(
                                                isSelected
                                                ? Brand.Color.cyan.opacity(0.6)
                                                : Color.white.opacity(0.08),
                                                lineWidth: 1
                                            )
                                    )
                                    .opacity(config.isAvailable ? 1.0 : 0.5)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }

                // The card itself — family and rarity both live-update.
                Card3DSpikeCard(
                    plane: demoPlane(rarity: rarity, family: family),
                    family: family
                )

                // Hint line: available or pending.
                let config = CardModelRegistry.config(for: family)
                if config.isAvailable {
                    Text("Flick to spin · grab to stop · pinch to zoom")
                        .font(Brand.Font.mono(size: 11))
                        .foregroundStyle(Brand.Color.textSecondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Model pending — download from Sketchfab (login required)")
                        .font(Brand.Font.mono(size: 10))
                        .foregroundStyle(Brand.Color.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Rarity picker.
                Picker("Rarity", selection: $rarity) {
                    ForEach(Rarity.allCases, id: \.self) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
            }
            .padding(.vertical)

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
