# App Store creative assets (header, search results)

Product page **header** and **search results** images (iOS 27 / iPadOS 27
creative assets). Specs from App Store Connect, 2026-10-12:

| Asset | Ratio | Size | File |
|---|---|---|---|
| Product page header | 21:9 | 3840 × 1646 | `out/header_21x9_3840x1646.png` |
| Search results | 3:2 | 3840 × 2560 (min 1920 × 1280) | `out/search_3x2_3840x2560.png` |
| Universal (either slot) | 16:9 | 5244 × 2950, PNG | `out/universal_16x9_5244x2950.png` |

No alpha (the script flattens to RGB). Creative assets are set in App Store
Connect separately from a version's screenshots.

## Rebuild

```bash
bin/marketing-stage-photos
TEST_RUNNER_MARKETING_CAPTURE=1 xcodebuild test \
  -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,id=<sim>' -parallel-testing-enabled NO \
  "-only-testing:TailspotTests/MarketingSnapshotTests/renderFleetWeekHUD()" \
  "-only-testing:TailspotTests/MarketingSnapshotTests/renderFleetWeekCardParts()"
python3 marketing/app-store-creative/compose.py   # needs Pillow; uses SF Pro Display if installed, else the system SF
```

(Swift Testing filters need the trailing `()`; without it xcodebuild runs 0
tests and still reports success.)

Every card and the HUD screen are the app's own views; `compose.py` only
lays them out on the deck's dusk gradient and sets the headline in SF Pro
Display. Header: the airshow trio (T-33, Patriots L-39, T-6). Search and
universal: the HUD (C-27J over the Golden Gate) beside the Legendary E-6.
Headlines only, no subline (too small to read at these scales).

**The header is cropped on iPhone.** App Store Connect's preview shows a
16:9 centre crop of the 21:9 image (about 2926 of 3840 px), with the back
and share buttons over the top corners. `header()` sizes the headline and
cards as one group that fits inside that crop with a margin; check the
Preview tool in App Store Connect after any layout change.
