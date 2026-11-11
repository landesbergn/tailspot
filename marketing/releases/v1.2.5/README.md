# v1.2.5

**Status:** approved by Noah 2026-11-11 and **uploaded to App Store Connect the same day** (by Claude, through the API, at Noah's request). Version 1.2.5 is not submitted. All seven slides rendered 2026-11-10 at 1206 × 2622; slides 3–7 redrawn as illustrations the same day, then slides 3, 4, 6 and 7 revised on 2026-11-11.

## Upload

What is in App Store Connect for 1.2.5 (en-US), as of 2026-11-11:

- **6.9" (`APP_IPHONE_67`)**: `screenshots-6.9in/`, 1320 × 2868. This set also covers
  6.5" phones, so the old 1284 × 2778 6.5" set was deleted from 1.2.5 (the live 1.2.4
  listing keeps its own copy).
- **6.3" (`APP_IPHONE_61`)**: `screenshots/`, 1206 × 2622.
- **Header**: `creative/header_21x9_3840x1646.png`. **Search results**:
  `creative/search_3x2_3840x2560.png`. `universal_16x9_5244x2950.png` is in the asset
  library but not placed.

The creative slots use the App Store Connect API's asset library: upload with
`POST /v1/appAssetLibraryImages` (category `CREATIVE_ASSETS`, relationship
`assetLibrary`), commit with `uploaded: true` (no checksum attribute), then delete
the localization's old `appAssetLibraryPlacements` of that type (one per slot) and
`POST` a new placement with the image and `appStoreVersionLocalization`.

To do it by hand instead: App Store Connect → 1.2.5 → iPhone screenshots → drag the folders in order.
- **Size:** App Store Connect rejected 1284 × 2778 for this slot on 2026-11-10 and
  listed 1206 × 2622, 1179 × 2556 (and landscape) as the accepted sizes. This set is
  1206 × 2622. Earlier sets in this folder are 1284 × 2778.
- Screenshots lock when 1.2.5 is submitted.
- Creative assets (set in App Store Connect separately from the version's screenshots):
  `creative/header_21x9_3840x1646.png` (product page header),
  `creative/search_3x2_3840x2560.png` (search results) and
  `creative/universal_16x9_5244x2950.png` (either slot). RGB, no alpha.

## Contents

- `screenshots/01-what-plane.png` … `07-challenges.png`, in upload order (1206 × 2622)
- `screenshots-6.9in/`: the same slides at 1320 × 2868, rendered from `deck.html` with
  `--force-device-scale-factor=1.094527363` (1320 × 2870), then resized to exactly
  1320 × 2868 and flattened (`magick in.png -resize '1320x2868!' -alpha off PNG24:out.png`)
- `source/deck.html`: the renderer for all seven slides
- `source/creative.html`: the renderer for the three creative assets (`#header`, `#search`, `#universal`)
- `source/e6.png`, `source/l39.png`: photo crops for slides 1–2
- `source/ph/`: `c27j_gg.jpg` (the header photo, a copy of `catch-photos/fw_c27j_golden_gate.jpg`), `c27j_card.jpg` (the header card's photo), `a321_guess.jpg`, slide 3's photo (the area inside the bracket baked into
  `catch-photos/a321_with_route_first.jpg`, crop 256x144+294+212, scaled to 941 × 529),
  and the app icon for slide 7's push

## What changed

Slides 1–2 were redesigned for people who find Tailspot by searching for a
flight tracker. In search results only the first three screenshots show, at
thumbnail size, and the old slide 1 plane was a speck. Search tap-through was
about 5% (Aug 1–Nov 8). Slides 3–7 were then redrawn to match, so the whole
set has one look:

| Slide | Headline | Content |
|---|---|---|
| 1 | What's that plane? Point your phone at it. | E-6 Mercury catch card (Legendary, +500) |
| 2 | Every catch goes into your Hangar. | L-39 Patriots catch card (Rare, +50) |
| 3 | Guess where it's coming from. | The in-card guess round for the JBU1770 A321neo: real four answers, GYE in the app's correct state |
| 4 | Collect every make and model. | The Hangar's Sets tab: five family sets with progress rings |
| 5 | Earn trophies for unique catches. | Legendary trophy unlock, then a shelf of real trophies and two locked |
| 6 | Make your way up the leaderboard. | Podium and rows with no handles; one row up 3 |
| 7 | Challenge your friends. | The real "You got passed" push over a live race, you in 2nd |

- Every slide: the dusk gradient, the headline at the top in the same size and
  weight, white with the second half in cyan, and the content starting at the
  same height.
- Slides 1–2: no phone. The card is a simplified marketing redraw of the in-app
  catch card (bigger photo, no split-flap lettering), not the app's own
  `SettledCatchCard` view. The photos are real catches
  (`catch-photos/fw_e6_crowd.jpg`, `fw_l39_patriots.jpg`), cropped from the
  full-size originals to the area inside the bracket the app baked into each
  photo, with one reticle drawn on top in the app's style and centred on the
  planes. The numbers are the catch rows.
- Slides 3–7 are **illustrations drawn in HTML**, not app screenshots (Noah's
  review, 2026-11-10: centre them, show the feature off, no usernames, don't
  lead with the invite code; 2026-11-11: slides 3 and 4 must still look like
  the app). They use the app's own parts:
  - 3: the photo is cropped to inside the app's baked-in bracket, with one
    reticle drawn on top, as on slides 1–2. Laid out like the round in `CatchRevealView` (mono question, full-width
    chips, the green correct and dimmed states). The chips are the JBU1770
    catch's real values.
  - 4: drawn like `SetsScreen` (segmented control, `SetCompletionCard` rows,
    `CompletionRing`). Set sizes are the real family sets in `Sets.swift`
    (A220 2, A320 6, 777 5, 737 8, 787 3); progress is illustrative.
  - 5: trophy names, summaries and icon paths from `Trophies.swift` and
    `design/game-trophies.jsx`; tier metals from `TrophyTier`.
  - 6: no handles or names, no week label, no crown. Points are illustrative.
  - 7: the push title and body are the backend's real no-handle variant
    (`backend/src/challenges/overtaken.ts`), with "the" added before the
    challenge name. Bars have no track behind them.
    Standings are illustrative.
- Slide 3 says "coming from", not "headed", because the guess it shows asks
  "Where's it coming from?".

This set is rendered from `source/deck.html`, not from the
`app-store-screenshots` deck editor. The editor's JSON still holds the 1.2.2
headlines and layouts.

## Creative assets

Same look as the slides (dusk gradient, the slide headline type, no phone), and
the two slots show different images:

- **Search results (and universal):** "What's that plane? Point your phone to
  catch it." with the E-6 and L-39 catch cards fanned on the right. This is the
  image a searcher sees. Its line (Noah's, 2026-11-11) adds "catch". Slide 1
  keeps "Point your phone at it.": the longer line runs to five lines at
  slide width and pushes the card down, and the first thumbnail needs a short
  headline.
- **Header:** "Catch the planes flying overhead." with the whole catch told left to
  right: the C-27J over the Golden Gate (`catch-photos/fw_c27j_golden_gate.jpg`,
  copied to `source/ph/c27j_gg.jpg`) with the app's pinned label (`C2703 · EPIC
  +100`), dashed zoom lines from the bracket to its catch card, and the card
  itself (C-27J Spartan, US Coast Guard, Epic, 427 ft, 132 kt, 1.9 km, +100: the
  catch row). The card photo is `source/ph/c27j_card.jpg`, crop 300x250+432+1516
  of the original, so the plane is big enough to see. Redone 2026-11-11 after
  Noah found the first header hard to read (the plane was a speck in a crowd
  photo). A few strangers in the crowd are recognisable at full size, as on the
  1.2.2 slide 1.

They replace the 1.2.2 airshow-trio header and the phone-plus-E-6 search image,
which used the old split-flap cards. The header keeps everything inside the 16:9
centre crop App Store Connect shows on iPhone (about 2926 of 3840 px); check the
Preview tool there after upload.

Render at half size with a device scale factor of 2:

```bash
src="$PWD/marketing/releases/v1.2.5/source"; out=$(mktemp -d)
for k in header:1920,823 search:1920,1280 universal:2622,1475; do
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
    --hide-scrollbars --force-device-scale-factor=2 --window-size=${k#*:} \
    --virtual-time-budget=3000 --user-data-dir="$out/profile" \
    --screenshot="$out/${k%%:*}.png" "file://$src/creative.html#${k%%:*}"
done
echo "$out"   # then flatten: magick in.png -alpha off PNG24:out.png
```

## Re-render

```bash
src="$PWD/marketing/releases/v1.2.5/source"; out=$(mktemp -d)
for n in 1 2 3 4 5 6 7; do
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
    --hide-scrollbars --force-device-scale-factor=1 --window-size=1206,2622 \
    --virtual-time-budget=3000 --user-data-dir="$out/profile" \
    --screenshot="$out/$n.png" "file://$src/deck.html#$n"
done
echo "$out"
```

Run it from the repo root. The PNGs land in a temp folder, not in `source/`, and
the separate profile keeps your own Chrome out of it. The committed screenshots were
checked against this output pixel for pixel (`magick compare -metric AE`).

The type uses the Mac's system fonts (SF Pro, SF Mono), so render on a Mac.
