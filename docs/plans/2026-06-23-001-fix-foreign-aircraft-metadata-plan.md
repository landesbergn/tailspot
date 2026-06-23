# fix: Foreign-aircraft make/model (kill "Unknown aircraft" for non-US planes)

**Type:** fix · **Date:** 2026-06-23 · **Depth:** Standard (cross-codebase: backend + iOS)
**Status decisions:** scope = **forward pass-through + heal existing catches**; heal source = **both** (bulk mictronics seed + opportunistic feed top-up). Confirmed by Noah this session.

---

## Context

A caught Singapore Airlines A350 (SIA248, reg `9V-SMH`, ICAO type `A359`) shows as **"Unknown aircraft"** in both the catch card and the Hangar, even though the airline name ("Singapore Airlines") resolves correctly. Root cause, confirmed end-to-end this session:

- **Airline name** is resolved on-device from the callsign (`ios/Tailspot/Tailspot/Airlines.swift`: `SIA248`→`SIA`→"Singapore Airlines"). The backend never sends an operator (`backend/src/metadata/merge.ts:108` `operatorNameSeam()` returns `null`). This path works for any callsign-format flight.
- **Make/model/typecode** come from `GET /v1/metadata/{hex}`, which is **FAA-registry-only**: `DrizzleMetadataStore.lookup()` queries the `registry` table (`backend/src/metadata/store.ts:55`), populated solely from the US FAA Releasable Aircraft DB (`backend/src/ingest/faa.ts`). A foreign hex has no row → `mergeMetadata(null, null)` returns `null` (`merge.ts:54`) → route returns **404** (`routes/metadata.ts:45`) → iOS stores nil `typecode`/`model` → title falls to "Unknown aircraft" (`CatchCardView.swift:255`) and the classifier defaults to **GA / common** (`GameSystem.swift:257`).
- **The data was already in hand and discarded.** The adsb.lol feed the backend polls carries `t` (ICAO typecode) and `r` (registration) on essentially every aircraft — confirmed live: every plane over Bali, including a `9V-` jet (`TGW259 t=E290 r=9V-THJ`), had both. But `backend/src/providers/adsblol.ts` reads only the position fields and drops `t`/`r` before they reach `/v1/aircraft` or the iOS `Aircraft`.

This is **structural, not transient**: Noah field-tests in Bali/SE-Asia where nearly all overhead traffic is foreign-registered, so almost every catch reads "Unknown aircraft" with a correct airline label. The fix stops discarding the feed's `t`/`r` (forward), and gives the metadata endpoint a global registry so existing Hangar catches heal on open (retroactive).

**Intended outcome:** catching any aircraft the feed can identify yields a real make/model + correct type/tier at the moment of catch, globally; and the existing "Unknown aircraft" rows already in the Hangar self-correct.

---

## Key Technical Decisions

