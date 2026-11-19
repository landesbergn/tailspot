# v1.2.6

**Status:** slide 5 redrawn 2026-11-19 and picked by Noah the same day (option B of two). **Uploaded to App Store Connect 2026-11-19** (by Claude, through the API, at Noah's request): slide 5 replaced in both screenshot sets of version 1.2.6, in position 5, both processed. Version 1.2.6 is not submitted.

## What changed from v1.2.5

Only slide 5. The 1.2.6 Trophies rebuild ([PR #425](https://github.com/landesbergn/tailspot/pull/425)) replaced the hex medals and gold/platinum tiers with one ring badge and levels, so the old slide showed a look the app no longer has.

| Slide | Headline | Content |
|---|---|---|
| 5 | Earn trophies for unique catches. | The Trophies tab: an "On approach" chase card (Heavies Level 2, 48 / 50), then three level rows (Logbook, Airlines, Night) |

Slides 1–4, 6 and 7 are re-rendered from the same source and match the v1.2.5 files pixel for pixel at both sizes (`magick compare -metric AE` = 0). See `../v1.2.5/README.md` for what they show and why.

About slide 5:

- It is an **illustration drawn in HTML**, like slides 3–7 of v1.2.5, not an app screenshot. It is laid out like `HangarTrophiesView` (section captions, a chase card, level rows with a progress bar and a mono caption).
- The badge follows `TrophyBadge.swift`: a disc, a ring and one glyph. An endless track (Heavies, Logbook, Night) draws one arc toward its next level; a capped track (Airlines) draws one segment per level.
- The glyphs are hand-drawn monoline stand-ins for the SF Symbols the app uses (`airplane`, `book.closed`, `ticket`, `moon.stars`), so they are close to the app's icons, not identical.
- Track names, level counts and thresholds are real (`TrophyTracks.swift`, `Trophies.swift`): Heavies level 2 at 50, Logbook level 5 at 500, Airlines level 2 at 30 of 4 levels, Night level 2 at 25. The chase copy is the track's own ("2 more wide-bodies to go"). Progress numbers are illustrative.
- The headline is unchanged.
- Option A, not used: the unlock moment (a Legendary crown in a cyan ring with rays) over a grid of six trophies. Noah picked B.

## Contents

- `screenshots/01-what-plane.png` … `07-challenges.png`, in upload order (1206 × 2622, the 6.3" slot `APP_IPHONE_61`)
- `screenshots-6.9in/`: the same slides at 1320 × 2868 (the 6.9" slot `APP_IPHONE_67`), rendered with `--force-device-scale-factor=1.094527363`, then resized to exactly 1320 × 2868 and flattened (`magick in.png -resize '1320x2868!' -alpha off PNG24:out.png`)
- `source/deck.html`: the renderer for all seven slides
- `source/e6.png`, `source/l39.png`, `source/ph/`: the photos and app icon the deck uses

The header and search-results images are unchanged; they stay in `../v1.2.5/creative/` with their renderer.

## Upload

Done 2026-11-19 for en-US: in each set (`APP_IPHONE_67` from `screenshots-6.9in/`, `APP_IPHONE_61` from `screenshots/`) the new slide 5 was uploaded first, then the old one deleted and the set's order patched back to 1–7. The other six were left as they were, since they are the same files. The method and the accepted sizes are in `../v1.2.5/README.md`. Screenshots lock when 1.2.6 is submitted.

## Re-render

```bash
src="$PWD/marketing/releases/v1.2.6/source"; out=$(mktemp -d)
for n in 1 2 3 4 5 6 7; do
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
    --hide-scrollbars --force-device-scale-factor=1 --window-size=1206,2622 \
    --virtual-time-budget=3000 --user-data-dir="$out/profile" \
    --screenshot="$out/$n.png" "file://$src/deck.html#$n"
done
echo "$out"   # then flatten: magick in.png -alpha off PNG24:out.png
```

Run it from the repo root, on a Mac (the type is SF Pro and SF Mono).
