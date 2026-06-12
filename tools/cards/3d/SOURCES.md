# 3D card-art model sources

Provenance + license record for every 3D asset shipped in the app for the
interactive-card spike (`feat/card-3d-spike`). Every model here must be
CC0/PD or CC-BY. CC-BY requires the attribution line below to appear on the
in-app attributions page before this ships to TestFlight.

---

## Boeing 747 (low-poly) — SHIPPED

- **Model name:** Boeing 747
- **Author:** Miha Lunar
- **Source URL:** https://poly.pizza/m/49CLof4tP2V
- **Original download (GLB):** https://static.poly.pizza/f9afa9f0-92a5-41c1-afa4-c0b7d3444f35.glb
- **License:** Creative Commons Attribution (CC-BY 3.0)
- **License URL:** https://creativecommons.org/licenses/by/3.0/
- **Required attribution text:**
  > "Boeing 747" by Miha Lunar, licensed under CC-BY 3.0 (https://creativecommons.org/licenses/by/3.0/) via Poly Pizza (https://poly.pizza/m/49CLof4tP2V)
- **Livery:** Neutral — white body, gray trim, light translucent glass.
  NOT a real airline livery, so no trademark concern. No recolor needed.
- **Geometry:** 1,904 triangles / 4,250 vertices across 3 meshes
  (body, trim, glass). Genuinely low-poly; flat-color stylized look.

### Conversion pipeline (GLB → OBJ+MTL)

The shipped asset is `ios/Tailspot/Tailspot/Boeing747.obj` (+ `boeing747.mtl`),
NOT the GLB — SceneKit doesn't load glTF natively. Conversion was done with
`trimesh` (Python) in a throwaway venv:

1. Load GLB as a `trimesh.Scene`, walk the scene graph, bake each node's
   transform into its mesh.
2. Normalize: center the combined bounds at the origin, uniformly scale so
   the largest extent = 2.0 units.
3. Write a single OBJ with one `o`/`usemtl` group per source mesh, plus a
   sidecar MTL naming three materials: `body` (white), `trim` (gray #595959),
   `glass` (translucent light #D4E3DE @ 40%).

Material colors are ALSO assigned in Swift at load time
(`Card3DSpikeView.swift`) so the in-app look doesn't depend on SceneKit
parsing the MTL — the OBJ only needs to provide geometry + normals.

Provenance copies kept in this dir (NOT bundled in the app):
- `boeing747-source.glb` — the original poly.pizza download (116 KB)
- `Boeing747.scn` — `scntool`-converted SceneKit scene, kept for reference;
  the app ships the OBJ, not this.

Shipped asset size: OBJ 329 KB + MTL <1 KB. Well under the 5 MB cap.

---

## Helicopter — SHIPPED

- **Model name:** Helicopter
- **Author:** Poly by Google
- **Source URL:** https://poly.pizza/m/6U2H_0VSAXY
- **Original download (GLB):** https://static.poly.pizza/fda50fdb-275b-4443-a32f-52e5b8c55280.glb
- **License:** Creative Commons Attribution (CC-BY 3.0)
- **License URL:** https://creativecommons.org/licenses/by/3.0/
- **Required attribution text:**
  > "Helicopter" by Poly by Google, licensed under CC-BY 3.0 (https://creativecommons.org/licenses/by/3.0/) via Poly Pizza (https://poly.pizza/m/6U2H_0VSAXY)
- **Geometry:** 2,372 triangles / 2,428 vertices across 10 meshes
  (fuselage, rotor assembly, tail, skids, windows, details).
  Low-poly stylized look consistent with the 747.

### Conversion pipeline (GLB → OBJ)

The shipped asset is `ios/Tailspot/Tailspot/FleetHelicopter.obj`.

1. Load GLB as a `trimesh.Scene` via `to_geometry()` (all node transforms baked).
2. Center combined bounds at origin.
3. Uniformly scale so largest extent (X — rotor diameter) = 2.0 units,
   matching the 747 normalization target. Final extents: X=2.0, Y=1.01, Z=1.26.
4. Export as OBJ (123 KB — well under 500 KB cap).

Per-model orientation adjustment in SceneKit (`CardModelRegistry`):
- 90° rotation about Y axis (`Float.pi * 0.5`) so the nose (along X+ in the
  normalized OBJ) faces toward the camera (Z+ in the hero pose).
- Uniform scale boost of 1.2× in SceneKit so the compact rotor footprint
  fills the card viewport comparably to the longer 747 fuselage.

Provenance copy:
- `incoming/helicopter-source.glb` — original poly.pizza download (100 KB)
- `output/FleetHelicopter.obj` — normalized output (123 KB)

---

## A320 Narrowbody — PENDING (Sketchfab login-walled)

- **Model name:** Low Poly Airliner
- **Author:** Mauro3D
- **Source URL:** https://sketchfab.com/3d-models/low-poly-airliner-f06d488f08764e3ca26f2917d4053c69
- **License:** CC-BY 4.0 (per Sketchfab listing)
- **Status:** Download requires a logged-in Sketchfab account.
  Manual download required — save as `incoming/narrowbody-source.glb` then
  run `convert_fleet.py` to produce `FleetNarrowbody.obj`.

---

## Boeing 787 Widebody — PENDING (Sketchfab login-walled)

- **Model name:** Low Poly Boeing 787 Dreamliner
- **Author:** Mauro3D
- **Source URL:** https://sketchfab.com/3d-models/low-poly-boeing-787-dreamliner-50baa323fabd49a6b861096cb88e5c25
- **License:** CC-BY 4.0 (per Sketchfab listing)
- **Status:** Download requires a logged-in Sketchfab account.
  Manual download required — save as `incoming/widebody-source.glb`.

---

## GA Prop — PENDING (Sketchfab login-walled + license unverified)

- **Model name:** Low Poly Plane
- **Author:** scailman
- **Source URL:** https://sketchfab.com/3d-models/low-poly-plane-76230052903540e9aeb46b7db35329e4
- **License:** UNVERIFIED — survey listed CC-BY but page could not be confirmed.
  **Verify the license on the Sketchfab page before shipping this model.**
- **Status:** Download requires a logged-in Sketchfab account.
  Manual download required — save as `incoming/gaprop-source.glb`.
  Do NOT bundle until license is verified.