- **KTD-1 — Forward fix is feed pass-through, not a new metadata fetch.** The typecode/registration already arrive in every `/v1/aircraft` response from adsb.lol; thread them through to the catch instead of relying on the per-hex FAA endpoint. Works globally, at catch time, with zero extra requests. The FAA `/v1/metadata` endpoint stays as secondary enrichment/backfill.
- **KTD-2 — No schema migration anywhere.** `Catch` already has `typecode` (`Catch.swift:70`) + `registration` (`Catch.swift:67`). The backend `registry` table already has `icao24`/`registration`/`typecode`/`source`, and `source` is explicitly documented as a "future seam for other registries" (`schema.ts:56`). Both halves are purely additive data flow. **No SwiftData migration, no Drizzle migration** — which sidesteps the manual-prod-migration trap entirely.
- **KTD-3 — Canonical names come for free.** The `typecodes` table is the full DOC-8643 set from `AircraftTypes.json` (same data iOS bundles). A foreign registry row only needs `(icao24, registration, typecode)`; the existing merge resolves `A359` → "Airbus / A350-900" via the typecode join (`store.ts:63`, `merge.ts`). No new naming code.
- **KTD-4 — Additive sources must NOT clobber FAA rows.** The existing `upsertRegistry()` overwrites *every* field from the incoming row (`registryUpsert.ts:26`). That is correct for an FAA refresh but **wrong** for foreign/feed sources, which carry no `manufacturerRaw`/`modelRaw` — a full overwrite would null out FAA-canonical names for US tails. Part 2 needs a **non-destructive** upsert: bulk mictronics ingest uses conflict-do-nothing (FAA wins for US hexes; mictronics fills the foreign gap); opportunistic feed upsert fills only `typecode`/`registration` and never touches `manufacturerRaw`/`modelRaw`/canonical fields.
- **KTD-5 — Wire contract additions are backward-compatible.** `/v1/aircraft` and `/v1/metadata` are described as "frozen" in comments; the new per-aircraft `typecode`/`registration` are **optional** fields. Old iOS builds ignore unknown keys; new iOS builds tolerate their absence (the backend half ships first). Call out the sequencing (below).
- **KTD-6 — Live feed beats the metadata endpoint at catch time.** In `performCatch`, prefer `observed.aircraft.typecode/registration` (fresh, from the feed) over the `/v1/metadata` value, falling back to metadata when the feed lacks it. The feed is as-observed and always present when the plane is in view.

---

## Sequencing & Deploy (read first)

