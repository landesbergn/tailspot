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
