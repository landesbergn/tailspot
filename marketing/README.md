# Marketing assets

Everything that ends up on the App Store listing. Start here, not in
`app-store-screenshots/README.md` (that one documents the generic editor
scaffold, not this pipeline).

```
marketing/
├─ releases/<version>/      what each App Store version uploaded — START HERE to upload
├─ catch-photos/            real catch photos, committed — see its README
├─ app-store-creative/      header / search results builder (compose.py)
└─ app-store-screenshots/   the Next.js deck editor
   ├─ app-store-screenshots.json      the deck: copy, layout, which file per slide
   ├─ public/screenshots/apple/iphone/en/   the seven source screenshots
   └─ export/                          current store-ready PNGs (gitignored)
```

## The seven slides

Files are named for the slide they fill, so the deck and the folder agree.
**This was not always true** — they used to be `01.png`…`07.png`, where slide 2
was `07.png` and `02.png` was unused. Don't go back to numbers.

| Slide | File | Source | Content |
|---|---|---|---|
| 1 | `slide1-ar-catch.png` | `mkt_01_fleet_week` | C-27J (C2703) over the Golden Gate, Fleet Week 2026: real catch photo + HUD label and capture button |
| 2 | `slide2-collection-card.png` | `mkt_07_fleet_week_e6` | E-6 Mercury, LEGENDARY, +500 (Fleet Week 2026) |
| 3 | `slide3-guess-round.png` | `mkt_03_guess_round` | A321neo up from Guayaquil |
| 4 | `slide4-hangar-sets.png` | `mkt_04_hangar_sets` | Sets grid |
| 5 | `slide5-trophies.png` | `mkt_05_trophies` | Trophy case |
| 6 | `slide6-leaderboard.png` | `mkt_06_leaderboard` | Standings |
| 7 | `slide7-challenges.png` | `mkt_08_challenge_live` | A live private challenge: 7 spotters, me 1st by 35 (added for v1.2.0; `isolated` in the deck) |

The deck uses the connected canvas, so a phone can bleed across a slide
edge (slide 6's two phones reach into slides 5 and 7). A slide with
`"isolated": true` in `app-store-screenshots.json` is drawn above the shared
canvas inside its own clip, so nothing bleeds onto it or off it. Slide 7
uses it; flipping it on for another slide changes only that slide's export.

`mkt_02_reveal` and `mkt_07_collection` (the old BD-700 slide 2) also render but **no slide uses them** — it's a spare if the
deck ever wants the reveal screen. Likewise `mkt_08b_challenge_live_expanded`
(my catch log open) and `mkt_09_challenges_hub` render as Challenges spares. `bin/marketing-collect` owns the
shot → filename mapping so nobody has to remember the crossover.

## Regenerating slides 1–7

```bash
bin/marketing-stage-photos          # real catch photos → /private/tmp
xcrun simctl boot <sim>             # a booted sim is required
tools/marketing-shot-watcher.sh &   # only for shots 4–6 and 8–9 (see below)

TEST_RUNNER_MARKETING_CAPTURE=1 xcodebuild test \
  -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,id=<sim>' \
  -parallel-testing-enabled NO \
  -only-testing:TailspotTests/MarketingSnapshotTests

bin/marketing-collect               # harness output → deck, by slide name
```

Then open the editor and click **Export bundle**:

```bash
cd marketing/app-store-screenshots && npm run dev   # localhost:3000
```

**Always re-stage immediately before capturing.** `/private/tmp` gets swept,
and without the photos the card shots render the illustrated placeholder.
That used to happen silently; it now fails loudly, and `marketing-collect`
refuses to leave a slide stale without telling you.

Two capture paths exist, for a reason:
- **Shots 2, 3, 07** render offscreen — no watcher needed. ImageRenderer
  can't draw them (any photo-bearing card comes out as a yellow "no entry"
  placeholder, because `RevealPhoto` wraps the hero in a UIKit tag view), so
  they go through `writeOffscreen`.