1. **Phase 1 (forward) is self-contained and ships first.** The iOS pass-through is **inert until the backend emits the new fields** — so the backend change must deploy before the iOS build can benefit. **Backend deploy (Fly.io) is manual and Noah's call only.**
2. **Phase 2 (heal) needs the data loaded in prod.** The bulk mictronics ingest is a one-off `npm run ingest:mictronics` against prod (like `ingest:faa`); the opportunistic upsert ships with the backend. **No Drizzle migration to apply** (KTD-2) — but the bulk ingest job must be run against prod for existing catches to heal.
3. Each phase is independently deployable and independently valuable. Land Phase 1 first; verify forward catches; then Phase 2.
4. Repo flow per `CONTRIBUTING.md`: worktree off `main` (Noah's preference) → field-test via `bin/deploy` → PR → squash-merge (does **not** ship). TestFlight is a separate, Noah-only step.

---

## Implementation Units

### U1. Backend — pass `t`/`r` through the position pipeline

**Goal:** the adsb.lol typecode + registration survive normalization and appear in every `/v1/aircraft` aircraft object.
**Dependencies:** none.
**Files:**
- `backend/src/providers/types.ts` — add optional `typecode?: string`, `registration?: string` to `NormalizedAircraft`.
- `backend/src/providers/adsblol.ts` — add `t?: string`, `r?: string` to the `AdsbLolAircraft` interface; in `normalizeOne()` extract + trim them (reuse the existing `trimCallsign`-style null-if-empty guard) and include them in the returned `NormalizedAircraft`.
- `backend/src/routes/aircraft.ts` — **confirm** it passes `snapshot.aircraft` through unchanged (it does); the new optional keys flow automatically.
- `backend/src/routes/tileCache.ts` — **confirm** the cache stores `ProviderSnapshot` opaquely (it does); no change.
- `backend/src/providers/opensky.ts` — legacy provider; leave `typecode`/`registration` undefined (OpenSky never carried them). Confirm it still type-checks against the widened `NormalizedAircraft`.
- Tests: `backend/test/adsblol.test.ts`, `backend/test/aircraft.route.test.ts`.

**Approach:** mechanical field pass-through. `t`/`r` are already present in the upstream JSON (the `adsblol-point.json` fixture carries them); the normalizer just stops ignoring them. Trim and null-empty so `""` never reaches the client.
**Patterns to follow:** the existing trim/null-if-empty handling for `flight`→`callsign` in `normalizeOne()`; the contract-field assertion loop in `aircraft.route.test.ts`.
**Test scenarios:**
- `normalizeAdsbLol` round-trips `typecode`/`registration` from a fixture row (e.g. assert a known hex maps to `typecode === "A359"` / `registration === "9V-SMH"`).
- A row missing `t`/`r` (or with empty strings) yields `undefined`/`null`, not `""`.
- `GET /v1/aircraft` response objects include `typecode` and `registration` keys for an aircraft that has them, and omit/null them for one that doesn't.
- Existing position/unit assertions still pass (no regression to alt/speed/track mapping).

### U2. iOS — carry `typecode`/`registration` on `Aircraft`

**Goal:** the backend's new fields decode into the core `Aircraft` value.
**Dependencies:** U1 (wire shape).
**Files:**
- `ios/Tailspot/Tailspot/Aircraft.swift` — add `let typecode: String?`, `let registration: String?` to the struct. In the **legacy OpenSky positional** `init(from:)`, set both to `nil` (OpenSky's positional array has no type/reg — do **not** try to decode them from the array). Consider a small custom memberwise initializer with `typecode: String? = nil, registration: String? = nil` defaults so existing `Aircraft(...)` call sites and tests don't all need the two new args.
- `ios/Tailspot/Tailspot/TailspotBackendClient.swift` — add `typecode: String?`, `registration: String?` to `BackendAircraft`; map them in `asAircraft()`.
- Tests: `ios/Tailspot/TailspotTests/TailspotBackendClientTests.swift`.

**Approach:** the production path is `BackendAircraft` (keyed JSON) → `asAircraft()`; the positional decoder in `Aircraft.swift` is legacy/test-only since the 2026-06-21 OpenSky cutover, so it just nils the new fields. The defaulted memberwise init keeps the test/diff surface small.
**Patterns to follow:** the existing optional-field decode in `BackendAircraft` (`callsign`, `velocityMps`, etc.) and `asAircraft()`'s field mapping.
**Test scenarios:**
- Decoding a `BackendAircraftResponse` whose aircraft carry `typecode`/`registration` maps them onto `Aircraft`.
- Null/absent `typecode`/`registration` decode as `nil` (the existing `nullableFieldsDecodeAsNil` test extended).
- An old-shape response with no `typecode`/`registration` keys still decodes (backward-compat — KTD-5).

### U3. iOS — prefer the live feed over metadata at catch time

**Goal:** a catch records the feed's typecode/registration, so a foreign plane gets a real name immediately without depending on `/v1/metadata`.
**Dependencies:** U2.
**Files:**
- `ios/Tailspot/Tailspot/ContentView.swift` — in `performCatch` (the `Catch(...)` init, ~lines 974–975), set `typecode` and `registration` preferring `observed?.aircraft.<field>` (trimmed-non-empty) and falling back to `metadata?.<field>`.
- Tests: `ios/Tailspot/TailspotTests/CatchTests.swift` (or the nearest catch-path suite).

**Approach:** a two-source coalesce, feed first (KTD-6), each guarded by the existing `trimmedNonEmpty` idiom already used on the metadata values at that call site.
**Patterns to follow:** the sibling line `operatorName: metadata?.operatorName ?? Airlines.name(forCallsign:)` — same prefer-then-fallback shape, here feed-then-metadata.
**Test scenarios:**
- Catch built from an `ObservedAircraft` whose `aircraft.typecode == "A359"` records `typecode == "A359"` even when injected metadata says something different (feed wins).
- Feed typecode nil but metadata typecode present → catch records the metadata value (fallback).
- Both nil → catch records nil (unchanged "Unknown aircraft" behavior; no crash).
- `Covers` the end-to-end name resolution: a catch with `typecode == "A359"` resolves through `AircraftNaming.canonical` to a non-"Unknown" title and `resolvedType == .wide` (sanity assertion that the stored typecode drives naming/tier).

> **Phase 1 boundary** — U1–U3 fix all *future* catches globally. Deployable on its own (backend deploy first, then iOS). Phase 2 below heals *existing* catches.

### U4. Backend Part 2a — bulk mictronics global-registry ingest

**Goal:** load a global hex→`(registration, typecode)` dataset so `/v1/metadata` resolves foreign hexes immediately and deterministically.
**Dependencies:** none (independent of U1–U3), but only *useful* alongside the unchanged merge.
**Files:**
- `backend/src/ingest/mictronics.ts` (new) — parser + `importMictronics(db, …)` streaming batched upserts + a `main()` entry, mirroring `faa.ts`.
- `backend/src/ingest/registryUpsert.ts` — add a **non-destructive** variant (e.g. `upsertRegistryFillOnly` / conflict-do-nothing) so an existing FAA row for a US hex is **not** overwritten by a thinner mictronics row (KTD-4).
- `backend/package.json` — add `"ingest:mictronics"` script mirroring `ingest:faa`.
- Tests: `backend/test/mictronics.test.ts` (new), mirroring `backend/test/faa.test.ts`.

**Approach:** download the mictronics "standing-data" basic aircraft DB (the same source adsb.lol/readsb bundle; ODbL — already anticipated in `PLAN.md` Track 3 legal). Parse rows to `RegistryInsert` with `registration` + `typecode` set, `manufacturerRaw`/`modelRaw` left null, `source: "mictronics"`. Upsert with conflict-do-nothing so FAA rows win for overlapping US hexes and mictronics fills the foreign gap. Stream + batch like `importFaa` (the file is large — never fully load into memory).
**Execution-time unknowns (do not resolve in plan):** the exact mictronics distribution URL, file format (CSV vs JSON), and column names; the precise ODbL attribution string. Verify the live artifact at implementation; the FAA importer's streaming/batching structure is the template regardless of format.
**Patterns to follow:** `backend/src/ingest/faa.ts` (`importFaa` streaming + `BATCH` + `upsertRegistry`), `backend/src/ingest/registryUpsert.ts`, the `faa.test.ts` parser tests.
**Test scenarios:**
- Parser maps a sample mictronics row to a `RegistryInsert` with the right `icao24` (lowercased), `registration`, `typecode`, and `source: "mictronics"`.
- A foreign hex (e.g. `9V-SMH`'s hex → `A359`) round-trips through ingest and `DrizzleMetadataStore.lookup()` returns a record whose merged `model` resolves to the A350-900 canonical name via the `typecodes` join.
- **No-clobber:** an existing FAA registry row (with `manufacturerRaw`/`modelRaw`) is **not** overwritten when a mictronics row for the same US hex is ingested.
- Empty/malformed rows are skipped (lossy-per-row), not fatal.

### U5. Backend Part 2b — opportunistic registry upsert from live tile fetches

**Goal:** keep the registry fresh and growing from the data the backend already fetches, covering new/changed airframes without a re-ingest.
**Dependencies:** U1 (the snapshot now carries `typecode`/`registration`).
**Files:**
- `backend/src/routes/tileCache.ts` (or the provider-fetch seam it calls) — on a **fresh** upstream fetch (cache-miss path only, not cache hits / last-good), fire-and-forget a batched, non-destructive upsert of `(icao24, registration, typecode)` for aircraft that carry them, `source: "adsblol"`.
- `backend/src/ingest/registryUpsert.ts` — reuse the non-destructive variant from U4 (fill `typecode`/`registration` only; never null `manufacturerRaw`/`modelRaw`).
- Tests: `backend/test/tileCache.test.ts` (or wherever the cache/provider seam is tested).

**Approach:** the backend already fetches every visible aircraft's `t`/`r` on each cache-miss tile fetch; capture that for free. Must be **fire-and-forget** (never block or fail the `/v1/aircraft` response on a DB write), batched (one multi-row upsert per fetch, not per aircraft), deduped by hex, and **non-destructive** (KTD-4) so it never degrades FAA or mictronics canonical data. Only upsert rows that actually have a `typecode` (skip position-only contacts).
**Patterns to follow:** the single-flight / fresh-vs-stale distinction already in `tileCache.ts`; the batched `upsertRegistry` shape from `registryUpsert.ts`.
**Test scenarios:**
- A fresh fetch containing an aircraft with `typecode`/`registration` triggers an upsert with `source: "adsblol"`; a cache **hit** or last-good fallback does **not**.
- The upsert **never nulls** an existing row's `manufacturerRaw`/`modelRaw` (fill-only on `typecode`/`registration`).
- A DB write failure does not surface as a `/v1/aircraft` error (fire-and-forget isolation).
- Aircraft without a `typecode` are not upserted (no empty rows).

> **Existing catches heal with no iOS change.** After U4+U5 deploy and the bulk ingest runs against prod, the already-built `CatchBackfill.backfillAll` path (`ios/Tailspot/Tailspot/CatchBackfill.swift`) re-fetches `/v1/metadata/{hex}` on Hangar open for rows where `needsMetadata` is true (`typecode == nil || registration == nil`) — which now resolves foreign hexes — fills `typecode`/`model`, and `resolvedType`/`resolvedRarity` re-derive live on read. Confirm `needsMetadata` still gates these rows (it does: they have nil typecode).

---

## Minor / Deferred

- **`source` label cosmetics (optional).** `mergeMetadata` reports output `source` as `faa`/`doc8643`/`merged` based on which *inputs* contributed, not the registry row's provenance — so a mictronics- or feed-sourced row may be labeled `merged`/`faa`. The iOS client only reads `typecode`/`model`/etc.; `source` is informational. Threading the registry row's `source` through merge is a nicety, not required. Deferred.
- **Live AR-overlay type pre-catch.** With `typecode` now on `Aircraft`, the live HUD label could also resolve type from the typecode (today it uses the string classifier). Out of scope here; note as a follow-up if the pre-catch/post-catch tier divergence (already tracked in `PLAN.md`) is worth closing.
- **ODbL attribution surface.** Adding mictronics data introduces an ODbL attribution obligation (already anticipated in `PLAN.md` Track 3 legal). Ensure the About/privacy attribution is updated before App Store distribution — tracked there, not blocking this fix.

---

## Verification

**Phase 1 (U1–U3) — fixes forward:**
- Backend: `npm test` in `backend/` green (new adsblol + aircraft-route assertions).
- iOS: Swift Testing suite green via `xcodebuild test … -only-testing:TailspotTests` (iPhone 17 sim).
- Deploy backend to Fly.io (Noah), then `bin/deploy` the iOS build to the iPhone.
- **Field check:** catch a foreign-registered plane (any non-`N` callsign overhead in Bali) → expect a real make/model title (not "Unknown aircraft"), a correct type badge (e.g. WIDE for a widebody), and the right tier/points — at the moment of catch.

**Phase 2 (U4–U5) — heals existing:**
- Backend: `npm test` green (new mictronics parser + no-clobber + opportunistic-upsert tests).
- Run `npm run ingest:mictronics` against **prod** (one-off, like `ingest:faa`); confirm row count + spot-check a known foreign hex via `GET /v1/metadata/{hex}` returns a resolved typecode/model.
- **End-to-end heal check:** open the existing **SIA248 "Unknown aircraft"** catch in the Hangar → `CatchBackfill` re-fetches `/v1/metadata/{hex}` → the card self-corrects to "Airbus A350-900" / WIDE / proper tier on read (no reinstall, no migration).
- Confirm a US (`N`-number) catch still shows its FAA-canonical make/model (no-clobber regression check).

---

## Out of scope / Non-goals

- No SwiftData or Drizzle migration (KTD-2).
- No operator/livery source on the backend (the `operatorNameSeam` stub stays; airline names keep coming from the on-device `Airlines.swift` callsign table).
- No new iOS SPM dependencies.
- No runtime ADS-B source toggle, no change to the visibility filter, fetch/annotation split, or projection math.
