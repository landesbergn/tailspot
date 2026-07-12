# Screenshot plan — 6.7" set (GA)

Drafted 2026-07-11 (PLAN §9 #8). Six portrait shots that tell the strategy's
story in order: **the catch is real → the reveal pays off → it's a game → the
collection grows → the hard stuff is a trophy → it's social.**

## Sizes first (this changes the capture strategy)

App Store Connect wants **1290 × 2796** for the 6.7" slot (Apple scales it down
for smaller devices; one 6.7"/6.9"-class set can cover all iPhone slots).
Noah's iPhone 16 captures at **1179 × 2556 (6.1")** — native device screenshots
do NOT fit the 6.7" slot directly. Two workable paths:

- **Framed composites (recommended):** capture on the iPhone 16, place each
  shot inside a device frame / caption layout on a 1290 × 2796 canvas. Apple
  explicitly allows framed + captioned marketing screenshots as long as they
  show real app UI. This also solves "AR shots only exist on the real phone."
  A one-off HTML/Canvas compositing script in `tools/` can batch this.
- **Native-resolution sim captures:** iPhone Pro Max simulator at 1290 × 2796
  for the data screens only (Hangar/trophies/leaderboard) — full-bleed, no
  frame. Cannot produce the AR/camera shots (simulator has no camera, GPS, or
  compass), so the set would mix full-bleed and framed styles. Avoid; pick one
  style, and only the framed style can include the money shot.

So: **all six shots captured on the real iPhone during one field session +
seeded data, then framed to 1290 × 2796.**

## The six shots

| # | Shot | Screen | What it must show | State needed | Capture notes |
|---|---|---|---|---|---|
| 1 | **The catch moment** (money shot) | AR view (`ContentView`) | Blue sky, visible aircraft, lock-on reticle snapped to it, label with callsign/type readable | A close plane (< ~10 km, approach traffic best) with rich ADS-B data — an airliner descending into OAK/SFO over Berkeley is ideal | **Real device only.** Field session, clear day, shoot into the sky *away* from the sun. Take many; pick the one where the plane is visibly a plane. |
| 2 | **The reveal, mid-flap** | `CatchRevealView` | Split-flap make/model mid-animation, photo hero, ALT·SPD·ROUTE, score counting up | Immediately follows shot 1's catch — same field session | Timing is sub-second: **record the screen** (Control Center screen record) through the catch → reveal, then extract the best frame with `ffmpeg`/Photos scrubbing. A FIRST OF TYPE ledger line is a bonus if the session produces one. |
| 3 | **The guess round** | Bonus-round chips (game-layer PR3) | The 4-chip "Call the type" / "Where's it headed?" question over a real catch | **Gated: PR3's UI is not on `main` yet** (only `GuessOptions`/`GuessScheduler` logic landed). | Capture once PR3 lands — same screen-recording technique as #2. If GA ships before PR3, substitute: the catch detail card (`SettledCatchCard`, handsome and static) or the Sets grid twice-angled. Plan for 6, ship 5 if needed. |
| 4 | **The Hangar — sets** | `HangarSetsView` | The sets grid with real progress — several sets partially filled, one near completion | **Rich Hangar** — Noah's own device (~85 catches with photos) is the best data that exists; a fresh install shows an empty grid | Static screen: screenshot directly on Noah's phone. No seeding needed — his real collection IS the marketing asset. |
| 5 | **Trophy case** | `HangarTrophiesView` | Earned trophies incl. at least one rare/hard one (the taste memo: hard trophies are the brag) | Same rich Hangar | Static; Noah's device. If the case looks thin, this is also the natural moment to check which trophies the collection *should* have unlocked. |
| 6 | **Leaderboard** | Leaderboard (`PublicScreens`) | Standings with handles, Noah's row highlighted with rank + points | Live prod board (real testers' handles) | Static; any device. **Check handles for anything unfit for a store listing before shipping the shot** — they're user-chosen. If any are borderline, capture on a staging dataset instead. |

Caption strip per frame (short, dry, matching the app voice), e.g.:
1 "Point at the sky. It knows the plane." · 2 "Every catch is real." ·
3 "Call the type before the reveal." · 4 "Fill the Hangar." ·
5 "The hard ones are trophies." · 6 "Claim a handle. Climb the board."

## Session logistics

- **One field session covers 1–3:** clear sky, OAK/SFO approach path
  (Berkeley home base), screen-recording running for every catch attempt;
  stills for #1, frame-extraction for #2 (and #3 when PR3 lands).
- **Five minutes at a desk covers 4–6** on Noah's phone as-is.
- Do the capture session **after** the current polish rounds land on the
  device (`bin/deploy` from `main`) so the shots show GA UI, not tester UI —
  and re-check after any UI-visible merge between capture and submission.
- Status bar: real-device shots will show Noah's carrier/time — the framing
  pass should either crop to the app's safe area inside the device frame or
  accept it (Apple no longer requires a clean 9:41 bar, but it looks better).
- Keep the raw captures in `docs/ga/screenshots-raw/` (gitignored if large) so
  the framed set can be regenerated when the UI changes.

## Not doing (deliberate)

- **App preview video** — allowed 15–30 s, would show the catch loop
  beautifully, but it's its own production task; revisit post-GA with the
  same field-session footage.
- iPad screenshots — the app is `TARGETED_DEVICE_FAMILY = 1`, iPhone-only.
- Localized screenshot sets — worldwide region, English-only listing at GA.
