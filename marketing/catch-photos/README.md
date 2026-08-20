# Real catch photos (marketing fixtures)

Ten of Noah's own catches, exported from the app's share cards
(`CatchShareCard`) on 2026-08-19 and cropped back to the bare photo.

**These are the app's own composed catch JPEGs.** `CatchPhotoComposer`
bakes the cyan lock-on brackets into every catch photo at capture time, so
the framing you see here is the framing the user saw in the AR view — no
overlay is added or needed. Feeding one to `CardPlane.photoURL` reproduces
exactly what the Hangar shows.

## Use

`bin/marketing-stage-photos` copies them to
`/private/tmp/tailspot_snaps/marketing/photos/`, where
`MarketingSnapshotTests` reads them (the simulator can read `/private/tmp`,
not the repo checkout). Run it before any `MARKETING_CAPTURE=1` run.

## The set

`focus.json` carries each photo's normalized bracket centre — pass it as
`CardPlane.photoFocus` so the hero's aspect-fill crop stays on the plane.

| File | Catch | Tier | Notes |
|---|---|---|---|
| `bd700_rare.jpg` | WWI21 · BD-700 Global Express · Worldwide Jet Charter | rare | 43,225 ft, 546 kt, 27.1 km. Contrail against deep blue. **The reveal shot.** |
| `a220_with_route_uncommon.jpg` | ACA568 · A220-300 · Air Canada | uncommon | YVR → SFO. Dramatic cloud + tree edge. |
| `a321_with_route_first.jpg` | JBU1770 · A321neo · JetBlue | common | GYE → JFK, first of type. Plane clearly reads. **The guess shot.** |
| `b737.jpg` | SWA1598 · 737-800 · Southwest | common | 2.1 km. Best plane legibility in the set. |
| `b767_with_route.jpg` | DAL405 · 767-300 · Delta | common | SFO → JFK. Silhouette against a dark cloud band. |
| `c560_uncommon.jpg` | N561SR · Cessna 560 Citation V · private | uncommon | 2.4 km, first of type. |
| `bd100_uncommon.jpg` | LXJ506 · BD-100 Challenger 350 · Flexjet | uncommon | 2.7 km. |
| `175.jpg` | SKW5711 · Embraer 175 · SkyWest | common | SFO → ASE. |
| `a320.jpg` | UAL2818 · A320 · United | common | 9.4 km. Plane barely visible. |
| `b777_with_route.jpg` | UAL926 · 777-200 · United | common | SFO → FRA. Plane barely visible. |

## Choosing one

At App Store thumbnail scale a real plane at 10,000 ft is a few pixels.
`b737`, `b767`, `a321` and `a220` are the only four where the plane still
reads as a plane when the shot is scaled down; `bd700`'s contrail reads
even better than an airframe would. Prefer those for anything a shopper
sees before tapping.
