//
//  SilhouetteFrom3DRenderTests.swift
//  TailspotTests
//
//  Silhouette-from-3D render harness — feat/card-3d-spike.
//
//  HYPOTHESIS: Tailspot's flat card silhouettes should be derived from the
//  bundled 3D fleet models (orthographic top-down render → solid silhouette)
//  rather than hand-traced — one pipeline, guaranteed 3D↔thumbnail consistency.
//
//  This harness tests that hypothesis by:
//    1. Loading Boeing747.obj and FleetHelicopter.obj from the app bundle.
//    2. Setting up an orthographic camera looking straight down (top view),
//       nose oriented toward +Z (up in frame), flat white unlit materials
//       on all geometry, black background.
//    3. Rendering at 1024×1024 via SCNView.snapshot() (the documented
//       off-screen SceneKit path on iOS).
//    4. Saving raw renders and a composited version (white silhouette on
//       dark card ground) to /tmp/silhouette-from-3d/.
//
//  The `#expect`s only assert files were written (non-empty). The real
//  output is the images themselves, which the authoring agent reads back
//  and judges for planform quality.
//
//  ── Why SCNView.snapshot() not SCNRenderer ────────────────────────────
//  SCNRenderer.render(atTime:viewport:commandBuffer:passDescriptor:) on
//  the iOS Simulator software-renderer does NOT produce output — it
//  silently returns with no pixels written. SCNView.snapshot() routes
//  through the view's own rendering path and works reliably on simulator.
//
//  The technique: allocate an SCNView at the desired render size, give
//  it a real window (UIWindow on a disconnected screen) so Metal/CoreAnimation
//  has a backing layer, set the scene, call snapshot(). This is the same
//  path the interactive spike card uses — we just suppress gesture setup
//  and fire one still frame.
//
//  ── Background colour ────────────────────────────────────────────────
//  We render on a black background (not transparent) because transparent
//  backgrounds require SCNView.isOpaque = false + a CAMetalLayer configured
//  for transparency, which is unreliable off-screen. Black background +
//  white geometry produces a clean high-contrast silhouette; the composited
//  card version then layers the real dark card color underneath via UIKit
//  blend modes (source-over, black pixels = fully "filled in" by background).
//  For production asset generation, run a Core Image threshold pass to
//  convert the black background to pure transparent alpha.
//
//  ── Camera setup (top-down orthographic) ─────────────────────────────
//  Both OBJs are normalized by the trimesh pipeline: centered at origin,
//  max extent = 2.0 units. Coordinate axes:
//    Boeing747: Z-axis is nose-to-tail (±1.0). X-axis is wingspan (±0.98).
//               Y-axis is height (±0.66). Camera at (0, +10, 0), looking
//               at origin, with +Z as world-up → nose at top of frame.
//    Helicopter: X-axis is dominant (rotor diameter ±1.0). CardModelRegistry
//               rotates it π/2 about Y so nose points to +Z. Same camera setup.
//

import Testing
import SceneKit
import UIKit
@testable import Tailspot

@MainActor
@Suite("SilhouetteFrom3DRender")
struct SilhouetteFrom3DRenderTests {

    private static let outDir = URL(fileURLWithPath: "/tmp/silhouette-from-3d", isDirectory: true)
    private static let renderSize = CGSize(width: 1024, height: 1024)

    // MARK: - Test entry point

