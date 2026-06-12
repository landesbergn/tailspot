# Silhouette-from-3D pipeline

Spike result: `feat/card-3d-spike`, 2026-06-11.
Harness: `TailspotTests/SilhouetteFrom3DRenderTests.swift`.
Outputs: `/tmp/silhouette-from-3d/` (raw + composited PNGs).

## What the spike proved

Loading the bundled OBJ into SceneKit, setting an orthographic camera at
`(0, 10, 0)` with `eulerAngles.x = -π/2` (straight down), applying flat
white `.constant` materials to all geometry, and calling `SCNView.snapshot()`
produces a clean black-and-white top-down planform render.

**Boeing 747** — planform reads unmistakably: four nacelles on swept wings,
characteristic upper-deck hump, wide inboard chord, correct stabilizer
proportions. A ~25° clockwise rotation in the frame (OBJ authoring artifact)
needs a further Y-trim to straighten, but identity is unambiguous. Landing
gear struts protrude as small rectangular nubs along the wing undersides —
clutter at card thumbnail scale, removable with a small Z-offset in the
trimesh pipeline.

**Helicopter** — fuselage body and tail boom read correctly; skid rails
are the most visually dominant element (prominent cross-hatch framing the
body). Critical gap: **the OBJ has no rotor blades**. Without the main
rotor disc the top-down silhouette reads as a torpedo-with-skids, not a
helicopter. The disc must be added — either as geometry in the source GLB
(preferred) or as a post-process SVG/Core Graphics overlay composited on
top of the render before the card asset is baked.

## Camera and orientation notes

- `eulerAngles.x = -π/2` on the camera node: look direction = world -Y
  (straight down), camera-up = world -Z.
- World -Z appears at the **top** of the rendered frame; world +Z at the
  bottom.
- The trimesh pipeline places the nose at +Z. All fleet OBJs therefore
  need `orientationAdjustment.y = π` (plus any per-model fine trim) so
  the nose reaches -Z and appears at the top.
- Helicopter additionally needs `+π/2` to bring its nose from +X to +Z
  before the flip. Net: `Ry(3π/2)`.

## Recommended production path

**Pre-render at build time, not at runtime.**

Generate one PNG per fleet family (1024×1024 or 512×512) by running the
`SilhouetteFrom3DRenderTests` harness as a `xcodebuild test` step in the
Xcode Cloud `ci_post_clone.sh`, writing assets to a known path, then
copying them into the app bundle as a build phase. Each card then loads
its silhouette PNG exactly as it loads a photo asset — no SceneKit scene
graph, no Metal device, no per-frame overhead at display time.

The alternative — render-and-cache at runtime the first time a card is
shown — works but burns ~4–5 s per model on simulator (software Metal)
and an unknown but non-trivial budget on device. Startup or first-open
jank is the predictable cost. It also means the first user to open a
card family incurs the penalty, and the cache is lost on reinstall.

Pre-rendering has one tradeoff: adding a new fleet model requires a CI
rebuild to regenerate its asset PNG. That is the right tradeoff here —
the fleet is small and infrequently updated, and baking the silhouettes
at build time keeps card display logic simple and fast.

**Cleanup pass required before shipping any asset:**

1. **747 Y-trim:** add ~0.02 rad additional Y rotation to straighten the
   fuselage to vertical in the frame. Current offset is ~25° clockwise.
2. **Landing gear nubs:** in `tools/cards/3d/convert_fleet.py`, filter out
   or collapse the gear geometry before export, or set a slightly elevated
   camera angle (2–3° off true vertical) so struts hide behind the wing.
3. **Helicopter rotor disc:** add a thin disc mesh to the source GLB before
   running `convert_fleet.py`, or composite a programmatic ring (radius =
   ~0.9× rotor diameter, 4 px stroke, 20% opacity) on top of the rendered
   PNG using Core Graphics in the harness. The disc is essential for
   instant helicopter recognition from above.
