#!/usr/bin/env python3
"""
convert_fleet.py
Convert incoming GLB/glTF aircraft models to normalized OBJ files
for bundling in the iOS app.

Normalization pipeline (matching Boeing747.obj as the reference):
  1. Load GLB/glTF as a trimesh.Scene, bake all node transforms.
  2. Center the combined bounding box at the origin.
  3. Uniformly scale so the largest extent = 2.0 units (Y-up).
  4. Export as OBJ (< 500 KB target; decimate if needed).

Usage:
  python3 convert_fleet.py

Input files expected in ./incoming/:
  narrowbody-source.glb   → FleetNarrowbody.obj
  widebody-source.glb     → FleetWidebody.obj
  gaprop-source.glb       → FleetGAProp.obj
  helicopter-source.glb   → FleetHelicopter.obj  (already processed)

Output files written to:
  ./output/<name>.obj

Then copy to ios/Tailspot/Tailspot/ to bundle in the app.
"""

import os
import sys
import trimesh
import numpy as np

# Maps input filename (in ./incoming/) → output OBJ name (no extension)
FLEET = {
    "narrowbody-source.glb": "FleetNarrowbody",
    "widebody-source.glb":   "FleetWidebody",
    "gaprop-source.glb":     "FleetGAProp",
    "helicopter-source.glb": "FleetHelicopter",
}

TARGET_EXTENT = 2.0   # largest axis normalized to this (units, matching 747)
MAX_SIZE_KB   = 500   # warn if OBJ exceeds this

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
INCOMING    = os.path.join(SCRIPT_DIR, "incoming")
OUTPUT_DIR  = os.path.join(SCRIPT_DIR, "output")
os.makedirs(OUTPUT_DIR, exist_ok=True)


def normalize(mesh: trimesh.Trimesh) -> trimesh.Trimesh:
    """Center + uniform scale to TARGET_EXTENT, in place."""
    mesh.vertices -= mesh.bounding_box.centroid
    extents = mesh.bounding_box.extents
    max_extent = extents.max()
    if max_extent > 1e-6:
        mesh.apply_scale(TARGET_EXTENT / max_extent)
    return mesh


def decimate_if_needed(mesh: trimesh.Trimesh, name: str) -> trimesh.Trimesh:
    """Decimate if estimated OBJ size exceeds MAX_SIZE_KB."""
    # Rough OBJ size estimate: ~100 bytes per vertex
    est_kb = len(mesh.vertices) * 100 / 1024
    if est_kb > MAX_SIZE_KB:
        target_faces = int(len(mesh.faces) * MAX_SIZE_KB / est_kb)
        print(f"  Decimating {name}: {len(mesh.faces)} → ~{target_faces} faces")
        try:
            mesh = mesh.simplify_quadric_decimation(target_faces)
        except Exception as e:
            print(f"  Decimation failed ({e}), keeping original.")
    return mesh


def convert(glb_path: str, out_name: str) -> bool:
    """Load, normalize, and export one model. Returns True on success."""
    print(f"\n{os.path.basename(glb_path)} → {out_name}.obj")
    if not os.path.exists(glb_path):
        print(f"  SKIP: file not found — download it first.")
        return False

    try:
        scene = trimesh.load(glb_path, force="scene")
        mesh  = scene.to_geometry()
    except Exception as e:
        print(f"  ERROR loading: {e}")
        return False

    print(f"  Loaded: {len(mesh.faces)} triangles, {len(mesh.vertices)} vertices")
    print(f"  Raw bounds:   {mesh.bounds}")
    print(f"  Raw extents:  {mesh.bounding_box.extents.round(3)}")

    mesh = normalize(mesh)
    mesh = decimate_if_needed(mesh, out_name)

    print(f"  Scaled extents: {mesh.bounding_box.extents.round(3)}")
    print(f"  Final bounds:   {mesh.bounds.round(3)}")

    out_path = os.path.join(OUTPUT_DIR, out_name + ".obj")
    mesh.export(out_path)
    size_kb = os.path.getsize(out_path) // 1024
    print(f"  Exported: {out_path}  ({size_kb} KB)")

    if size_kb > MAX_SIZE_KB:
        print(f"  WARNING: {size_kb} KB exceeds {MAX_SIZE_KB} KB target!")

    return True


def main():
    any_skipped = False
    for glb_name, out_name in FLEET.items():
        glb_path = os.path.join(INCOMING, glb_name)
        ok = convert(glb_path, out_name)
        if not ok:
            any_skipped = True

    print("\n" + "="*60)
    if any_skipped:
        print("Some models were skipped (see above). Download them from")
        print("Sketchfab (requires login) into ./incoming/ and re-run.")
    else:
        print("All models converted.")
    print(f"\nOutput OBJs are in: {OUTPUT_DIR}")
    print("Copy to ios/Tailspot/Tailspot/ to bundle in the iOS app.")
    print("Then update CardModelRegistry.swift (resourceName for each family).")


if __name__ == "__main__":
    main()
