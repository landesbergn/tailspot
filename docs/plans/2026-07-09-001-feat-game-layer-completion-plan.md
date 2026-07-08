# Game-Layer Completion — Route-Guess Bonus, Guess-the-Type, Trophy Rework

**Plan** `2026-07-09-001` · type: feat · PLAN §9 #4 (Bet B · Collection) · est. ~2.5–3.5d across 6 PRs
**Closes out:** the 2026-06-29 economy plan's deferred Decision 3 + Phase 2's remaining route-guess piece; absorbs wishlist #1 (guessing), #9 (grounded-plane easter egg), #10d (medal/threshold review).
**Authority:** locked design in `docs/plans/2026-06-29-001-feat-economy-d2-reveal-prototype.html` (route-guess round is fully specified there); STRATEGY.md Bet B; CLAUDE.md conventions. User preference overrides docs on conflict.

---

## 0. Noah decisions needed (before or during — defaults proposed for all)

| # | Decision | Options | Proposed default |
|---|----------|---------|------------------|
| D1 | **Guess-round shape for TYPE** — the route-guess design is locked (own screen *before* the reveal, answer hidden, 4 options + skip, occasional). Does guess-the-type ride the same single pre-reveal round, or is it a separate/more-frequent mechanic? | (a) One shared "bonus round" screen, question kind varies · (b) type-guess on every catch, route-guess occasional · (c) type-guess lives pre-catch in the AR view | **(a)** — one interstitial, one pacing budget, one code path. (b) violates the "not a per-catch tax" call already made; (c) clutters the AR view and delays the catch itself. |
| D2 | **Bonus sizes** — route is locked at **+10% of catch points**. Type-guess size? | +10% / +25% / +50% / flat points | **+25% of base** — the marquee skill test should outpay the route coin-flip but stay below first-of-type's +50%. |
| D3 | **Cadence** — design doc locked "every ~3–5 catches, randomized" for route. Same budget for the combined round? | shared ~1-in-3 roll · separate budgets | **Shared**: one round max per fresh single catch, ~1-in-3 eligible catches, min gap 2 catches. |
| D4 | **Type-guess granularity** — exact type from 4 chips ("Boeing 737-800" vs "A320neo" vs "E175" vs "CRJ-900"), or family-level? | exact typecode · family | **Exact typecode** displayed as canonical names — multiple-choice makes exact fair, and it's server-verifiable as a string compare. |
| D5 | **Timed or untimed round?** | countdown ring · untimed with skip | **Untimed**, prominent SKIP — pacing protection comes from cadence, not a stress timer. |
| D6 | **Trophy roster changes** — sign-off on the threshold table in §C2 (new guess + points trophies, pruning candidates). Taste check: hard/rare over participation. | — | Table below; nothing removed without your call. |
| D7 | **Grounded-plane easter egg shape** — cheeky toast only on a tap near a grounded plane (no AR labels for grounded, unchanged filter), or surface grounded planes visibly? | toast-on-tap · visible labels | **Toast-on-tap** — zero visual change to the field-tuned AR view; wishlist #9's open question resolved conservatively. |
| D8 | **Trophy-case recap moment** — one-time full-screen sheet on first launch after the update ("Your trophy case — N earned"), or a quieter Hangar banner? | sheet · banner | **One-time sheet** — you asked for a recap *moment*; the reseed machinery makes it safe either way. |
| D9 | **Reveal optimism** — ledger shows the guess bonus from local truth immediately; the server may (rarely) disagree at upload (see §A4). Accept the drift? | optimistic · "pending" styling | **Optimistic** — same posture as the existing locally-derived FIRST OF TYPE line. |

---

## 1. Context — what's actually true in the repo today

Research corrections to the item as written in PLAN §9 (worth recording so the plan builds on reality):