    @Test func renderTopDownSilhouettes() throws {
        try FileManager.default.createDirectory(
            at: Self.outDir, withIntermediateDirectories: true)

        // ── Boeing 747 ────────────────────────────────────────────────
        // Camera-up = world -Z (from Rx(-π/2)). Nose at +Z appears at
        // BOTTOM; nose at -Z appears at TOP. OBJ nose is at +Z.
        // Fix: Ry(π) sends nose from +Z to -Z → nose at top. ✓
        // The fuselage is ~6° off the Z-axis in the XZ plane; the small
        // 0.10 rad Y-trim corrects that lean in the frame.
        // The 4 nacelles on the wings confirm orientation: swept wings
        // with nacelles appear in the mid-section, nose upper, tail lower.
        let raw747 = renderTopDown(
            resourceName: "Boeing747",
            orientationAdjustment: SCNVector3(0, Float.pi + 0.10, 0),
            modelScale: 1.0,
            orthographicScale: 1.15
        )
        #expect(raw747 != nil, "SCNView failed to load / render Boeing747.obj")

        let comp747 = raw747.flatMap { compositeOnDarkCard(raw: $0) }

        try writeImage(raw747,  name: "raw-747-topdown.png")
        try writeImage(comp747, name: "card-747-topdown.png")

        // ── Helicopter ────────────────────────────────────────────────
        // X is dominant (rotor diameter 2.0 units). CardModelRegistry
        // applies (0, π/2, 0) to rotate nose from +X to +Z. Then the
        // same camera-up=-Z issue applies: add π to flip nose to top.
        // Net: (0, π/2 + π, 0) = (0, 3π/2, 0).
        // Scale boosted to 1.5 and orthographicScale widened to 1.35
        // so the tail boom (which extends below the main fuselage in
        // model space) stays inside the frame.
        // NOTE: the OBJ has NO rotor blades — the disc is absent from
        // the mesh. Top-down shows fuselage + skid rails but no disc.
        // A post-process step (overlay an SVG disc ring) is needed for
        // production card assets.
        let rawHeli = renderTopDown(
            resourceName: "FleetHelicopter",
            orientationAdjustment: SCNVector3(0, Float.pi * 1.5, 0),
            modelScale: 1.5,
            orthographicScale: 1.35
        )
        #expect(rawHeli != nil, "SCNView failed to load / render FleetHelicopter.obj")

        let compHeli = rawHeli.flatMap { compositeOnDarkCard(raw: $0) }

        try writeImage(rawHeli,  name: "raw-helicopter-topdown.png")
        try writeImage(compHeli, name: "card-helicopter-topdown.png")

        // Verify outputs are non-trivially different from each other
        // (both models loaded and rendered distinct geometry).
        if let i747 = raw747, let iHeli = rawHeli {
            let match = imagesAreIdentical(i747, iHeli)
            #expect(!match, "747 and helicopter renders are pixel-identical — one may not have loaded")
        }
    }

    // MARK: - Core render function

    /// Build an SCNScene with a top-down orthographic camera and flat-white
    /// materials, render it via SCNView.snapshot(), return the UIImage.
    private func renderTopDown(
        resourceName: String,
        orientationAdjustment: SCNVector3,
        modelScale: Float,
        orthographicScale: Double
    ) -> UIImage? {
        // ── Scene ─────────────────────────────────────────────────────
        let scene = SCNScene()
        // Black background: clean contrast for the white silhouette.
        scene.background.contents = UIColor.black

        // ── Model ─────────────────────────────────────────────────────
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "obj"),
              let loaded = try? SCNScene(url: url, options: [.createNormalsIfAbsent: true])
        else {
            return nil
        }

        let modelNode = SCNNode()
        for child in loaded.rootNode.childNodes {
            modelNode.addChildNode(child)
        }

        // Per-model orientation correction (align nose to +Z).
        let adj = orientationAdjustment
        if adj.x != 0 || adj.y != 0 || adj.z != 0 {
            modelNode.eulerAngles = adj
        }
        if modelScale != 1.0 {
            modelNode.scale = SCNVector3(modelScale, modelScale, modelScale)
        }

        // Override all materials: flat white, .constant (ignores lights).
        applyFlatWhiteMaterials(to: modelNode)
        scene.rootNode.addChildNode(modelNode)

        // ── Camera: looking straight down ─────────────────────────────
        // Position camera at (0, +10, 0) — high on the Y axis above the
        // model which sits at origin.
        // We want to look toward -Y (straight down) with the nose (+Z)
        // appearing at the top of the rendered image.
        //
        // After look(at: .zero), the node's -Z axis points at the target.
        // For a camera at (0, 10, 0) looking at (0, 0, 0), this means
        // the camera's -Z is now pointing DOWN (-Y world). That's correct.
        //
        // The camera's "up" direction after look(at:) with this configuration
        // is ambiguous (camera is directly above the target). We pin it
        // explicitly via the node's orientation: we want +Z world to be "up"
        // in the rendered image (camera's +Y). This is equivalent to rotating
        // the camera node so its local X axis = world +X and local Y = world +Z.
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = orthographicScale
        camera.zNear = 0.01
        camera.zFar = 50.0
        cameraNode.camera = camera

        // Place camera directly above the model on the Y axis.
        cameraNode.position = SCNVector3(0, 10, 0)

