# Changelog

Historical per-session "Current state" entries. As of 2026-06-22, CLAUDE.md no
longer carries a live "Current state" block — the authoritative current status
lives in **PLAN.md §9**, and each completed round lands here, newest first.
Git history + PLAN.md §9 remain the authoritative record.

## 2026-07-20 — Authenticity-gate moderation for GA: warm bar 0.07→0.10, occluded texture bar split — branch `tune/gate-moderation`

Noah's pre-GA report: the "go outside" state and the "did you really see
it?" question both fire too aggressively. 30 days of enforcing telemetry
agreed, and located both problems in two specific dials:

- **Indoor gate (`SkyCheck.warmThreshold` 0.07 → 0.10).** The ambient
  `pointedIndoors` state ("Not many planes indoors." + total ambient-label
  suppression) blocks on warm light at 0.07 — but 30 of 36 field `notSky`
  blocks sat at warmth **0.04–0.096**, the outdoor evening/golden band,
  while the clearly-indoor cluster reads **0.11–0.19** (corpus warm
  ceilings ~0.13+). The threshold sat directly on top of outdoor warm
  light. Raised to 0.10 (same bump in `LocalSkyGate.warmThreshold`, in
  lockstep as before).
- **Occluded gate (`LocalSkyGate`: new `texOccluder = 0.10`, split from
  `texSmooth = 0.014`).** The "did you really see it?" question fired on
  ~15% of catches and, where answered, was overridden with Keep **22 of 31
  times (~70% false)**. Joining every flag to its recorded patch features:
  the false flags cluster at texture 0.02–0.09, cool, with sky in frame —
  **cloud/haze under the bracket**, which the single smooth-sky bar
  (calibrated on clear sky) read as a building. True occluders (NYC cheat
  frames, warm-lit facades) read ~0.10+ texture or 0.13+ warmth. The cool
  branch now blocks only at `texOccluder`+; between the bars is
  `uncertain` (allow, silently). `texSmooth` still owns the confident-sky
  verdict and the sky-fraction tile test, unchanged.

**Validation.** The original labeled corpus images are no longer on disk;
the field telemetry replaced them (and is better for this change — both
edits only *shrink* the block set, so the only question is whether frames
that should still block stay above the new bars; they do). Re-scored on the
30 days: occluded flags drop **39 → 8** (17 of the 22 Keep-answered false
flags removed, every high-texture/warm true block kept). Nothing that
previously passed changes behavior. `tools/authenticity-gate/
score_local_gate.py` + CALIBRATION.md updated to match. North-star note:
this *improves* catch-confirmation signal — a 70%-wrong question trains
Keep-mashing.

**Deliberate costs** (both owned by backlogged successors): mildly-warm
interiors (0.07–0.10) now slip the indoor gate like cool-lit ones always
have — the learned indoor/outdoor classifier is the real fix; cool
mild-texture occluders (gray building, overcast) slip the occluded gate —
queued for the L4 detector gate (in shadow) to own.

## 2026-07-20 — Empty-sky-tap honesty: far-toast subject rescue + literal toast + starved-poll retry — branch `fix/far-toast-diagnosis`

Field report (Noah, 2026-07-19, driving the Dumbarton bridge watching SFO
arrivals): repeated **"Nearest plane is 30–90 km out — beyond eyeshot"**
toasts while an arrival was plainly in sight — and close in the debug list.

**Root cause.** The empty-sky-tap diagnosis picked its subject by angular
offset alone, blind to tier. In a moving car the compass error rotates the
sky model tens of degrees (car-body magnetism; sustained acceleration also
tilts the gravity estimate feeding camera elevation), so the close visible
plane projects far from the tap — sometimes behind the camera, where the
diagnosis assigns a synthetic 180° offset that loses to anything in front.
Near SFO the 50 km data bbox always holds a far, low, hidden-tier plane
within the 40° tap cone; that stranger won the angular contest, classified
`filtered-far`, and the toast printed *its* distance as "nearest" — false
both by sight and by the distance-sorted debug list.

**Fix, two layers (both free functions, `EmptySkyTapSubjectTests`):**

- **`chooseEmptySkyTapSubject` — the rescue.** If the angular-nearest plane
  classifies `filtered-far`, the subject switches to the angular-nearest
  *actionable* plane in the cone — airborne AND (visible-tier OR plausibly
  revealable) — which then classifies and routes normally (`filtered` /
  `off-frame` reveal, `on-screen` ripple). The `empty_sky_tap` analytics
  event gains a `rescued: true` flag on that path. Deliberately NOT
  rescued: a `grounded` primary (the parked-plane toast + Ground Stop
  easter egg must win) and the NYC couch case (nothing revealable in the
  cone → `filtered-far` stands, PR #142's protection intact).
- **`farTapToastSlantMeters` — the honesty guard.** The toast now only
  shows when NO airborne in-data plane anywhere is within plausible reveal
  reach, and it reports the **distance**-nearest slant (what "nearest"
  means to a reader), never the angular winner's. A gross heading error
  can defeat the rescue (the visible plane computes behind the camera,
  outside the cone) — but it can't defeat this guard, because the lie
  requires a close plane in data, which the guard sees regardless of
  angles. When the guard vetoes, the tap falls back to the plain
  NO AIRCRAFT HERE ripple.

**Adjacent fix (`ADSBManager`): starved-poll fast retry.** Both Noah's and
another Bay Area tester's driving sessions show taps seconds after
foregrounding hitting a completely EMPTY `observed` — after a background
trip every cached row is stale (dropped by `maxPositionAge` on annotate),
and a *failed* first fetch used to sleep out the full 10 s poll interval
before retrying (flaky bridge cellular made that window long). The poll
loop now retries in 2 s while failing AND data-starved; a healthy poll
keeps the 10 s cadence (`/v1/aircraft` has no rate limit).

**Confirmed against the field recording (same day).** The drive's own
analytics never reached PostHog (the phone's entire session is absent —
likely connectivity loss), but the on-device replay
(`replay-2026-07-19T221714Z`, Oakland, 3.85× zoom) captured six taps at a
visible plane: **all six recorded `filtered-far`** — SKW3789 (hidden,
~28 km, only 7–11° off the tap) and N20230 (10 km GA, beyond its
small-airframe reveal reach) — while the data simultaneously held
close/visible planes (SWA3087 at 5.6 km *visible tier*, N562AC/N52275 at
~1.5 km) that the sky model placed **74–153° away** from the tap: a
~75°+ real heading error under an OS-reported ±10° accuracy. Under the
fix, the rescue reveals N553TP (7 km, ~30° off, revealable) and the guard
vetoes every toast. The recording is bundled as the local-tier fixture
`local-fartoast-2026-07-19.jsonl` with a pinned regression
(`FarToastRegressionTests`): the old selection must keep reproducing
`filtered-far` on all six taps, and the fixed pipeline must never toast
while an actionable plane is in data (skips on CI, like
`FailureModeRegressionTests`).

## 2026-07-19 — Wrong-route fix: multi-leg leg picking + stale-filing corridor gate + on-device repair — branch `fix/route-leg-picking`

Field reports (Noah, SFO arrival path): UAL1375 carded "ONT → ORD" while
FR24 showed ONT → SFO; SWA1067 carded "MAF → DAL" while actually flying
BWI → SFO. Two distinct root causes in the adsb.lol route enrichment, one
shared symptom (a confidently wrong journey on the card):

- **Multi-leg filings were collapsed to first → last.** UAL1375 is filed
  `KONT-KSFO-KORD`; the parser's "multi-leg collapses to first → last" rule
  produced ONT → ORD — a pair nobody flies. Fix (backend
  `adsblolRoutes.ts`): a filing with 3+ codes now parses into one leg per
  consecutive pair (generalizing the 2026-07-11 A-B-A round-trip pick), and
  `enrich` picks the leg the plane is ON — corridor plausibility (near the
  leg's great-circle segment, tolerance `max(250 km, 15% of leg)` mid-leg /
  250 km past an endpoint) then track alignment (points at the leg's
  destination within 55°, beating the runner-up by 40°). One plausible leg +
  no track is accepted; ambiguity stays null (never fabricate a journey).
- **Stale filings served verbatim.** adsb.lol's route DB is keyed by
  callsign and can hold another day's routing (Southwest reuses flight
  numbers): SWA1067 was on file as `KMAF-KDAL`. Fix: the SAME corridor
  check now gates plain two-code routes per-plane — a plane 1,900 km off
  the filed corridor gets no route rather than a wrong one.
- **`GET /v1/routes/:callsign` gained optional `lat`/`lng`/`track`** so the
  position-less paths get the same picks: catch-time resolve passes the
  plane's live position + track; the Hangar backfill passes the catch's
  observer position (within slant range of the plane). Malformed params
  degrade to a position-less resolve (never a 400). Without a position a
  multi-leg filing resolves to null — the first→last collapse is dead
  everywhere. Backfill also went per-row (was per-callsign groups): two
  catches sharing a callsign can be different flights on different legs;
  deduped by callsign + ~11 km position bucket.
- **On-device repair for already-wrong rows** (`CatchBackfill.
  clearImplausibleRoutes`, runs in every `backfillAll` pass): a stored
  route whose corridor the OBSERVER was nowhere near (checked offline
  against bundled `airports.json` coords, server tolerance + slant-distance
  slack so a server-approved route can never flap) is cleared back into the
  fill-nil pool, where the position-aware lookup re-fills it correctly or
  honestly leaves it routeless. Frozen-moment carve-out #3, documented in
  the file header: these values were bad enrichment, not observations.
  Noah's two bad rows: SWA1067 clears and stays routeless (BWI → SFO was
  never on file); UAL1375 clears and stays routeless too (near SFO both
  legs are plausible and old rows recorded no plane track — honest null
  beats a guess).

Tests: backend 49 route tests green (new: UAL1375/SWA1067 fixture suites,
endpoint param passthrough/degradation); iOS full suite green (new: repair
+ corridor-geometry cases). One mid-run SwiftData `SIGTRAP` (notification
timer, no Tailspot frames) reproduced identical pre-existing crashes from
07-13/07-14 — sim flake, passed clean on re-run.

## 2026-07-13 — Catch-target plausibility (+ lone-plane catchable): stop bagging the wrong plane in dense sky — branch `fix/catch-target-plausibility`

Field mis-catch (Noah, NYC): a 12.9 km cruise A319 at ~70° elevation (nearly
overhead) was caught instead of the closer, lower plane he aimed at. Root
cause: catch-target selection ranked candidates by SCREEN-PIXEL distance to the
crosshair alone — zero preference for the closer / lower / larger / more-obvious
plane — so whichever labelable ADS-B plane projected nearest the reticle won,
which under a poor compass (his sessions log ±12–20°) is often not the plane the
eye is on. Three changes, an offline spike over all 44 replay sessions guiding
the design (`tools/target-selection/target_spike.py`):

- **Prominence-weighted single selection** (`LockOnEngine.catchCandidates` +
  `dominantAimTarget`): when several planes sit in the catch zone and ONE is far
  more visually prominent (crosshair-proximity × apparent size, proximity scaled
  by the logged compass σ), catch just it instead of multi-bagging the cluster.
  A comparable formation/approach pair still multi-catches. σ ties the weighting
  to compass quality, so a trusted compass reduces it to the old
  nearest-crosshair behavior — the corpus changed only ~1% of target-bearing
  ticks, always toward the closer/bigger plane.
- **Uncertain-aim flag** (`CatchSuspicion.uncertainAim` + `aimConfidence`): a
  CENTER (non-tapped) catch that's off-crosshair AND too small to resolve AND
  made under a poor compass is flagged — flag, never block (2026-07-04 doctrine)
  → one Keep/Discard question after the reveal, `catch_uncertain_aim` telemetry
  to tune the floor. An explicit tap is exempt (deliberate choice). Honest
  limit, pinned as a test: a resolvable-but-wrong jet near the compass-rotated
  center still reads high-confidence — selection + metadata own that case, not
  the flag.
