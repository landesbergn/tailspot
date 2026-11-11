# v1.2.5

**Status:** approved by Noah 2026-11-11, ready to upload. All seven slides rendered 2026-11-10 at 1206 × 2622; slides 3–7 redrawn as illustrations the same day, then slides 3, 4, 6 and 7 revised on 2026-11-11. Not uploaded.

## Upload

- Screenshots: App Store Connect → 1.2.5 → iPhone screenshots → drag `screenshots/` in order.
- **Size:** App Store Connect rejected 1284 × 2778 for this slot on 2026-11-10 and
  listed 1206 × 2622, 1179 × 2556 (and landscape) as the accepted sizes. This set is
  1206 × 2622. Earlier sets in this folder are 1284 × 2778.
- Screenshots lock when 1.2.5 is submitted.

## Contents

- `screenshots/01-what-plane.png` … `07-challenges.png`, in upload order
- `source/deck.html`: the renderer for all seven slides
- `source/e6.png`, `source/l39.png`: photo crops for slides 1–2
- `source/ph/`: `a321_guess.jpg`, slide 3's photo (the area inside the bracket baked into
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