        // Rotate the camera to look straight down:
        //   Default orientation: looks toward -Z (local), up is +Y (local).
        //   After Rx(-π/2): look direction = world -Y (down) ✓
        //                   up direction   = world -Z
        //
        //   This means world +Z maps to the BOTTOM of the rendered frame
        //   and world -Z maps to the TOP. Models whose nose is at -Z (after
        //   orientation adjustment) will render nose-up. The orientation
        //   adjustments for each model account for this: both 747 and heli
        //   have their nose rotated to -Z before rendering.
        cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)

        scene.rootNode.addChildNode(cameraNode)

        // ── Ambient light ─────────────────────────────────────────────
        // .constant materials ignore lights, but add one for correctness.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // ── Off-screen render via SCNView.snapshot() ───────────────────
        // We create a real UIWindow with a hidden root view controller so
        // SceneKit's backing CAMetalLayer is properly configured. Without
        // a window, snapshot() may return a blank image on simulator.
        let renderSize = Self.renderSize
        let scnView = SCNView(frame: CGRect(origin: .zero, size: renderSize))
        scnView.scene = scene
        scnView.pointOfView = cameraNode
        scnView.backgroundColor = .black
        scnView.isOpaque = true
        scnView.antialiasingMode = .multisampling4X
        scnView.allowsCameraControl = false
        scnView.rendersContinuously = false

        // Give the view a window so it gets a proper CAMetalLayer.
        let window = UIWindow(frame: CGRect(origin: .zero, size: renderSize))
        let vc = UIViewController()
        vc.view.frame = CGRect(origin: .zero, size: renderSize)
        vc.view.addSubview(scnView)
        window.rootViewController = vc
        window.isHidden = false
        window.layoutIfNeeded()

        // Force one render cycle before snapshot.
        scnView.setNeedsDisplay()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        let image = scnView.snapshot()

        // Clean up — remove from window so the test doesn't leave dangling UI.
        window.isHidden = true
        scnView.removeFromSuperview()

        return image
    }

    // MARK: - Material override

    /// Walk all geometry-bearing nodes and replace their materials with a
    /// flat white unlit material. `.constant` ignores all scene lighting
    /// and displays the diffuse color directly — clean uniform white
    /// silhouette regardless of the model's original materials.
    private func applyFlatWhiteMaterials(to node: SCNNode) {
        node.enumerateChildNodes { child, _ in
            guard let geometry = child.geometry else { return }
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = UIColor.white
            mat.isDoubleSided = true
            // Preserve the geometry element count — some OBJs have multiple
            // elements per node (nose section, fuselage section, etc.).
            geometry.materials = Array(repeating: mat,
                                       count: max(1, geometry.materials.count))
        }
        if let geometry = node.geometry {
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = UIColor.white
            mat.isDoubleSided = true
            geometry.materials = Array(repeating: mat,
                                       count: max(1, geometry.materials.count))
        }
    }

    // MARK: - Compositing

    /// Composite a black-background silhouette render onto the dark card ground
    /// color (`#12161F` — same as SilhouetteCheckCard in SilhouetteCardSpike).
    ///
    /// The raw render has white geometry on black. We composite it using
    /// `.screen` blend mode: black from the raw image is transparent,
    /// white passes through and illuminates the card ground. Visually:
    /// white silhouette on the dark Tailspot card navy.
    private func compositeOnDarkCard(raw: UIImage) -> UIImage? {
        let size = raw.size
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // 1. Dark card ground — #12161F
            UIColor(red: 0x12/255.0, green: 0x16/255.0, blue: 0x1F/255.0, alpha: 1.0)
                .setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // 2. Raw silhouette in screen mode: black vanishes, white shines.
            raw.draw(in: CGRect(origin: .zero, size: size),
                     blendMode: .screen, alpha: 1.0)
        }
    }

    // MARK: - Pixel comparison helper

    private func imagesAreIdentical(_ a: UIImage, _ b: UIImage) -> Bool {
        guard let da = a.pngData(), let db = b.pngData() else { return false }
        return da == db
    }

    // MARK: - File I/O

    private func writeImage(_ image: UIImage?, name: String) throws {
        guard let image, let png = image.pngData() else {
            return
        }
        let url = Self.outDir.appendingPathComponent(name)
        try png.write(to: url)
    }
}
