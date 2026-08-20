# Marketing assets

Everything that ends up on the App Store listing. Start here, not in
`app-store-screenshots/README.md` (that one documents the generic editor
scaffold, not this pipeline).

```
marketing/
├─ catch-photos/            real catch photos, committed — see its README
└─ app-store-screenshots/   the Next.js deck editor
   ├─ app-store-screenshots.json      the deck: copy, layout, which file per slide
   ├─ public/screenshots/apple/iphone/en/   the six source screenshots
   ├─ export/                          current store-ready PNGs (gitignored)
   └─ export-archive/<version>/        what actually shipped for that version
```

## The six slides

Files are named for the slide they fill, so the deck and the folder agree.
**This was not always true** — they used to be `01.png`…`07.png`, where slide 2
was `07.png` and `02.png` was unused. Don't go back to numbers.

| Slide | File | Source | Content |
|---|---|---|---|
| 1 | `slide1-ar-catch.png` | **Noah's field capture** | Real sky, real plane, HUD locked on |
| 2 | `slide2-collection-card.png` | `mkt_07_collection` | BD-700, RARE, first of type, +75 |
| 3 | `slide3-guess-round.png` | `mkt_03_guess_round` | A321neo up from Guayaquil |
| 4 | `slide4-hangar-sets.png` | `mkt_04_hangar_sets` | Sets grid |
| 5 | `slide5-trophies.png` | `mkt_05_trophies` | Trophy case |
| 6 | `slide6-leaderboard.png` | `mkt_06_leaderboard` | Standings |

`mkt_02_reveal` also renders but **no slide uses it** — it's a spare if the
deck ever wants the reveal screen. `bin/marketing-collect` owns the
shot → filename mapping so nobody has to remember the crossover.

## Regenerating slides 2–6

```bash
bin/marketing-stage-photos          # real catch photos → /private/tmp
xcrun simctl boot <sim>             # a booted sim is required
tools/marketing-shot-watcher.sh &   # only for shots 4–6 (see below)

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
- **Shots 4, 5, 6** carry `.glassEffect`, which offscreen capture garbles.
  They're shown on the real simulator screen and grabbed by
  `tools/marketing-shot-watcher.sh` via a flag-file handshake. That watcher
  must be running or those three will hang for 20 s each and produce nothing.

## Slide 1 is different

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

1. Re-capture if any UI on slides 2–6 changed since the last export.
2. Export the bundle; upload from `export/ios/iphone/1284x2778/en/`.
3. Once the version ships, copy the set to `export-archive/<version>/` so
   there's a record of what each listing actually showed.

Listing copy, privacy, and the ASC click-through checklist live in
`docs/ga/appstore-listing.md`. Current status is PLAN §9 item 8.