- **The reveal is ready for the guess.** `CatchRevealView.swift` ships the split-flap + photo + counting score ledger; the file header and CHANGELOG 2026-06-30 both note "the ledger already reserves its line" for the route-guess bonus. Ledger rows are one-liner `ledgerRow(...)` calls — adding a bonus line is trivial.
- **Scoring is settled law and the seams exist.** Backend: ONE canonical scorer `DrizzleCatchStore.scoreCatch` (`backend/src/identity/store.ts`), bonus math in `backend/src/catches/points.ts` (`firstOfTypeBonus`, `CURRENT_SCORING_VERSION = 2`), frozen per-row flags (`first_of_type`, migration `0005`), idempotent `npm run rescore`. The upload path computes the eligibility flag (`isFirstOfType`) and *passes it into* the scorer — the exact pattern a guess verdict slots into.
- **The wire never trusts the client for points.** `POST /v1/catches` carries no points/rarity; the guess leg must carry the *guess value*, never a "guessedRight" boolean — the server verifies against its own truth (registry for type, `RouteResolver`/adsblolRoutes for route, both already wired in `app.ts`).
- **Uploads are deferred, not at catch time** (`CatchUploader.uploadPending` on scenePhase→active; "per-catch immediate upload" is an open follow-up). So the guess outcome must be **frozen on the `Catch` row** and shipped with the eventual upload. No race: uploads never fire mid-catch-flow.
- **iOS `UploadCatchResponse` doesn't yet decode `firstOfType`** (backend sends it). The guess response keys are additive the same way.
- **The trophy system is NOT the "19 leveled MEDALS + BADGES" of the old wishlist.** The 2026-06-20/21 overhaul (PR #56) already made every award **binary** — one flat pool of **49** achievements (24 visible incl. milestone chains w/ `prerequisite`, 18 secret), no medals/badges split, **no "started vs earned" header** (removed in the redesign), unlock moments via `TrophyUnlock` + a seeded `UserDefaultsTrophyLedger`. The rework is threshold sanity + new content + the recap moment — not a re-architecture.
- **Wishlist #10c/d rarity-bucket leftovers are already shipped** by economy Phase 1 U3/U4: live-AR rarity resolves from the typecode table (`resolveAROverlayRarity` in `ContentView.swift` ~L2624), and `CardSetEntry.rarity` derives from the table (`Sets.swift`). Only cosmetic vestige left: the classifier's unused per-rule `rarity` field (kept deliberately for pinned tests — leave it).
- **Grounded planes are invisible today**: `ADSBManager.annotate` drops `onGround` aircraft before annotation (L116), so there is currently *no* path where a user can even attempt a grounded catch — the easter egg needs a small, deliberately-hidden data seam (§C3).
- **Prod scale for threshold sanity:** 219 catches total, top user 68 catches / 1100 pts (post-rescore 2026-07-01).

**Goal.** Finish the game layer: make correct calls pay (route +10%, type +TBD), keep the field-polished catch→reveal pacing intact (guessing is an occasional treat, never a tax), and bring the trophy case up to the new economy — all inside the server-authoritative scoring regime.

---

## 2. Workstream A — the shared guess-round engine + route-guess (+10%)

### A1. Interaction (locked by the 2026-06-29 design doc, extended per D1)

Catch → *(only if scheduler fires and the catch is eligible)* → **Bonus Round screen** → reveal with the result in the ledger.

- Own full-screen step **before** the reveal; the answer (route or make/model) is hidden during the guess — you're guessing blind, then the reveal shows the truth *and* your result.
- 4 option chips + a quiet **SKIP**. Wrong or skipped → no bonus, no penalty, straight to the reveal.
- **Route kind** (locked design): "Where's it coming from?" / "Where's it headed?" — asks about the endpoint **farther from the observer** (observer lat/lon is on the catch). Chips show `HKG · Hong Kong`. Correct = the exact airport.
- **Type kind** (workstream B): "Call the type" — 4 canonical aircraft names; correct = the exact typecode.
- **Eligibility:** fresh single catches only (no duplicates — no points to bonus; no multi — `MultiCatchReveal` untouched; no suspect catches — don't stack a game on top of the post-reveal Keep/Discard question, check `suspectReason == nil`). Route kind additionally requires a frozen route on the row.
- **Cadence:** `GuessScheduler` (pure + a UserDefaults counter): roll ~1-in-3 on eligible catches, minimum 2-catch gap, never on the user's very first catch (protect activation). Kind pick: route-eligible → 50/50 route/type; else type.

Pacing guarantee (the hard constraint): most catches see **zero change**; when the round fires it's one optional tap; the reveal itself is untouched except one added ledger line. `RevealSnapshotTests`-style snapshot for the new screen + a field pass before merge.

### A2. iOS data model (SwiftData — additive, lightweight)

New optional fields on `Catch` (`ios/Tailspot/Tailspot/Catch.swift`), all nil-default:

- `guessKind: String?` — `"route"` / `"type"`; nil = round never offered or skipped.
- `guessValue: String?` — the guessed ICAO airport ident or typecode (audit + upload payload).
- `guessCorrect: Bool?` — the **local** verdict, frozen at answer time (drives the reveal ledger + trophies offline).

### A3. Wire + backend (the "don't trust the client" leg)

`POST /v1/catches` body gains an optional block:

```
guess: { kind: "route" | "type", value: string }   // the GUESS, never a verdict
```

Server side (`backend/src/routes/catches.ts`):
1. Validate shape (422 on malformed; absent = no guess).
2. **Verify server-side:**
   - `type` → compare `value` (uppercased) against the server's own `resolveRarity(icao24).typecode`.
   - `route` → `routeResolver.resolve(callsign)` (the same standing-data resolver behind `GET /v1/routes/:callsign`) → correct iff `value` matches either endpoint's ICAO ident. Resolver failure or no route on file → `guessCorrect = false` (never trust, never block the catch; log for telemetry).
3. Pass the verdict into the canonical scorer — mirroring `firstOfType` exactly: `scoreCatch(icao24, { firstOfType, guess: { kind, correct } })`.
4. Freeze onto the row; echo in the response.

`backend/src/catches/points.ts`:
- `guessBonus(base, kind)` → `round(base * 0.10)` route / `round(base * 0.25)` type (D2). Defined once, used only by the scorer.
- `CURRENT_SCORING_VERSION → 3` (the scoring logic changed; documented rule in the file header says bump).

Drizzle **migration `0006`** (additive): `guess_kind text`, `guess_value text`, `guess_correct boolean NOT NULL DEFAULT false` on `catches`. Frozen-flag semantics identical to `first_of_type`: the *verdict* is frozen (route truth is standing data and can drift; re-verifying later could flip an honestly-earned bonus), the *amount* floats with the current base at rescore time.

Response (additive keys, old clients ignore): `guessCorrect: boolean`, plus decode `firstOfType` on iOS at last (`UploadCatchResponse` in `TailspotAccountClient.swift`).

**Rescore implications, spelled out:** `rescoreCatches` already recomputes stale rows through the one scorer; extend the scorer call to read the stored `guess_kind`/`guess_correct` (as it reads `first_of_type`). The v2→v3 rescore is a **provable zero-delta** (no existing row has a guess) — run `npm run rescore -- --all --dry-run` on prod and confirm 0 before `rescore`; the bump still matters so future regime changes have an honest version history. Ops mirror of `docs/runbooks/2026-07-01-economy-leaderboard-rollout.md`: apply `0006` → deploy Fly → dry-run → rescore.

**Parity hygiene:** add a `bonuses` block to the generated `scoring-points.json` (`{ firstOfType: 0.5, routeGuess: 0.1, typeGuess: 0.25 }`, written by `tools/generate-aircraft-types.py`) and pin it in both `points.parity.test.ts` and `ScoringPointsParityTests` — today the 0.5 lives as duplicate literals in `points.ts` and `CatchRevealView.firstOfTypeBonus`; this stops the guess percentages growing the same drift class the ladder just escaped.

### A4. The honest limits (state them, don't hide them)

- **The device knows the answer** (typecode and route are on the catch row before the guess screen renders). A modified client can always "guess" right. Server-side verification kills casual API spoofing (there is no `correct:true` to send — you send a value, the server checks it), but commit-before-reveal nonces would require online-at-catch and are out of proportion for a friendly leaderboard. Consistent with the repo's "anti-cheat instrumented, never enforced" posture: emit per-device guess-accuracy telemetry (`guess_round_answered` w/ correctness) and watch for 100%-correct outliers in PostHog.
- **Client/server verdict drift**: the reveal shows the local verdict; the server verifies independently at upload (registry may lag the feed's `t`; routeset filing may change between catch and upload). Expected rare; match route on *either* endpoint to absorb the asked-endpoint ambiguity; log mismatches server-side. Profile headline already reads the server's authoritative standing, so the board is always self-consistent.

### A5. Route-guess option generation

Correct airport + 3 distractors. No airport dataset is bundled on iOS today — add a small curated `airports.json` asset (~200–300 major airports: ICAO, IATA, city, lat/lon; source from the backend's adsb.lol `_airports` shape or OurAirports public domain). Distractors picked by plausibility: same broad region as the correct answer, weighted by distance-from-observer so they aren't laughably wrong. Pure `GuessOptions` helper, seeded RNG for testability.

---

## 3. Workstream B — guess-the-type

Rides the workstream-A engine (per D1); what's specific to type:

- **Question:** "CALL THE TYPE" while the split-flap answer is still hidden. 4 chips of canonical display names (`AircraftNaming.canonical`), value = typecode.
- **Distractors:** from the bundled `AircraftTypes.json` — sample 3 typecodes sharing the catch's `AircraftType` class (narrow/wide/mil/…) and within ±1 rarity tier, so the choices are genuinely confusable ("737-800 / A320 / A220-300 / E195" — not "737-800 / B-52 / Cessna 172 / Concorde"). Never include a typecode whose canonical name collapses to the same display string as the answer.
- **Eligibility:** typecode + resolvable canonical name present (else the round can't render honest options).
- **Alternative considered — airline or rarity guesses** (wishlist #1 names all three): airline is weakly server-verifiable (operator name isn't resolved server-side today) and rarity-guessing teaches the tier table rather than plane recognition. **Recommend type-only for v1**; the `guess.kind` wire enum leaves room for `"airline"` later without a migration (columns are generic kind/value/correct).
- **Reveal integration:** ledger gains a gold `TYPE CALLED +N` / `ROUTE CALLED +N` line between FIRST OF TYPE and TOTAL; `CardPlane` gains `guessBonus: Int` (display-only, computed off the row like `isFirstOfType`). A wrong guess shows nothing (no rub-it-in line) — the guess screen itself flashes the miss before transitioning.
- **The engagement-hook telemetry Noah will want:** `guess_round_shown` / `_answered` (kind, correct, elapsed) / `_skipped` — feeds directly into catches-per-spotter analysis of whether the hook works.

---

## 4. Workstream C — trophy/medal rework

### C1. What's already done (do not redo)

Binary flat pool, secret + prerequisite mechanics, unlock moments + seeded ledger, "started vs earned" header removed, rarity single-sourcing (#10c/d). The rework is **content + thresholds + two new mechanics**.

### C2. Threshold sanity + roster pass (Noah sign-off table, per D6)

Principles from Noah's taste: hard/rare beats participation; the new economy (all-military epic+, A380→rare, flatter ladder) already made the rarity one-shots meaningfully harder — good, keep.

Proposed changes (all in `Trophies.swift` roster; ~30 min of code, the value is the judgment):

| Change | Rationale |
|---|---|
| **Add** points milestones: "Four Figures" (1,000 pts), "High Roller" (5,000 pts, prereq-chained) | Wishlist #10b — "clear running total"; needs a `totalPoints` input (base × resolvedRarity per row — offline approximation, same as profile fallback) |
| **Add** guess trophies: "Called It" (first correct guess), "Clairvoyant" (10 correct), secret "Hot Streak" (3 correct in a row) | Couples the new mechanic into progression; derivable from `guessCorrect` rows (+`caughtAt` ordering for the streak) |
| **Add** grounded-plane secret badge "Ground Stop" — *tried to catch a parked plane* | Wishlist #9, §C3 |
| **Review** "Rare Hunter 5 / Treasure Hunter 25 rare-or-better" against post-retier reality (rare+ = 116 of 2,612 typecodes but includes all military) | Likely fine; verify against prod catch distribution before touching |
| **Flag for Noah** the participation-flavored low end ("First Catch" at 1, "Plane Spotter" at 5) | Chained visibility means only one shows at a time — recommend **keep** (they serve the measured activation leak), but it's a taste call |

New `TrophyProgressInputs` fields (`correctGuesses`, `bestGuessStreak`, `totalPoints`, `triedGroundedCatch`) get defaulted initializer params — the established pattern, zero call-site churn.

### C3. Grounded-plane easter egg (wishlist #9, per D7)

- `ADSBManager`: instead of discarding `onGround` aircraft at `annotate` (L116), annotate them into a **hidden** tier with a `grounded` flag — excluded from labels, catchability, and the tap-to-reveal path (so the six `FieldReplays/` floor assertions and the field-tuned filter are structurally untouched; add a regression test asserting grounded ⇒ never visible/catchable/revealable).
- `ContentView` empty-tap classification: when the nearest in-data plane at the tap is grounded (within the tap-reveal radius), show the playful toast — *"That one's still parked — Tailspot is for planes in the air."* — and record a one-time event.
- The badge can't derive from the Hangar (no `Catch` row is created — correctly), so it's the first **event-based** trophy: a tiny UserDefaults event store feeding the new `triedGroundedCatch` input. Keep it a single generic `TrophyEventStore` so future event badges reuse it.

### C4. One-time "trophy case" recap on update (per D8)

- Stamp the ledger with a `rosterVersion`. On first launch where the stored stamp < current: compute the earned set, present the **recap sheet** (earned trophies grid + count — reuse `TrophyView` hexes; one CTA), then `TrophyUnlock.seed` + stamp. This is the existing anti-flood seeding mechanism upgraded from "silently swallow" to "make it a moment."
- Also the safety net for C2: threshold changes can newly-earn (or un-earn — display only, ledger never revokes) trophies; the recap absorbs what would otherwise be a toast flood.

---

## 5. Data-model / wire changes (consolidated)

| Layer | Change | Migration risk |
|---|---|---|
| Postgres | `0006`: `catches.guess_kind text`, `guess_value text`, `guess_correct bool NOT NULL DEFAULT false` | Additive; journal discipline per the 0003 drift lesson |
| Backend | `CURRENT_SCORING_VERSION → 3`; `guessBonus()` in `points.ts`; scorer + `insertOrGet` + response + rescore read the new fields | Zero-delta rescore (verify via dry-run) |
| Wire | `POST /v1/catches` optional `guess:{kind,value}`; response `+guessCorrect` (and iOS finally decodes `firstOfType`) | Additive both directions; old clients unaffected (pinned by a decode regression test, the PR #65 pattern) |
| SwiftData | `Catch.guessKind/guessValue/guessCorrect` optional nil-default | Lightweight/additive — the only kind allowed |
| Assets | `airports.json` (new, ~small); `scoring-points.json` gains `bonuses` block (generator change + both parity tests) | — |
| UserDefaults | `GuessScheduler` counter; `TrophyEventStore`; ledger `rosterVersion` | — |

---

## 6. PR breakdown

| PR | Contents | Est. | Test strategy |
|----|----------|------|---------------|
| **PR1** `backend/guess-bonus` | Migration 0006, `guessBonus`, version 3, wire parse+verify (type via registry, route via `RouteResolver`), scorer + rescore extension, `scoring-points.json` bonuses block + generator + backend parity test | ~0.5d | `catches.route.test.ts`: correct/wrong/malformed/absent guess, route-resolver-down ⇒ false-not-500, either-endpoint match; `rescore.test.ts`: stored-flag recompute + v2 rows zero-delta; `points.parity` pins bonuses |
| **PR2** `ios/guess-data` | `Catch` fields, upload payload `guess` block, `UploadCatchResponse` +`guessCorrect`+`firstOfType`, `GuessScheduler`, `GuessOptions` (route + type distractors), `airports.json`, iOS parity test for bonuses | ~0.5d | `CatchUploadPayloadTests` ext; `GuessSchedulerTests` (cadence, min-gap, first-catch guard); `GuessOptionsTests` (correct included, 4 unique, plausibility buckets, seeded determinism); decode regression |
| **PR3** `ios/guess-round-ui` | `GuessRoundView` (photo-hero-consistent, chips + SKIP, miss flash), `performCatch`→`pendingGuess`→`pendingReveal` sequencing (eligibility guards incl. suspect), reveal ledger line + `CardPlane.guessBonus`, telemetry events | ~1d | Snapshot tests (guess screen + reveal-with-bonus-line via the `RevealSnapshotTests` harness); flow unit tests on the eligibility/sequencing helpers; **on-device field pass before merge** (pacing is the acceptance bar); debug `✦ Catch` button exercises the round per tier |
| **PR4** `ios/trophies-economy-pass` | C2 roster changes + new inputs (`correctGuesses`, streak, `totalPoints`), threshold adjustments per D6 sign-off | ~0.5d | `TrophiesTests` ext (roster integrity, new metrics aggregation, streak edge cases); `TrophyUnlockTests` unchanged-green |
| **PR5** `ios/grounded-easter-egg` | ADSBManager grounded-hidden annotation, empty-tap toast, `TrophyEventStore`, "Ground Stop" badge | ~0.5d | Regression: grounded never visible/catchable/revealable (FieldReplays floors untouched); toast-trigger unit test; event-store persistence test |
| **PR6** `ios/trophy-case-recap` | rosterVersion stamp, recap sheet, seed-on-update flow | ~0.5d | Ledger-version unit tests (shows once, seeds, never re-shows); snapshot of the sheet |

Sequencing: PR1 ∥ PR2 (wire contract agreed first), PR3 after PR2, PR4–PR6 independent of A/B except PR4's guess trophies (land the inputs defaulted; trophies activate as data arrives). **Noah-gated ops after PR1 merges:** apply `0006` to prod → deploy Fly → `rescore --dry-run` (expect 0) → `rescore` → runbook note. iOS reaches testers on the next TestFlight cut (also carries the still-undelivered economy/reveal client work — worth cutting soon regardless).

---

## 7. Risks

1. **Pacing regression on the catch→reveal moment** — the one thing explicitly protected. Mitigations: cadence caps (1-in-3, min gap, never first catch), fresh-single-only, untimed + SKIP, snapshot + mandatory device pass. Kill-switch: scheduler probability is one constant; a debug-panel row can force/disable rounds for field testing.
2. **Client-knows-answer cheating** — inherent (§A4); accepted per the instrumented-not-enforced posture; watch per-device accuracy in PostHog.
3. **Verdict drift (local ledger vs server award)** — rare; either-endpoint route matching + server-side mismatch logging; board self-consistent by construction (profile reads server).
4. **Route-guess starvation** — route coverage is opportunistic (adsb.lol routeset warms on later polls); type kind keeps the round alive when route is absent, and the scheduler only counts *eligible* catches.
5. **Distractor quality** — a bad option set makes the round feel dumb. Curated airport pool + same-class/similar-tier type sampling, unit-tested; iterate from `guess_round_answered` accuracy (too high = too easy).
6. **Threshold changes → unlock flood / user confusion** — PR6's recap + reseed is the designed absorber; ship PR6 in the same TestFlight as PR4.
7. **Scoring-regime discipline** — v3 bump with a zero-delta rescore must still follow the dry-run runbook so the journal/version history stays trustworthy for the *next* real re-balance.