- **Catch capture metadata** (`CatchCaptureDiagnostics` → additive
  `Catch.captureDiagnosticsJSON`): pose (heading/elevation/roll/zoom), compass
  accuracy, the caught plane's crosshair offset + size, tap-vs-center, and the
  OTHER in-zone candidates the selector passed over — so the next mis-catch is
  diagnosable from the row itself (this one needed reconstruction because replay
  recording wasn't running). Pure debugging; never gates or scores.

`TargetSelectionTests` pins the A319 geometry (bad compass → closer/bigger
plane; good compass → unchanged; the limitations as tests).

**Folded in from `fix/lone-plane-catchable` (#145, Portland field report) on
merge:** the same capture-mode block also needed a **lone-plane whole-frame
fallback** — when the tight central catch zone is empty but exactly ONE plane
is visible anywhere on frame, it stays catchable (`.single`), so a lone
off-centre / fast-moving plane that was never tapped isn't a dead shutter.
Two+ on frame still require aim or a tap (the dense-airspace spray exploit
stays closed). #145 closed as absorbed. Both edge cases now live in one
resolver; full suite green.

## 2026-07-13 — The compass warning made LOUD: broken-compass misID diagnosed at SFO — branch `fix/loud-compass-warning`

Field report (Noah, watching arrivals at SFO): **UAL195, a Boeing 777-222(ER)
on final (reg N225UA, MUC→SFO), was identified as a Cessna 172.** Pulled the
on-device replay (`replay-2026-07-13T214656Z`, 2:46 PM PDT, Noah at the SFO
terminals) and it's unambiguous — **the compass was 35–40° off true north** for
the whole session (`headingAccuracyDeg` 35–40; the reported heading snapped
**90°→339°** in one tick at 21:47:12 as it finally recalibrated, without Noah
rotating the phone — direct proof the earlier north was ~100°+ wrong). Standing
amid the terminal's steel/jet-bridges = severe magnetic interference. With north
that far out every projection is garbage: both tap-pins in the window landed on
distant *filtered* planes (a King Air at **46 km**, N824AK at **31 km**), never
the 777 — which was `onGround` the whole window (grounded → `.hidden`), so it was
never what got labeled. The "Cessna 172" happened a minute earlier on final,
same broken compass, same failure — a real distant GA plane in the 130-aircraft
feed garbage-projecting under the 777's apparent position.

**Ruled out** (so we fixed the right thing): the source data is correct
(adsb.lol reports N225UA as `t:B772`/heavy), there is **no C172 fallback** (a
typeless plane resolves to nil, never a Cessna), and this is **not** the
lone-plane capture rule. Root cause is purely the compass; no selection logic
can help when north itself is wrong.

**The gap:** the app already detects this (`compassBadThreshold = 25°`, debounced
4 s → `showCompassWarning`) but the warning was a **deliberately-quiet, advisory
corner capsule** — invisible when you're locked onto a landing 777, and it gated
nothing. The telemetry comment in the code already called it "the suspected
silent killer of 'label points the wrong way' first sessions." Caught red-handed.

**The fix (Noah's call — warn loudly, keep the shutter live; IDs/catches are NOT
gated):** `ContentView.cautionBadge` is now a **loud filled-amber banner** — a
pulsing warning glyph, the live `COMPASS OFF ±N°` readout, and a plain
`Labels may be wrong — tap to calibrate` line (dark-on-amber, amber glow so it
lifts off the live camera, slides in from the top). A **one-shot warning haptic**
fires the moment the compass latches bad (declarative `.sensoryFeedback` on the
top-center stack; recovery is silent) — a felt cue since you may be watching the
plane, not the HUD. Tap still opens `CompassCalibrationSheet`. New
`CompassWarningSnapshotTests` (visual pass, day-sky + dark backdrops); full suite
green. Distinct from `fix/lone-plane-catchable` — separate branch, separate
cause.

## 2026-07-12 — Tap-reveal plausibility bound: dense airspace stops being a catch-anything button — branch `fix/tap-reveal-plausibility`

Field report (Noah, on a couch in Manhattan, replay-2026-07-12T150351Z): with
**110 airborne planes** in the NYC data (EWR/LGA/JFK + GA), the ambient band
correctly hid ALL of them — but **tap-to-reveal has no distance bound**, so
all 11 empty taps revealed and force-locked planes 27–72 km out at 0.4–9.6°
elevation, through a wall, and a Piper Cherokee was caught at **75.8 km**
(the post-catch gates did their job: flagged suspect, Noah discarded). The
reveal was built for the Berkeley cases where the tapped plane is genuinely
visible (FDX1268, DAL972); in dense airspace "nearest in-data plane" is
always *something*, so explicit intent alone stopped meaning "I can see it".

- **`ObservedAircraft.isPlausiblyRevealable`** bounds the FILTERED reveal:
  reveal reach = the faint band (elevation curve × `faintBandFactor`, capped
  at 35 km) relaxed by **`revealBandFactor = 1.5`**, and strictly-below-
  horizon planes are never revealable (behind terrain by definition; the
  0–1° skyline gray zone stays revealable — ambient floor still 1°). No
  hysteresis term: reveal is a one-shot decision.
- The empty-tap classifier splits hidden-tier into **"filtered"** (within
  reach → reveals, unchanged) and **"filtered-far"** (beyond reach → an
  honest beyond-eyeshot toast with the distance, no reveal, no lock). The
  new reason flows through replay recordings + `empty_sky_tap` telemetry;
  `FailureMode`'s missedPlane scorer keys on "filtered", so implausible
  couch taps stop inflating the miss bench.
- **The confirmed-visible marginal cases the reveal exists for still pass**
  (pinned by `TapRevealPlausibilityTests`): FDX1268 10.9 km @ 3.6° (reach
  ~15.8 km), SKW5480 18 km @ 12.1°, N21866 5.8 km @ 5° small-airframe. The
  couch session's 11 reveals + the 75.8 km Cherokee are all refused, as is
  the below-horizon N383TA (6.4 km @ −0.45°). OFF-FRAME reveal is untouched
  (it already requires visible tier).
- **Indoors = no ambient labels** (second half of the report, Noah's call:
  "if the frame reads as not sky — don't show labels"). The band was also
  passing planes that ARE outdoor-visible from that location (river-corridor
  GA at 2–3 km, LGA finals at 8 km; 9 passed at a live check) — the
  geometric filter can't know about walls. `interactiveVisible(_:)` is now
  the one definition of the label set (render loop + metadata prefetch +
  signature, previously three copies): the ambient tier is suppressed while
  `pointedIndoors` (the existing 5 s-debounced SkyCheck streak behind the
  "Not many planes indoors." hint), the tap-revealed plane survives, and
  zone catchability/lock/taps consume the same gated set. The
  `first_plane_seen` activation latch skips while indoors.

## 2026-07-12 — Pre-v1 cleanup round: dead code, stale docs, repo organization — branches `chore/v1-backend-cleanup` · `chore/v1-ios-cleanup` · `chore/v1-docs-cleanup`

A three-PR housekeeping sweep ahead of the v1 launch, driven by a full-repo
dead-code/staleness audit. No behavior changes.

1. **Backend** (`chore/v1-backend-cleanup`): deleted the unreachable OpenSky
   provider (`POSITION_PROVIDER=opensky` — prod never sets it and nothing
   provisions its OAuth secrets since the 2026-06-21 cutover) + its test and
   fixture; dropped 10 unused drizzle type exports; `isRarity` un-exported;
   `@electric-sql/pglite` → devDependencies (the prod image was shipping a
   WASM Postgres); esbuild override + vite refresh — **backend `npm audit`
   now 0 vulnerabilities** (was 3 open Dependabot alerts); README provider
   docs match the real default (adsb.lol + airplanes.live composite).
2. **iOS** (`chore/v1-ios-cleanup`): the audit's headline is that the app
   target is clean — no orphaned files (ReferenceScreens/PublicScreens/
   LogCapture are live; FailureMode/ReplayRedaction are test-bench
   infrastructure). Removed the empty "Live/mock toggle" test MARK; extracted
   the triplicated `ReplayEvent` timestamp switch into one computed property
   (`ReplayAnalyzer`/`ReplayRedaction`/`FailureMode` now share it); fixed
   stale comments (Geo's "mock ADS-B source" attribution, two light-mode
   rationales outdated by the dark lock). 957 tests green.
3. **Docs/repo** (`chore/v1-docs-cleanup`): new `docs/archive/` holds the
   historical material (superpowers tree, shipped dated plans, review
   HTML artifacts, brainstorms, backend-handoff) with living-doc references
   updated; README rewritten to current reality (was "Friday POC, backend
   planned"); PLAN §8 backend row + §9 merged-status drift fixed (rows #4/#7/
   #12 "in review" → merged #124/#125/#131/#132/#135; pending-table dupes and
   the obsolete OpenSky-secret row retired); CLAUDE.md's `bin/log-tail`
   "no-op stub" claim corrected (it streams the device syslog via
   `idevicesyslog`; app-side `os_log` is the remaining gap) and its "visual
   confirmation dormant" line updated (it ships enabled; L2 enforcing, L4 in
   shadow); CONTRIBUTING's "Current state"/OpenSky-secret references fixed;
   spent one-off generators (`generate-icon-options.swift`,
   `generate-hangar-options.swift`) deleted; onnx eval-tool pin bumped to
   1.22.0 (clears the last 2 Dependabot alerts).

Also outside the tree: pruned 15 merged-PR worktrees + 20 merged local/remote
branches (each tip verified against its merged PR head first). Kept:
`fix/skywatcher-bugs` (unmerged 2026-06-28 content, likely superseded by
#100 — Noah's call) and `spike/card-art-mediums` (kept for the record).

## 2026-07-11 — GA-gate housekeeping drafts (PLAN §9 #8) — branch `docs/ga-housekeeping`

Research + drafting round, docs only (no app code). Four deliverables in
`docs/ga/`, every factual claim verified in source:

1. **`privacy-policy.md` + `terms.md`** — GA revisions of the already-hosted
   `tailspot.app/privacy.html` / `terms.html` (effective 2026-06-11), which
   turned out to be **stale in four material ways**: the PostHog SDK is now
   embedded with session replay (the hosted policy claims "no analytics SDKs
   embedded"); location is used continuously while open (bounding-box
   `/v1/aircraft` polls every ~10 s), not "only at the moment of a catch";
   Hangar restore (PR #125) makes catch records server-recoverable (photos
   stay unrecoverable); Apple geocoding + Planespotters image loads are
   undisclosed processors. Biggest code finding: **nothing in the app is
   `.postHogMask()`ed today** — the camera-preview mask was removed during the
   all-black-replay diagnosis (`ContentView` "EXPERIMENT" comment) and never
   re-added; the `PostHogSessionReplay.swift` header claiming the camera is
   masked is stale. Flagged as a pre-GA open item (re-add scoped mask or
   verify replays render the camera black), along with `maskAllImages=false`
   meaning displayed catch photos appear in replay screenshots.
2. **`licensing-review.md`** — Planespotters photo API terms (recovered via
   Wayback, 2026-06-18 snapshot; the live page Cloudflare-403s): compliant on
   6 of 7 requirements (no >24 h caching, original URLs, identifying UA,
   photographer credit, free feature) — the one gap is that the terms want the
   *thumbnail* linked back, and only the caption is tappable. **Verdict: keep,
   with the small tap-target fix.** adsb.lol (ODbL 1.0): fully compliant —
   Settings credit + the attributions page's ODbL statement. ICAO DOC 8643
   re-check stays open (~30 min, Noah).
3. **`appstore-listing.md`** — name/subtitle ("Tailspot: Catch Real Planes" /
   "Catch the planes overhead"), description in the app voice with an honest
   worldwide-coverage caveat, 98-char keywords, Games→Casual + Education, 4+,
   and an honest nutrition-label table (location IS collected — observer
   lat/lon uploads with catches; everything device-id-keyed marked Linked=Yes,
   which the committed `PrivacyInfo.xcprivacy` currently contradicts — small
   follow-up PR recommended). Region decided: **worldwide**. Full App Store
   Connect click-through checklist for Noah, incl. review notes explaining the
   app can't demo indoors.
4. **`screenshot-plan.md`** — six 6.7" shots (AR catch → mid-flap reveal →
   guess round → Sets grid → trophy case → leaderboard); capture all on the
   real iPhone (sim has no camera/GPS), frame 1179×2556 → 1290×2796
   composites; reveal/guess frames pulled from screen recordings; the
   guess-round shot is gated on game-layer PR3 landing; Hangar shots use
   Noah's real ~85-catch collection.

PLAN §9 #8 updated (drafts done; remaining = hosting, the mask decision, two
small code PRs, and Noah's App Store Connect steps); §6.6 region question
closed as worldwide.
## 2026-07-11 — Dynamic leaderboards PR3 — winner trophies — branch `feat/leaderboard-trophies`

The payoff half of dynamic leaderboards (PLAN §9 #12): winning a board now
mints trophies. Three additions to the roster, all **server-truth** — the
backend alone decides wins (UTC Monday crowning, shared crowns count each
sharer, no winner floor; L3–L5 of the locked design) and the app never infers
a win locally.

1. **The trophies.** **Top Flight** (visible) — win a weekly leaderboard
   (`weeklyWins >= 1`), laurel-wreathed-star hex. **Dynasty** (SECRET, masked
   `???` until earned, the Hot Streak treatment) — win 3 weekly boards,
   stacked-crowns hex; deliberately NOT prereq-chained behind Top Flight
   (`TrophyBoard` ignores prerequisites for secrets — always listed masked —
   so the chain would be a silent no-op; the 3-win threshold subsumes it).
   **Chart Topper** (visible) — ever hold #1 on the all-time board
   (`everToppedAllTime`), summit-flag hex. Icons follow the existing
   custom-`Shape` stroke style in `TrophyView.swift`; Top Flight composes a
   stroked wreath around a FILLED star (the CenturionIcon pattern — a stroked
   star collapses into a dot at badge size, caught in the snapshot pass).
2. **Server facts → trophy inputs.** `TrophyProgressInputs` gained
   `weeklyWins: Int` / `everToppedAllTime: Bool` as defaulted params (the
   zero-churn pattern). They're fed by the new `LeaderboardStandingCache` — a
   `TrophyEventStore`-shaped nonisolated UserDefaults wrapper owning the
   existing `tailspot.standing.weeklyWins` key (the Profile laurel's
   @AppStorage reads the same key, so laurel and trophies can never disagree)
   plus a new `everToppedAllTime` key. Writes happen ONLY in the screens'
   fetch completions (ProfileScreen `loadStanding`, LeaderboardScreen `load`)
   via `update(from: me)` — every leaderboard response that carries the
   additive fields updates the cache; the client/network layer stays
   side-effect free. `weeklyWins` mirrors the server as-is; the monotonic
   `everToppedAllTime` only latches true. Offline degradation falls out of
   the storage: cached values persist, fresh installs read 0/false → all
   three locked.
3. **Recap, not a toast storm.** `Trophies.rosterVersion` 2 → 3, so an
   existing device whose server facts already carry wins (e.g. Noah's
   historical crown backfill) reseeds silently and gets ONE trophy-case recap
   absorbing all pre-earned winner trophies. Live crossings still fire
   normally afterwards — and since the facts only ever change inside the
   Profile sheet (standing + leaderboard fetches live there), ContentView now
   re-diffs on Profile-sheet close (the existing Hangar-close pattern), so a
   Monday-crowning crossing celebrates as soon as the sheet dismisses.
4. **Tests + visual pass.** `TrophiesWinnerTests` (earn boundaries 0/1/3 wins
   + topper flag, inputs defaulting, hangar-alone-never-earns, cache
   mirror/latch semantics, Dynasty secrecy/board masking),
   `TrophyUnlockCenterTests` additions (version-bump reseed absorbs
   server-earned trophies into the recap without a flood; live crossings fire
   once each), and `renderWinnerTrophyStates` snapshots (locked/masked, first
   crown, all earned) reviewed as PNGs. Full suite green (967 tests); review
   doc `docs/reviews/2026-07-11-winner-trophies.html`.
## 2026-07-11 — Backend DB resilience: 1GB Postgres + transient-connection retry on every idempotent read — branch `db-retry-backoff`

Prod hotfix after a `tailspot-db` OOM (Sentry BROKEN-DARKNESS-5055-7 and its
query-split siblings -8…-D). The single `shared-cpu-1x:256MB` Postgres instance
was OOM-killed (`oom_killed=true`, 17:13 UTC); while it thrashed and restarted,
the API took `CONNECT_TIMEOUT tailspot-db.flycast:5432` bursts across every DB
route (leaderboard *and* metadata). Two-part fix:

1. **DB memory 256MB → 1GB** (`fly machine update … --vm-memory 1024`, applied
   live 2026-07-11). 256MB is Fly's floor for postgres-flex and OOMs under real
   load (300 `max_connections` on 256MB is a dangerous mismatch). This is the
   root-cause fix — nothing at the app layer can paper over a multi-second DB
   restart.
2. **`withDbRetry` now backs off, and wraps every idempotent store read.** The
   original `-3` retry fired all 3 attempts in <1 ms — zero time for a fresh
   connection to open, so an ECONNRESET/CONNECT_TIMEOUT still surfaced (Sentry
   -5/-7). It now waits a jittered exponential backoff (~50/100 ms) between
   attempts. And the leaderboard / catches / devices idempotent reads + `ON
   CONFLICT DO NOTHING` writes are wrapped like the metadata route already was —
   previously *only* metadata had retry, so the others 500'd on a single blip.
   The two non-idempotent writes (`createDevice`'s plain INSERT, `claimHandle`'s
   UPDATE) are deliberately left unwrapped — a retried lost-ack could
   double-apply. Backend-only; no iOS or wire-contract change. 325 tests green
   (added a backoff-schedule test + a `DrizzleCatchStore` retry regression).

## 2026-07-11 — Launch readiness — v1.0.0 — branch `feat/launch-readiness`

Closes every code-level gap from the GA audit (PLAN §9 #8; audit docs land
separately as PR #128). Noah approved launching to the App Store.

1. **Session-replay privacy (the launch-blocking item).** User catch photos
   now carry a scoped `.postHogMask()` at every render site — `RevealPhoto`
   (reveal + `SettledCatchCard` hero, incl. the Hangar detail),
   `CatchCardView`'s photo (`.postHogMask(url.isFileURL)` — card reveal,
   multi-catch, model-slot detail), and `FocusThumbnail` (Hangar rows) — so
   only the photo rect is redacted and the card/UI chrome still replays.
   Planespotters stock photos stay visible (public imagery, not user
   content). The **live camera view is excluded STRUCTURALLY, not by mask**:
   replay's screenshot capture (`drawHierarchy`) cannot read
   `AVCaptureVideoPreviewLayer`'s out-of-process surface, so camera frames
   never reach PostHog — and a `.postHogMask()` on the full-window
   `CameraPreview` is exactly the 2026-06 all-black-replay bug (PostHog
   redacts by drawing masked-view RECTS over the flat screenshot; a
   full-window rect blacks every frame, sheets included). That guarantee is
   now pinned by **`SessionReplayPrivacyTests`** (PreviewView must stay
   backed by `AVCaptureVideoPreviewLayer`); the stale "camera is masked"
   header comment in `PostHogSessionReplay.swift` and the EXPERIMENT
   comment in `ContentView` were rewritten to describe the real posture.
   `maskAllImages` stays false (masking is selective by design).
2. **Planespotters attribution fix** (licensing review): the photo
   THUMBNAIL itself now links to the photo's Planespotters page — new
   optional `SettledCatchCard.onPhotoTap`, passed by `CatchDetailView` only
   when the hero is Planespotters imagery; the tappable caption stays.
   UA bumped to `Tailspot/1.0 (+https://tailspot.app)`.
3. **PrivacyInfo.xcprivacy truthed up:** all declared data types flip to
   **Linked = true** (everything is keyed to the server device-id —
   pseudonymous is still "linked" in Apple's sense); the Photos/Videos
   declaration is REMOVED (photos never leave the device and replay now
   masks them — not "collected" per Apple's definition). Manifest header
   rewritten for the single-SDK-pipeline reality. Nutrition label is a
   manual App Store Connect step (Noah).
4. **Export compliance:** `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption =
   NO` in both Tailspot target configs (standard HTTPS only → exempt);
   verified in the built product's Info.plist.
5. **MARKETING_VERSION 0.5.0 → 1.0.0** (the App Store launch is the "major
   change worth flagging"); `CURRENT_PROJECT_VERSION` stays 1 (CI bumps).
6. **Real privacy policy + terms published to source** (`web/public/
   privacy.html`, `terms.html`) from the GA-audit drafts — kills the false
   "no analytics SDKs embedded" / "location only at the moment of a catch"
   claims; replay section reflects this round's masking (camera excluded,
   catch photos masked); effective date 2026-07-11, what-changed note up
   top per the policy's own §10. **Deploy is a separate Fly app**
   (`tailspot-www`, nginx static): `cd web && flyctl deploy --remote-only`
   — NOT deployed in this round; Noah's call.

Full `TailspotTests` green (958 pass, incl. all snapshot suites — the mask
modifier is inert under ImageRenderer, zero pixel drift) + device build
verified. App Store Connect steps that remain manual: nutrition label sync,
the TestFlight/App Store build itself.

## 2026-07-11 — Dynamic leaderboards PR2 — iOS board tabs + champion UI — branch `feat/leaderboard-tabs`

The iOS half of the dynamic-leaderboards feature (PLAN §9 #12), built against
the pinned backend-PR1 contract (`GET /v1/leaderboard?window=week|month|all`
adding `window`/`resetsAt`/`champions` + `me.weeklyWins`/`everToppedAllTime`)
with fixtures — the backend lands in parallel. Winner trophies (Top
Flight/Dynasty/Chart Topper) are deliberately NOT here — that's PR3, after
both sides land.

1. **Board tabs.** `LeaderboardScreen` grew a WEEK (default) / MONTH /
   ALL TIME segmented switcher — the `HangarSegmentedSwitcher` pattern
   (Liquid Glass capsule track, matched-geometry pill, 40 pt full-segment
   hits) restyled to the mono readout voice, sitting at the top of the List
   content (the screen keeps its stock-but-branded system nav — utility
   screen, per the Brand chrome rule). Per-window responses are cached in
   `@State` for the screen's appearance: flipping back to a tab shows its
   last board instantly while `.task(id: selectedWindow)` re-fetches and
   swaps data in silently (the ProfileScreen cached-standing pattern; no
   spinner churn), and a failed silent refresh keeps the stale board.
2. **FAIL-SOFT against the old backend.** The pre-windows backend never
   sends the `window` key → `LeaderboardResponse.supportsWindows` is false,
   the tabs hide entirely, and the screen renders today's all-time board
   unchanged (the old backend ignores the `window` query param). All new
   DTO fields are optional decodes, pinned by old-payload regression tests
   (the PR #65 pattern).
3. **Reset countdown.** "RESETS MONDAY · 2D 14H LEFT" (week) / "RESETS
   AUG 1" (month), mono caption under the switcher, computed by the pure
   `LeaderboardCountdown` helpers in the DEVICE's locale + timezone (a
   Monday-00:00-UTC reset honestly reads SUNDAY in California; never
   "UTC"). Recomputed per render — no live ticking timer. Unit tests cover
   day/hour floors, under-1H, past-due clamp, timezone weekday shift, and
   month/year wrap.
4. **Champion banner** (week tab only): gold-accented row above the podium —
   laurel glyphs, "LAST WEEK'S CHAMPION" eyebrow, "@handle · 840 PTS".
   Shared crowns render side by side ("@a & @b"), 3+ collapse to
   "@a, @b +1 more", a null handle displays as "anonymous spotter", and an
   empty champions array (the board reset with nobody on it) shows the
   quiet "NO CHAMPION CROWNED — The sky was quiet last week." line. Copy
   rules live in the pure `ChampionBanner` helper (`LeaderboardWindows.swift`).
5. **Your standing, per window.** The standing section header names the race
   ("YOUR STANDING · THIS WEEK" — the week tab's whole point is "you're #2
   THIS WEEK"); the handle-less local-points hint only renders where it's
   honest (all-time / old backend — local points are a lifetime number).
   Fresh empty windows say "No catches this week yet / The sky's wide open."
6. **Profile laurel (L6).** `ProfileScreen` shows a quiet gold
   "WEEKLY CHAMPION ×3" laurel row under the identity header once
   `me.weeklyWins ≥ 1` (no "×1" suffix for a single crown). Cached in
   `@AppStorage("tailspot.standing.weeklyWins")` so it renders offline;
   deliberately a flat non-glass row (a new glass surface would have to
   join the GlassEffectContainer — the hit-testing lesson — and a trophy
   accent doesn't need to refract). `loadStanding()` now requests
   `window: .all` explicitly so the headline stays lifetime points/rank.
7. **Client.** `TailspotAccountClient.leaderboard(window:limit:)` appends
   the `window` param (nil = no param); new wire types `LeaderboardWindow` /
   `LeaderboardChampion`; `MyStanding`/`LeaderboardResponse` extended with
   the optional fields + `resetsAtDate` (fractional + plain ISO-8601).
8. **Tests + visual pass.** `LeaderboardWindowTests` (decoding new/old/null
   payloads, fail-soft, countdown math, champion copy 1/2/3+/anon/none) +
   `LeaderboardWindowSnapshotTests` (window-hosted drawHierarchy renders of
   all three tabs, four banner variants, fail-soft board, Profile laurel
   ×1/×3 → `/private/tmp/tailspot_snaps/`, reviewed). Full suite green
   (955 tests); device build green.
## 2026-07-11 — Dynamic leaderboards PR1: backend windows + weekly champions — branch `feat/leaderboard-windows`

The backend half of dynamic leaderboards (PLAN §9 #12): `GET /v1/leaderboard`
grows a `window=week|month|all` param (absent/invalid → `all`, so old clients
are untouched — the new top-level fields are additive-only), and closed weeks
get frozen champions. Noah's locked design calls (L1–L6): **calendar** windows
(not rolling), **UTC** boundaries (Mon 00:00 / 1st 00:00 — no DST), **no winner
floor** (a 1-catch week still crowns), **shared crowns** on points ties (every
tied device gets a `weekly_champions` row and a win), **all three trophies**
(weekly-win count + ever-topped-all-time + last week's champions), **banner +
laurel** presentation (iOS PR2/PR3).

- **Response additions:** in-window `entries`/`me.rank`/`me.points`;
  `me.weeklyWins` + `me.everToppedAllTime` (lifetime, on every window);
  `resetsAt` (next boundary, null on all); `champions` (last CLOSED week's
  winner(s), week window only — empty array for a zero-catch week, null handle
  for an anonymous champion).
- **Decide-on-read, lazy + idempotent** (`CatchStore.ensureWeeksDecided`): the
  first week-window request after a Monday boundary crowns the previous week —
  one atomic `INSERT…SELECT` per week with `ON CONFLICT DO NOTHING` (concurrent
  double-decides are no-ops), backfilling every never-decided week since the
  earliest catch (zero-catch weeks skipped). Fast path when the last closed
  week is already decided = one point-read.
- **All-time topper ledger** (`alltime_toppers`): every code path that computes
  all-time #1 (`window=all` requests + week-decide) upserts the current #1;
  first sighting wins, the flag never unsets. Anonymous devices can top/win —
  they occupy real ranks.
- **Migration `0007_leaderboard-windows.sql`** (`weekly_champions` composite-PK
  week_start+device_id; `alltime_toppers`) — **generated, NOT applied to prod:
  manual `drizzle-kit migrate` (or psql apply + journal insert) required before
  the next backend deploy** (the standing backend-migration-drift trap).
- New pure UTC window math in `src/identity/windows.ts` (Monday re-basing,
  month lengths, year wraps — unit-tested). Windowing lives in the leaderboard
  aggregates' JOIN condition so the "≥1 catch" entry ticket becomes "≥1
  in-window catch" and `me` keeps a rank (0 pts) rather than vanishing.
- Tests: 311 green (13 new route tests in `test/leaderboardWindows.route.test.ts`,
  window-math units in `test/windows.test.ts`; existing leaderboard suite
  updated for the additive `me` fields). Biome + tsc clean.

iOS PR2 (window picker + champions banner) is being built against this exact
contract in parallel; PR3 (trophies) consumes `weeklyWins`/`everToppedAllTime`.

## 2026-07-10 — Polish sweep PR B — the taste calls — branch `polish/taste-calls`

Noah's seven verdicts on the UI-survey taste questions. Four built, three
recorded as deliberate keeps/rules:

1. **D1 — App locked to dark.** `preferredColorScheme(.dark)` on the root
   `RootView` in `TailspotApp.swift` — sets the window's style, so onboarding,
   the main app, sheets/fullScreenCovers, alerts/confirmationDialogs, and the
   share sheet all render dark regardless of the device setting. PR A's
   light-mode compensations (branded List chrome etc.) stay as
   belt-and-suspenders.
2. **D2 — Radius token scale.** New `Brand.Radius` (chip 6 / row 12 / card 16 /
   hero 26). **69 cornerRadius literals snapped** (44 value changes — 7→6, 8→12,
   10→12, 11→12, 14→16, 18→16, 20→16 — and 25 same-value re-routes). Judgment
   exceptions left literal: `CatchCardView`'s per-size dims table (12/14/16 —
   radius proportional to card size), the reveal ledger's `11 * scale`, tiny
   3–4 pt accents (rarity bars, `BadgeViews`, AR label chips, reveal flap — 6
   turns them into pills), and the AR HUD brackets. Capsules stayed capsules.
3. **D3 — One type rule.** `Brand.Font.display` (26 pt bold system) is now the
   single prose-head size; converted the nine freelancing heads (onboarding ×4
   incl. the 30 pt welcome, Hangar empty "Go outside." 28, rarity reference 26,
   compass sheet 24, `ModelDetailScreen` empty head 17, `PermissionRecoveryCard`
   title 18). Rule codified in `Brand.swift`: mono = readouts/data/labels,
   system = human prose, heads use `.display`. Mono readouts and the reveal
   card's established type untouched.
4. **D6 — Dry voice.** Indoor hint "Maybe try looking outside 😉" → **"Not many
   planes indoors."** (emoji-free, same clinical register as the grounded
   toast). Unclaimed handle is now an honest designed state: the Profile header
   shows a cyan mono **CLAIM YOUR HANDLE →** affordance (NavigationLink into
   Settings' SPOTTER section) + a quiet person-glyph avatar instead of
   "@spotter_42" with fake "SP" initials; Settings no longer prefills
   "spotter_42" as the field's value for unclaimed users (empty draft → the
   "handle" prompt shows). The leaderboard was already honest ("(you)" + claim
   hint); the share card carries no handle. TextField placeholders keep
   "spotter_42" as a format example — that usage is fine.
5. **D4 — Profile Liquid Glass STAYS** (Noah's explicit keep; the glass +
   radial-glow backdrop is the intended look).
6. **D5 — Duplicate-catch haptic STAYS** as is.
7. **D7 — Nav-chrome rule codified, no code:** custom chrome for game surfaces
   (Hangar/cards/reveals), stock-but-branded system nav for utility screens
   (Settings/Map/Leaderboard) — recorded in `Brand.swift`'s header + CLAUDE.md.

Snapshot harness grew unclaimed-Profile/Settings + empty-state renders
(`ProfileSettingsSnapshotTests`). Full `TailspotTests` green; before/after
visual pass over the snapshot corpus reviewed by eye (radii/type-size shifts
only; no layout breaks).

## 2026-07-10 — Hangar restore-from-server (PLAN §9 #7, issue #58) — branch `feat/hangar-restore`

The local-only Hangar's catastrophic-loss gap gets its restore path: catches
already upload to the backend for scoring, the Keychain device id (#55)
survives reinstall, so a fresh install can now pull the collection back.
**Catch-data only — photos were never uploaded and cannot come back**; the
prompt says so plainly. No schema change anywhere (no drizzle migration, no
SwiftData field).

- **Backend `GET /v1/catches`** (auth required — the bearer token both
  authenticates and scopes; there's no deviceId param to probe): the device's
  own catches, oldest-first, `limit`/`offset` paged (≤500/page; the biggest
  real device is <100), with `total` always the full count. Rows carry what
  the server actually stores — catchUuid, icao24, callsign, frozen scoring
  facts (typecode/rarity/points/firstOfType), the guess triple, caughtAt,
  observer lat/lon, aircraft altitude — plus two cheap LEFT joins:
  `registration` from `registry`, clean `manufacturer`/`model` from
  `typecodes`. New `CatchStore.listCatches`; 8 new route tests
  (`test/catchesList.route.test.ts`): 401s, own-rows-only isolation,
  pagination/ordering, null-heavy rows, param clamping, guess passthrough.
- **iOS restore flow** (`HangarRestore.swift` + `HangarRestorePromptView.swift`):
  once per launch, ContentView asks `HangarRestoreManager.checkIfNeeded` —
  local Hangar empty → wait (bounded, no self-register: racing a second
  `POST /v1/devices` is the #55/#76 duplicate-identity bug class) for the
  launch registration → probe `fetchCatches(limit: 1)` → server total > 0
  ⇒ a full-screen branded offer in the `TrophyUnlockView` chrome family:
  "WELCOME BACK / N CATCHES FOUND", the photo caveat, RESTORE / NOT NOW
  (declining stays quiet until next launch). Restore pages everything, maps
  rows → `Catch` (`HangarRestore.makeCatch`), saves, and shows "N CATCHES
  RESTORED"; failure gets a TRY AGAIN screen (re-runs are safe).
- **Idempotency:** keyed on the upload idempotency uuid — `Catch.serverUuid`
  == the server's `catchUuid` — compared case-folded (local UUIDs are
  uppercase, Postgres returns lowercase), deduped against the store AND
  within the batch, so re-running restore never duplicates.
- **No re-upload, no re-toast, one event:** restored rows are born
  `uploadedAt != nil` (the uploader's pending predicate can't see them; no
  per-catch telemetry). After the bulk insert the trophy ledger is
  **re-seeded** (`TrophyUnlockCenter.reseedAfterRestore` — the first-launch
  silent-seed pattern) *before* ContentView's diff task can observe the new
  rows, so trophies land in the trophy case without a celebration flood.
  Analytics is exactly one `hangar_restored` event (`count`, `server_total`).
- **Unknown-distance display:** the server never stored slant distance, so
  restored rows carry the 0 sentinel — new `CardPlane.distText(fromMeters:)`
  renders it as "—" instead of "0.0 km" (trophy math already treated 0 as
  never-far). Restored placeName/country/route/operator heal via the existing
  `CatchBackfill` passes on the next Hangar open, like any old row.
- Tests: 10 new Swift tests (`HangarRestoreTests` — wire decode incl. nulls,
  full + nil-field mapping, guessCorrect-nil rule, case-folded + intra-batch
  idempotency, re-run inserts nothing, not-pending-upload, reseed queues no
  celebrations) + `HangarRestoreSnapshotTests` (visual pass: offer N=1/62/500,
  restoring, done, failed). Full `TailspotTests` green (910 test cases);
  backend 290 green; Release device build clean. Visual pass fixed two
  things: the system `ProgressView` (renders as a placeholder under
  ImageRenderer, off-brand anyway) → a drawn cyan `RestoreSweep` arc, and a
  mono-font apostrophe artifact ("COULDN' T") → "RESTORE FAILED".
## 2026-07-10 — Polish sweep PR A — the mechanical ten — branch `polish/mechanical-sweep`

Ten objective UX/UI fixes from the full-app UI survey (taste-level changes are
a separate Noah-gated PR B):

1. **Stale copy ×3** (`PublicScreens.swift`): "Settings → Identity" — a section
   that no longer exists — rewritten to the real path, "Profile → Settings"
   (the handle claim lives in Settings' SPOTTER section, reached from the
   Profile hub).
2. **Leaderboard List branded**: was the only List without
   `.scrollContentBackground(.hidden)` + Brand background (system grouped
   chrome flipped white in light mode, washing the handles out). Also gave the
   error/empty/standing rows `Brand.Color.bgElevated` row backgrounds — same
   fix Settings got on 2026-07-08.
3. **AccentColor asset filled in**: the colorset was empty, so system-tinted
   controls (alert buttons, share sheet) rendered iOS blue; now brand cyan
   `0x00D4FF` (any + dark).
4. **`Color.primary` leak** (`SettingsScreen.swift`): legal-link labels were
   system-primary on the fixed-dark row — invisible in light mode — now
   `Brand.Color.textPrimary`.
5. **Accessibility labels** on `CatchDetailView`'s icon-only chrome pills:
   "Back" / "Delete catch" / "Share catch".
6. **44 pt hit targets**: the 36 pt chrome pills (`CatchDetailView`) and the
   Hangar child-bar back chevron keep their visual size; the tappable region
   grows via `contentShape(Rectangle().inset(by: -4))`.
7. **Dead code deleted**: `ComingSoonPill.swift` (ComingSoonPill +
   ComingSoonBanner, zero call sites).
8. **Re-typed hexes routed through Brand** (pure indirection, zero pixel
   drift — reveal snapshots byte-checked): new tokens `Brand.Color.ledgerGold`
   (0xFBBF24, was `RP.gold`'s literal) and `Brand.Color.duplicateRose`
   (0xE0556B, the reveal's ALREADY CAUGHT stamp); `Rarity.rare` now returns
   `Brand.Color.cyan` instead of a duplicate 0x00D4FF literal.
9. **Leaderboard section headers** restyled from the default system look to
   the app-wide mono ALL-CAPS style ("YOUR STANDING", SettingsScreen pattern).
10. **Reduce Motion coverage** (TrophyUnlockView template): the reveal's
    split-flap tumble becomes a straight fade to the identical settled frame
    (`FlapRow.reduceMotion`), bonus-round chips lose the scale pop,
    `MultiCatchReveal` keeps its cadence (haptic/chime ladder) but lands cards
    as plain fades, `Figure8Animation` renders a static path + steady dot, and
    the empty-sky `EmptyPulse` dot holds steady.

Also new for the visual pass: a DEBUG `LeaderboardScreen(_debugEntries:me:)`
seam + `renderLeaderboard` snapshot, and a reduce-motion settled-reveal case in
`RevealSnapshotTests`.

## 2026-07-10 — Trophy roster expansion + one-time trophy-case recap (game-layer PR4+PR6) — branch `feat/trophy-roster`

One PR delivering the plan's PR4 (roster) and PR6 (recap) together, since the
recap is the designed absorber for the roster change (plan §C4 / risk 6).

**Roster: +5 trophies** (`Trophies.swift`, per D6 sign-off — low-end kept):

- **Four Figures** (visible, 1,000 lifetime points) and **High Roller** (5,000,
  prereq-chained behind Four Figures). Progress reads a new
  `TrophyProgressInputs.totalPoints` — the OFFLINE approximation (Σ
  `resolvedRarity.basePoints`, same math as `ProfileStats`), which excludes
  server bonuses so it can only undercount: a points trophy earned offline is
  always honestly earned.
- **Called It** (visible, first correct route call) and **Clairvoyant** (10,
  chained). Guessing is route-only (PR3), so these read the frozen local
  verdicts (`Catch.guessCorrect == true`) with no kind filter.
- **Hot Streak** (secret): three correct calls IN A ROW — consecutive over
  *answered* rounds in `caughtAt` order. Plain catches and SKIPs (all guess
  fields nil) neither count nor break a streak; only a wrong answer resets.
  New inputs `correctGuesses` / `bestGuessStreak` follow the defaulted-param
  pattern (zero call-site churn). Three new hex icons: `coin` (poker chip),
  `crystal` (crystal ball), `bolt`.

**One-time trophy-case recap** (`TrophyRecapView`, new): a full-screen
celebratory sheet — RP reveal palette, gold accents, a count-up of the earned
total, and a staggered grid of the earned hexes (secrets included — earning
reveals them), one `TO THE SKIES` CTA. Reduce Motion renders the settled frame.
Mechanism: the ledger now carries a **`rosterVersion` stamp**
(`Trophies.rosterVersion = 2`); on the first `enqueueNewUnlocks` where the
stored stamp is behind, `TrophyUnlockCenter` **reseeds instead of diffing**
(silently acknowledging newly-added trophies the user already qualifies for —
no unlock-toast flood) and queues the recap with the full earned set. Zero
earned → stamp only, no recap (a fresh install never sees it). This replaces
the old one-shot `recapShown` boolean + small recap card from the 2026-06-20
redesign: a boolean can fire once ever; a version stamp fires once per roster
expansion. Simulated ✦ catches stay inert — they're never inserted, and
trophies/recap derive only from the `@Query` Hangar.

Tests: new `TrophyRosterExpansionTests` (threshold boundaries at 999/1,000 and
4,500/5,000, guess-count edges at 9/10, streak reset/ordering/gap semantics,
roster-version pin), `TrophyUnlockCenterTests` version-bump suite
(reseed-no-flood, stamp-silently-when-zero-earned, crossings-still-fire-after),
and `TrophyRecapSnapshotTests` (recap at 1/24/long-name states + the Hangar
trophy card list in mixed and fresh/masked states). Full suite green (919
cases). Snapshot lesson: >2,000 pt offscreen windows don't draw at all under
`drawHierarchy` — the card list snapshots render the extracted `TrophyCardRow`
column via ImageRenderer instead.

## 2026-07-10 — Guess round, redesigned IN-CARD on the reveal (game-layer PR3) — branch `feat/guess-round-ui`

Noah's 2026-07-10 direction reshaped the bonus round: **supersedes the separate
pre-reveal "own screen, guess blind" design** (the 2026-07-09 `GuessRoundView`
cover, itself descended from the 2026-06-29 economy mock). The round now plays
**on the reveal card itself** — "more like the catch card: reveal the airline +
make/model, then pop up an extra guessing opportunity for bonus points, and the
answer resolves as correct/incorrect on the card." One fluid surface, no cover
handoff. Four beats, all on `CatchRevealView`:

1. **Normal reveal first.** The card runs its existing settle exactly as today
   (split-flap make/model, tier line, ALT/SPD, count-up ledger) — never delayed.
   The ROUTE slot renders **masked** from the moment it fades in (a gold
   `BONUS ROUND · +10%` eyebrow + the cyan-mono `Where's it headed?` /
   `Where's it coming from?` prompt keyed off `RouteQuestion.endpoint`), so the
   real route is never spoiled before the guess.
2. **The round pops.** ~0.2 s after the reveal settles, the four airport chips
   spring in below the route section (staggered `easeOutBack` scale+fade;
   reduced-motion → a plain fade) with a quiet SKIP. The photo hero shrinks while
   the chips are up so the whole round + ledger clears the safe area, restoring to
   full height on collapse. The ledger shows base (+ FIRST OF TYPE) and the TOTAL
   settles to the **pre-bonus** value.
3. **Resolve in place.** Tapping a chip locks the set: correct → the chip flashes
   green + `.sensoryFeedback(.success)`; wrong → the chosen chip flashes red, the
   right chip highlights green, `.sensoryFeedback(.error)`. Simultaneously the
   masked panel **crossfades to the real route** (codes + city names, the normal
   layout). On a correct call a gold **`10% ROUTE BONUS +N`** row animates into
   the ledger and the TOTAL **counts up** to the new total (a second clock, `bt`,
   reusing the reveal's count-up mechanism). No penalty for wrong — no rub-it-in
   line; the route just settles.
4. **Settle.** After a beat the chips collapse; the standard settled card remains
   with the full route (+ bonus line if earned). SKIP / dismiss-mid-chips is a
   wrong-minus-flash: chips collapse, route reveals, no line, freeze nothing.

- **Threaded into the reveal, not a cover.** `CatchRevealView` gained
  `guess: GuessRoundQuestion?` + `onGuessShown` / `onGuessResolved(answeredValue:correct:)`.
  The whole `pendingGuess` / `pendingGuessReveal` / `GuessRevealPayload` cover
  machinery is **deleted**; `PendingReveal` carries the question + the fresh
  `Catch` row to freeze onto (+ an `isSimulated` flag). When the scheduler fires
  in `runCatch`, the reveal is presented **immediately with** the payload — no
  deferred present, no two-cover race. ContentView's `onGuessResolved` freezes the
  outcome onto the row (`guessKind`/`guessValue`/`guessCorrect` + `save()`) and
  fires `guess_round_shown` (chips-pop) / `_answered` / `_skipped` (kind always
  `route`); the ✦ Catch simulator keeps its `isSimulated` mute (no telemetry, no
  persistence). Eligibility/cadence unchanged — `GuessRoundPlanner` +
  `GuessScheduler` still decide; the standalone `GuessRoundView` is gone (its chip
  styling/logic moved into `CatchRevealView`; `GuessRoundQuestion` +
  `GuessRoundPlanner` live on in the renamed `GuessRound.swift`). Multi-catch,
  duplicate, and suspect-review sequencing are untouched (guess resolves before
  dismiss; the B-52's nil-dest catch never offers a round).
- **Card stays a pure function of its clocks** (`t`, count-up `bt`, chip
  stagger `gt`) + an immutable `GuessRender`, so any beat renders as a static
  frame. Tests: `GuessRoundSnapshotTests` rewritten to the three beats
  (chips-popped · correct-settled · wrong-settled → `/private/tmp/tailspot_snaps`,
  visual-pass reviewed); `GuessRoundPlannerTests` + `GuessSchedulerTests` +
  telemetry-builder tests unchanged; full `TailspotTests` green.
## 2026-07-09 — Card-art medium DECIDED: keep the current hero — docs only

The §6.3 question (open since 2026-06-18) is closed. Noah compared the
candidate mediums **on his own phone against his real catches** via a
throwaway "Card Art Lab" spike (local branch `spike/card-art-mediums`,
never merge): the production `CatchCardView` with the hero slot swapped
across CURRENT / generative livery-silhouette / treated own-photo /
real 3D models (FR24 glTF, converted 1.0→2.0 and pre-rendered via
three.js; the license map on the record: FR24 = GPL-2.0 prototype-only,
Sketchfab CC-BY = the shippable 3D path if ever revisited). Verdict:
**none beat the current look — keep the own-photo/placeholder hero, no
commissioning pipeline, no art spend.** PLAN §9 #5 retired; §6.3 marked
resolved. Card excitement keeps improving through the chrome/reveal
polish track (#6) instead. Decision materials: the decision-pack and
catches-×-mediums comparison artifacts (2026-07-09 session).

## 2026-07-09 — Catch card: flight number, plane-centered photo crop + focus backfill — branch `feat/catch-card-centering`

Field feedback (Noah, 2026-07-08): the catch photo doesn't center on the
plane ("especially for planes less close to the center of the frame"), and
he wanted the **flight number** on the card. Also re-opened N415YX (RPA4343):
the plane IS visible — my earlier "sub-floor speck" call was wrong; a
targeted detector pass finds it at 15 px / 0.54 conf, so it re-heals.

- **Flight number on `SettledCatchCard`**: the callsign (already carried on
  `CardPlane`, never shown) now renders right-aligned on the tier line
  (`● COMMON · AIR CANADA        ACA708`), truncating a long carrier before
  itself. The detail card previously surfaced the tail number only, in the
  fine-print footer.
- **Photo now centers on the plane.** Root cause: 82/85 catches had no
  `photoFocus`, so `FocusFill` center-cropped the tall photo and the plane
  landed at the frame edge. Two fixes: (1) **`CatchPhotoFocusRecovery`**
  (new) recovers focus from the cyan bracket already baked into each saved
  JPEG (nearest-neighbor downsample + strict brand-cyan centroid, span-gated
  against multi-catch) — the bracket IS the focus, so this is
  correct-by-construction and follows the offline heal; wired as a
  version-gated one-time pass in `CatchBackfill.backfillPhotoFocus`, run off
  the Hangar `.task` (bytes + pixels off the MainActor). (2) **`FocusFill`
  zoom-to-center**: the short/wide hero slot pins outer-band planes to the
  edge even with correct focus, so the crop now zooms in just enough
  (capped 1.6×) to bring an edge plane toward center — center-band planes
  are untouched.
- **N415YX re-healed** onto its detected plane (554,860) and pushed to the
  device; the on-device focus backfill then centers it.
- Verified with before/after `ImageRenderer` snapshots over four real
  catch photos (`FocusCenteringSnapshotTests`); new `FocusFill` zoom +
  `CatchPhotoFocusRecovery` orientation/centroid unit tests. Full
  `TailspotTests` green.
- **Follow-up (branch `feat/thumbnail-focus`):** the Hangar **list
  thumbnail** (`TailCard`) had the same defect — a plain aspect-fill
  `AsyncImage` center-cropping the tall photo. New `FocusThumbnail` crops
  toward `photoFocus` via the shared `FocusFill` (so the 76 px thumbnail
  and the big card frame the plane identically), decoding at thumbnail
  size via ImageIO (`kCGImageSourceThumbnailMaxPixelSize` +
  `…WithTransform` for upright pixels) off the MainActor with an
  `NSCache` — a scrolling list can't decode full 12 MP stills per row.
  `FocusedImage` split out so the crop renders synchronously for the
  snapshot harness. New loader (downsample + orientation) tests.

## 2026-07-09 — Guess-round UI: the pre-reveal bonus round (game-layer PR3) — branch `feat/guess-round-ui`

> **SUPERSEDED 2026-07-10 (same PR/branch) — the round moved IN-CARD.** The
> separate pre-reveal `GuessRoundView` cover described below was replaced by the
> in-card bonus round on `CatchRevealView` (see the 2026-07-10 entry above) per
> Noah's direction — "more like the catch card." The `pendingGuess` cover
> machinery, `GuessRoundView`, and the "guess blind before the reveal" flow are
> gone. The `GuessScheduler` / `GuessOptions` / `GuessRoundPlanner` /
> `CardPlane` / telemetry / freeze-on-answer pieces below survive; only the
> presentation changed. The bullets below are retained for history.

Third PR of the game-layer plan (`docs/plans/2026-07-09-001`, §9 #4). The data
layer landed in PR1 (#115, backend) + PR2 (#118, iOS `GuessScheduler` /
`GuessOptions` / `Catch` guess fields); this PR is the **player-facing round**
and the ContentView sequencing that hosts it. No data-layer logic changed.

> **Update 2026-07-09 (later, same PR) — route-guessing ONLY, type guessing
> cut (Noah's call).** Before merge Noah decided the client should ask **only**
> the route question. Removed from the client: `GuessOptions.typeQuestion` /
> `typeAvailable` / `TypeQuestion`; the scheduler's route-vs-type 50/50 pick +
> `typeAvailable` param (it's now a pure route cadence gate — fires route or
> nil); `GuessRoundPlanner`'s `typeAvailable`/`typecode`; the `CALL THE TYPE`
> screen; and **`MilitaryDesignators.swift` + its tests** (that distractor
> guard existed solely to keep *type* distractors commercial — reverting the
> ac14239 fix is correct now that type guessing is gone). The ledger label is
> **`10% ROUTE BONUS`** (Noah's pick over the plan's "ROUTE CALLED"). `GuessKind`
> keeps both cases and `ScoringBonuses.typeGuess` stays — they're the backend
> wire + scoring contract (`scoring-bonuses.json`, pinned by parity tests); the
> client simply never sends `kind:"type"`. **Backend untouched** — no migration,
> no rescore; the server still accepts `type` harmlessly. `Catch.guessKind`
> stays generic (only ever `"route"` now). The bullets below describing the
> type path / `MilitaryDesignators` are retained for history but no longer
> reflect the shipped client.

- **`GuessRoundView` (new)** — the reveal surface with the answer MASKED. Reuses
  `RevealPhoto` + the `RP` palette so the guess and the reveal read as one
  screen: photo hero, a cyan-mono prompt ("Where's it coming from?" /
  "Where's it headed?" keyed off the asked endpoint · "CALL THE TYPE"), 4 chips
  (OnboardingFlow's bgElevated + cyan-hairline styling; route chips read
  `HKG · Hong Kong`), and a quiet SKIP. **UNTIMED** — pacing protection is the
  scheduler's cadence, not a stress timer (decision D5). A correct tap gets a
  `.sensoryFeedback(.success)` beat; a wrong tap a `.error` buzz + a red MISS
  FLASH that also marks which chip was right; either way it hands to the reveal
  after a brief beat (a miss lingers ~1.15 s so the right answer registers). A
  wrong guess shows **no** rub-it-in line in the reveal — the flash was the
  answer. Purely presentational (no analytics/SwiftData in the view), so it
  snapshot-tests off-device.
- **The interleave seam (`ContentView.runCatch`)** — right before the reveal,
  a fresh **single** catch (never a duplicate — no points to bonus; never a
  multi-catch — `MultiCatchReveal` owns its path; suspect-aware) runs the
  scheduler. The eligibility translation is a pure, unit-tested
  `GuessRoundPlanner` so ContentView stays thin, and the scheduler's cadence
  counters advance **only** on catches that could host a round. When it fires
  AND an honest question builds, the reveal defers behind a `pendingGuess`
  full-screen cover; otherwise the reveal path is byte-for-byte unchanged. The
  guess→reveal handoff fires from the guess cover's **`onDismiss`** (two
  `fullScreenCover`s can't present at once — presenting the reveal synchronously
  would drop it); `captureInFlight` stays latched across the whole
  catch→guess→reveal chain, and the post-reveal suspect Keep/Discard step still
  fires after, unchanged.
- **Freeze-on-answer** — the outcome writes to the row like `serverUuid` (after
  it's born): correct/skip → `guessKind`/`guessValue`/`guessCorrect` (SKIP
  leaves all three nil), `modelContext.save()`, then the deferred upload
  (`CatchUploader`, already shipped in PR2) carries the guess *value* — never a
  verdict — for the server to re-verify.
- **Reveal ledger** — a gold **`ROUTE CALLED +N` / `TYPE CALLED +N`** line
  after FIRST OF TYPE, shown **only on a correct call**, with N via
  `ScoringBonuses.guessBonus` (pinned to `scoring-bonuses.json` by the parity
  test) and folded into the count-up TOTAL. `CardPlane` gained
  `guessKind`/`guessBonusPoints`, computed off the row like `isFirstOfType`
  (re-tiers on read). **Label flagged for Noah:** the plan specifies parallel
  "ROUTE/TYPE CALLED"; the older economy mock said "10% ROUTE BONUS" — defaulted
  to the plan, one-line swap in `CatchRevealView` if Noah prefers the mock.
- **Telemetry** — `guess_round_shown` / `_answered` (kind, correct, elapsed_ms —
  the per-device accuracy stream that watches for 100 %-correct cheat outliers)
  / `_skipped`, house pattern (pure builders + `@MainActor` fire wrappers).
- **Tests (13 new, full `TailspotTests` green):** `GuessRoundSnapshotTests`
  (route-question · type-question · reveal-with-guess-bonus PNGs to
  `/private/tmp/tailspot_snaps`, visual-pass reviewed), `GuessRoundPlannerTests`
  (8 — fresh-single gate, duplicate/multi exclusion, suspect flag, route/type
  availability), and 4 telemetry builder tests.
- **Distractor-quality fix — military types excluded (follow-up in this PR).**
  The observation below bit for real: an A321neo type round drew **Boeing
  EA-18 Growler** + **Tupolev Tu-22** because ~55 genuine military combat jets
  (fighters/bombers/attack/EW) are miscoded `.narrow`/`.wide`/`.ga` in the
  bundled `AircraftTypes.json` — the 2026-06-09 round deliberately left the
  military tail mislabeled as "low ROI," and the guess mechanic surfaced it.
  **Fix path chosen: a runtime guard, NOT a JSON/generator reclassification.**
  The generator (`generate-aircraft-types.py`) fetches LIVE ICAO DOC 8643 data
  and has no offline source snapshot, so a regen would mix upstream drift (PR1's
  documented reason for not running it); and reclassifying these to `.mil`
  moves their rarity `common → epic` (the military default), which feeds
  scoring and would need a `scoring_version` bump + prod re-score — out of scope
  for a distractor fix. Instead, a new **`MilitaryDesignators`** — a curated,
  EXACT-MATCH designator set (regex/keyword matching floods with false
  positives: Diamond DA-20 "Falcon", the aerobatic Sukhoi Su-26/29/31, the
  Tupolev Tu-134/154/204/334 airliners) — feeds an `effectiveClass` in
  `GuessOptions.typeQuestion` that collapses every military type to `.mil` for
  BOTH the answer and each candidate. A commercial question now offers only
  commercial distractors, and a military question only military ones — **zero
  scoring impact** (the JSON/rarity is untouched). When a deterministic regen
  eventually lands (source saved offline + rescore), these become truly `.mil`
  and the set is redundant but harmless (`isMilitary` short-circuits on
  `.type == .mil`). +3 tests (the pinned A321neo/737-800-never-military bug
  guard across 200 seeds, the military-draws-military symmetry, and the
  designator-set unit test); re-rendered `guess_type_question.png` verified
  clean (737-800 / A320neo / E175-E2 / Martin 2-0-2).

**Acceptance bar is the on-device pacing** of catch → guess → reveal — needs
Noah's field pass before merge; **no auto-merge**.

## 2026-07-09 — Bracket-snap follow-ups: full-res stills, orientation fix, off-frame drop + collection heal — branch `fix/bracket-snap-followups`

Field trigger: Noah's RPA4343 / ACA708 / DAL405 catches (2026-07-08, Central
Park) all had the bracket well off the plane — diagnosed as *the snapper never
shipped* (TestFlight builds 79/80 predate PR #106; zero `catch_photo_snap`
events ever). Fixing that surfaced more:

- **Latent 90° orientation bug in `CatchPhotoSnapper`** (would have field-fired
  on first ship): raw AVFoundation stills are sensor-landscape + EXIF
  orientation 6, and the snapper searched the raw `cgImage` while the composer
  draws in UIImage-oriented space. All search math now runs on
  `uprightCGImage`; pinned by tests.
- **Full-sensor stills** (`AVCapturePhotoOutput.maxPhotoDimensions` → ~12 MP,
  `.speed` quality prioritization to keep shutter lag down): the root reason
  RPA4343-class photos can't heal is that a distant plane is ~10 px in a
  1080-wide photo, under the detector's ~15–20 px floor; at 12 MP it's ~28 px.
  `CatchPhotoSnapper` became **resolution-adaptive**: fine native-res ring
  (distance gates scaled by width/1080) then, for wide photos, a coarse
  1080-equivalent pass (the exact eval-calibrated policy) + one native refine
  crop. Saved photos cap at 3072 long side (`CatchPhotoComposer.savedPhotoSize`)
  so the Hangar doesn't eat 12 MP decodes; bracket-less saves normalize through
  `normalizedWithoutBracket`.
- **Off-frame targets save bracket-free** (`catch_photo_snap` outcome
  `offframe`): a re-projected prediction outside the frame with no detection
  used to bake a clipped, pointing-at-nothing bracket (the ACA708 photo).
- **Collection heal (offline, one-off):** all 80 on-device catch photos ran
  through a full-frame detector sweep (`scratchpad heal_collection.py`, mask
  out the baked glyph, nearest-within-700px, composer-style redraw after
  inpaint). 11 healed + pushed back to the device (incl. ACA708 + DAL405);
  2 candidate heals **vetoed by cross-checking the SwiftData row's recorded
  slant** — the detector wanted gate/taxiing planes for targets ADS-B put at
  38–62 km (the known airport wrong-plane mode). 40 fallbacks are the
  sub-floor-speck class the 12 MP capture fixes going forward. Originals:
  `~/Desktop/tailspot-catch-backup-2026-07-08/`; review doc sent to Noah.

## 2026-07-09 — Onboarding re-do phase 2: calibration step + denied-permission recovery — branch `feat/onboarding-calibration-redo`

The design half of PLAN §9 #3 (phase 1 below instrumented it). **Compass
calibration is now the flow's final step** (4 of 4; design ref
`design/screens/onboarding.jsx` Variation A): figure-8 coaching
(`Figure8Animation`, back in onboarding for the first time since the handle
step displaced it), a live HDG/± readout off the flow's own
`LocationManager` (heading updates already start on grant), and a latch at
≤10° that flips the quiet "Skip · I'll do it later" button into a bright
"Start spotting" — the skip is deliberately subtle so the coaching gets a
chance. The handle claim moved from flow-end to the handle step's own
"Claim handle" CTA (409 still holds the user there; Back-then-forward skips
the re-claim via the confirmedKey check); `onboarding_completed` now fires
from the final step with a `calibrated` boolean — the evidence for whether
the step earns its place (watch it against later `compass_caution_shown`).
**Both first-run dead ends got recovery UI** (`PermissionRecoveryCard`,
standalone for snapshotability): an explicit camera denial used to render a
silent black void, a location denial a forever-"waiting" GPS; each now gets
a card naming what's off, why it matters, and an Open Settings deep-link.
Visual pass via `OnboardingSnapshotTests` (all four steps + SE height + all
three denial variants; `OnboardingFlow._snapshotScreen` flattens the
ScrollView that ImageRenderer can't see into); review doc with every screen
at `docs/reviews/2026-07-09-onboarding-redo.html`.

## 2026-07-09 — Activation funnel instrumented end-to-end — branch `feat/activation-funnel-telemetry`

Phase 1 of the onboarding re-do (PLAN §9 #3): before redesigning the leaky
first-run (~36 openers → 5 catchers/30d), make the leak measurable — the
funnel was blind between the SDK's "Application Opened" autocapture and
`first_plane_catch`. New `ActivationTelemetry` (CatchTelemetry's shape: pure
tested builders + thin fire wrappers): `onboarding_step_viewed`
(welcome/permissions/handle, onAppear + step change), `permission_outcome`
(camera from the `requestAccess` callback; location from the throwaway
manager's published `authorizationStatus`, one-shot), `onboarding_completed`
(claim result: success / offline_fallback — a 409 keeps the user on the step
and is already covered by `handle_claimed`), once-per-install milestones
`ar_first_frame` (first camera frame ever — latched UserDefaults, fired from
the frame-bridge tap) and `first_plane_seen` (first post-filter visible
label, from an `onReceive` on the observed list at ~1 Hz), plus the compass
triad `compass_caution_shown` (after the existing 4 s debounce) /
`compass_sheet_opened` / `compass_calibrated` (the sheet's false→true latch
transition only — arriving already-good doesn't count). The funnel now reads:
opened → step 0/1/2 → permissions granted? → completed → first frame → first
plane seen → first catch, with the compass events explaining the "saw a label
but it pointed wrong" gap. Phase 2 (the design pass — calibration step back
into the flow per `design/screens/onboarding.jsx` Variation A, camera-denied /
location-denied recovery UI, general craft) follows.

## 2026-07-09 — L4 detector soft-gate ships in shadow (anti-cheat PR3) — branch `feat/l4-detector-soft-gate`

The last anti-cheat lever (docs/anti-cheat-plan.md §5 L4), adapted to the
2026-07-04 post-catch confirm model: when the camera *should* have seen the
plane and didn't, the catch gets the `no_detection` suspicion — post-reveal
Keep/Discard, never a block. "Should have seen it" is the competence envelope:
daylight (`meanLuminance ≥ 0.12`, SkyCheck's color-trust dial) AND an expected
footprint ≥ 24 px in the captured still (`DetectorGate.expectedFootprintPx` —
wingspan/slant through the zoom-effective FOV; the model's measured floor is
~15–20 px). "Saw it" = the `CatchPhotoSnapper` full-res ring search over the
captured still (the strongest evidence the catch path has, reused from PR
#106 via the new `snapOutcome` API) OR a live preview `VisualFix` (fresh by
construction — expires after ~1 s of misses). Corroboration always wins;
night, specks, multi-catches, and missing signals are never judged (fail
open, same doctrine as SkyCheck/LocalSkyGate). Ships in SHADOW exactly like
L2 did: `catch_detector_gate` fires on every single-target catch (verdict +
envelope signals; `detector_verdict` also lands on `catch_performed`), and a
debug-overlay row toggles `[L4 SHADOW]` ↔ `[L4 ENFORCE]`
(`detectorGateEnforcing`, UserDefaults). Flip enforcement when the shadow
stream shows in-envelope no-detections are cheats rather than recall misses.
New pure `DetectorGate` + `DetectorGateTests`; suspicion precedence is now
occluded > no_detection > too_far > indoor.

## 2026-07-08 — Profile hub reorganized ("Direction A") — branch `feat/profile-standing-layout`

Follow-on to the same-day cleanup below, answering Noah's "what is this page
prioritizing?" Three questions drove it: medals-vs-trophies (one system, and
this screen's MEDALS tile was the only surface not calling them Trophies),
no clear information hierarchy, and a data-dishonest rarity strip (equal
segments regardless of counts — the old code comment admitted it).

Four divergent layouts were mocked in real SwiftUI (rendered via the
snapshot harness; review artifact 2026-07-08) — A "Standing" scoreboard,
B "Progression" quest log, C "Flight deck" instrument cluster, D "Boarding
pass". **Noah picked A**; D's boarding-pass concept moved to the backlog as
the share/invite artboard (PLAN §9 #10 "Spotter Pass").

The shipped layout, in priority order: identity + points/rank hero → ONE
quiet collection-stat strip (Catches · Unique · Rare+ · **Trophies**) → nav.
The four stat tiles and the rarity strip are gone (census detail lives in
the Hangar/references). Surfaces moved to iOS 26 Liquid Glass
(`.glassEffect`) tinted to `bgElevated` — untinted glass resolves too
bright over the fixed dark palette — over a backdrop with two faint radial
glows so the glass has something to refract. `ProfileStats` is unchanged;
only the view reorganized.

**Field-review round 2 (Noah, 2026-07-08):** the Map's rarity filter strip
no longer hyphen-wraps ("LEGENDAR-Y") — chips are lineLimit(1) + fixedSize
inside a horizontal ScrollView, so overflow scrolls instead of wrapping.
The profile gained the **BEST CATCH** card from the exploration's
Direction B (highest-rarity airframe, most recent on ties; taps through to
the catch detail via the Map screen's single-catch HangarRow pattern). The
**Sets quick card** was removed (the Hangar's default segment IS Sets — a
duplicate door), and the **Types reference** was cut entirely (link +
screen — the Sets segment teaches the type buckets in context). The Rarity
reference copy was sharpened to the current tiering: tiers = sky presence
plus a scarcity layer (military/vintage/vanishing airliners), and
unidentified planes default to Common. Its examples were already re-synced
to `AircraftTypes.json` in the cleanup round below.

**Share (same branch — iterated with Noah to deliberately minimal):** the
toolbar Share got the brand CTA treatment (cyan disc, dark glyph — the
page's one action) and is a DIRECT `ShareLink`: one tap → the system share
sheet with **"Join me on Tailspot:" + https://tailspot.app** — nothing
else. Messages renders the link as a rich preview from the site's OG tags.
The old `ShareCardSheet` preview detour is deleted, and so is the
in-between iteration: a rendered stat-card artboard (Direction-B language —
points/rank hero, NEXT UP tier ring, best catch, challenge copy + a
tailspot.app QR) was built, reviewed, and **cut as too much** — an invite
should be a text and a link (Noah). The artboard lives in git history and
the 2026-07-08 exploration artifact if the Spotter Pass work (PLAN §9 #10)
wants to resurrect it as the share object. New `profile_share_opened`
funnel event (simultaneous gesture — ShareLink exposes no tap callback;
"opened", not "completed"). The **invite trophy** stays coupled to Spotter
Pass: awarding it honestly needs joined-from-your-invite attribution.

## 2026-07-08 — Profile/Settings legacy-artifact cleanup for v1 — branch `polish/settings-v1-cleanup`

A pre-launch scrub of the Profile hub + Settings surface (PLAN §9 #6). Every
change removes something stale or false rather than adding surface:

- **Settings ABOUT told users the wrong data source** — "OpenSky Network",
  dead since the 2026-06-21 cutover. Now "Live aircraft data · adsb.lol",
  matching the attributions page; stale OpenSky/ODbL comments fixed too.
- **Fake affordances removed**: the hardcoded `PUBLIC` pill on the Profile
  header and onboarding's "Public profile / anyone can view your hangar"
  toggle (wrote `tailspot.profile.public`, which controlled nothing — the
  public hangar was cut in WP 1.7). Onboarding copy no longer promises a
  public hangar.
- **Notifications placeholder retired**: the Profile row + `NotificationsScreen`
  ("coming after launch") deleted — push is post-GA (#9); re-add with the real
  feature. `TrophiesScreen.swift` deleted too (orphaned wrapper, zero callsites
  since trophies moved into the Hangar).
- **Rarity reference re-synced to the 2026-07-01 economy**: example strings
  had A330/787/777 at uncommon (now common), C-130/C-17 at rare (now epic),
  A380 at epic (now rare), B-52 at epic (now legendary); footer copy now
  mentions the first-of-type bonus. Verified each example against
  `AircraftTypes.json` tiers.
- **Settings/Notifications were the last two screens on system list chrome**
  (white in light mode against the fixed dark Brand palette) — Settings now
  uses the SetsScreen brand treatment (`scrollContentBackground(.hidden)` +
  `bgPrimary` + `bgElevated` rows).
- New `ProfileSettingsSnapshotTests` visual-pass suite (UIWindow +
  `drawHierarchy`, since ImageRenderer renders List/NavigationStack blank).

Known-but-deferred: `SpotterHandle.defaultPlaceholder == "spotter_42"` is a
real user's claimed handle, but the string doubles as the "not claimed"
sentinel in `HandleSyncer`/`AnalyticsIdentity` — changing it silently flips
existing placeholder installs to "claimed", so it needs its own careful pass.

## 2026-07-08 — Asia-Pacific operator gaps (APJ545 / BTK6143) — branch `fix/asia-pacific-operator-gaps`

Field report: two 2026-07-03 catches (APJ545 — Peach Aviation, BTK6143 —
Batik Air) showed "Operator unknown". Root cause: no upstream source supplies
an operator (the backend metadata seam is intentionally null, the adsb.lol
feed carries none), so the ONLY operator source is the client's hardcoded
`Airlines.byICAO` callsign-prefix table — and its original seed was
US/Europe-heavy with no Asia-Pacific LCC coverage.

Fix, in two rounds the same day (Noah: "just compile a comprehensive list"):
first ~45 hand-added Asia-Pacific designators, then the durable version —
operator resolution is now TWO layers: the curated `byICAO` table survives
only as a display-name override ("FedEx Express" over the legal "Federal
Express"), and beneath it sits `airlines.json`, a bundled ~5,900-designator
snapshot of the VRS standing-data airline list (CC0), regenerated by
`tools/generate-airlines.py`. Coverage gaps are now dataset-refresh problems,
not code problems. A shape-invariant test (keys must be 3 uppercase letters —
lookup is `prefix(3)`) caught and removed an unreachable 4-char `"FDX2"`
entry. No migration needed: `CatchBackfill.backfillAll`'s offline pass retries
every `operatorName == nil` catch on Hangar open, so existing cards heal on
first open after update. Per-airframe operator truth behind the backend's
`operatorNameSeam` stays a later work package.

## 2026-07-07 — `first_plane_catch` activation event — branch `feat/first-catch-event`

The user's very first catch (the tap that takes the Hangar 0 → N) now fires a
first-class `first_plane_catch` event — the activation edge the ~36 openers →
5 catchers funnel (PLAN §9 #3) pivots on, without reconstructing "first" in
HogQL over `catch_performed`. Carries icao24/rarity/aircraft_type/slant_km in
the performed vocabulary. Fired at most once per install (UserDefaults latch;
a reinstall wipes Hangar + latch together, so the semantics stay "first catch
in this Hangar"). Detection = `fetchCount` of `Catch` snapshotted before the
insert loop in `runCatch`.

## 2026-07-06 — Catch-photo bracket snaps onto the detected plane — branch `photo-bracket-snap`

Field reports (2026-07-04 iPhone-15 tester + Noah's 2026-07-05 NYC/PHL batch):
the bracket baked into the catch photo often sits well off the plane. Root
causes: compass wobble in the geometric prediction, plus hand drift during
the ~0.2–0.6 s between the catch tap and the shutter (positions were
snapshotted at tap time). Validated offline first: the shipped YOLOX model
was run over all 79 real on-device catch photos (pulled via `devicectl`);
the shipped policy simulation snaps 14/42 bracketed photos (median
correction 150 px, max 404 px) with zero hallucinated snaps — full
annotated evidence in the session's snap-eval review doc.

- **`CatchPhotoSnapper` (new)**: after the shutter returns, runs the
  detector over the captured STILL — native-res 640 px crops (center +
  8-tile ring at ±480 px; never a downscaled wider crop, which erases
  near-floor planes and hallucinates giant boxes), gates conf ≥ 0.25 +
  box ≤ ⅓ crop + snap radius ≤ 700 px, and picks the detection NEAREST
  the prediction (airports: nearest beats most-confident). No hit → the
  geometric position ships as before (never worse than today).
- **Shutter-lag re-projection**: `runCatch` re-projects the target through
  the CURRENT pose once the photo exists (`refreshedScreenPosition`) so
  even the fallback bracket reflects where the phone points at exposure
  time, not at tap time.
- **`AirplaneDetector.detect(in: CGImage, …)`**: still-photo entry point
  refactored out of the pixel-buffer path (shared CIImage core).
- Snapped focus flows into `Catch.photoFocusX/Y`, so the reveal/share
  plane-anchored crop (#104) now anchors on the actual plane too.
- Single-target catches only (a multi-catch could snap two brackets onto
  one detection); multi keeps tap-time geometry. Telemetry:
  `catch_photo_snap` (outcome + correction_pt) to watch the snap rate and
  tune the confidence floor from the field.
- Known limitation (eval-verified, accepted): at an airport with background
  aircraft in view the nearest detection can be a parked plane.
- Tests: `CatchPhotoSnapperTests` pin the gates + nearest-wins choice and
  the ring geometry; full TailspotTests suite green.
- **2026-07-08 floor tuning from Noah's ground truth:** Noah hand-labeled
  all 65 non-snapping photos via a local click-to-label utility
  (`tools/visual-confirmation/labeler.py`; labels committed as
  `labels.json`). Analysis (`analyze_labels.py`): every reachable labeled
  plane down to conf 0.25 is real, the none/unsure photos yield zero
  candidates even at 0.20, and all 14 verified snaps are choice-stable at
  0.25 — so `confidenceFloor` dropped 0.45 → 0.25 (+5 correct snaps on
  the corpus, incl. the house-wall case and the July-5 E175). Also
  measured: the detector cannot see ~60% of the labeled specks at any
  threshold (model recall floor) — a future model upgrade, not a
  threshold problem.

## 2026-07-06 — Offline-banner debounce (field: North Shore Towers) — branch `fix/offline-banner-debounce`

Field report 2026-07-05 (JFK approach corridor, one-bar cellular): intermittent
"THE INTERNET CONNECTION APPEARS TO BE OFFLINE" flashes. Root cause: any single
failed 10 s poll set `lastError` immediately, while the 1 Hz re-annotation loop
was gliding fine on forward-extrapolated positions — the banner screamed about
a non-problem.

- `ADSBManager.refresh` now tolerates `fetchFailureGraceCount` (3) consecutive
  poll failures (~30 s at the 10 s cadence) before surfacing the error; a
  success resets the count. Cold-start-while-offline (`lastFetched == nil`)
  still surfaces the FIRST failure — an empty sky needs an explanation.
  Suppressed failures still log via `Log.adsb`.
- Tests: `ScriptedSource` fixture (ordered results) + grace-exhaustion and
  blip-reset cases; existing cold-start error tests unchanged and green.

Same field session, tracked not fixed here: (1) Recent list still shows ICAO
route codes — the PR #102 IATA translation is merged but the **prod backend
was never redeployed after it** (deploy = the fix; rows then self-heal via the
Hangar backfill); (2) dense-corridor precision — catches of not-actually-
visible planes / wrong plane under a JFK arrival stream — folded into the
PLAN §9 #2 residual (L4 detector soft-gate + disambiguation under density).

## 2026-07-05 — Share card = settled card + plane-anchored photo crop — branch `feat/share-settled-focus`

Field feedback on Direction B, same day: (1) the SHARE image still used the
old pre-B artboard; (2) the hero photo "cropped weirdly" — the aspect-fill
crop centered on the FRAME, so an off-center plane (they usually are; you
shoot upward) got pushed to the edge or out of the hero entirely.

- **Share artboard restyled**: `CatchShareCard` now wraps `SettledCatchCard`
  in minimal brand chrome (wordmark + tier up top, "CAUGHT ON TAILSPOT"
  below) — one card design across catch, Hangar, and share.
  `CatchShare.image(for:)` drops the separate photo param (the card loads
  its own local JPEG); both call sites (CardReveal, CatchDetailView) updated.
- **Plane-anchored crop**: `CatchPhotoComposer.compose` now also returns the
  bracket center as NORMALIZED photo coordinates (`Composed.normalizedFocus`,
  clamped 0…1); persisted as `Catch.photoFocusX/Y` (additive, lightweight
  migration) and carried through `CardPlane.photoFocus`. `RevealPhoto` gained
  a focus-anchored fill mode via the pure `FocusFill.layout` helper — scale
  identical to `.fill`, slid so the plane lands as close to the hero center
  as the image edges allow. nil focus (pre-field rows, Planespotters photos)
  → the old center crop.
- **Two side-fixes found by the snapshot pass**: RevealPhoto now clips both
  fill paths itself (ImageRenderer let the oversize fill bleed past the card
  in share renders), and non-file photo URLs render via AsyncImage —
  Planespotters heroes on photo-less catches had silently regressed to the
  sky placeholder in Direction B.
- Tests: `normalizedFocus` mapping/clamping, `FocusFill` center/offset/clamp/
  degenerate cases, compose smoke updated; `ShareCardSnapshotTests` renders a
  synthetic marker photo with/without focus + the new share artboard.

## 2026-07-05 — Detail screen becomes the settled reveal (Direction B) — branch `feat/detail-settled-card`

Noah picked Direction B from the design-directions doc ("mirroring the reveal"):
the catch detail screen now frames the reveal card AT REST instead of stacking
grey panels.

- **New `SettledCatchCard`** — the reveal's layout settled at t=1, built from the
  SAME atoms the reveal animates (RP palette, `FlapRow`, `statCell`/`ledgerRow`,
  `RevealPhoto`, `wrapName` — all promoted from `private` to internal), so the
  catch moment and the Hangar cannot drift apart. Photo hero, static split-flap
  name, tier line (dot + tier + carrier), ALT/SPD + full-width ROUTE (IATA display
  codes), and the score ledger — with a re-derived **FIRST OF TYPE +50%** line when
  this catch was historically first of its typecode (computed from the Hangar, no
  stored flag — same philosophy as `resolvedRarity`).
- **`CatchDetailView` collapses to card + fine print**: one quiet block with
  REG / ICAO / TYPE over a rule and CAUGHT date · time · place. The EARNED / ROUTE /
  FIRST CAUGHT / AIRFRAME box stack is deleted — each fact appears exactly once
  (the doc's critique #2/#3). Share sheet unchanged (still the share-card image).
- Visual pass via new `SettledCardSnapshotTests` (route/no-route, first-of-type,
  long wrapped name, tier extremes, all-nil); full `TailspotTests` green.

## 2026-07-05 — IATA route codes + detail-view ROUTE panel + degenerate-route fix — branch `feat/detail-reveal-language`

Three field reports from Noah's Haneda session, one round:

- **"Use the common airport identifiers" — IATA end-to-end.** The standing-data
  `_airports[]` rows carry 3-letter IATA codes; `parseRoute` now emits
  `originIata`/`destIata` (uppercased) alongside the ICAO pair → `/v1/aircraft` +
  `/v1/routes` wire (additive) → `Aircraft`/`BackendAircraft.Route` → new
  `Catch.originIata`/`destIata` (additive migration). ALL route display goes through
  `Catch.displayOrigin`/`displayDest` (IATA preferred, ICAO fallback) — reveal, Recent
  card, and the new detail panel show **HND → SFO**, not RJTT → KSFO. The backfill
  gains a **translation pass**: rows with a full ICAO route but no IATA re-qualify,
  and IATA/names fill ONLY when the lookup's ICAO pair matches the stored one (never
  re-routing an as-flown journey to today's filing).
- **"KLGA → KLGA" degenerate routes.** Out-and-back filings ("KLGA-KTEB-KLGA")
  collapsed first → last to the same airport. `parseRoute` now rejects origin == dest
  (which leg was flown is unknowable), and `CatchBackfill.clearDegenerateRoutes`
  repairs already-stored ones on Hangar open (cleared rows re-enter the fill pool,
  where the fixed lookup answers null).
- **"It still looks the same" — the detail view.** The Recent-card redesign (#96)
  restyled the LIST row; the tap-through `CatchDetailView` was untouched and had no
  route display at all. New **ROUTE panel** in the reveal's routeCell vocabulary
  (mono display codes, rarity-tinted arrow, city subline) between EARNED and FIRST
  CAUGHT.

Backend 241 tests green (degenerate + IATA parse pins); `TailspotTests` green
(IATA fill/translate/mismatch-guard, degenerate repair, display-preference tests).

## 2026-07-05 — Leaderboard: one catch is the entry ticket + stranded-handle cleanup — branch `fix/leaderboard-zero-catch`

Fallout from the "why 23 handles for ~13 testers" reconciliation: onboarding's
suggestion chips mint a handle for every drive-by install, and those 0-point rows
padded the public leaderboard.

- **`leaderboard()` now requires ≥1 catch** (`HAVING count(catches.id) > 0`) — a
  claimed handle alone no longer appears on the public board. `myStanding` is
  unchanged (it already returned null for catch-less devices). Route test added.
- **Data op (prod):** nulled the 4 stranded day-one duplicate handles — spotter_42,
  contrail_cam, blue_hour, approach_287 (all registered 2026-06-16, zero catches,
  zero analytics; pre-#55 keychain-loss orphans of testers who re-claimed under
  their current names). Frees the names for re-claim; the matching stale PostHog
  handle on approach_287's person was `$unset`.

## 2026-07-04 — Route lookups go direct to standing data (prod enrichment was silently dead) — branch `fix/route-lookup-standing-data`

Deploy-time discovery while verifying `GET /v1/routes` (the backfill endpoint): **every
adsb.lol route GET from Fly was timing out** — the `api.adsb.lol` hop takes ~6 s just to
serve its 302 from sjc (IPv6 addresses stall before the v4 fallback), past the 4 s lookup
timeout. All prod route enrichment had been silently failing (the AbortError spam in the
logs), meaning live catches were getting routes only from earlier cache warm-ups, if ever.

Fix: `getRoute` now fetches adsb.lol's **standing-data host directly** at the same URL the
(deprecated-marked) API redirects to — `vrs-standing-data.adsb.lol/routes/<CS[0:2]>/<CS>.json`,
~100 ms from Fly, same JSON shape — with the API URL kept as a transport-error-only
fallback (a standing-data 404 is the authoritative "no route"). New tests pin the primary
URL, the fallback ordering, and 404-doesn't-fall-back; 239 backend tests green.

## 2026-07-04 — Analytics: handle self-heal for pinned-id devices — branch `fix/handle-selfheal-pinned-id`

Root-caused why several claimed handles (eagle_eye, skywatcher, …) never appeared on
their PostHog persons despite the launch self-heal: **posthog-ios's `identify()` is a
silent no-op when the SDK is already identified under a different distinct_id — and
the handle `$set` riding along is dropped with it** (verified in the SDK source: the
different-id branch requires "not yet identified"; same-id re-identify becomes a
`$set`). Devices pinned to a pre-#76 throwaway local id hit this on every launch, so
neither the claim-time identify nor the self-heal could ever land their handle.

- **`AnalyticsIdentity.identifyRoute`** — new pure routing decision (unit-tested):
  first identify / same-id re-identify → `identify()`; pinned to a different id →
  fall back to a `$set` of the handle on the *current* (pinned) person — the
  2026-06-26/27 server-side merges made that the same person as the server-id one;
  pinned with no handle → drop (logged). `PostHogAnalyticsSink.identify` now routes
  through it, so ALL identify call sites (launch self-heal, registration, handle
  claim/change in Settings) are covered.
- **One-time backfill (data op, not code):** `$set` handle via the capture API for
  the 4 affected persons with verified distinct_id↔person mappings — eagle_eye,
  skywatcher, grant, approach_287. The remaining 3 backend handles missing from
  PostHog (spotter_42, contrail_cam, blue_hour — all registered day-one 2026-06-16)
  have **zero analytics events ever**; no person exists to backfill, and their
  unpinned SDKs will identify correctly on their next launch with a current build.
- Diagnosis artifact: the three "UUID persons" Noah flagged were eagle_eye,
  skywatcher, and planespotters — the last was already healed (its SDK id matches
  the server id; its launch `$set` landed 2026-07-03).
## 2026-07-04 — Route backfill: old catches gain origin → destination — branch `feat/route-backfill`

Noah's ask after the Recent-card redesign: "backfill the old cards to the new design."
The design applies everywhere already — what old catches lack is route DATA (capture
started 2026-06-29, and only for flights the feed had routes for). Both halves:

- **Backend `GET /v1/routes/:callsign`** — per-callsign route lookup for the heal.
  `AdsbLolRouteService` gains an awaitable `resolve` (RouteResolver seam) over the SAME
  cache the position-path enricher fills; anonymous, per-IP rate-limited (120/min),
  `route: null` is a normal 200, upstream failure → 502 (client retries a later pass).
  Registered only when an adsb.lol-backed resolver exists; tests inject a fake.
- **iOS `CatchBackfill`** — new route pass in `backfillAll` (Hangar-open heal): once
  per DISTINCT callsign, fill origin/dest (+ names) onto catches where BOTH codes are
  nil. **Route joins operatorName as a documented best-effort exception to the
  frozen-moment rule** — the lookup answers with the route *currently on file*, which
  for scheduled callsigns is almost always the flown pair. A one-sided as-observed
  route is moment-data and is never touched; a half answer from the lookup fills
  nothing. CLAUDE.md + the `runCatch` comment updated accordingly.
- Backend 238 tests (8 new) + `TailspotTests` green (4 new `CatchBackfill` route tests).

## 2026-07-04 — Backend: airplanes.live fallback feed — branch `backend/airplanes-live-fallback`

Cheap transport-failure insurance for the position feed (from the same coverage audit
as the 10 s polling round). airplanes.live speaks the identical readsb `/v2/point` API
as adsb.lol, and live sampling (2026-07-03) showed it equal-or-superset everywhere
tested (Singapore 14 vs 9, all 9 shared; Berkeley ~even; Bali 0=0 — the Lombok gap is
a *shared* receiver desert no aggregator fixes).

- **`AirplanesLiveProvider`** — the adsb.lol client pointed at `api.airplanes.live`
  (thin subclass, same normalizer).
- **`FallbackProvider`** — new default (`adsblol+airplaneslive`): serves adsb.lol; on
  a THROW serves airplanes.live. Deliberately narrow: empty-but-successful responses
  do NOT fall back (zero planes is a legitimate answer), results are never merged
  (duplicate icao24s with conflicting positions), and every engagement is logged via
  `onFallback` → `app.log.warn` — no silent failover (the 2026-06-21 cutover lesson).
- `POSITION_PROVIDER=adsblol|airplaneslive|opensky` still selects a single feed; the
  route enricher gate now matches `name.startsWith("adsblol")` so the composite keeps
  route enrichment.
- Tests: fallback semantics (5), airplanes.live URL/name/error identity (2), selector
  (2). 230 backend tests green. **Not yet deployed to prod** — deploy is Noah's call.
## 2026-07-04 — 10 s polling + OpenSky-era dead code removed — branch `ios/poll-cleanup`

Fell out of a coverage/accuracy Q&A: an audit of the actual rate-limit situation showed
the app's 20 s poll + 429 backoff were guarding against an API that no longer exists.

- **Poll interval 20 s → 10 s.** `/v1/aircraft` has **no rate limit** (the backend's
  token buckets cover register/handle/catch/suggest only); the real upstream protection
  is the tile cache (10 s TTL, single-flight), so 10 s is the fastest cadence that can
  see fresh data — faster only re-reads the cache.
- **429 backoff machinery removed** (`maxBackoffInterval`, `currentInterval`,
  `ADSBSourceError.rateLimited`, `lastErrorIsTransient`, the reAnnotate staleness
  widening): the backend never returns 429 on the aircraft route, so all of it was
  dead. Errors now surface uniformly via `lastError`; the empty-sky pill lost its
  "transient" softening (nothing produces a transient error anymore).
- **OpenSky positional-array decoder deleted** (`Aircraft: Decodable`,
  `FailableDecodable`, `AircraftDecodingTests`): production decodes only the backend's
  keyed DTOs; the array decoder was exercised by its own tests and nothing else. Its
  baro-first field order misleadingly suggested barometric altitude was in play —
  the pipeline prefers GEOMETRIC (`alt_geom`) end-to-end (backend normalizer), now
  documented on `Aircraft.altitudeMeters`.
- Dead `refreshNow()` (mock-toggle leftover) removed; stale comments (maxPositionAge
  rationale, backend-client header, replay-format note) rewritten; CLAUDE.md + PLAN §8
  updated to match.

## 2026-07-04 — North-star baseline + L2 sky-gate calibration → ENFORCE — branch `feat/l2-gate-enforce`

GA-push items #1 and #2 (Bet A close-out).

**#1 North-star baseline (PostHog, no code):** new pinned dashboard **"North star — Real
catch (Bet A)"** (id 1797334) with three insights: weekly catch-confirmation-rate
(`(catch_performed − catch_deleted)/catch_performed`), raw attempt/delete volumes +
unique catchers, and per-gate blocks-vs-overrides (indoor, size, L2 would-block, L2
override). **Baseline ≈ 97.7% kept** — 133 `catch_performed` / 3 `catch_deleted` since
the telemetry shipped (2026-06-26); all 3 deletes from one tester. The attempt-inclusive
framing (un-overridden gate blocks counted as failed attempts) reads ~75%; kept out of
the headline because a working anti-cheat block is not a distrusted ID.

**#2 L2 localized sky gate — calibrated from shadow telemetry, enforcement flipped ON:**

- **Shadow data (74 `catch_local_gate` events, 9 users, 06-28 → 07-03) confirmed the
  texture dial transfers on-device:** sky verdicts max at `patch_texture` 0.0116, first
  would-blocks at 0.0153 — `texSmooth = 0.014` sits in the gap, unchanged. The would-block
  population clusters exactly where L2 was built to fire (the NYC-canyon session, foliage
  at 0.08–0.15).
- **Two real false-block classes surfaced, both guarded:** (1) **night catches self-block**
  — the bracket centers the plane, so its own lights (bright dots on black) read as
  texture at `patch_lum < 0.12`; new night guard fails open (`uncertain`) when the patch
  is near-dark. (2) **Golden-hour skies read 0.045–0.06 warm** — `warmThreshold` 0.04 →
  0.07, the same fix the whole-frame `SkyCheck` gate took in the 2026-07-01 field
  recalibration. Both mirrored in the offline reference scorer (`score_local_gate.py`).
- **`localGateEnforcing` default OFF → ON** (`VisualConfirmationPipeline`; UserDefaults
  override preserved, debug-overlay SHADOW↔ENFORCE toggle unchanged). A block always
  offers one-tap "Catch anyway"; `catch_occluded_override` (already on the north-star
  dashboard) is the live false-block signal. Visual confirmation could not serve as
  ground truth — `visual_fix_active` was false on every shadow-joined catch (distant
  specks, the model's size cliff) — which is why **L4 (detector soft-gate) stays next**
  as the mirror-glass backstop.
- New `LocalSkyGateTests`: golden-hour-not-warm (0.055 allows / 0.08 blocks) + night
  textured fails open.

**Post-catch confirm — same-day field pivot (airport test, Noah).** The enforcement
model reversed within hours of the flip: a pre-catch block interrupts a moving target,
and its "Catch anyway" re-runs seconds later against stale aim — the **JA10VA case**
(aimed at a just-departed plane not yet in the feed; the override caught the only
in-data candidate in the cone, an invisible plane **62.6 km** out in haze, ~2′ — below
the size floor). New model, all three gates:

- **Gates raise suspicion, never block.** Catch + reveal proceed instantly; the
  pre-catch nudge / "Catch anyway" apparatus is deleted (`CatchBlock`, `blockCatch`,
  the nudge overlay + state, the `catch_*_override` events + fire wrappers).
- **`Catch.suspectReason`** (additive optional: `occluded` / `too_far` / `indoor`;
  `CatchSuspicion` with occluded > too_far > indoor precedence). While set, the row is
  **quarantined from upload** (`CatchUploader.pendingPredicate`, now static + pinned by
  a test) — a doubted catch never touches the leaderboard unanswered.
- **One Keep/Discard question after the reveal** (never on top of it): reason-specific
  copy ("That one was 63 km out — could you really see it?"). Keep → clears the flag,
  uploads on the next scene-activation sweep (`catch_suspect_kept`). Discard → deletes
  row + photo (`catch_suspect_discarded` + `catch_deleted`, so the north-star headline
  absorbs it). Unanswered → stays local + quarantined.
- New events: `catch_suspected` / `catch_suspect_kept` / `catch_suspect_discarded` —
  the **earned** confirm/deny signal for catch-confirmation-rate. The gate-positive
  streams (`catch_blocked_*`, `catch_local_gate`) keep their names for dashboard
  continuity but now mean "suspicion raised".
- Data-latency follow-up noted: just-departed planes lag the feed (the actual JA10VA
  root cause) — no client gate can fix that; tracked as a backend freshness question.

## 2026-07-04 — GA-push re-prioritization of PLAN §9 (docs only)

Re-ranked the canonical backlog for a concerted push toward GA launch, strictly by the
STRATEGY.md bet sequence (supersedes the 2026-06-24 ordering). Shape of the call:

- **Bet A is closed out, not re-litigated:** the engine work shipped (telemetry, replay
  loop, visual confirmation, anti-cheat L1/L3). What remains is #1 *reading* the
  north-star (catch-confirmation-rate has never been computed from the shipped events)
  and #2 flipping L2 from shadow to enforcing off its accumulated telemetry.
- **The push's bulk goes to Bet B:** #3 onboarding re-do (the measured ~36→5 activation
  leak, now unblocked by the shipped economy; compass-calibration UX folded in), #4
  game-layer completion (route-guess bonus + the deferred Decision 3 trophy/medal
  rework + guess-the-type), #5 card-art medium decision → cards build, #6 polish sweep.
- **Two GA-scale enablers promoted from "not urgent":** #7 Hangar restore/sync (the
  local-only Hangar is a catastrophic-loss risk at GA scale) and #8 GA-gate
  housekeeping (ICAO terms re-check, privacy policy/ToS, App Store assets, region call).
- **#9 push alerts recommended post-GA** (retention lever needs an installed base);
  #10 sharing/reticle-color polish stays the tail.

Also flagged: a TestFlight build cut is due (economy/reveal/iPhone-only/airport names
are on `main` but not on testers' phones) — Noah's call. No code changes this round.

## 2026-07-04 — Recent card speaks the reveal's design language — branch `feat/recent-card-reveal-language`

Noah's follow-on to the reveal (airport field session): the Hangar **Recent** card
(`TailCard` rich variant) now matches `CatchRevealView`'s vocabulary. Display-only —
no model/schema/telemetry change; the Sets compact variant is untouched.

- **Make/model promoted to the hero line** (primary ink, semibold — the card's echo of
  the reveal's split-flap name; was mid-grey secondary).
- **Route surfaces on the card for the first time**: mono ICAO codes with the
  rarity-tinted `→` (the reveal's `routeCell` pattern) + a short date. One-sided routes
  render one code, never a dangling arrow; no-route rows keep the quiet
  `date · location` line. Rarity tint now carries two meanings (points + route arrow) —
  still the two-hue discipline (cyan callsign; rarity tint).
- Visual pass via new `TailCardSnapshotTests` (ImageRenderer, RevealSnapshotTests
  pattern) over routes/one-sided/none, long names, hex-fallback callsign, all-missing,
  and the Sets regression. Before/after review doc:
  `docs/reviews/2026-07-04-recent-card-reveal-language.html`.

## 2026-07-01 — Airport city names + economy rolled out to prod — branch `feat/route-airport-names` (PR #89) + ops

**Airport city names (PR #89):** real catches now get the reveal's city subline. adsb.lol's
routeset response already carries per-airport detail (`_airports`); the backend now reads the
origin/dest city (municipality, falling back to the airport name) and threads
`originName`/`destName` through `AircraftRoute` → `/v1/aircraft` → iOS `Aircraft` → frozen on
the `Catch`. Additive/optional throughout. Route enrichment is **opportunistic** — it surfaces
on later polls once the routeset cache warms, and only for flights adsb.lol has route data for.

**Economy rolled out to prod — the live leaderboard now reflects the re-balance** (runbook:
`docs/runbooks/2026-07-01-economy-leaderboard-rollout.md`):

- Migration `0005` (`first_of_type`) applied (`0004` was already live); drizzle journal at 6.
- Backend deployed to Fly (v10): points `10/20/50/100/500`, `CURRENT_SCORING_VERSION` 2,
  server-authoritative first-of-type, route + airport-name passthrough.
- Regenerated `AircraftTypes.json` (2,612 types) re-ingested into prod `typecodes`
  (A380→rare, C-17→epic, B-52→legendary; dist 2181 common / 315 uncommon / 35 rare / 46 epic / 35 legendary).
- All 219 catches rescored (dry-run reviewed first): total **5310 → 3100** — board-wide
  compression from the flatter ladder + tier moves (epic→rare ×3 −1350, uncommon→common ×30,
  rare 100→50). Leaderboard: noah 1100 (68), skywatcher 770 (57), jdurovsik 620 (44).

iOS reaches testers via the next TestFlight (Noah's call). Pre-`0005` catches keep
`first_of_type=false`, so the rescore did not retroactively grant the +50% (correct — going-forward).

## 2026-07-01 — Reveal field-polish + indoor-gate tuning — branch `feat/collection-economy-reveal`

On-device review of the reveal drove a polish pass (verified by rendering the real view to PNG via a new `RevealSnapshotTests` harness, not by eyeballing a green build):

- **Legibility:** every metric now scales off the card width (~1.2× on a phone) — the prototype's 300pt-card literals read small/cramped on-device; width cap 360 → 420, section spacing opened up.
- **Long names wrap** across split-flap lines at a legible cell size instead of shrinking to dust (settle flows continuously across the lines).
- **Data block restructure** (per Noah's mock): ALT/SPD as a two-column row with a tinted unit suffix, then a full-width ROUTE row — big ICAO codes, tinted arrow, human-readable city names underneath. No-route catches show DIST on its own row (fixes an ALT/SPD/DIST column collision); one-sided routes show just the known endpoint (no dangling `→ —`). `Catch` gains additive `originName`/`destName`; `CardPlane` carries the four route fields.
- **Tap routing:** the dismiss gesture was on the container enclosing the CTA and swallowed "View in Hangar" — reworked to a layered hit-test (card taps fall through to a dismiss catcher; the button captures its own tap).
- **CTA overlap:** a tall (wrapped-name) card's bottom ran through the "tap to continue / View in Hangar" strip. Card + CTA now share one VStack so the CTA is always a reserved strip below the card — can't overlap at any card height.

**Indoor "look outside" gate — tuned back** (field report: over-eager): the ambient banner now needs ~5 s sustained not-sky (was 3), and `SkyCheck.warmThreshold` 0.04 → 0.07 so mildly-warm outdoor scenes (horizon, warm buildings, hazy/golden sky) stop false-tripping `.notSky` while clear interiors (~0.13+) still block. Only makes blocking rarer. Full corpus re-validation (`tools/authenticity-gate`) is a follow-up.

`TailspotTests` green throughout.

## 2026-06-30 — Catch-reveal shipped: split-flap + photo + score ledger (Bet B #7, Phase 2 core) — branch `feat/collection-economy-reveal`

The agreed Decision-2 reveal replaces the v0 holo-flip card for single catches. `CatchRevealView` renders the design we mocked in `RevealV3` / `docs/plans/2026-06-29-001`: a **photo hero** (the real catch photo, else a stylized sky placeholder), the make/model in a **split-flap** display that settles char-by-char, a tier line, an **ALT · SPD · ROUTE** data row, and a **score ledger that counts up** from the rarity base — adding a gold **FIRST OF TYPE** line when it's a new type for you. Every beat is a function of one normalized clock `t` through `ss()` smoothsteps (ported verbatim from the prototype); `TimelineView(.animation)` drives `t` live instead of hand-rendered frames. **Cadence + intensity scale by tier** — common settles quickly and quietly (~1.7 s); legendary takes ~3.2 s with a tinted radial bloom.

- **`CatchRevealView.swift`** (new) — the reveal; tap to skip-then-dismiss, "View in Hangar" CTA once settled, success haptic on settle.
- **`CardPlane`** gains `routeText` + `isFirstOfType` (display-only — the backend stays authoritative for the awarded bonus); `cardPlane(from:)` formats the route from the frozen origin/dest ICAO and derives first-of-type from the Hangar.
- **Debug `✦ Catch`** button (wrench panel, DEBUG-only) fabricates a non-persisted catch per tier and fires the reveal — cycles C-17 (epic) → Cessna 172 (common) → A220 (uncommon) → 747-400 (rare) → B-52 (legendary), so the reveal/economy is testable without a real plane. Doesn't touch the Hangar.
- `MultiCatchReveal` (N≥2) unchanged for now; the old `CardReveal` survives only behind its own previews.

The **route-guess +10% bonus round** (the pre-reveal "where's it going?" step, wishlist #9) is the remaining Phase 2 piece — the ledger already reserves its line. `TailspotTests` green; deployed to device.

## 2026-06-29 — Collection economy re-balance + route data (Bet B #4/#6/#7, Phase 1) — branch `feat/collection-economy-reveal`

Phase 1 of the Collection-economy redesign (design walk-through in `docs/plans/2026-06-28-002…004`; plan `2026-06-29-002`). 7 implementation units, all green on iOS + backend, committed. **Decision 3 — the trophy/medal rework + the full guess-the-type mechanic — is deferred.** The leaderboard-moving prod re-score is gated on Noah.

- **Re-tier (U1 + military pass):** rewrote `tools/generate-aircraft-types.py` to a 2025-26 fleet-grounded tier list — **all military is now epic-or-legendary** (transports/tankers/patrol/trainers + helis incl. Apache/Black Hawk/Osprey at epic; combat jets — fighters, A-10, MiG/Su/Rafale/Typhoon/Tornado — plus bombers, AWACS/command, recon & icons at legendary; nothing military below epic), vanishing airliners + rare narrowbodies (A318·737-200 epic, 727 legendary, A340·717·MD-80·Fokker·BAe146 rare), a warbird/vintage layer, workhorse widebodies → common, A380 → rare, plus pin corrections (727/717/MD-80/90/MD-11/E-4/P-51). Regenerated `AircraftTypes.json` (rarity reassignments only — no name/dim drift).
- **Re-balance (U2):** points `10/25/100/500/2000` → **`10/20/50/100/500`** (flatter — Common→Epic 10× not 50×; Legendary still towers). The generator writes `scoring-points.json` as the single source; iOS `Rarity.basePoints` and backend `POINTS` are each pinned to it by a parity test (`ScoringPointsParityTests` + `points.parity.test.ts`), so the profile-vs-leaderboard drift class can't recur. `CURRENT_SCORING_VERSION` → 2.
- **Consolidation (U3, U4):** the no-typecode rarity fallback resolves to a flat `.common` — the string classifier no longer carries a divergent rarity ladder (TYPE only); `CardSetEntry.rarity` derives from the table for typecoded entries (drift-proof).
- **First-of-type (U5):** a device's first-ever catch of a typecode earns +50% of base, server-authoritative (frozen `first_of_type` flag, migration `0005`), echoed as `firstOfType` in the catch response.
- **Route (U6, U7):** adsb.lol route via the `routeset` endpoint → additive `route?:{originIcao,destIcao}` on `/v1/aircraft` (resilient, non-blocking, cached); iOS decodes it and freezes `originIcao`/`destIcao` on the `Catch`.

**Gated on Noah, in order:** apply migrations `0004`+`0005` to prod → re-ingest the regenerated `AircraftTypes.json` into `typecodes` (so prod tiers match) → deploy backend to Fly → `npm run rescore -- --dry-run` (review the leaderboard delta) → `rescore`. iOS reaches testers via the next TestFlight build. Phase 2 (the reveal + the route-guess bonus round) is next.

## 2026-06-27 — Fix Profile panel open/close freeze — branch `fix/profile-open-close-freeze`

The Profile sheet froze for a beat on both open and close ("frozen, then jumps").
Root cause was a synchronous main-thread block while building `ProfileScreen`, not
anything in the AR/camera/replay path: `stats` and `inputs` were **computed
properties** (`{ ProfileStats(catches:) }` / `{ Trophies.inputs(from:) }`) that
re-ran on every access, and the body accessed them many times over — `statsRow`
filtered the whole trophy roster, re-deriving `inputs` across all catches once *per
trophy*, and `rarityStrip` read `stats` inside two per-tier loops. On a 50–200 catch
Hangar that was thousands of `resolvedRarity` + `Calendar` passes each time the sheet
built or tore down.

- **`ProfileScreen`** now computes `stats` and `inputs` **once** at the top of `body`
  and threads them into `identityHeader` / `statsRow` / `rarityStrip` (converted from
  computed-property sections to functions taking the precomputed values). Behaviour is
  identical — same numbers, one O(n) pass instead of O(n × roster). No data/schema
  change. Field-confirmed snappy on device.

`TailspotTests` green.

## 2026-06-27 — Analytics consolidated onto the PostHog SDK (one pipeline, one identity) — branch `fix/analytics-sdk-consolidation`

Killed the dual analytics pipeline that fragmented one device into multiple
PostHog persons. The app had been running TWO pipelines: a hand-rolled SDK-free
REST pipeline (`Analytics.swift`, `$lib=tailspot-ios`) for product events, AND
the PostHog SDK (`$lib=posthog-ios`) for session replay — each with its OWN
identity. The REST path minted a *local* device id and let registration swap it
to the server id with nothing aliasing the two, while the SDK's call-once
`identify()` could pin to that pre-registration local id. Result: `app_opened` /
`handle_claimed` / `leaderboard_viewed` landed on a server-id person while
session replay + the handle landed on a *separate* local-id person (e.g. one
device = a `mach_6415` person + an unnamed `e28e8d13…` person).

- **`Analytics.swift` is now a thin facade over `PostHogSDK.shared`** behind an
  `AnalyticsSink` seam (tests inject a recording fake). The REST queue /
  transport / batch encoder / `distinctId` are gone. Same `capture(_:_:)` call
  shape and event names, so funnels are unaffected (events just move from
  `$lib=tailspot-ios` to `posthog-ios`).
- **One identity, never swapped.** The SDK owns the anonymous distinct_id from
  first launch; `TailspotAccountClient.ensureRegistered` calls
  `Analytics.identify(serverDeviceId)` once, so PostHog natively aliases the
  prior anonymous activity into the server-id person. `DeviceID` stays the
  backend device id (the value we identify to); its local-minting `current()`
  now has **zero production callers** — the app never invents a local id.
- **Handle-claim de-duped.** The old two-event dance (`handle_claimed` REST +
  `handle claimed` SDK to `$set` the handle) is now one
  `Analytics.identify(id, handle:)` + one `handle_claimed` event.
- `PostHogSessionReplay.start()` (SDK + replay config) is unchanged; it just
  routes its launch self-heal identify through `Analytics.identify`.
- Tests: `AnalyticsTests` rewritten for the facade; `AnalyticsIdentity` /
  `DeviceID` / `CatchTelemetry` suites unchanged. Full `TailspotTests` green.

Already-split persons are **not** fixed by the code (the SDK's call-once
identify won't move a live identity) — those are cleaned up separately via
`$merge_dangerously` (see PLAN §9).

The custom **`app_opened` event was dropped** in favor of the SDK's lifecycle
`Application Opened` (kept ON for session-replay flush; carries `$app_version` /
`$app_build` automatically), so there's now exactly one app-open event instead
of two. Five saved insights were repointed `app_opened → Application Opened`:
*Daily active users*, *Weekly user retention*, *User lifecycle (growth
accounting)*, *Key engagement events*, and *App opens by version* (its breakdown
moved from our `app_version` prop to the SDK's `$app_version`).

## 2026-06-27 — Leaderboard under-scoring fix + re-scoring foundation — PRs #79, #81

Triage of a real bug — `@noah`'s profile showed **2715** points, the leaderboard
**940** — that turned into the foundation for the #4 / #10 scoring rework. Shipped
to `main` and the backfill applied to prod the same day.

- **Root cause (prod-confirmed):** the backend freezes `catches.points` at upload
  (`resolveRarity`: `icao24 → registry → typecode → typecodes → rarity`). The
  registry was FAA **US-tails-only** when most catches were uploaded, so every
  *foreign* airliner resolved to unknown → the **10-pt floor** and stayed frozen
  there (21 of `@noah`'s 67 catches, including **three A380s**). The iOS profile
  recomputes rarity *live* from the bundled `AircraftTypes.json`, so it already
  showed the right number. Re-resolving against today's (now-grown) registry:
  **940 → ~2755 ≈ the profile's 2715** — the profile was right; the board
  under-counted. Not a device split (one device) and not the board re-tiering
  itself (its frozen sum == its live recompute).
- **Fix — points are a re-derivable PROJECTION, not a frozen fact (option A):**
  - `catches.scoring_version` column (migration `0004_useful_chimera`) stamps the
    scoring regime; `CURRENT_SCORING_VERSION` in `catches/points.ts` (bump on any
    scoring-logic change).
  - ONE canonical scorer `CatchStore.scoreCatch` — upload AND re-score both call
    it, so they can never drift. The upload route stops resolving + scoring inline.
  - Idempotent, dry-runnable `rescoreCatches` (`catches/rescore.ts`,
    `npm run rescore -- [--all] [--dry-run]`): re-scores the *stale* set (rarity
    still null OR `scoring_version < CURRENT`), one resolve per airframe, in a
    single transaction, printing a before→after delta + rarity transitions so a
    public-board move is reviewable before it lands. 6 new tests.
  - **iOS:** the Profile headline now reads the server's authoritative standing
    (`/v1/leaderboard` `me` → total points **and** the previously-placeholder
    global rank), falling back to the local Hangar total when offline — so profile
    and leaderboard agree by construction.
- **Applied to prod (2026-06-27):** migration `0004` applied manually (+ repaired a
  pre-existing journal drift — `0003` had never been recorded in
  `drizzle.__drizzle_migrations`; the journal now lists all 5). Backend deployed,
  then `rescore` corrected **24 of 29 stale catches** board-wide: **`@noah` 940 →
  2755** (now == his profile), the 3 A380s → epic, other testers' foreign widebodies
  fixed; up-only, nobody lost points; 5 unresolvable airframes stay at 10.
- **Follow-up (PR #81):** the `rescore` CLI lingered after printing (the pg pool kept
  the event loop alive); added `closeDb()` so the one-shot script exits cleanly. The
  iOS profile change is on `main` but reaches testers only on the next TestFlight build.

Backend: typecheck + 28 tests + lint green. `TailspotTests` green.

## 2026-06-26 — Sync the claimed handle to the canonical person on launch — branch `fix/posthog-handle-launch-sync`

Follow-up to #76. That fix re-aligned the person *id* on launch but not the
`handle` person property — which is only `$set` at claim time (OnboardingFlow /
SettingsScreen). So a canonical person missing the handle (claimed on a
since-merged anonymous profile, or an older build) never re-acquired it just by
reopening the app.

- **`PostHogSessionReplay.start()`** now passes the on-device handle into the launch
  `identify(_:userProperties:)` for a returning, claimed-handle user, so the handle
  re-attaches to the canonical person every run. posthog-ios (3.60.1) `$set`s the
  property even when the distinct_id is unchanged and **dedupes an identical repeat**,
  so this is idempotent self-heal, not event spam. New pure
  `AnalyticsIdentity.launchUserProperties(handle:placeholder:)` (same claimed-handle
  gate as `launchIdentity`) + 3 tests.

`TailspotTests` green.

## 2026-06-26 — Analytics integrity: identity dedup + aircraft detail on `catch_uploaded` — PRs #75, #76

Two analytics-quality fixes plus a one-time PostHog data cleanup. The PRs touch
disjoint files (#76 deliberately left `Analytics.swift` to #75), so they landed
independently.

- **Aircraft detail on `catch_uploaded` (PR #75).** The event sent only
  `rarity`/`points`/`duplicate`, so PostHog couldn't say *which* plane was caught.
  Added `icao24`, `registration` (tail), `typecode`, `manufacturer`, `model`,
  `operator_name`, `aircraft_type`, `category`, `callsign`, `place_name` — built in
  the existing pure `CatchTelemetry.uploadedProperties(...)` (off-MainActor, unit-
  tested) rather than inlined at the callsite. Nil/blank fields omitted (trimmed,
  blank-is-absent); no coordinates or user PII; rarity still prefers the server value.
  4 new tests.
- **Pre-identification identity split (PR #76).** Root cause: on a fresh install the
  PostHog SDK `identify()`'d with a throwaway *local* UUID before the server device-id
  existed, then `ensureRegistered()` overwrote the device-id with the server's — so SDK
  events (handle) and REST events (`catch_uploaded`) split across two person profiles.
  Fix: identify only once the server id exists (`DeviceID.currentIfPresent()`, never
  mints), identify right after a handle is claimed, and fire `app_opened` after
  registration. New pure `AnalyticsIdentity` decision helpers (`launchIdentity` /
  `isClaimedHandle`) + tests. Prevents all future fragmentation.
- **One-time dedup (data, not code).** Merged 6 high-confidence pre-identification
  duplicate person pairs in PostHog via `$merge_dangerously` (incl. the reported
  `purple_hour`/anonymous pair) — each verified against production by distinct_id↔person
  mapping + same-second app-open device coincidence before writing. 11 lower-confidence
  pairs (mostly iCloud Private Relay / Cupertino, no coincidence proof) left for manual
  review.

`TailspotTests` green in CI on both PRs.

## 2026-06-26 — Clear two Xcode Cloud build warnings — branch `fix/build-warnings`

Surfaced by the first Xcode Cloud (TestFlight) build after the portrait + visual-
confirmation rounds:

- **Dropped `UIRequiresFullScreen` from `Info.plist`.** Added in the portrait-lock
  round as the (then-)required companion for a portrait-only universal app; Apple
  deprecated it in iOS 26 and ignores it (deployment floor is 26.2), so it only
  emitted a warning. The portrait lock is unaffected — `UISupportedInterfaceOrientations`
  is what actually pins the UI.
- **Marked `extension SkyFeatures` (frame extraction) `nonisolated`.** Under
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` the extension was implicitly MainActor-
  isolated, so calling `SkyFeatures.extract` from the nonisolated camera-queue path
  (`VisualConfirmationPipeline.ingestFrame`) warned about a cross-actor call. `extract`
  is pure pixel math — `nonisolated` is correct. (The CLAUDE.md "extensions don't
  inherit isolation" trap, in the wild.)

No behavior change; `TailspotTests` green, Release device build clean.

## 2026-06-26 — Visual confirmation go-live — branch `feat/visual-confirmation-golive`

Turned on the on-device airplane detector (YOLOX) that snaps the AR aiming
reticle onto the real plane in the camera, correcting compass wobble. It was
fully built and running in DEBUG; this ships it to testers. **Ship-and-learn,
not gate-and-wait** (Noah's call) — same posture as the authenticity gate.

- **Flipped the Release default ON.** `VisualConfirmationPipeline.defaultEnabled`
  was `#if DEBUG true #else false`; now unconditionally `true`. The debug overlay
  can still toggle it off on a dev build; production has no user-facing toggle.
- **Catch-time telemetry** so the rollout is measurable, not vibes: `catch_performed`
  now carries `visual_confirm_enabled`, `visual_fix_active`, and `visual_fix_confidence`
  — i.e. of catches, how often the detector was actually locked on, and how
  confidently. This is the wild "is it helping?" signal (parallel to the gate's
  `catch_gate_override`).
- **YOLOX Apache-2.0 attribution** added to the Attributions page
  (`web/public/attributions.html` + `docs/legal/attributions.md`); also dropped the
  now-stale OpenSky entry (removed in the 2026-06-21 cutover). **The web deploy is
  a separate Fly step — Noah's call.**
- **Why it's safe to just flip:** worst case the detector finds nothing and the
  bracket falls back to the geometric prediction — it never blocks or alters a
  catch. Evidence: ran the shipped model on the curated test set + real field
  crops — reliable (0.76–0.94) on planes large-in-frame, no-ops on distant specks
  (the documented size cliff). The native-res crop around the predicted spot is the
  mitigation that keeps closer planes in the model's reliable range.

Full `TailspotTests` green; Release device build clean. Rides the next TestFlight
build alongside Bet A + the portrait lock.

## 2026-06-26 — Lock the app to portrait only — branch `feat/portrait-only`

Small, surgical change bundled into the next TestFlight build. `Info.plist`
`UISupportedInterfaceOrientations` (and `~ipad`) are now **Portrait only**, plus
`UIRequiresFullScreen = YES`. No upside-down: the identify engine assumes an
upright portrait hold (`LocationManager.headingOrientation = .portrait`; camera
elevation = `90° − pitch`), so landscape/upside-down would break heading + elevation.

- **Why the plist, not code:** locking the supported-orientation set is the robust,
  app-wide way to stop iOS rotating the UI — no per-view orientation handling needed.
  A source grep found **no** orientation-adaptive UI code to remove (the only
  `landscape` hit is `CameraPreview.swift`'s note about the *sensor's* native buffer
  orientation, which is unrelated to UI rotation and untouched).
- **`UIRequiresFullScreen`:** required on this universal target (`TARGETED_DEVICE_FAMILY
  = "1,2"`) — an app that doesn't support all interface orientations must opt out of
  iPad multitasking or App Store validation rejects the build.
- Resolves PLAN §9 #16 (was "Deferred") as **not doing landscape** — now enforced,
  not just de-facto. Full `TailspotTests` green; Release device build clean.

## 2026-06-25 — Bet A pivot: all eggs into the indoor gate — branch `feat/bet-a-real-catch-trust`

Product calls from Noah after reviewing the rendered screens:

- **Scrapped the "is this right?" confirm/deny affordance** — removed the reveal
  prompt, the `catch_confirmed`/`catch_denied` events, and the `Catch.confirmed`
  field. Kept the passive `catch_performed`/`catch_deleted` events (a delete is
  itself a "didn't trust it" signal).
- **The gate now ships enforcing by default** — no shadow mode, no dev toggle.
  `performCatch` split into a gate check + `runCatch`; a `.notSky` verdict blocks
  with the nudge and a one-tap **"Catch anyway"** escape (fires
  `catch_gate_override`, the calibration signal). Removed the debug "Indoor block"
  row and the `outdoor_gate_shadow` event / `enforced` flag.
- **No user-facing beta toggles** (visual confirmation stays dev-only).
- **Tuned the gate thresholds against a 48-image labeled set** (24 plane/sky +
  24 interior; `tools/authenticity-gate/{tune.py,CALIBRATION.md}`). The old
  thresholds blocked only ~12% of interiors; the new fail-open knee
  (`edgeBusy 0.08`, `varianceBusy 0.0275`, `warmThreshold 0.02`) passes ~96% of
  plane/sky frames and blocks ~63% of interiors. Heuristic ceiling ~85% balanced
  on the set; a learned indoor/outdoor classifier is the path beyond that.
- **Proactive indoor hint.** The gate signal runs every camera frame, so a
  sustained not-sky read now surfaces an ambient "Maybe try looking outside 😉"
  banner (debounced ~3s, auto-clears on sky) — warning before a catch is
  attempted, complementing the catch-time block.
- **Field-test recalibration → block on warm light alone.** First on-device test:
  pointed at a plain warm-lit ceiling, no warning fired. The ceiling read
  `edge 0.02` — as *smooth as the sky* — so the "busy AND warm" rule never
  triggered (a featureless ceiling has no clutter to detect; structure can't
  separate it from sky). Only its warm light distinguishes the two. Recalibrated
  the rule to **block on warmth alone** (drop the busy requirement):
  `warmThreshold 0.04`, `lumTrust 0.12`. Now ~92% of plane/sky frames pass and
  ~67% of interiors block, including smooth/blank warm ceilings. Cost: warm/golden
  skies can false-block (recoverable via "Catch anyway"); **cool-lit interiors
  still slip through** — added a backlog item (PLAN §9 #11) for a learned
  indoor/outdoor classifier as the real fix, gated on the real-user override rate.
  New regression test `smoothWarmCeilingIsNotSky` pins the field case.

Decision: ship it enforcing and learn from real users (the override rate) rather
than gate the rollout on a formal field test. Full `TailspotTests` suite green;
Release device build clean. **Shipped to `main` 2026-06-25 via PR #70** (rebased
onto the emitter-category work from PRs #69/#71); TestFlight build remains Noah's
call.

## 2026-06-24 — Bet A: make the catch real (telemetry + v1 authenticity gate) — branch `feat/bet-a-real-catch-trust`

Executed the Bet A plan (`docs/plans/2026-06-24-001-feat-bet-a-real-catch-trust-plan.md`).
Research reframed the track: the regression bench (#2) and the visual-confirmation
pipeline (#3) were already built, so the round focused on the genuinely-new work —
catch-confirmation telemetry and the v1 "are you outdoors?" gate. Continued and
shipped 2026-06-25 (see the entry above; PR #70).

- **Catch-confirmation telemetry (U1–U2).** `catch_performed` (+ `is_duplicate`)
  and `catch_deleted` events, plus a subtle reveal-moment "is this right?"
  confirm/deny → `catch_confirmed` / `catch_denied` and an additive
  `Catch.confirmed` flag. The north-star (catch-confirmation-rate) is now a real
  PostHog funnel — it previously had no delete/mis-ID signal. Pure `CatchTelemetry`
  helper. Single-catch confirm only (multi-catch deferred).
- **v1 authenticity gate (U4–U7) — the indoor-catch fix.** New `SkyCheck` answers
  "pointed at open sky?" from frame structure + colour (night-aware — never
  brightness, so a dark night sky still reads as sky); the camera is decisive and
  **fails open** (only a confident warm-lit-interior `notSky` blocks; GPS accuracy
  is logged but never blocks on its own). Ships **shadow-mode first**
  (`outdoor_gate_shadow`, never blocks); enforcement (`catch_blocked_outdoors` + a
  friendly "head outside" nudge) is flag-gated, default **off** until validated. A
  debug-overlay "Sky gate" row flips shadow↔enforce on device. Offline validator +
  field protocol in `tools/authenticity-gate/`.
- **Visual confirmation (U8).** Kept dev-only (debug-overlay toggle) for now —
  no user-facing Settings toggle until the field gate validates it.
- **Privacy (U3).** Manifest finalized; new events ride the existing Product
  Interaction declaration (no new data type). ASC nutrition-label sync is Noah's
  manual step.
- **#2 documented shipped.** `os_log` capture is session-scoped via `LogCapture`
  (from `OSLogStore` at recording-stop); decided **not** to add an always-on log.
- **Model licensing (U10).** Bundled detector is stock YOLOX-S COCO (Apache-2.0,
  via `pixeltable-yolox`) — permissive, no AGPL issue; provenance + Apache-2.0
  compliance checklist recorded in `tools/visual-confirmation/MODEL-LICENSE.md`.
- **Remaining (Noah, on device):** run the two field gates (visual-confirmation
  ≥2× error reduction; authenticity-gate false-block check) then flip the Release
  defaults; bundle the YOLOX `LICENSE`/NOTICE + Attributions-page credit.

## 2026-06-24 — Onboarding: suggested handles are always free (PR #67)

First-run bug: the handle step offered the same four HARDCODED chips
(`spotter_42`, `blue_hour`, `approach_287`, `contrail_cam`) to every user. But
handles are case-insensitively unique on the backend, so the first person to tap
each chip claimed it and everyone after got a 409 "already taken" — the
suggestions were never available. (The in-code comment even still claimed
"handles aren't unique yet — no backend.")

Fixed on both sides (Noah's call: do both):

- **Backend — verified-free suggestions.** New
  `GET /v1/handles/suggestions?count=N` (anonymous, per-IP rate limited 30/min)
  generates aviation-themed candidates (`contrail_4821`) from a word bank
  (`identity/handleSuggester.ts`), filters them against the devices table via a
  new `IdentityStore.takenHandles`, and returns up to N (default 4, max 10) names
  free at query time. A claim can still race another device — handled by the
  existing 409 path — so this is freshness, not a reservation. No schema change
  (reads `devices.handle`), so **no Drizzle migration**.
- **Client — randomized fallback + fetch.** `OnboardingFlow` seeds the chips from
  a local randomized generator (`HandleSuggestions.swift`, mirrors the backend
  word bank) so they're never the old deterministic set even offline / before the
  backend is deployed, then replaces them with the backend's verified-free set
  when the handle step appears. A claim that comes back taken refreshes the chips.
  `TailspotAccountClient.suggestHandles` is the new client call.
- **Tests:** backend +7 (`handleSuggester` generator + `handles.route` contract,
  incl. "never suggests an already-claimed handle" and the 429 cap); iOS +6
  (`HandleSuggestionsTests` generator incl. seeded-determinism + "never the old
  set", and two `SuggestHandlesResponse` decode cases). Backend suite + full iOS
  `TailspotTests` green.
- **Deploy status:** backend **deployed to Fly.io 2026-06-24** (`tailspot-api`,
  rolling, zero-downtime) — `GET /v1/handles/suggestions` is live on
  `api.tailspot.app` and verified returning DB-checked-free names. The iOS half
  (the verified-free fetch + the randomized fallback) is merged to `main` but
  reaches testers only in the **next TestFlight build** (Noah's call); until then
  installed builds keep the old hardcoded chips, and any build degrades gracefully
  if the endpoint is ever unreachable (404 → local randomized set).

## 2026-06-24 — Foreign-aircraft metadata: kill "Unknown aircraft" (PR #65)

Field report: a caught Singapore Airlines A350 (SIA248 / `9V-SMH`) showed as
**"Unknown aircraft"** with a GA badge and +10 pts — even though the airline
("Singapore Airlines") resolved. Structural, not a one-off: in Bali / SE Asia
nearly all overhead traffic is foreign-registered, so almost every catch hit it.

- **Root cause:** the airline name resolves on-device from the callsign
  (`Airlines.swift`), but make/model came only from the backend
  `GET /v1/metadata`, which is **FAA-registry-only** and 404s for any non-US
  hex. Meanwhile adsb.lol already sends the ICAO typecode (`t`) and registration
  (`r`) in the same feed the backend polls — and the pipeline was dropping them.
- **Phase 1 — forward pass-through:** backend reads `t`/`r` → optional
  `typecode`/`registration` on `NormalizedAircraft` → `/v1/aircraft` → iOS
  `Aircraft`/`BackendAircraft` → `Catch` at catch time, feed preferred over the
  metadata endpoint (`Catch.preferredAirframeField`). The card/type/tier already
  re-derive from the stored typecode, so a foreign catch now shows the real
  model + WIDE + correct rarity at catch time. No SwiftData migration.
- **Phase 2 — heal existing catches:** gave `/v1/metadata` a global
  hex→(reg, typecode) source so existing "Unknown" Hangar catches self-correct
  on open (via the already-shipped `CatchBackfill`). Two non-destructive sources,
  both via a new `upsertRegistryFillMissing` (`coalesce(existing, incoming)` —
  never clobbers FAA's richer US data): a bulk **ADSB Exchange `basic-ac-db`**
  import (`ingest/mictronics.ts`, 615,656 airframes loaded to prod) + an
  opportunistic feed-enrich (`ingest/feedEnrich.ts`) that caches type/reg from
  each fresh position snapshot via a new `TileCache.onFreshSnapshot` hook. No
  Drizzle migration (the `registry.source` column was already a seam).
- **Backward-compatible for users on older app builds:** the wire is additive
  (the shipped `Decodable` ignores the new keys — pinned by a regression test),
  `/v1/metadata` shape unchanged (foreign hexes just return 200 instead of 404),
  no fields removed/retyped. Old builds even *gain* the heal via their existing
  `CatchBackfill`.
- **Shipped to prod:** PR #65 (CI green) merged; backend deployed to Fly.io
  (release v6, clean rolling deploy, health verified); forward fix + heal both
  verified live (incl. the exact reported airframe `9V-SMH` → "Airbus A350-900").
  Backend 182 tests; iOS `TailspotTests` green. Plan:
  `docs/plans/2026-06-23-001-fix-foreign-aircraft-metadata-plan.md`.
- **Remaining:** an iOS TestFlight build activates the catch-*time* fix for new
  catches (the heal for existing catches is already live for all users, no app
  update needed).

## 2026-06-21 — ADS-B source cutover: mock + OpenSky removed (PR #57)

Triggered by a field session in Bali where a real Citilink flight (CTV9661)
"failed to capture" and was identified as a "United Airlines B737" that doesn't
exist.

- **Root cause** (on-device replay `2026-06-21T02:14:32Z` + os_log): the app was
  in **MOCK** mode. A single tap on the debug source-row flipped Tailspot-API →
  MOCK, and once the wrench overlay was closed there was no indication you were
  seeing synthetic planes. The "United 737" was the `MockADSBSource`
  `UAL248`/`a3b15e` fixture verbatim (`BOEING 737-800 / United Airlines`). The
  fake catch saved to the Hangar **and queued for upload to the real backend**
  (`CatchUploader` had no mock guard). On the live source the real CTV9661 was
  correctly ingested (`shown=1`) but sat at bearing ~222–256° while the phone
  pointed heading 76° — off-screen behind the user.
- **Fix (per Noah: remove both, don't patch around them):**
  - **Mock source removed** — deleted `MockADSBSource.swift`, the `useMock`
    toggle, and the source-cycle UI. The replay harness covers offline testing.
  - **OpenSky removed** — deleted `OpenSkyClient.swift` and the silent
    backend→OpenSky failover (it hid backend problems mid-session). The shared
    error enum moved to `ADSBSourceError` in `ADSBSource.swift`. `ADSBManager`
    now has a single injectable `source` (`init(source:)`), no `useBackend`.
    `CatchBackfill` uses the backend client for metadata.
  - **Credential apparatus removed** — no `OPENSKY_*` in `Tailspot.xcconfig`,
    `Info.plist`, the secrets template, or `ci_post_clone.sh`. The shipped binary
    carries no extractable API secret beyond the optional PostHog key, ending the
    credential-leak surface (two prior leaks were both OpenSky).
- If the backend is unreachable, the app surfaces an error / empty sky instead of
  degrading to a sparser source — the intended trade for debugging clarity.
- Tests: full iOS suite green; removed the obsolete mock-integration test + the
  backend-toggle suite; swapped `OpenSkyClient.ClientError` → `ADSBSourceError`.
- **Follow-ups at the time:** delete the fake "United 737" catch from the Hangar
  (predates the `isMock` tag, untagged; may have hit the backend — check icao
  `a3b15e`); retire the OpenSky console credential once a cutover build reaches
  testers.

## 2026-06-21 — Trophies / achievements overhaul shipped (PR #56)

The Trophies tab rebuilt around a real **unlock moment**: `TrophyUnlockView` is a
full-screen "NEW TROPHY" celebration (cyan hex, glow + rotating ray-burst,
haptic, Reduce-Motion + VoiceOver paths) driven by `TrophyUnlockCenter` +
`UserDefaultsTrophyLedger` — the ledger records which awards have been *shown*,
so a newly-earned one is detected as a transition and fired exactly once
(commit-on-shown, seeds silently on first run so existing testers aren't flooded,
one-time "trophy case" recap on update). Fires `trophy_unlocked` /
`trophy_recap_shown` via the PostHog REST pipeline (`Analytics.swift`). The
roster is now **binary** — every achievement earned-or-not, no bronze→platinum
metals, no medals/badges split, no stat header; earned hexes render in a distinct
**cyan**. Count families split into **milestone chains** that reveal progressively
via `Achievement.prerequisite` (Centurion appears only after Catcher); two
unearned states — **visible** (real name + a quiet `62/100`) and **secret** (a
locked `???`). ~56 achievements incl. a reverse-geocoded `Catch.country` trophy
(Mr. Worldwide); 31 custom hex icons reviewable in a DEBUG `⚑ Icons` gallery.
Pure `Trophies.swift` + `TrophyBoard` filtering are unit-tested. **Deferred:**
scoring/points/rareness + medal-system rework (PLAN §9); Constellation/Quintet
stay secret-dormant until multi-catch; the catch-a-kind heuristic matcher wants
real-world tuning as catches land.

## 2026-06-17 — post-0.5.0: PostHog session replay fixed + decode fix shipped

**Post-0.5.0 maintenance release (same `MARKETING_VERSION` 0.5.0, build
auto-bumps — nothing user-visible).** Shipped on `main` via three PRs: #39
(visual-confirm decode fix), #41 (PostHog session replay, now working), #42
(manual-ship docs). Highlights of this session:

- **PostHog product events were never broken** — they flow via the SDK-free
  REST pipeline (`Analytics.swift`); "missing" events were just the Replay/
  Activity views filtering test-account devices. Confirmed live via the PostHog
  MCP.
- **Session replay now works** (`PostHogSessionReplay.swift`). Three fixes
  found by field-testing against live PostHog data: (a) **screenshot mode**, not
  wireframe — SwiftUI on iOS 26 renders blank in wireframe (posthog-ios#408);
  (b) the full-screen `.postHogMask()` on the root `CameraPreview` was blacking
  the WHOLE window (every other screen is a sheet over it) — removed, since the
  camera is a GPU surface screenshot mode can't read and renders black on its
  own; (c) `flushAt = 1` + `captureApplicationLifecycleEvents = true` fixed
  ~1-in-7 capture (short sessions never hit a flush trigger). Text unmasked
  (`maskAllTextInputs = false`) since Tailspot's text is non-sensitive game
  data; `config.debug` is DEBUG-only. **Diagnosis lesson:** prefer querying
  live PostHog (MCP) + an on-device experiment over chaining inference from
  forum posts — the "SDK bug" theory was wrong; it was our own mask + flush.
- **Decode fix (#39)** is dormant in Release (visual confirmation is
  `#if DEBUG` + off by default), so it changes nothing for testers — it's
  there for Noah's own dev builds and the visual-confirmation field re-record.

**0.5.0 is the release — backend becomes the default ADS-B source and the
Hangar is fully redesigned.** Shipped via PR #32 (the release PR — it grew
from "Sets redesign" to carry the whole 0.5.0: `feat/backend-default-failover`
was merged into it so `main` transitions `0.2.2 → 0.5.0` in one Xcode Cloud
build, no intermediate half-state to TestFlight). `MARKETING_VERSION` 0.5.0.

1. **Backend default-on with auto-failover (was `feat/backend-default-failover`).**
   `ADSBManager` now uses the Tailspot backend (`api.tailspot.app`, adsb.lol +
   MLAT) as the live source, auto-failing-over to OpenSky on backend trouble.
   Precision elevation-aware visibility (kills the MLAT firehose), podium color
   tokens. **The OpenSky secret was deliberately NOT rotated** — it's kept as
   the failover rung, so no existing tester is broken. Rotation is a future
   coordinated event (warn testers first), to happen only once adsb.lol is
   fully field-proven and OpenSky is dropped from the prod ladder. *(Superseded
   2026-06-21: OpenSky removed entirely.)*

2. **Hangar redesign (the bulk of PR #32), one card language across three tabs:**
   - **Sets** — completion-driven make/model families, ordered by % complete,
     cyan `CompletionRing` + "X of N variants"; tap a family → list of its
     models (count + most-recent) → tail cards → `CatchDetailView`. MECE
     coverage (GA props, Comac, Citation variants, …).
   - **Recent** — a chronological feed of the shared `TailCard` (photo · cyan
     callsign · airline · date · location). Tail lists lead with the **flight
     callsign**, not the N-registration; "Unknown operator" resolves/backfills
     from the callsign's ICAO prefix (`Airlines.swift`, offline).
   - **Trophies** — awards split into **MEDALS** (leveled, bronze→platinum,
     progress bar to next tier — goal-framed "→ SILVER 17/30", never "LOCKED")
     and **BADGES** (1-of-1 feats, earned/locked, no tier). 19 awards (6 new:
     Single Aisle, Frequent Flyer, Globetrotter, Set Master, Rare Hunter,
     Regular). Two-stat header ("N/14 MEDALS · M/5 BADGES").
   - Shell: segments switch via a **paged `TabView`** (kept alive, smooth);
     `TrophyView` caches each hex via `.drawingGroup()` (no blur shadow) — the
     fix for the trophies-tab compositing lag.

**Process learnings (now conventions):** (a) NEVER rebase an already-pushed
branch — merge main into the branch instead (squash-merge makes branch
history cosmetic). (b) **When iterating across branches, `git checkout` the
PR branch BEFORE editing** — editing on the throwaway `integration` branch
stranded commits off PR #32 repeatedly this session; recover via cherry-pick
or by re-pointing the tree to `integration` (the proven combination). (c)
Tests must not touch process-global state outside a single `.serialized`
owner suite (CI clones race). (d) Keychain APIs don't work in CI sim clones.
(e) Cross-file SwiftUI SourceKit errors ("Cannot find 'Catch'/'Brand'") are
cascade noise — `xcodebuild test` is the real check.

## 2026-06-11 — backend deployed + leaderboard live + field-driven visibility fix

**The backend is DEPLOYED and the social layer is live.** Two days of program
execution: `https://api.tailspot.app` (Fly.io `tailspot-api`, sjc; Postgres
`tailspot-db`; runbook `docs/backend-handoff.md` — every command verified on
the real deploy) serves positions (adsb.lol, MLAT incl.), merged metadata
(313,523 FAA tails + DOC 8643 + the WP 1.4b typecode map: 71% of US tails
resolve `source:"merged"` with clean names + rarity), anonymous identity,
catch ingestion, and the leaderboard. PRs #12–#19 landed; highlights:

1. **WP 1.7 leaderboard live (PR #16).** `TailspotAccountClient` (device
   token in Keychain — `AfterFirstUnlockThisDeviceOnly`, security-reviewed),
   handle claim wired to onboarding + Settings (409 → inline "taken"),
   `CatchUploader` backfills existing catches (`aircraft: null` → server
   verdict "unverifiable" — contract relaxed for this), real
   `LeaderboardScreen`. PublicHangarScreen REMOVED; NotificationsScreen
   reduced to one honest line (fake toggles deleted).

2. **Field-driven visibility fix (PR #17), the day's best story:** Noah
   photographed a contrail plane at Sea Ranch that never got a label.
   Replay analysis identified it as ANA179 (12.1 km cruise, slant 19.2 km,
   elevation 39.1°, bearing matching his camera within ~5°) — delivered by
   the backend, hidden by the 13 km visibility plateau. The curve gained a
   contrail segment (13 km @ 30° → 25 km @ 45°+, low-elevation half
   untouched); the photo+replay is the documented field datum in
   `ObservedAircraft.maxVisibleDistance` and `VisibilityContrailTests`.

3. **Visual confirmation camera half BUILT (PR #13, OPEN — held for Noah's
   device eyeball):** frame tap in CameraPreview (8 fps, portrait-rotated),
   `AirplaneDetector` (direct MLModel on a 640 px native-res crop around
   the predicted position), `VisualFixTracker` association, bracket
   snapping for the locked plane, 1 Hz ground-truth crop JPEGs to
   `Documents/replays/frames/` while recording. Feature-flagged: Debug ON,
   Release OFF until the field go/no-go. The combined build (this + all of
   main) is installed on Noah's phone.

4. **Observability (PR #19):** `Analytics.swift` — PostHog via plain REST
   `/batch/` (NO SDK per the no-deps rule), distinct_id = the account
   deviceId, no-op without `POSTHOG_API_KEY` (xcconfig→Info.plist, same
   flow as OpenSky creds). MetricKit subscriber logs + captures crash/hang
   headlines. AR-session events deferred until PR #13 merges (ContentView
   ownership). **Noah activation step:** create PostHog project "Tailspot",
   put `POSTHOG_API_KEY = phc_…` in `Tailspot.secrets.xcconfig`.

5. **Rarity divergences fixed (PR #18):** HUD tier now typecode-first via
   `resolveAROverlayRarity` (mirrors `Catch.resolvedRarity`); 24 of 47
   Sets-catalog entries were stale and got re-tiered, with an exhaustive
   consistency test pinning every entry to `AircraftTypes.json`.

6. **Also:** debug panel redesigned (PR #12: one OPENSKY→TAILSPOT→MOCK
   cycling source row, sections, artifacts deleted, collapsible aircraft
   list); ops runbook (PR #14); legal drafts (PR #15, OPEN — Noah must
   read; flags an OpenSky-as-fallback compliance loose end: recommendation
   is dropping OpenSky from the prod ladder after adsb.lol is field-proven).

**Process learnings (now conventions):** (a) NEVER rebase an already-pushed
branch — force-push is permission-blocked; merge main into the branch
instead (squash-merge makes branch history cosmetic). (b) Tests must not
touch process-global state (standard UserDefaults, statics) outside a
single `.serialized` owner suite — Swift Testing runs suites in parallel
and CI clones race where local runs pass. (c) Keychain APIs don't work in
CI simulator clones — probe availability and skip. (d) Don't run two
disk-heavy jobs (xcodebuild + model downloads) concurrently.

**Tests: iOS 379+ on `main`, backend 164+, all green.**

## 2026-06-10 — production v1 program: backend complete, IP scrub shipped, visual-confirmation spike

**The production v1 program (spec: `docs/superpowers/specs/2026-06-10-production-v1-program-design.md`)
went from approved to substantially executed in one day. Six PRs merged to
`main`; orchestration ran as Fable 5 designing/reviewing with Opus/Sonnet/Haiku
agents executing work packages in parallel worktrees.**

1. **Backend (Track 1) — server side COMPLETE, WP 1.1–1.5 merged.** `backend/`
   is Node 22 + TypeScript + Fastify + Drizzle, 152 hermetic tests (PGlite —
   in-process WASM Postgres, no Docker), own CI job (`backend-tests.yml`,
   path-filtered). Serves: `GET /v1/aircraft` (adsb.lol primary / OpenSky
   fallback behind a `PositionProvider` seam; 0.25° tile cache w/ single-flight
   + last-good fallback — note the review fix: the FETCH uses the expanded tile
   bounds, never the raw bbox); `GET /v1/metadata/{icao24}` (FAA registry +
   DOC 8643 merge, store-injection pattern); `POST /v1/devices` + handle claim
   + `POST /v1/catches` (server-resolved points, per-device idempotency,
   instrumented-never-enforced `validateCatch`) + `GET /v1/leaderboard`.
   Security review (Fable) fixed two real findings pre-merge: catchUuid
   idempotency was globally scoped (now composite `(device_id, catch_uuid)`,
   migration 0002) and `trustProxy` was unset (per-IP rate limit would have
   429'd globally behind Fly's proxy). NOT deployed yet — needs Noah's Fly.io
   account + hostname; WP 1.9 runbook still to write.

2. **IP scrub (Track 3) SHIPPED.** All Pokémon trademark references removed
   pre-beta: "POKÉDEX ENTRY"→"LOGBOOK ENTRY", "POKÉDEX-STYLE"→"SPOTTER SETS",
   `PokeCardView`→`CatchCardView` (file renamed), `PokePlane`→`CardPlane`,
   `PokeSet*`→`CardSet*`. 321 tests stayed green; zero `poke` grep hits.

3. **Visual confirmation (Track 2 Stage 2a) — pre-camera stack done on branch
   `feat/visual-confirmation-spike`** (NOT merged): YOLOX-Small COCO → CoreML
   INT8 (9.2 MB, Apache-2.0-clean via the Pixeltable fork; conversion pipeline
   + REPORT.md under `tools/visual-confirmation/`), Swift decode+NMS port
   (`AirplaneDetectionDecoder`, 18 tests), and `VisualFixTracker` (gated
   association + EMA-smoothed offset, 11 tests; branch suite = 350). KEY
   FINDING: COCO-pretrained detection dies under ~15–20 px, so the design
   (SWIFT-DESIGN.md) detects in a **640 px native-resolution crop centered on
   the ADS-B-predicted position** — recovering the ~6× apparent size lost to
   full-frame downscale. Remaining: camera frame tap, MLModel crop pipeline,
   bracket wiring, replay fields + 1 Hz crop JPEGs, then Noah's field session
   for the go/no-go.

4. **Process findings (need Noah):** (a) **`main` has NO branch protection** —
   no classic protection, no rulesets — despite CONTRIBUTING.md documenting an
   enforced Unit-tests gate from 2026-06-09. Restoring it is a repo-settings
   change the permission classifier blocks Claude from making; same for
   enabling repo auto-merge. (b) One merge (PR #7) went in while its
   final-commit checks were still registering (local verify was green; post-
   merge CI confirmed green). (c) A disk-full incident killed two agents
   mid-task (recovered, no loss); macOS later reclaimed purgeable space —
   118 GB free now.

5. **Pre-cutover requirement discovered in review (WP 1.4b, tracked):** the
   FAA ingest yields NO ICAO typecode (MASTER.txt doesn't carry it), so
   production metadata would serve raw ALL-CAPS names — a regression vs the
   bundled-FAA path (iOS naming keys on typecode). An MFR-MDL-code → ICAO
   designator enrichment must land before the WP 1.8 cutover.

**Tests: iOS 321 on `main` (350 on the spike branch); backend 152.**

## Current state (as of session ending 2026-06-11 [WP 1.7: leaderboard live, account client, catch upload pipeline — PR #16 open])

**WP 1.7 is complete on branch `feat/leaderboard-live` (PR #16, awaiting
security review + merge). Prior agent crashes left uncommitted work in the
worktree; this session verified, committed, and extended it.**

1. **Backend Part 1 (verified + committed):** `POST /v1/catches` now accepts
   `aircraft: null` for pre-WP-1.7 iOS catches that never recorded the
   aircraft position. Migration `0003_sticky_spyke.sql` drops `NOT NULL` from
   `aircraft_lat/lon/altitude_meters`. Verdict is `"unverifiable"` but catch
   is scored normally from icao24. `Catch.swift` gains optional `serverUuid` +
   `uploadedAt` (additive, lightweight migration). **164 backend tests green.**

2. **iOS Part 2 — `TailspotAccountClient.swift`:** `nonisolated struct`
   mirroring `TailspotBackendClient` conventions. `ensureRegistered()` →
   `POST /v1/devices`, token to **Keychain** via `KeychainStore`
   (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`),
   deviceId to UserDefaults. `claimHandle()` → `PUT /v1/devices/me/handle`,
   409 → typed `AccountError.handleTaken`. `uploadCatch()` → `POST /v1/catches`
   with `aircraft: null`. `leaderboard()` → `GET /v1/leaderboard`, bearer when
   available. Base URL injectable for tests.

3. **iOS Part 3 — `CatchUploader.swift`:** `@MainActor` class,
   `uploadPending(context:)` fetches `uploadedAt == nil` rows, assigns
   `serverUuid` lazily (once set, never regenerated — same UUID retries
   for server-side dedup), uploads sequentially; failure leaves row pending.
   `TailspotApp` hooks `scenePhase → .active` to fire it on every foreground
   transition. Per-catch immediate upload is a PLAN §9 follow-up.

4. **iOS Part 4 — UI:** `LeaderboardScreen` → live data (loading / error /
   empty states, pull-to-refresh, podium for top 3, highlighted "me" row
   works handle-less with a "claim a handle" hint), `ComingSoonBanner` removed.
   `PublicHangarScreen` + its `NavigationLink` removed (backend not ready).
   `NotificationsScreen` → one honest "coming after launch" info section; 9
   fake `@AppStorage` toggles removed. Onboarding step 3 and Settings handle
   field both call `claimHandle` on the backend; 409 → inline "taken" error;
   non-fatal network failures persist locally and continue.

5. **iOS Part 5 — tests:** 28 new Swift Testing tests. `KeychainStoreTests`
   (save/load/overwrite/delete/multi-account isolation). DTO decode fixtures
   for `UploadCatchResponse` (fresh + duplicate), `LeaderboardEntry`,
   `LeaderboardResponse` (with/without me, empty), `UploadCatchRequest`
   encoding (aircraft key present as JSON null). `CatchUploaderTests` via
   injected `FakeUploadClient` (success/failure/duplicate/partial/registration-
   abort/uuid-stability). `CatchMigrationAdditivityTests` (new fields nil by
   default, round-trip persists). **349 iOS tests, 0 failures** (was 321).
   **164 backend tests, 0 failures** (unchanged).

**Security review required before merge (noted in PR #16):** verify
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is correct for an
anonymous per-device credential (it is: survives restarts, doesn't migrate
to new devices via iCloud Keychain backup), and that bearer tokens only
travel over HTTPS (the default base URL is `https://api.tailspot.app`).

**Known gap carried from prior agent work:** `SettingsScreen.saveHandle()`
is called on `onSubmit` (Return key). A "Save" button or debounce would be
friendlier UX — this is a PLAN §9 polish item.

**`MARKETING_VERSION` stays 0.2.2** (no new user-visible surface shipped to
TestFlight yet — this PR targets review + merge, then a TestFlight build).

**Next up:** WP 1.4b FAA typecode enrichment (pre-cutover requirement —
see PLAN §9), then WP 1.8 cutover + OpenSky secret rotation (warn testers
first), WP 1.9 Fly.io deploy runbook (needs Noah's account/hostname).
Camera half of the visual-confirmation spike (`feat/visual-confirmation-spike`)
is parked until the cutover sequence completes.

## 2026-06-09 — activity-based rarity tiering + bizjet/regional type fix

**Re-tiered rarity by sky presence instead of curated spotter-interest, and
finished moving rarity onto the typecode-driven path (the last derived property
still using OpenSky free-text).** Driven by a user observation: a 737 MAX was
`uncommon` purely for being new (it's one of the most-seen jets), while a Phenom
300 was `common` despite being a rarely-airborne bizjet. The fix tiers by "how
many of a type are airborne at any given moment" — using global presence, not
local hub frequency, so a 747 stays special even under SFO/OAK. Spec +
implementation plan: `docs/superpowers/specs/2026-06-08-activity-rarity-design.md`,
`docs/superpowers/plans/2026-06-08-activity-rarity.md`.

1. **Typecode-driven rarity (Approach B).** `tools/generate-aircraft-types.py`
   gained `RARITY_OVERRIDES` + `aircraft_rarity()` and emits a per-typecode
   `rarity` in `AircraftTypes.json` (category default keyed on DOC 8643
   description/engine/WTC, plus a curated override table). `AircraftNaming.rarity(
   forTypecode:)` reads it, mirroring `aircraftType(forTypecode:)`. The regen diff
   is rarity-only (2612 insertions, 0 deletions — the naming audit's make/model are
   untouched). Distribution: common 2235, uncommon 340, rare 27, epic 8,
   legendary 2.

2. **`Catch.resolvedRarity` now derives live and DROPS the stored snapshot** —
   typecode → re-tiered string classifier, ignoring the stored `rarity` string.
   This is the **deliberate exception to the frozen-moment rule** (`resolvedType`
   still keeps its stored middle step): rarity floats with the table so re-tiering
   **corrects prior catches on read**, no migration. The stored `rarity` is kept
   only as an as-caught audit value. Verified every caught-data display site reads
   `resolvedRarity` (via `HangarRow.rarity` → `mostRecent.resolvedRarity` and
   `PokePlane(catchRecord:)` → `c.resolvedRarity`), so the Hangar/detail/card/
   reveal/points surfaces all show the new tier — not the stale stored one.

3. **Tier moves (user-visible):** 737 MAX `uncommon→common`; light/mid bizjets
   (Phenom, Citation, Learjet, Challenger, Falcon) `common→uncommon`; workhorse
   widebodies (A330, 767, 787, 777, A350) → `uncommon` (a step below the
   narrowbody wall, but far from rare); scarce widebodies (747, A340, MD-11) +
   heavy bizjets (G650, Global) → `rare`; super-heavy/strategic (A380, 747-8,
   B-52, C-5) → `epic`; icons (Air Force One, SR-71, B-2, U-2) → `legendary`.
   Rotorcraft → `uncommon`. The string `AircraftClassifier` was re-tiered to match
   and is now only the no-typecode fallback. Explainer (`RarityReferenceScreen`)
   reworded: "Ranked by how much each type actually flies."

4. **Bizjet + regional type-classification fix (2026-06-09 follow-on).** Root
   cause found via systematic debugging: `aircraft_type()`'s jet-fallback
   (`Jet+WTC M → narrow`, `Jet+WTC L → ga`) has no signal for non-airliner jets,
   so the whole tail relied on the hand-maintained `BIZ`/`MIL` exact-match sets —
   and ~50 bizjets + ~12 regional jets were missing, landing in narrow/ga at
   `common`. Expanded `BIZ` (Gulfstream G300–G800, Global 5000/7500/Express,
   Citation VII/Bravo/1SP/2SP, Falcon 10/20/50/6X, Learjet 23–28/70, Embraer
   Legacy/Praetor, Hawker 125/4000, Beechjet 400, HondaJet, Cirrus Vision,
   Eclipse 500, + classic JetStar/Sabreliner/Westwind/Corvette/Hansa/Jet
   Commander) and added a `REGIONAL` exact-match set (BAe 146, Avro RJ, Fokker
   70/100/F28, Dornier 328JET, An-148/158). Each verified against its DOC 8643
   `ModelFullName`. **Correct side effect:** the newly-`biz` airframes pick up the
   biz default rarity → `uncommon` (were wrongly `common`); flagship ULR
   Gulfstreams G600/G700/G800 overridden → `rare`. Eclipse 500 VLJ reclassified
   `ga→biz`. Distribution: narrow 223→176, biz 39→86, regional 40→52. Display
   path already correct (`HangarRow.aircraftType` → `resolvedType` → typecode).
   **The ~110 military jets (F-16/F-35/MiG/Su/etc.) were deliberately left
   mislabeled** — MLAT-excluded on OpenSky free tier so they almost never surface
   in-app; fixing them is low-ROI and would need a make/model heuristic (PLAN §9).

5. **Two known rarity divergences (parked, not bugs):** (a) `ContentView` line
   ~1735's live AR-overlay tier uses `AircraftClassifier.classify(...)` directly
   (string path), bypassing the typecode even when known — small divergence now
   that the string rules match the table, but the pre-catch HUD tier can differ
   from the post-catch tier for an airframe where string≠typecode. (b)
   `SetsScreen`'s `entry.rarity` is static set-catalog metadata (`Sets.swift`),
   NOT re-tiered to the activity model — the Sets browser may show a slot's old
   curated tier. Both are PLAN.md §9 follow-ups.

**Tests: 314 → 321, 0 failures** (verified green on iPhone 17 sim). New
`RarityResolutionTests` (typecode→tier for every bucket + a re-rank-on-read proof:
a Catch with a stale `.uncommon` snapshot but typecode `B38M` resolves to
`.common`) and `bizjetRarityAfterTypeFix`; new `mistypedBizjets_nowBiz` /
`mistypedRegionals_nowRegional` type suites. `GameSystemTests` / `CatchTests` /
`TrophiesTests` assertions updated for the new tiers (787/A350 rare→uncommon, MAX
uncommon→common; an `explicitRarity*` test rewritten to document that explicit
rarity is now stored-but-not-resolved).

**`MARKETING_VERSION` stays 0.2.2** (build-only bump). Per the version-bump
preference, this re-tier is a tuning of an existing system, not a new surface, so
it ships as a routine build for faster TestFlight approval. **Release note for
testers: existing catches get re-categorized — both point totals AND type
grouping.** Tiers shift (a MAX drops 25→10; a Phenom rises 10→25; a 787 drops
100→25), and the bizjet/regional type fix moves aircraft between Hangar sections
(a Citation jumps NARROW→BIZ; a BAe 146 → REGIONAL) and shifts type-keyed counts.
All expected, not a bug. Bump to 0.3.0 instead if you want testers to notice in
the version string.

## 2026-06-08 — field-fix ship: naming audit + visibility hysteresis (v0.2.2)

**Release-coordination round: bundled two field-driven fix streams that had been
sitting unshipped onto `main`, bumped to `MARKETING_VERSION` 0.2.2, and pushed for
TestFlight + `bin/deploy` to Noah's iPhone.** Both are tunings of existing
chokepoints — no new architecture. This session ran as the integrator across
several parallel work sessions: each session committed its own work (the
hysteresis stream landed on `fix/visibility-hysteresis-roll-readout`, the naming
audit was already on `main` from a prior commit), and this round merged, version-
bumped, doc-updated, and shipped once the working tree was clean.

1. **Aircraft-naming audit (was "in flight" last round, now shipped).** Commit
   `4430c39` fixes 57 DOC 8643 name mis-picks — military / foreign-licensee /
   converter / doubled strings → the recognizable civil name (e.g. H25B → Hawker
   800XP, GA6C → Gulfstream G600), each grounded in a real DOC 8643 / FAA row via
   the generator's `OVERRIDES` table. Files: `tools/generate-aircraft-types.py`,
   `AircraftTypes.json`, `AircraftNamingTests`, `GameSystemTests`. Known
   type-classification follow-up — several bizjets still typed `narrow`/`ga` — stays
   parked in PLAN.md §9 (couple it to the activity-rarity work; it changes rarity).

2. **Visibility hysteresis (AR bracket de-flicker).** A Schmitt trigger on the
   visibility distance cap: a plane already shown last frame keeps a wider cap so it
   doesn't blink off when it hovers right at the boundary (and drop the lock). New
   `ObservedAircraft.visibilityHysteresisFactor = 1.2` (~20% outer band) +
   `wasShownLastFrame` flag, applied via the shared `nonisolated
   applyVisibilityHysteresis(_:previouslyShown:)` helper. Threaded through BOTH the
   live path (`ADSBManager.reAnnotate`, carried in private `shownIcaos`) and the
   offline `ReplayAnalyzer` (carried across ticks) so the two can't drift — same
   "one chokepoint, both paths" discipline as the pinhole round. Field report
   2026-06-08: ASA733 oscillated False→True→False across consecutive ticks at the
   ~9 km cap (±0.1–1.1 km swing); the 1.2 band absorbs it while still dropping
   planes that genuinely recede. New plane must clear the *inner* cap to appear.

3. **Gravity-roll debug readout (`ContentView`).** A debug-overlay readout of the
   gravity-derived roll (behind the debug wrench), to eyeball the pinhole camera
   basis in the field. Debug-only; no production-surface change.

**Tests: 307 → 314, 0 failures** (verified green on iPhone 17 sim before push). New
`VisibilityHysteresisTests` (5: appear/stay/drop state machine end-to-end + helper
stamps `wasShownLastFrame` from the prior shown set).

**`MARKETING_VERSION` 0.2.1 → 0.2.2** (user-visible: recognizable aircraft names +
AR labels stop blinking at the distance edge).

## 2026-06-08 — 3D pinhole projection for AR label placement (v0.2.1)

**3D pinhole projection landed; device-verified by Noah; on `main` as
`MARKETING_VERSION` 0.2.1.** Replaces the separable tan projection in
`Geo.screenPosition` — which treated screen-x (from bearing delta) and screen-y
(from elevation delta) as independent — with a proper pinhole camera that couples
azimuth and elevation and honors device **roll**. This fixes the documented
systematic label offset (the "~1/cos(camElev) horizontal exaggeration", ~25% at
40° camera elevation) that was PLAN §9 #3's "cheaper partial step". The random
component (compass wobble) is untouched — that's the later Vision/ML half of #3.
Spec: `docs/superpowers/specs/2026-06-08-3d-pinhole-projection-design.md`.

Architecture principle: **all AR placement funnels through one chokepoint
(`Geo.screenPosition`), so the fix reaches the live overlay, lock-on, tap-to-ID,
multi-catch capture detection, and offline `ReplayAnalyzer` at once.** The camera
orientation is derived from the **gravity vector + heading** (consistent with the
gravity-based `cameraElevationDeg`; never the gimbal-flaky Euler roll).

1. **Pinhole core (`Geo.swift`).** New `Geo.CameraBasis` (forward/right/up world
   ENU unit vectors via `SIMD3<Double>`), two builders — `cameraBasis(headingDeg:
   cameraElevationDeg:rollDeg:)` and `cameraBasis(gravityX:Y:Z:headingDeg:)` (derives
   camEl + roll from gravity, delegates) — plus `rollDeg(gravity:)` and the pinhole
   `screenPosition(...basis...)`. The old scalar `screenPosition(...phoneHeadingDeg:
   cameraElevationDeg:rollDeg:...)` now builds a basis and delegates, so it gains the
   coupling fix + a `rollDeg` param while the existing `GeoTests`/`ClosestTargetTests`
   invariant net stays green unchanged (the regression proof that the common case
   didn't move). Builds for arm64 device.

2. **Roll threaded through every consumer.** `ObservedAircraft.screenPosition`
   gains a `CameraBasis` overload (built once per frame, then 3 dot products per
   plane); `closestTargetIcao24`/`icaosInZone` take `rollDeg` and build the basis
   once so lock-zone geometry matches label placement; `ContentView` builds the
   basis from the live gravity vector each frame and forwards roll to `handleTap`;
   `ReplayAnalyzer` derives roll from the recorded gravity vector when present, else
   falls back to roll = 0.

3. **Replay format additions (additive/optional, the `zoomFactor` pattern).**
   `SensorSnapshot` gains `gravityX/Y/Z: Double?` (lets future recordings
   reconstruct the exact live basis); `TapPin` gains `x/y: Double?` (pixel-exact
   tap ground truth for projection + the future visual-confirmation work).
   Synthesized `Codable` omits nil, so pre-existing recordings decode unchanged.
   `recordReplayTick` records gravity; `recordTapPin(tapPoint:)` records the tap.

4. **Verification.** Correctness is proved by analytic unit tests (basis-builder
   absolute correctness vs known poses; self-checking coupling identities —
   level-x == old separable x, level-y == old-y/cos(dB); the 302.16px
   horizontal-compression anchor; gravity-roll sign). No strong *offline* ground
   truth exists (committed `replays/*.jsonl` have no tap-pins), so the on-device
   eyeball was the acceptance gate — **passed** (roll glues correctly, overhead +
   corner planes sane). Future pin-protocol recordings now carry gravity + tap-xy
   for pixel-exact replay validation.

**Tests: 287 → 307, 0 failures.** New `CameraBasisTests` (16) + integration tests
in `ReplayAnalyzerTests` (roll plumbing) and `ReplayRecorderTests` (gravity +
tap-location round-trip, nil back-compat).

**`MARKETING_VERSION` 0.2.0 → 0.2.1** (user-visible AR accuracy: labels track the
real plane far better at elevation and under roll).

## 2026-06-07 — Aircraft-identity overhaul: classification, FAA fallback (v0.2.0)

**Shipping as TestFlight v0.2.0.** Built on the 2026-06-06 naming/catch-detail
work (ICAO DOC 8643 table, `AircraftNaming`, Catch schema +5 fields, `CatchDetailView`
AIRFRAME panel + delete). Field testing and a full data audit exposed a second
layer of problems: the DOC 8643 table had messy manufacturer strings, `AircraftType`
classification was broken for rotorcraft and GA, OpenSky 404s for US aircraft
left entire class of airframes unresolved, and the replay recorder was silently
recording only the filtered-visible subset (defeating the ReplayAnalyzer when
visibility filtered everything out). All fixed. Architecture principle established:
**every derived property (canonical name + aircraft type) resolves from the ICAO
typecode through authoritative reference data — DOC 8643 for names, DOC 8643
description/engine/wake for type — never from OpenSky's free-text fields; a
collection-wide background backfill (`CatchBackfill`) ensures old catches carry
a typecode.** Key files: `AircraftNaming.swift`, `CatchBackfill.swift`,
`IcaoRegistry.swift`, `FAARegistry.swift`, `ReverseGeocode.swift`; bundled
resources `AircraftTypes.json`, `faa-aircraft.bin`, `faa-models.json`; generators
`tools/generate-aircraft-types.py`, `tools/generate-faa-registry.py`; reference
data `tools/data/faa_aircraft_characteristics.xlsx`.

1. **Canonical-manufacturer normalization + FAA cross-check in the generator.**
   `tools/generate-aircraft-types.py` now normalizes messy OpenSky/DOC 8643 make
   strings to clean brand names ("Gulfstream Aerospace"→"Gulfstream",
   "Canadair"→"Bombardier"), strips doubled-brand model prefixes, and cross-checks
   ~5 military/conversion mis-picks against the committed FAA Aircraft
   Characteristics Database (`tools/data/faa_aircraft_characteristics.xlsx`). FAA
   wingspan/length data carried into ~92 entries as bonus metadata. `OVERRIDES`
   table extended accordingly; regeneration is idempotent.

2. **Airbus engine-variant collapse + Boeing 737 MAX short-codes in
   `AircraftNaming.cleanedModel`.** Engine-suffix variants collapse to family
   names ("A380-842"→"A380-800", "A321-271NX"→"A321neo"). Bare OpenSky model
   strings "737-8" / "737-9" (no typecode, no suffix) collapse to "737 MAX 8" /
   "737 MAX 9" — converging the no-typecode catch path with the typecode path.
   "737-800" NG stays distinct. Convergence pinned by parameterized tests in
   `AircraftNamingTests`.

3. **`AircraftType` classified from the typecode via DOC 8643 authoritative data.**
   `AircraftTypes.json` now carries a `type` field per entry (derived from
   DOC 8643 description + engine + wake categories). `Catch.resolvedType` reads it
   via `IcaoRegistry`. This fixes the core misclassification: helicopters (R44,
   EC35) and light GA (Cessna 172) were landing in `narrow` because the string
   classifier had no rotorcraft awareness and defaulted unknowns to `narrow`. New
   default is `.ga`; the string classifier (no-typecode fallback only) gained
   helicopter awareness. Type distribution across 2,612 entries: ga 2227,
   narrow 223, wide 61, regional 40, biz 39, mil 22. `AircraftTypeResolutionTests`
   pins every type bucket with representative icao24s.

4. **Collection-wide typecode backfill (`CatchBackfill.swift`).** On Hangar open,
   `CatchBackfill.backfillIfNeeded(in:)` fetches a typecode for every catch
   missing one (one OpenSky call per icao24, cached, fill-only-if-nil, runs in a
   background Task). Ensures the entire collection resolves through the clean table,
   not just newly caught planes. `CatchBackfillTests` covers the fill/skip
   semantics and the 404-fallback path.

5. **Sets model list sorts alphabetically** (was tail-count descending). Unknown
   bucket still forced to last. Fixes the jarring reorder on each catch.

6. **Replay recorder fix.** `ReplayRecorder.recordReplayTick` was silently recording
   only the visibility-filtered subset (`adsb.observed` post-filter), so when the
   filter rejected everything (a contrail cruising past the distance cap) the JSONL
   tick carried zero aircraft — defeating the ReplayAnalyzer's purpose. Now records
   the full annotated set before filtering. Found while diagnosing a contrail that
   was filtered as "no aircraft in range" and produced an empty replay.

7. **FAA-registry fallback for US aircraft OpenSky 404s (`IcaoRegistry.swift`,
   `FAARegistry.swift`).** US icao24↔N-number is a deterministic bit-level
   encoding; a bundled FAA snapshot (313,376 US aircraft, ~3.5 MB, binary-searched
   via `faa-aircraft.bin` + model table `faa-models.json`, generated by
   `tools/generate-faa-registry.py` from the public FAA Civil Aircraft Registry)
   supplies make/model/type when OpenSky has no record. Verified: Cirrus SR20
   (a9eefa), Embraer E175 (a8d71c), Pilatus PC-12 (a00965) recover; foreign tails
   (Korean 71c575) correctly stay unknown. Community aggregators (hexdb.io, adsbdb)
   404 the same airframes — shared OpenSky lineage, so they don't help. FAA fallback
   is wired into `CatchBackfill` as the OpenSky-404 path. `FAARegistryTests` and
   `IcaoRegistryTests` pin the round-trip encoding + lookup.

8. **ADS-B metadata sources research doc.** `docs/superpowers/research/2026-06-07-adsb-metadata-sources.md`
   documents when/how to move off OpenSky for metadata. Key findings: the baked
   single credential makes the 4,000/day quota a global bucket (exhausts at ~4
   simultaneous spotters); OpenSky terms are research-only (commercial use
   prohibited); adsb.lol (ODbL) is the one MLAT source whose license permits a
   distributed app; the planned backend is the keystone next step (fixes credential
   exhaustion + MLAT licensing + stale bundle at once). **NOT being built now —
   deferred to the backend round.** See the research doc for provider comparison
   table and decision matrix.

**Tests: 244 → 287, 0 failures.** New suites: `AircraftNamingTests` (extended),
`AircraftTypeResolutionTests`, `CatchBackfillTests`, `IcaoRegistryTests`,
`FAARegistryTests`, `ReverseGeocodeTests` (extended).

**`MARKETING_VERSION` 0.1.4 → 0.2.0** (major user-visible surface: standardized
aircraft identity + authoritative classification + catch-detail overhaul).

## 2026-06-06 — Naming standardization + catch detail upgrades (v0.1.4)

**Shipping as TestFlight v0.1.4.** Four user-reported problems drove
this round: (1) aircraft names were inconsistent — OpenSky raw strings
like "THE BOEING COMPANY" and customer-code variants like "737-8H4"
made sets look wrong and section headers untrustworthy; (2) Hangar sets
grouped by airline ended up with duplicates because the same type
appeared under multiple raw name variants; (3) the Unknown bucket sorted
to the **top** of the grouped list rather than the bottom; (4) the
Catch detail was missing useful information — ALT/SPD always blank, no
location name, no registration or ICAO typecode, and no way to delete a
row. Full spec: `docs/superpowers/specs/2026-06-06-plane-naming-catch-detail-design.md`.

1. **ICAO DOC 8643 table + generator.** `tools/generate-aircraft-types.py`
   fetches the official ICAO designator endpoint
   (`https://doc8643.icao.int/external/aircrafttypes`, 7,260 rows),
   reduces to one canonical (make, model) per designator (2,612 entries),
   and writes `ios/Tailspot/Tailspot/AircraftTypes.json` as a bundled
   resource. Reduction rules: most-frequent manufacturer per designator,
   shortest model string, title-case polish + Airbus hyphen fix. ~50
   human-reviewed `OVERRIDES` correct the handful of cases where
   "shortest name" picks a military designation (e.g., E145 → "C-99"
   without an override). **Full table, no corridor subset** — Noah
   explicitly chose full ICAO coverage over a US/EU cut-down. Licensing:
   factual aeronautical data; ICAO's pre-release terms pass; FAA JO
   7360.1 is the noted public-domain fallback if ICAO terms ever become
   an issue. Regeneration workflow documented in the script docstring;
   `--input` flag allows clean diffs against a saved source file.

2. **`AircraftNaming` — read-time canonical resolution.**
   `AircraftNaming.canonical(typecode:manufacturer:model:) -> CanonicalName`
   is the single entry point: typecode lookup in the bundled table wins
   outright; fallback applies string-cleanup rules (Boeing customer-code
   collapse `737-8H4` → `737-800`, idempotent on already-clean strings;
   make title-casing with aviation-specific exceptions; make-in-model
   dedupe). Architecture: raw OpenSky strings remain stored in SwiftData
   — canonicalization is read-time and pure, so classifier rule
   improvements apply retroactively to every existing catch without a
   migration. `AircraftNamingTests` sweeps the entire 2,612-entry bundled
   table for structural integrity plus the Boeing customer-code fallback
   suite (13 parameterized argument sets → 13 case executions).

3. **Sets + grouping fixes.** `HangarGrouping.key(.aircraftType)` now
   keys on the canonical `displayName` rather than the raw OpenSky model
   string — customer-code variants collapse across airlines, so UA and
   AA 737-800s share a section. `modelGroups` uses a sort key that pins
   the Unknown bucket to last position (was first). `PokeSets.matches`
   changed from intersection to UNION (raw OR canonical) — set membership
   only gains from canonicalization. `SetDetailView` and
   `ModelSlotDetailView` dropped their inline re-casing hacks (now
   redundant).

4. **`Catch` schema +5 optional fields** (lightweight migration):
   `registration`, `typecode`, `altitudeMeters`, `velocityMps`,
   `placeName`. All optional with nil defaults so existing rows migrate
   without disruption. `performCatch` populates them at save time
   (metadata.registration + metadata.typecodeIcao from `AircraftMetadata`;
   altitude + velocity from `ObservedAircraft`; placeName via a
   post-save fire-and-forget reverse-geocode).

5. **`ReverseGeocode` (new file).** `MKReverseGeocodingRequest` is the
   implementation — `CLGeocoder` is `API_DEPRECATED` at iOS 26 in the
   SDK headers, forcing the switch. **Gotcha:** `MKAddressRepresentations`
   (the MapKit successor's address model) has NO `administrativeArea`
   field, unlike `CLPlacemark`. The has-city path uses Apple's
   `cityWithContext` property (locale-aware, e.g., "Berkeley, CA" or
   "Toulouse, Occitanie") rather than assembling city + state manually.
   `ReverseGeocodeTests` verifies every placemark shape (city-only,
   country-only, city + country, nil result).

6. **`CatchDetailView` upgrades.** New place line (geocoded name if
   present, fallback to lat/lon coords). New AIRFRAME panel (REG / ICAO /
   TYPE). Red trash delete pill → confirmation alert → deletes the
   SwiftData row AND its photo file. **Backfill on open:** `CatchDetailView`
   may fill nil-only airframe fields (registration, typecode, manufacturer,
   model, placeName, operatorName) by re-fetching metadata — never
   overwrites a stored value, never touches moment-data. See "Hangar
   collection" section for the amended read-only-snapshot invariant.
   `ModelSlotDetailView` tail rows now prefer registration over hex ICAO
   when available. `HangarRecentView.performDelete` gained an
   orphaned-JPEG cleanup that the row-delete path was previously missing.

7. **`PokePlane` fixes.** Shared `altText(fromMeters:)` / `speedText(fromMps:)`
   helpers centralize unit formatting. `PokePlane.init(catchRecord:)`
   reads persisted `altitudeMeters` / `velocityMps` from the Catch row
   (previously always nil because the fields didn't exist yet — this was
   the "ALT/SPD always blank" bug). Canonical model names feed the PokeCard
   hero so cards now show "Boeing 737-800" instead of "737-8H4 (CFMI)".

**Tests: 213 → 244** (256 case executions). 30 net-new named tests:
`AircraftNamingTests` + `ReverseGeocodeTests` (new suites) + extensions
to `CatchTests`, `HangarGroupingTests`, `ADSBManagerTests`.

**`MARKETING_VERSION` 0.1.3 → 0.1.4.**

**Pending at session end:** device deploy + Noah's field-verification
checklist (canonical names on-screen, place names in catch detail, delete
flow) + merge to main. Device was unavailable for re-pair during this
session; the feature branch `feature/naming-catch-detail` is fully
tested (244/244 pass) and ready to merge when Noah re-pairs.

## 2026-06-06 — AR tracking overhaul: recall, elevation, ground-truth visibility (v0.1.3)

**Shipping as TestFlight v0.1.3.** The arc of this multi-day round: Noah
reported planes "identifying / locking on less reliably" + "labels far
off." Systematic diagnosis (git archaeology + offline replay analysis +
field recordings) found and fixed four distinct problems:

1. **Recall regression — the 2026-05-26 visibility triple-tightening.**
   20 km cap + 3° floor + 60 s freshness deleted ~73% of historically-
   visible planes (replayed against a real session). The 60 s freshness
   also interacted with 429 backoff (poll gap up to 120 s) to age out
   EVERY plane at once — the "no planes at all, restart fixes it"
   mechanism. Freshness now 150 s and **backoff-aware** (allowance grows
   by how overdue polling is; see `reAnnotate`'s `effectiveMaxAge`).

2. **Camera-elevation gimbal lock.** `90 − CMAttitude.pitch` breaks at
   the upright-portrait pose: pitch is Euler-bounded at ±90°, so tilting
   the camera below the horizon made pitch *reflect* (roll flips ±180°)
   and elevation went the wrong way — labels slid DOWN as you tilted
   down. Confirmed in a field replay (pitch peaked ~89° and bounced).
   Fixed: `cameraElevationDeg = asin(gravity.z)` — continuous through
   the horizon, roll-invariant, singularity-free. `MotionManagerTests`
   pins anchor poses + through-horizon monotonicity.

3. **Precision — ghost labels.** Solved by **the pin protocol**, the
   methodology discovery of this round: while recording a replay, the
   user tap-pins each plane they can ACTUALLY see; pins land in the
   JSONL with callsigns, so every recording becomes labeled ground
   truth. 4 sessions / 21 labeled planes produced a decisive split:
   every confirmed sighting was an airliner ≤ 8.3 km; ghosts included
   an 11 km/17.4° 737 in daylight and a 4.8 km/8° Cessna. Naked-eye
   spotting is a single-digit-km activity. The filter is now:
   - `maxVisibleDistance(forElevationDeg:)` — 4.5 km at the 1° floor
     ramping to a 13 km plateau at 30° (plateau kept for near-overhead
     cruise/contrail traffic, which no ghost observation contradicts);
   - `Aircraft.isLikelySmallAirframe` (US registration callsign pattern
     `N`+digit) **halves the cap** — GA airframes subtend ~⅓ of an
     airliner at the same distance. Separates all 21 ground-truth
     planes correctly; `ADSBManagerTests` pins every confirmed sighting
     and ghost class as regression tests. Don't re-tune without new
     pin-protocol data.

4. **`VisibilityDiagnostic` funnel + TEMP on-screen readout.** Per-tick
   counts (`fetched → onGround → stale → lowElev → far → shown`) via
   os_log + an always-visible readout strip in ContentView showing
   `air N · shown M · el E° · …` plus `ANON` / API-limit flags.
   **Deliberately ships in 0.1.3** (Release has no debug wrench;
   testers become sensors and can report the numbers). Remove after
   the TestFlight round validates the re-tune.

Also: `AspectFillTransform` marked `nonisolated` (cleared the four
Swift 6 MainActor warnings from Build 21 — would be hard errors under
Swift 6 language mode); mock templates retuned so couch-testing shows
4 visible planes + 1 deliberately-filtered far one.

**Known limitation (next round's work):** horizontal label offset.
Field-quantified: urban compass wobbles ±20° within seconds (one 165°
jump in 1 s) while CL claims ±10°, and the separable (dB,dE) projection
exaggerates horizontal offsets by ~1/cos(camElev) at high pitch (~25%
at 40°). The fix ladder: CV bracket-snap (PLAN §9 Pending #3, the real
answer) and/or proper 3D rotation projection in `Geo.screenPosition`.

**Tests: 213 pass.** `MARKETING_VERSION` 0.1.2 → 0.1.3. The replay
pull command (`xcrun devicectl device copy from … Documents/replays`)
plus offline python analysis of the JSONL was the workhorse instrument
all round — see Replay recorder section.

## 2026-05-29 — Typography + onboarding shipped (v0.1.2)

**Shipping as TestFlight v0.1.2.** Second feature drop today. The
2026-05-27 "first-tester feedback" work that had been sitting in a
local stash on Noah's machine now lands on main. Four UX fixes:

1. **"Reticles" copy dropped.** Two user-visible strings used the
   word (OnboardingFlow permissions step + HangarView empty state).
   Replaced with plainer language ("labels match the plane in view",
   "aim at a plane, then tap to catch it").

2. **Aviation typography — SF Pro + B612 Mono.** SF Pro stays for
   body/UI text (iOS-native); monospace swaps from SF Mono to
   **B612 Mono** (Airbus's open-source cockpit MFD font, SIL OFL 1.1).
   This is where the aviation feel hits hardest — callsigns, ICAO
   codes, headings, badge labels, wordmark. Files at
   `ios/Tailspot/Tailspot/B612Mono-{Regular,Bold,Italic,BoldItalic}.ttf`
   (~530KB total), registered in Info.plist via `UIAppFonts`. All
   137 ad-hoc `.system(... design: .monospaced)` callsites swept to
   `Brand.Font.mono(size:weight:italic:)` (new helper). B612 Mono
   ships in Regular + Bold only; SwiftUI weight requests map
   regular/medium → Regular, semibold/bold/heavy/black → Bold.
   `Brand.Font.wordmark` / `hudCallsign` / `hudData` retained as
   thin aliases over the helper. Process note: the perl sweep
   initially used `[^,]+?` which over-matched across `.system(...)`
   boundaries (regex spanned past `)` and ate `design: .monospaced`
   from a sibling callsite); reverted and re-ran with `[^,)]+?`.
   Document the safer form if doing any similar sweep again.

3. **Permission prompts moved into onboarding step 2.** Previously
   iOS surfaced the camera + location alerts at the end of
   onboarding when ContentView mounted — testers found the gap
   confusing. Now `OnboardingFlow.advance()` triggers
   `requestSystemPermissions()` when leaving the Permissions step,
   firing `AVCaptureDevice.requestAccess(for: .video)` plus
   `LocationManager.requestPermissionAndStart()` via a transient
   `@StateObject` LocationManager. CMMotion needs no prompt and
   stays informational on the row. ContentView still creates its
   own LocationManager later; iOS just doesn't re-prompt because
   auth state is already decided.

4. **Figure-8 calibration step removed from onboarding.** Awkward
   and rarely needed at launch. `totalSteps` dropped to 3 (Welcome
   → Permissions → Handle). The compass-warning badge in the AR
   view still opens `CompassCalibrationSheet` (with the figure-8
   animation) when accuracy genuinely degrades — same in-app
   trigger, just no upfront prompt. `Figure8Animation` struct
   retained for the sheet.

**Tests:** 176 still pass (no behavioral tests touched — the sweep
changed presentation only). Font loading is exercised by the host-
app build that runs before the test suite, so a missing or
unregistered .ttf would break the build.

**External TestFlight remains approved** (since 2026-05-26 Build 18).
v0.1.2 builds auto-approve for external testers via App Store
Connect → TestFlight → External Testing.

**MARKETING_VERSION bumped 0.1.1 → 0.1.2.** CFBundleVersion stays
at 1 locally; Xcode Cloud's `ci_pre_xcodebuild.sh` rewrites per
archive.

**Open follow-ups specific to this round:**
- Field-test the new typography on device. The B612 Mono swap is
  unmissable but its weight mapping (collapses 4 SwiftUI weights
  into 2 physical faces) may look slightly heavier than SF Mono
  did at small sizes. Calibrate if needed.
- The semantic-size patterns (`.system(.body, design: .monospaced)`
  etc.) were converted to fixed sizes (17 / 12 / 11). This loses
  Dynamic Type scaling for those few callsites. Acceptable for v0
  but worth a `Brand.Font.mono(_:weight:)` TextStyle overload if
  Dynamic Type matters later.
- `design/font-explorer.html` — side-by-side font preview built
  during the typography decision. Reference material; remove if
  it gets stale.

## 2026-05-29 — Catch-photo bracket overlay + bigger reticles (v0.1.1)

**Shipped as TestFlight v0.1.1.** First post-v0 feature drop. Two
landings on main this session, both user-visible to testers.

1. **Catch photos now show which plane you caught.** New
   `CatchPhotoComposer` (pure CG/UIKit, no SwiftUI) decodes the
   captured JPEG, runs the screen→photo pixel transform assuming
   `.resizeAspectFill` (which `CameraPreview` uses), and re-renders
   with the cyan corner-bracket box drawn at the plane's on-screen
   position at capture time. Multi-catch saves one bracket per
   plane on each plane's own photo file.

   The path is: ContentView projects every visible plane to screen
   once per TimelineView frame (`onScreenProjected: [(icao, pos)]`),
   stashes the icao→position map, and threads `screenSize` +
   `positions` through `captureBar` → `captureButton` →
   `performCatch`. At save time the loop looks up `positions[icao]`,
   builds a `CatchPhotoComposer.BracketOverlay`, and calls
   `compose(jpegData:overlay:)`. Fall-through: if compose returns
   nil (bad JPEG, zero-area screen) OR positions misses the icao
   (the plane was on-screen when the button rendered but not in
   the dict at fire time), we save the raw JPEG. No catch is lost.

   `AspectFillTransform` factored out as its own struct so the
   coordinate math is unit-testable without touching UIImage.
   Tests cover same-aspect, wide-photo crops-sides, tall-photo
   crops-top, iPhone 12MP sanity, the compose smoke path, and
   invalid-input fall-throughs (176 tests total — added 7).

2. **Bigger lock-on reticles** for alignment forgiveness. The 56pt
   pinned bracket read tight in field testing: small sensor noise
   or HFOV mis-cal pushed the plane just outside the box. New
   sizes — pinned 140, ambient 96, empty-sky center 200, photo
   overlay 140 (matches pinned so saved photos show the same
   framing). Arm length stays `max(8, boxSize * 0.22)`, so arms
   scale proportionally.

**Tests:** 176 pass (169 baseline + 7 for CatchPhotoComposer).
Reticle bumps don't touch tests — they're presentation constants.

**Doc-staleness hook now guards on main.** `bin/doc-staleness-check`
used to false-fire on feature branches (its check is HEAD-vs-
`origin/main`, which is always ahead on a feature branch even when
that branch is fully pushed to its own remote). Added a one-line
guard: `[ "$current_branch" = "main" ] || exit 0`. Feature-branch
sessions no longer get blocked by the Stop hook — doc updates
land with the merge into main, where the hook still fires.

**MARKETING_VERSION bumped 0.1.0 → 0.1.1** (two configs in
`project.pbxproj`). `CURRENT_PROJECT_VERSION` stays at 1 locally;
Xcode Cloud's `ci_pre_xcodebuild.sh` rewrites it to
`CI_BUILD_NUMBER` per archive.

**Open follow-ups specific to this round:**
- Field-test the new 140pt pinned reticle. If still too tight,
  bump further; if too loose, dial back. The photo-overlay constant
  in `CatchPhotoComposer.bracketScreenBoxSize` must stay in lockstep
  with the live `LockBrackets` size in `ContentView` so saved photos
  match what testers saw.
- The bracket's center is the *predicted* screen position (from
  ADS-B + extrapolation + projection). Eventually the long-term
  fix for "box should land on the actual plane" is CV detection
  (PLAN §9 #3 Vision + COCO airplane class) — let the bracket
  snap to the detected airplane bbox rather than the prediction.
  Until that lands, the bigger box is the cheap forgiveness.

## 2026-05-26 — TestFlight v0 prep (v0.1.0)

**TestFlight v0 prep — landed 2026-05-26.** Everything required to
build, sign, and upload a TestFlight build is in place. See
`docs/testflight-handoff.md` for the step-by-step. Highlights:

- **Credentials baked via xcconfig + Info.plist.** Tailspot.xcconfig
  (committed) `#include?`s Tailspot.secrets.xcconfig (gitignored,
  holds real OpenSky values). Build-time substitution flows into
  Info.plist keys `OpenSkyClientID` / `OpenSkyClientSecret`. New
  resolution order in `OpenSkyClient.init`: explicit creds → env
  vars → `Bundle.main.infoDictionary` → nil/anonymous. Env-var path
  preserves Noah's existing dev loop; the bundle path is the only
  one that survives TestFlight / home-screen / `devicectl` launches.
  **Security accepted:** the values are in the shipped binary,
  extractable from any `.ipa`. v0 risk for 1-2 trusted testers;
  backend proxy is the path for wider distribution (PLAN.md §1).
- **Manual `Info.plist`** at `ios/Tailspot/Info.plist` replaces the
  previously-auto-generated one. Adds `ITSAppUsesNonExemptEncryption=false`
  and the custom OpenSky keys. The Tailspot target switched from
  `GENERATE_INFOPLIST_FILE=YES` + `INFOPLIST_KEY_*` build settings to
  `INFOPLIST_FILE=Info.plist`. The Info.plist sits at the project
  root (outside the synchronized `Tailspot/` folder) so it's not
  bundled as a duplicate resource.
- **Privacy manifest** at `ios/Tailspot/Tailspot/PrivacyInfo.xcprivacy`.
  Declares UserDefaults (`CA92.1`) + FileTimestamp (`0A2A.1`)
  required-reason API usage, and the two data categories we collect
  (precise location + photos — app-functionality only, not linked
  to identity, not tracking). Update when the backend ships.
- **Version + build number scheme.** `MARKETING_VERSION=0.1.0`,
  `CURRENT_PROJECT_VERSION=1`. Bump `CURRENT_PROJECT_VERSION` on
  every TestFlight upload (App Store Connect requires monotonic
  per marketing version); bump `MARKETING_VERSION` on meaningful
  feature drops.
- **App icon.** Programmatically generated 1024×1024 PNGs (3
  luminosity variants — light / dark / tinted) via
  `tools/generate-app-icon.swift`. Cyan→navy gradient + HangarGlyph,
  consistent with brand tokens. Re-run the script to regenerate,
  or replace the PNGs directly in `AppIcon.appiconset/`.
- **xcconfig precedence trick.** `Tailspot.xcconfig` defines
  `OPENSKY_CLIENT_ID =` (empty) as default, then `#include?`s the
  optional secrets file. Last-wins is xcconfig precedence — when
  the secrets file is present its assignments override the empty
  defaults; when missing, the empty defaults stand and Info.plist
  resolves to empty strings (anonymous mode). The `?` on
  `#include?` makes missing-file a no-error condition.

**Tests:** 169 still pass. The credential change is additive (env-var
fallback preserves existing tests that don't touch OpenSky live calls).

**Open follow-ups specific to TestFlight:**
- App Store Connect record creation, signing, Archive + Upload all
  live in Apple UIs — see `docs/testflight-handoff.md`.
- Privacy policy URL needed if/when adding external testers (>10
  beyond your team). Internal testers are sufficient for v0.

**Xcode Cloud (added 2026-05-26):** Apple's CI runs two scripts
checked into `ios/Tailspot/ci_scripts/`:

- `ci_post_clone.sh` materializes `Tailspot.secrets.xcconfig` from
  workflow env vars (`OPENSKY_CLIENT_ID` / `_SECRET`, both marked
  secret in the workflow's Environment Variables). When env vars
  are absent the script no-ops; build runs anonymous.
- `ci_pre_xcodebuild.sh` seds `CURRENT_PROJECT_VERSION` in
  `project.pbxproj` to match Apple's `CI_BUILD_NUMBER` before
  archive. Without this every CI archive shipped with
  `CFBundleVersion=1` and App Store Connect silently dropped
  subsequent uploads as duplicates — Xcode Cloud reported "build
  succeeded" while TestFlight stayed pinned to Build 1 forever.
  Local builds keep the committed value (1); only Xcode Cloud
  rewrites.

**Xcode Cloud setup gotchas that ate hours this session:**
1. Workflow's "Project or Workspace" field defaults to repo root;
   our project is at `ios/Tailspot/Tailspot.xcodeproj` — must be set
   explicitly or builds fail with the misleading "scheme Tailspot
   does not exist" error.
2. Workflow needs a TestFlight distribution **Post-Action**
   ("TestFlight Internal Testing"), separate from the Archive
   action. Without it, the archive succeeds but never reaches
   TestFlight.
3. Don't put trailing whitespace/newlines in env-var values; App
   Store Connect's UI rejects with "invalid value due to invalid
   value" without saying which character offended.

**Post-TestFlight polish landed same day (2026-05-26):**
- App icon swapped from the generated HangarGlyph-on-gradient to
  the B-lockon concept (cyan AR corner brackets framing a white
  airplane symbol on a navy gradient — references the AR mechanic).
  Generator: `tools/generate-icon-options.swift`. Picked variant's
  three PNGs (light/dark/tinted) committed in `AppIcon.appiconset/`;
  `tools/icon-options/` is gitignored.
- `ComingSoonPill` + `ComingSoonBanner` components (`ComingSoonPill.swift`).
  Applied to Leaderboard, Public Hangar, and Notifications screens
  with amber `hammer.fill` glyph so testers know these are mocks
  pending backend.
- Debug wrench toggle in `ContentView` wrapped in `#if DEBUG`.
  TestFlight (Release) builds show no wrench; local Xcode dev
  (Debug) keeps it.
- 8 Swift 6 prep warnings cleared (Log isolation, PhotoCaptureDelegate
  nonisolated, HangarGrouping no longer claims nonisolated when it
  touches `@MainActor Catch` state, MultiCatchReveal @ViewBuilder
  drop, Trophies closure @Sendable).
- Hangar glyph swapped to SF Symbol `airplane.path.dotted` (plane
  with dashed trail). Replaces the hand-drawn peaked-pentagon Shape
  in `HangarGlyph.swift`. Callers unchanged — same `HangarGlyph(tint:)`
  API, `lineWidth` retained as unused param for source compat.
- Settings → bottom of page renders `Tailspot 0.1.0 (build N) · tap
  to copy`. Tap copies the version line to the clipboard with a
  soft haptic; testers paste it verbatim into bug reports.
