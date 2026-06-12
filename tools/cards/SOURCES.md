# Card-silhouette sources & trace pipeline

Stage-2b card-style spike (`feat/card-style-spike`), **second attempt**. The
first round hand-drew the silhouettes from proportion notes and they didn't
resemble the real airframes. This round **traces license-clean reference
imagery** — the approach the program spec sanctions ("traced from license-free
references").

Every reference below is **public domain or CC0** — no share-alike, no
non-commercial, no attribution-required license touches a shipped asset. (We
checked each file's license page individually via the Wikimedia Commons
`imageinfo` API; Commons mixes licenses within a category, so per-file
verification was required.) The reference bitmaps live in
`tools/cards/references/` (total < 1 MB, so they're committed).

## Source table

| Card slot | Aircraft traced | File | License | Author / origin |
|---|---|---|---|---|
| **A320** (narrowbody twin) | Boeing KC-46 Pegasus — plan-view silhouette | [`File:Boeing_KC-46_Pegasus_plan_view_silhouette_drawing.jpg`](https://commons.wikimedia.org/wiki/File:Boeing_KC-46_Pegasus_plan_view_silhouette_drawing.jpg) | **Public domain** (PD-USGov-Military-Air Force) | US Air Force / Philip Bryant |
| **747** (widebody quad) | Boeing 747 (NASA Shuttle Carrier Aircraft) — 3-view, top panel | [`File:Shuttle_Carrier_Aircraft_diagram.gif`](https://commons.wikimedia.org/wiki/File:Shuttle_Carrier_Aircraft_diagram.gif) | **Public domain** (PD-USGov-NASA) | NASA Dryden, Feb 1998 |
| **Citation** (T-tail bizjet) | Learjet 24 — 3-view, top panel | [`File:Learjet_24_3-View_line_art.gif`](https://commons.wikimedia.org/wiki/File:Learjet_24_3-View_line_art.gif) | **Public domain** (PD-USGov-NASA) | NASA |
| **C172** (GA high-wing) | Cessna 172 — 3-view, top panel | [`File:Cessna_172.svg`](https://commons.wikimedia.org/wiki/File:Cessna_172.svg) | **CC0** | Marek Cel (Commons: *Cel 84*) |
| **Heli** (Bell 206) | Bell OH-58A Kiowa (military Bell 206) — 3-view, plan panel | [`File:Bell_OH-58A_Kiowa_3-view_line_drawing.png`](https://commons.wikimedia.org/wiki/File:Bell_OH-58A_Kiowa_3-view_line_drawing.png) | **Public domain** (PD-USGov) | US Army manual |

### Documented family substitutions

The spec asked for plan-form references and said to "use the closest
licensable family member, documented" where a clean one doesn't exist. Three
slots use a documented stand-in:

- **A320 → KC-46.** No clean-licensed A320/737/narrowbody **plan view** exists
  on Commons — the Airbus A320/A319/A321 4-views (`Julien.scavini`) are
  **CC-BY-SA 3.0**, and the `Boeing 737-800 silhouette.svg` is **CC-BY-SA 4.0**
  (both share-alike → cannot ship). The KC-46 (a Boeing 767-family tanker) is
  the closest license-clean **true top-down twin-jet** plan-form: two underwing
  engines, swept wing + winglets, swept tailplane, single fin. The refueling
  boom was masked off in the trace so it reads as a generic narrowbody twin.
  It is a widebody underneath, but at card-silhouette scale the *configuration*
  (twin underwing + single fin) is the A320 read.
- **Citation → Learjet 24.** No clean Citation plan view turned up; the Learjet
  is the same class (T-tail business jet, two aft-fuselage engines, low swept
  wing) and is **PD (NASA)**. Its wingtip fuel tanks (a Learjet signature) show
  at the wingtips. Same diagnostic bizjet read as a Citation.
- **Bell 206 → OH-58A Kiowa.** The OH-58A *is* the military Bell 206 JetRanger;
  the only clean-licensed Bell 206 plan view is this **PD (US Army)** manual
  drawing. The civilian `Bell 206A orthographical image.svg` is **CC-BY-SA 4.0**.

### Licenses we rejected (for the record)

| File | License | Why rejected |
|---|---|---|
| `Airbus A320 v1.0.png` (+ A319/A321) | CC-BY-SA 3.0 | share-alike contaminates shipped assets |
| `Boeing 747-400 3view.svg` | CC-BY-SA 4.0 | share-alike |
| `Boeing 747-400 silhouette.svg` | CC-BY-SA 4.0 | share-alike |
| `Bell 206A orthographical image.svg` | CC-BY-SA 4.0 | share-alike |
| `Boeing 737-800 silhouette.svg` | CC-BY-SA 4.0 | share-alike |
| `Boeing 737.svg` | CC0 (but 3/4 perspective render, not a plan view) | wrong view |

## Trace pipeline

Tools (install once): `brew install potrace imagemagick`.

The per-aircraft recipe (ImageMagick `magick`, then `potrace`, then
`svg2swift.py`). Coordinates are the actual crops/masks used; re-derive if a
reference is re-uploaded at a different size. All intermediate files land in
`tools/cards/work/` (gitignored scratch).

The core trick for line-drawing references (outline drawings, not solid
silhouettes): **flood-fill the exterior** with a sentinel color, then map
sentinel→white and everything-else→black. That collapses internal panel lines
into a solid silhouette without tracing them.

```sh
# --- C172 (CC0 Cessna 172.svg): plan view, nose-left, mirrored for symmetry ---
magick -density 600 -background white references/c172_marekcel_CC0.svg work/c172_full.png
magick work/c172_full.png -crop 2120x2381+0+1400 +repage -fuzz 8% -trim +repage work/c172_plan_iso.png
magick work/c172_plan_iso.png -alpha off -threshold 60% -bordercolor white -border 4 \
  -fill magenta -draw "color 0,0 floodfill" \
  -fuzz 22% -fill black +opaque magenta -fill white -opaque magenta -shave 4x4 work/c172_sil2.png
magick work/c172_sil2.png -background white -rotate 90 -fuzz 5% -trim +repage work/c172_nu.png
# mirror left half about the detected fuselage centerline (x≈1300) for a clean symmetric outline
magick work/c172_nu.png -crop 1300x%[h]+0+0 +repage work/c172_L.png   # (h = c172_nu height)
magick work/c172_L.png -flop work/c172_Lm.png
magick work/c172_L.png work/c172_Lm.png +append work/c172_sym.png
magick work/c172_sym.png -alpha off -threshold 50% -blur 0x3 -threshold 50% work/c172_final.pbm
potrace -s work/c172_final.pbm -o work/c172.svg --turdsize 250 --opttolerance 1.2 --alphamax 1.3

# --- 747 (NASA SCA diagram): top panel, nose-right ---
magick references/sca_747_nasa_PD.gif -crop 1620x1700+130+460 +repage work/747top2.png   # plan panel
magick work/747top2.png -fill white -draw "rectangle 1300,0 1620,420" \
  -fill white -draw "rectangle 1280,1230 1620,1700" work/747top4.png                       # mask side/front panels
magick work/747top4.png -alpha off -threshold 60% -bordercolor white -border 2 \
  -fill magenta -draw "color 0,0 floodfill" \
  -fuzz 20% -fill black +opaque magenta -fill white -opaque magenta -shave 2x2 work/747_raster.png
# drop thin remnants by keeping the largest connected blob, then mask the nose dimension thread
magick work/747_raster.png -negate -define connected-components:area-threshold=20000 \
  -define connected-components:mean-color=true -connected-components 8 -threshold 1% work/747_blob.png
magick work/747_blob.png -fill black -draw "rectangle 800,0 845,400" work/747_blob2.png      # erase leader thread
magick work/747_blob2.png -background black -rotate -90 -negate -fuzz 5% -trim +repage \
  -blur 0x2 -threshold 50% work/747_final.pbm
potrace -s work/747_final.pbm -o work/747.svg --turdsize 350 --opttolerance 1.2 --alphamax 1.3

# --- Learjet 24 (NASA 3-view): top panel, nose-right ---
magick references/learjet24_nasa_PD.gif -crop 1490x1390+80+135 +repage work/lj.png          # plan panel
magick work/lj.png -fill white -draw "rectangle 1330,0 1490,260" \
  -fill white -draw "rectangle 1250,1120 1490,1390" work/lj_painted.png                      # mask side/front panels
magick work/lj_painted.png -alpha off -threshold 60% -bordercolor white -border 2 \
  -fill magenta -draw "color 0,0 floodfill" \
  -fuzz 20% -fill black +opaque magenta -fill white -opaque magenta -shave 2x2 work/lj_raster.png
magick work/lj_raster.png -negate -define connected-components:area-threshold=15000 \
  -define connected-components:mean-color=true -connected-components 8 -threshold 1% work/lj_blob.png
magick work/lj_blob.png -background black -rotate -90 -negate -fuzz 5% -trim +repage \
  -blur 0x2 -threshold 50% work/learjet_final.pbm
potrace -s work/learjet_final.pbm -o work/learjet.svg --turdsize 200 --opttolerance 1.2 --alphamax 1.3

# --- KC-46 (PD plan-view silhouette, already solid black): mask refueling boom ---
magick references/kc46_PD.jpg -alpha off -colorspace Gray -threshold 50% -fuzz 5% -trim +repage work/kc46_bw.png
magick work/kc46_bw.png -fill white -draw "rectangle 630,1300 760,1472" work/kc46_noboom.png  # erase boom
magick work/kc46_noboom.png -fuzz 5% -trim +repage -blur 0x2 -threshold 50% work/kc46_final.pbm
potrace -s work/kc46_final.pbm -o work/kc46.svg --turdsize 200 --opttolerance 1.2 --alphamax 1.3
```

Then convert each SVG to a SwiftUI `Shape` and paste over the matching struct
in `ios/Tailspot/Tailspot/CardSilhouettes.swift` (the type names are
load-bearing — the spike harness references them):

```sh
python3 svg2swift.py work/kc46.svg    --name A320     --aspect 0.996 > generated/A320.swift
python3 svg2swift.py work/747.svg     --name B747     --aspect 1.043 > generated/B747.swift
python3 svg2swift.py work/learjet.svg --name Citation --aspect 0.902 > generated/Citation.swift
python3 svg2swift.py work/c172.svg    --name C172     --aspect 1.339 > generated/C172.swift
```

`--aspect` is the **measured span:length of the trace bounding box** (so the
normalized path renders undistorted). `svg2swift.py` flips y so the
already-nose-up reference maps to design-y 0 = nose.

Control-point counts (kept under "a few hundred" per the spec, via potrace
`--turdsize`/`--opttolerance` and a pre-trace blur to drop panel-line notches):
C172 ≈ 170, 747 ≈ 310, KC-46/A320 ≈ 262, Learjet/Citation ≈ 226.

## Helicopter: NOT a literal trace

The Bell OH-58A plan view is a **dimensioned engineering drawing** — its rotor
blades and dimension/leader lines bridge the airframe interior to the page
exterior, so the flood-fill silhouette leaks (verified: the fill floods the
whole page). The `HeliSilhouette` body is therefore a **reference-proportioned
procedural redraw** built to the measured Bell 206 plan proportions (cabin in
the forward third, thin tail boom ~half the length, tail rotor + horizontal
stabilizer, skids); the disc + crossed main-rotor blades stay procedural. This
is documented in `CardSilhouettes.swift` and is the honest split: four literal
traces + one reference-proportioned redraw.