- **Shots 4, 5, 6, 8, 9** carry `.glassEffect`, which offscreen capture garbles.
  They're shown on the real simulator screen and grabbed by
  `tools/marketing-shot-watcher.sh` via a flag-file handshake. That watcher
  must be running or those shots will hang for 20 s each and produce nothing.
  Newer simulators leave the Dynamic Island out of `simctl io screenshot`;
  the watcher paints it back from a second `--mask=black` shot (needs
  ImageMagick), so new captures match the older slides.
- **The Challenges shots never show the DEMO DATA badge.** That badge keys
  off the `-challengesFixture` launch argument; the harness injects its own
  `FixtureChallengesService` world (invented handles) straight into the
  model instead. Its invite code must be a valid 6-character code from the
  invite alphabet (no L, I, O, 0, 1), currently `WKND7X`.
- **The home indicator can land on slide 7's bottom row.** The sim draws it
  over window-hosted shots inconsistently; neither `persistentSystemOverlays`
  nor `prefersHomeIndicatorAutoHidden` on the capture window suppresses it.
  The 2026-10-02 slide 7 had its bottom 72 px (the indicator band) swapped
  for the same band of an earlier clean render of the identical rows (the
  400 px above matched pixel-for-pixel), so nothing but the system bar
  changed. If a re-capture shows the bar, do the same.

## Slide 1 is different

**Since 2026-10-12 (Fleet Week refresh):** slide 1 is the app's own composed
catch photo of the C-27J over the Golden Gate (`catch-photos/fw_c27j_golden_gate.jpg`,
brackets baked in by `CatchPhotoComposer` at capture), filling the screen,
with the HUD's pinned label and capture button drawn on top by
`renderFleetWeekHUD` using the same styling as `PlaneLabel` / `captureButton`.
The sky, plane and brackets are untouched. Only the pinned label and the
capture button are added; the live HUD also shows the Hangar and profile
buttons, which this render leaves out. Faces: the crowd is mostly backs of
heads, but a few strangers are recognisable at full size.

The previous slide 1, described below, was a real HUD screenshot.

It is a **real photograph**, not a render — the simulator has no camera. The
stylized stand-in that used to fill this slot was deleted once a real capture
existed, deliberately: a synthetic sky must not creep back into a listing
whose whole claim is that the catch is real.

Retouching applied to the shipped version:
- Status bar removed entirely (no time, carrier, wifi, battery). Only the
  Dynamic Island remains, since that's hardware.
- Lock-on bracket recentred on the plane. **Noah's call, 2026-08-20.** The
  contrail is excluded from the move, so the plane sits exactly where it was
  photographed and only the HUD chrome shifted.

The unretouched original is kept at
`docs/ga/screenshots-raw/01-hud-bracket-as-shot.png`. Keep it — if App Review
ever asks what was changed, that's the answer.

A better capture would still beat it: a closer plane (approach traffic into
OAK/SFO), bracket in the upper-middle third with the treeline in frame,
locked on before the shutter, Do Not Disturb on, and the **original file**
rather than a pasted screenshot.

## Export sizes

App Store Connect's iPhone slot accepts **1242 × 2688** or **1284 × 2778**.
The deck exports five sizes so the upload never bounces:

`1320×2868` · `1284×2778` · `1242×2688` · `1206×2622` · `1125×2436`

Sizes live in `src/lib/constants.ts` (`EXPORT_SIZES`).

## Before a submission

1. Re-capture if any UI on slides 2–7 changed since the last export.
2. Export the bundle (and run `app-store-creative/compose.py` if the
   creative assets changed).
3. `bin/marketing-release vX.Y.Z` packages it into `marketing/releases/vX.Y.Z/`
   (committed): `screenshots/` in upload order plus `creative/`. Upload from
   there, then flip the status in that folder's README and the index.
   `marketing/releases/README.md` is the history of every listing.
   (The old gitignored `export-archive/` sets were migrated there on 2026-10-12.)

## Header and Search Results (creative assets)

`app-store-creative/` builds the iOS 27 product-page **header** (21:9,
3840×1646), **search results** (3:2, 3840×2560) and **universal** (16:9,
5244×2950) images from the same real renders: `renderFleetWeekCardParts`
(transparent card PNGs) plus the slide 1 HUD screen. See its README.

Listing copy, privacy, and the ASC click-through checklist live in
`docs/ga/appstore-listing.md`. Current status is PLAN §9 item 8.
