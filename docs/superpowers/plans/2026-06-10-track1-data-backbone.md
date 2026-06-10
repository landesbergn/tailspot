# Track 1 Implementation Plan — Data Backbone & Anonymous Leaderboard

**Date:** 2026-06-10
**Spec:** `docs/superpowers/specs/2026-06-10-production-v1-program-design.md` (§3)
**Goal:** A deployed Fly.io backend serving positions, metadata, catch
ingestion, and the leaderboard — and the iOS app cut over to it with the
OpenSky credentials removed from the binary and rotated.

Each work package (WP) below is dispatched as its own agent task with a
detailed prompt written at dispatch time; the model column is the starting
tier (escalation rule per spec §2). Every WP lands as a feature-branch PR
through the CI gate with orchestrator (Fable 5) review.

## Stack decisions (made here, once)

- **Runtime:** Node 22 + TypeScript, **Fastify** (boring, fast, typed).
- **DB:** Fly.io managed Postgres. **Drizzle ORM** + drizzle-kit migrations
  (typed schema, no raw-SQL drift; simplest credible choice).
- **Tests:** vitest; provider adapters tested against recorded JSON fixtures
  (same FailableDecodable philosophy as the iOS client — lossy upstream rows
  must not poison a response).
- **Deploy:** `fly.toml` + GitHub Actions deploy on merge to `main` (backend
  paths only); secrets via `fly secrets`. Single region (`sjc`) at beta scale;
  single instance → in-memory caches and rate limiting are acceptable
  (flagged for revisit if instances > 1).
- **API:** versioned under `/v1`; JSON field names mirror the iOS `Aircraft`
  model where sensible.

## Work packages

| WP | Deliverable | Model | Depends on |
|---|---|---|---|
| 1.1 | **Backend scaffold**: `backend/` layout, Fastify app, health endpoint, vitest, lint/typecheck, GitHub Actions test job, `fly.toml`, README | Sonnet 4.6 | — |
| 1.2 | **Provider seam + adapters**: `PositionProvider` interface (`aircraftInBbox`), adsb.lol adapter (primary), OpenSky adapter (fallback, OAuth2), provider selection by config, fixture tests for both wire formats | Fable 5 (interface + association of upstream quirks) → Opus 4.8 (adapters) | 1.1 |
| 1.3 | **`GET /v1/aircraft` + tile cache**: bbox validation/clamping, region-tile keyed in-memory cache (~10 s TTL), single-flight dedup so concurrent requests share one upstream fetch, upstream-failure fallback to last-good tile (bounded staleness) | Opus 4.8 | 1.2 |
| 1.4 | **Metadata service**: Postgres schema (registry + typecode tables), FAA releasable-DB import job (daily cron via Fly machines or in-process scheduler), DOC 8643 import (reuse `tools/generate-aircraft-types.py` output), `GET /v1/metadata/{icao24}` merged lookup with per-icao cache | Sonnet 4.6 (import pipeline) + Opus 4.8 (lookup/merge semantics) | 1.1 |
| 1.5 | **Identity + catches + leaderboard**: device-token issuance (`POST /v1/devices`), handle claim with uniqueness + profanity filter, `POST /v1/catches` with pose payload, **instrumented** (never enforced) angular-tolerance validation as a pure tested function, `GET /v1/leaderboard`, per-token rate limits | Opus 4.8; **Fable 5 security review mandatory** (abuse, injection, token handling) | 1.1, 1.4 (points need typecode→rarity) |
| 1.6 | **iOS `TailspotBackendClient`**: implements `ADSBSource` (one-file swap per CLAUDE.md), metadata client replacing `OpenSkyClient.aircraftMetadata` behind `ADSBManager.metadata(for:)`, catch upload (fire-and-forget with local queue/retry — catches must never be lost offline), Swift Testing suites with fixture servers | Fable 5 (concurrency/isolation-sensitive; the `nonisolated`/Sendable rules apply) | 1.3, 1.4 contracts frozen |
| 1.7 | **Leaderboard UI wiring**: replace `LeaderboardScreen` mock rows with the API, handle-claim flow in onboarding/Settings, remove `ComingSoonBanner` from leaderboard | Sonnet 4.6 | 1.5, 1.6 |
| 1.8 | **Cutover + secret retirement**: config flips primary source to backend, delete OpenSky creds from Info.plist/xcconfig path, **rotate the OpenSky secret** (retires PLAN §9 #6), tester warning ahead of rotation per standing rule, `MARKETING_VERSION` → 0.5.0 | Fable 5 | 1.6, 1.7 deployed + field-tested |
| 1.9 | **Ops runbook**: `docs/backend-handoff.md` — every Noah-in-a-dashboard step (Fly.io account, Postgres provisioning, secrets, DNS, deploy, rollback, "is it up" checks), in the style of `docs/testflight-handoff.md` | Haiku 4.5 draft → Fable 5 verify against the real deploy | 1.8 |

## Ordering and parallelism

1.1 first (everything hangs off it). Then **1.2→1.3** (positions) and **1.4**
(metadata) run in parallel; **1.5** follows 1.4. iOS work (1.6) starts as soon
as the 1.3/1.4 API contracts are frozen — contract-first: the orchestrator
writes the endpoint contracts into the WP prompts so client and server build
against the same shapes. 1.7 after 1.5+1.6. 1.8 is the integration gate:
field-tested by Noah on device against the deployed backend before creds are
rotated. 1.9 trails 1.8.

## Noah-facing prerequisites (can start immediately)

- Fly.io account + org (runbook will walk the rest).
- Decide the API hostname (e.g. `api.tailspot.app`) — needs a domain you own.
- OpenSky console access ready for the §1.8 rotation.

## Verification bar (every WP)

- Unit tests green in CI (backend vitest job; iOS `TailspotTests` for 1.6/1.7).
- For 1.3: measured behavior under upstream outage (serve last-good, then
  empty-with-error, never 500-storm the app).
- For 1.5: security review sign-off recorded in the PR.
- For 1.8: a full field session on Noah's phone running purely through the
  backend, replay recorded, before the old path is deleted.
