# Tailspot API

Node 22 + TypeScript (strict, ESM) + Fastify backend for the Tailspot iOS app.

## What this service becomes

This scaffold is Work Package 1.1 of the Track 1 data-backbone programme
(`docs/archive/superpowers/plans/2026-06-10-track1-data-backbone.md`). Subsequent work
packages add: a **position proxy** (`GET /v1/aircraft?bbox=…`) that polls
adsb.lol server-side so OpenSky credentials are no longer baked into the iOS
binary; a **metadata service** (`GET /v1/metadata/{icao24}`) merging the FAA
releasable DB + ICAO DOC 8643; a **catch ingestion endpoint** (`POST /v1/catches`)
with instrumented anti-cheat validation; and an **anonymous leaderboard**
(`GET /v1/leaderboard`) backed by Fly.io managed Postgres with device-token
identity and claimable handles — no sign-in, no PII beyond a self-chosen handle.

## Endpoints

### `GET /healthz`

Liveness probe, and the only thing Fly's own health check watches
(`fly.toml`). Returns `{ "status": "ok" }` as long as the process can answer.
Deliberately no DB ping and no upstream probe: Fly restarts machines that fail
this check, and restarting the API because Postgres or adsb.lol is down would
add churn to the real outage. It used to include the package version; that was
free reconnaissance for an unauthenticated caller and nothing consumed it, so it
was removed (2026-09-06). For the running version, use
`fly image show -a tailspot-api`.

### `GET /readyz`

End-to-end readiness, and the URL the external uptime monitor watches (Sentry
monitor 8072647, every 60 s, down after 3 consecutive failures). 200 only when
Postgres answers `SELECT 1` **and** the position feed can serve planes for a
fixed canary bbox through the same tile cache the phones use:

```jsonc
{ "status": "ok", "checks": { "db": "ok", "feed": "ok", "feedSource": "organic", "feedProvider": "adsbfi" } }
```

`checks.feed` is one of `ok`, `stale` (serving last-good inside the 60 s
window), `fallback` (fresh data, but from adsb.lol because adsb.fi is
down), `unavailable` (upstream failed, nothing to serve — phones get 503) or
`timeout`. `checks.feedSource` says how the feed verdict was reached:
`organic` (a phone's recent successful fetch proved the feed, no request made)
or `probe` (the canary tile was fetched); absent on a timeout. `checks.feedProvider`
names the feed that produced the proving snapshot (`adsbfi` or `adsblol`), so the
monitor's captured body says which API was serving at that moment; absent when
nothing has been served. The same name is on every `/v1/aircraft` response and
in the Fly log: each genuine upstream fetch (never a cache hit or a last-good
serve) logs one `position feed fetched` line with `provider`, `tile`,
`aircraft`, `fetchedAt` and `upstreamMs`. The first three are 200: users are getting planes. The last two,
or `db: "unavailable"`, are 503. Budgets are 3 s for the DB and 4 s for the
feed, run concurrently, so the answer always lands inside the monitor's 5 s.

The canary goes through `TileCache.get`, so a probe inside the 10 s TTL is a map
read and a miss is one upstream fetch shared with anyone looking at that tile;
the monitor therefore costs at most one upstream request per minute. The default
bbox is the Bay Area; `CANARY_BBOX=lamin,lomin,lamax,lomax` moves it, and a
malformed value fails the boot. A quiet sky is not a failure, only a failed
fetch is.

**Why it exists (2026-10-19).** From 2026-10-03 to 2026-10-19 adsb.lol
rate-limited Fly's *shared* IPv4 egress (HTTP 429) and airplanes.live refused it
(HTTP 403), so every `/v1/aircraft` call 503'd once the cache aged out. The
process was up and the DB was fine, so `/healthz` stayed green, the uptime
monitor (then on `/healthz`) never fired, and the first reports came from users
sixteen days in. See `src/routes/feedProbe.ts`.

### `GET /v1/aircraft?lamin=&lomin=&lamax=&lomax=` (WP 1.2 + 1.3)

Cached, single-flighted position proxy. Takes a bounding box in decimal
degrees and returns a normalized, SI-unit snapshot of aircraft inside it:

```jsonc
{
  "fetchedAt": 1781116526,        // unix SECONDS of the upstream snapshot (NOT serve time)
  "provider": "adsbfi",           // the feed that produced it ("adsbfi" | "adsblol"); additive
                                  // 2026-10-20, a stale serve keeps the ORIGINAL producer
  "aircraft": [
    {
      "icao24": "a92d6d",          // lowercase hex
      "callsign": "UAL875",        // trimmed; null if empty
      "originCountry": "United States",
      "longitude": -122.45, "latitude": 37.82,
      "altitudeMeters": 3322.3,    // geometric preferred, baro fallback, 0 if unknown/on-ground
      "velocityMps": 150.1,        // ground speed; null if unknown
      "trackDeg": 311.94,          // degrees true; null if unknown
      "onGround": false,
      "positionTimestamp": 1781116525  // unix seconds of last position update; null if unknown
    }
  ]
}
```

Errors: `400 { "error": "..." }` for a missing / non-numeric / out-of-range /
inverted / oversized (> 4 sq deg) bbox; `503 { "error": "upstream unavailable" }`
when the upstream is down **and** no acceptably-fresh cache exists;
`429 { "error": "rate limited" }` past 120/min per IP (IPv6 clients are
limited per /64).

Behind the route:

- **Region-tile cache** — the bbox is quantized to a coarse grid (`0.25°`) to
  collapse a neighbourhood of near-identical viewports onto one cache key.
  Fresh entries (within `CACHE_TTL_SECONDS`, default 10) are served without an
  upstream call.
- **Single-flight dedup** — concurrent requests for the same tile share one
  in-flight upstream fetch.
- **Last-good fallback** — on upstream failure, a cached snapshot younger than
  `STALE_MAX_SECONDS` (default 60) is served with its true `fetchedAt` so the
  client sees the staleness; otherwise the request 503s. Upstream errors never
  surface as a 500.
- **Upstream request budget** (2026-10-21) — at most `UPSTREAM_RPS` (default
  0.8) feed requests per second leave this process, under adsb.fi's 1/s. When
  the budget is spent, a tile up to 30 s old is served from cache instead of
  refreshed, and a tile with nothing usable waits up to 2 s for a slot (then
  503s). Refreshes yield to cold tiles. See `src/providers/upstreamBudget.ts`.
- **Circuit breakers** (2026-10-21) — each feed sits behind a breaker. A 429 or
  403 opens it at once for the upstream's `Retry-After` (else 30 s, clamped to
  10 s–10 min); three other failures in a row open it for 30 s. While open, the
  feed is not called and the fallback is used immediately, instead of every
  poll waiting out an 8 s timeout. One trial request closes it; a failed trial
  doubles the cooldown. See `src/providers/circuitBreaker.ts`.

Every JSON response over 1 KB is gzipped when the client sends
`Accept-Encoding: gzip` (URLSession always does). The aircraft list shrinks
about 5×.

### `GET /v1/metadata/{icao24}` (WP 1.4)

Per-airframe metadata, merging the **FAA Releasable Aircraft DB** (authoritative
for US tails: registration + manufacturer/model + typecode) with **ICAO DOC 8643**
(authoritative for clean type naming). `{icao24}` is lowercase hex, validated as
`[0-9a-f]{6}` (uppercase is accepted and normalized).

```jsonc
{
  "icao24": "a12345",           // echoed, lowercased
  "registration": "N12345",     // FAA tail number; null if unknown
  "manufacturer": "Boeing",     // DOC 8643 clean name when the typecode is known there, else raw FAA
  "model": "737-800",
  "typecode": "B738",           // ICAO type designator; null if the FAA row carries none
  "operatorName": null,         // always null for now — community lookup is a later seam
  "source": "merged"            // "merged" | "faa" | "doc8643"
}
```

Errors: `400 { "error": "malformed icao24" }`; `404 { "error": "unknown aircraft" }`
when no source knows the airframe.

**Merge semantics.** The FAA registry says *which airframe* a US tail is and
supplies registration + typecode. When the FAA row's typecode is also in the DOC
8643 table, we prefer DOC 8643's **clean** manufacturer/model (`Boeing` /
`737-800`) over the FAA's messy ALL-CAPS strings (`BOEING` / `737-800` — the FAA
casing/formatting is inconsistent across rows). `source` records provenance:
`merged` (both contributed), `faa` (registry only — typecode absent or unknown
to DOC 8643), `doc8643` (type table only). The merge is a pure function
(`src/metadata/merge.ts`), unit-tested without a database.

**Storage.** Postgres via Drizzle ORM — `registry` (icao24 PK) + `typecodes`
(typecode PK). The route depends on an injected `MetadataStore` (mirrors the
aircraft route's injected `PositionProvider`), so the storage backend is swappable
and tests inject a PGlite-backed store. See **Database & ingestion** below.

### `GET /v1/stats`

The marketing site's "N planes caught so far" counter. No device auth; instead
the request's browser `Origin` must be `https://tailspot.app`,
`https://www.tailspot.app`, or the preview site
`https://tailspot-www-preview.fly.dev` (plus anything in
`STATS_ALLOWED_ORIGINS`), and the
response echoes it as `Access-Control-Allow-Origin` with `Vary: Origin`. Any
other origin, or no origin at all, gets a `404` so the route doesn't advertise
itself. A forged Origin from curl still works — the number is printed on the
homepage, so the fence exists to stop other *sites* embedding the endpoint,
not to hide the value. The `count(*)` is memoised in-process for 60 s and
served with `Cache-Control: public, max-age=300`, so site traffic reaches
Postgres at most once a minute.

```json
{ "catches": 5812, "asOf": "2026-09-05T23:41:07.000Z" }
```

### `POST /v1/catches/:catchUuid/guess` (one-time guess re-credit)

Clients 1.1.0 through 1.2.2 uploaded each catch before its bonus-round guess
resolved, and a replayed upload keeps the original row, so about 1,950 correct
guesses never earned their bonus. The 1.2.3 client sends each guess it still
has on the phone here, once, with `{ kind, value, localCorrect }`. Bearer auth,
the calling device's own catch only, metered per IP and per device (120/min).

The guess is applied only when the stored row has no guess and was inserted
(`created_at`) before `GUESS_RECREDIT_CUTOVER` in `src/catches/points.ts`.
Type guesses are checked against the server's resolved typecode. Route guesses
trust `localCorrect`, because the server keeps only the callsign and today's
route data can't judge an old flight number; the cutover keeps that trust to a
one-time backfill. Points are recomputed by the canonical scorer (era-aware, so
a route guess before 2026-08-13 earns +10%) with the row's frozen first-of-type
flag, and the row is stamped with the current scoring version, so a later
`npm run rescore` keeps the bonus. Decided weekly and monthly crowns are not
touched, and no "someone passed you" push is sent.

`200 { applied, points, guessKind, guessCorrect }` (`applied:false` means the
row already had a guess and nothing changed), `404 { code: "catch_not_found" }`,
`409 { code: "after_cutover" }`, `422` malformed body. The `code` field lets
the client tell this 404 from the framework 404 an older server returns.

### Challenges v1 (`/v1/challenges`, `/v1/invites`)

Head-to-head and small-group races over a shared time window, scored with the
standard catch points. Spec: `docs/reviews/2026-09-15-challenges-v1-spec.html`.
**Deployed dark**: every route below except `/config` answers `404` until
`CHALLENGES_ENABLED=true` is set on the Fly app.

| Route | Auth | Limit | Notes |
|---|---|---|---|
| `GET /v1/challenges/config` | none (browser `Origin` allowlisted like `/v1/stats`; no-Origin callers allowed) | 60/min/IP | `{ enabled, availability, minBuild, appStoreURL }` — the client and the landing page read this to explain "off", "TestFlight only" or "update the app". Answers even when disabled. |
| `POST /v1/challenges` | bearer + claimed handle | 30/h/device | body `{ name, duration: "1h"\|"24h"\|"3d"\|"7d", start?: "now"\|ISO }` (scheduled start 15 min – 14 d out). 201 with the detail payload; creator is the first participant. |
| `GET /v1/challenges?scope=open\|history` | bearer | 120/min/device (kept — the hub reads it on every appear and pull-to-refresh) | `{ open: [...], history: [...] }` for the caller, **50 per bucket**, open soonest-end-first, history newest-first; `scope` returns one bucket (default both). Rows carry `creatorHandle`, `participantCount` (active) and `myResult` (frozen placement, history only). One batched read, no per-row queries. |
| `GET /v1/challenges/:id` | bearer, active participant | 120/min/device | `{ challenge, standings, me, winners }`. Finalizes on the first read after `endsAt`. 404 for anyone else (never 403). |
| `GET /v1/challenges/:id/log/:handle` | bearer, active participant | 120/min/device | That spotter's in-window catches: **make + model, rarity, points, caughtAt only** — never callsign, hex, registration, operator, position or verdict. |
| `POST /v1/challenges/:id/leave` | bearer, active participant | 30/h/device | 204. Creator leaving an upcoming challenge cancels it. 409 after the end. |
| `POST /v1/challenges/:id/cancel` | bearer, creator | 30/h/device | 204 before start; 409 once live. |
| `GET /v1/invites/:code` | bearer | 30/min/IP **before** the token lookup | Join-sheet preview: `{ challenge, participants, needsHandle, alreadyIn, canJoin, reason? }`. Unknown code → 404. |
| `POST /v1/invites/:code/join` | bearer + claimed handle | 30/min/IP + 30/h/device | 200 detail (+ `alreadyIn`, `newDevice`); 409 full (10); 410 ended/cancelled; 422 no handle. Joining is idempotent; a leaver can rejoin. |
| `GET /v1/invites/:code/preview` | none, browser `Origin` allowlisted | 30/min/IP, 60 s memo | Landing-page preview: name, creator handle, window, participant count, status. Never a participant list. |

Rules the store enforces (all from the spec's decided list): status is derived
from the clock, never stored; joins are open until `endsAt` and a joiner's
earlier in-window catches count; a catch counts iff `caught_at ∈ [starts_at,
ends_at)` **and** `created_at <= ends_at` (no upload grace); ties share
placement (1, 1, 3) and everyone at 1 wins; fewer than two participants or
zero total points at the end is `no_contest`; results freeze into
`challenge_results` on the first read after the end and never move under a
rescore; disabled devices are invisible everywhere. Growth attribution: a
device that registered within 7 days and joins its first challenge gets
`challenge_participants.joined_as_new_device = true` and
`devices.referred_by_challenge_id` stamped once.

The scorer is an interface (`src/challenges/scorer.ts`) with one
implementation — the seam for future public quests (`challenges.kind`).

Not in v1: there is **no rename route** (a challenge's name is fixed at
creation; the client must not offer a rename) and no participant removal by the
creator. Push tokens arrived after v1 — see **Device push tokens** and
**Overtaken pushes** below. Concurrency: `join`, `leave` and finalization all take
`SELECT … FOR UPDATE` on the challenge row, so two joins racing at 9/10 can't
both land, standings + outcome freeze from one snapshot, and a join or leave
arriving after the freeze is refused (409 / 410) rather than silently landing
in a challenge that will never score it. Capacity counts the same participants
the preview shows — active rows whose device isn't disabled. `join` also locks
the **device** row (order: challenge → device) so one new device joining two
challenges at once can only claim the growth-attribution credit once.

### Device push tokens

| Route | Auth | Limit | Notes |
|---|---|---|---|
| `POST /v1/devices/push-token` | bearer | 30/h/device (per-IP metered first) | body `{ token, environment, build? }` → `204`. `token` is 64–200 hex characters (stored lowercased), `environment` is `"sandbox"` or `"production"`, `build` is accepted for triage and not stored (`null` counts as absent). `422` on any other shape. |
| `DELETE /v1/devices/push-token` | bearer | 30/h/device | `204`. Clears the caller's token; pushes silently stop. Clearing a device that has none is a no-op `204`. |

**A token belongs to one install.** Registering a token that another `devices`
row already holds **clears it from that row** in the same transaction. This
case is real — restoring a phone from backup, or reinstalling and registering a
fresh anonymous device, can hand the same APNs token to a second identity, and
if both kept it one phone would receive the other identity's notifications.

**No proof of possession — accepted, but watched.** Registration proves the
caller holds the device's *bearer token* and nothing more; it does not prove
they hold the *APNs* token they are claiming. Someone with a leaked bearer
token could therefore point that device's notifications at their own phone.
The leak is the real problem and the fix is `device:disable`; the mitigation
here is visibility, because a token changing hands is the one observable
symptom. Every move logs a `warn` naming **both device ids** (never the token)
and bumps a per-process counter, so a burst stands out in the Fly log.

`environment` is stored because a token minted against the sandbox APNs host is
rejected by the production host and vice versa: the host is chosen **per token**
(`api.push.apple.com` / `api.sandbox.push.apple.com`), not per deploy. A
TestFlight build uses the production environment; only a development (Xcode)
build is sandbox.

### Overtaken pushes

The one notification the backend sends today: **someone passed you in a live
challenge.**

After a *fresh* `POST /v1/catches` (a replayed `catchUuid` changes nothing, so
it doesn't count), the route schedules an evaluation with `setImmediate` —
after the reply is on the wire, fire-and-forget. For every challenge that is
**live** right now and that the uploader is an active participant of (the 20
soonest to end, so one upload can't fan out unboundedly), the current standings
are re-derived once and each participant's placement is compared with the one
remembered in `challenge_participants.last_placement`. A numerically worse
placement means somebody went past them, and the uploader is who to name. Every
participant's `last_placement` is then written forward, the uploader's included.

**Three phases, and the network is not in the locked one.**

1. Under `SELECT … FOR UPDATE` on the challenge row — the same lock `join`,
   `leave` and finalization take — read the roster, decide the recipients, write
   everyone's new `last_placement`, stamp `overtaken_notified_at` for the
   recipients, commit. Two phones uploading in the same second are serialised
   here, so they can't both read a stale board and double-notify.
2. **Outside every transaction**, send to all recipients in parallel, each
   capped at 5 seconds. Sending inside the lock was an outage waiting to happen:
   nine recipients × a 5 s APNs timeout is a 45 s lock, and `statement_timeout`
   is 5 s, so every concurrent join, leave, finalize and standings read on that
   challenge would 500 while we waited on Apple.
3. A second, short transaction undoes phase 1 for sends that failed retryably.

**A blip doesn't lose the notification.** If a send fails in a retryable way
(429, any 5xx, a 403 `ExpiredProviderToken`, or a transport that never
answered), phase 3 restores that participant's previous `last_placement` and
`overtaken_notified_at`, so the next catch sees the slip again and tries once
more. A dead token, a missing token, the cooldown and "push disabled" leave the
advance in place — there is nothing to retry in any of those. Phase 3 takes no
lock and writes unconditionally, so it can land the pre-round values on top of a
placement a concurrent evaluation wrote in the meantime: the restored baseline
predates the slip, so that can cost a **duplicate** push (a 5xx that actually
delivered, say) but never a lost one, and phase 1's lock still means nobody is
notified twice inside a cooldown that is standing. The cost of
writing optimistically is bounded: if the process dies between phases, one
participant silently misses one notification, which beats a 45-second lock.

**It only names the passer when it can prove it.** A participant's baseline can
predate somebody else's catch (a held-back retry, a skipped evaluation, an older
seed), so the uploader isn't necessarily who went past them. The push names the
uploader only when they were level with or behind that participant at the last
evaluation and are ahead now; otherwise the copy is nameless — *"You've dropped
to 3rd in Weekend Flyoff."*

`last_placement` is seeded at create (the creator is alone, so 1st) and inside
the join transaction from the board the joiner walks into — their earlier
in-window catches count, so a joiner can arrive anywhere. **Null means "never
evaluated" and never notifies**, which is also what an un-migrated row looks
like.

It will not: notify the uploader, fire for an upcoming / finished / cancelled
challenge, reach a disabled device, notify the same person twice within 30
minutes in the same challenge (`overtaken_notified_at`), do anything at all
when `CHALLENGES_ENABLED` is off, or throw — every failure is logged and
swallowed, because the catch was answered `201` before any of this ran.

The payload, which the iOS client is built against:

```json
{
  "aps": {
    "alert": { "title": "You got passed",
               "body": "@ada just passed you in Weekend Flyoff. You're now 2nd." },
    "sound": "default",
    "thread-id": "<challengeId>"
  },
  "challengeId": "<challengeId>",
  "kind": "overtaken"
}
```

A shared placement reads "You're now tied for 2nd." Changing any key here is a
client-visible contract change.

The sender (`src/push/apns.ts`) has no dependencies: an ES256 provider JWT
signed with Node's `crypto` (refreshed every 50 minutes) and one HTTP/2 POST
per notification via the built-in `http2` module, with `apns-push-type: alert`,
`apns-priority: 10` and a one-hour `apns-expiration`. A `410`, or a `400` with
reason `BadDeviceToken` / `Unregistered`, clears the stored token — the app was
deleted, or the token belongs to the other environment. Every send is raced
against its own deadline and resolves even if the HTTP/2 stream is torn down
without a response (a GOAWAY or RST). A timeout or transport error also destroys
the cached HTTP/2 session, because a half-open session accepts streams and never
answers them — keeping it would turn one timeout into every later send timing
out until the process restarted — and a 403 `ExpiredProviderToken` invalidates
the cached JWT so the next send mints a fresh one instead of re-presenting a
credential Apple just refused. `createApnsTransport` signs one JWT at startup,
so a mangled `APNS_KEY_P8` boots as "push disabled" with a loud line rather than
as "push enabled" that fails every send. `ApnsTransport` is the seam tests inject a fake
into, and `connect` is injectable so the request shape is unit-tested against a
stub session.

### Configuration (env)

| Var | Default | Meaning |
|---|---|---|
| `POSITION_PROVIDER` | — (composite) | Unset: **adsb.fi primary with adsb.lol failover** (swapped 2026-10-20: adsb.lol caps a client at 500 requests/day; see *Upstream quotas*). `adsblol`, `adsbfi`, `adsblolreapi` (needs the key) or `airplaneslive`: that provider only (airplanes.live 403s Fly's network pending an access request). Read once at startup. |
| `ADSBLOL_REAPI_KEY` | — | Fly secret. When set, the default pair's failover becomes the keyed adsb.lol re-api (`https://re-api.adsb.lol/?circle=lat,lon,nm`, key in the `x-api-key` header) instead of the public 500/day api.adsb.lol. Blank counts as unset. Route lookups stay on api.adsb.lol either way. |
| `CACHE_TTL_SECONDS` | `10` | Fresh-cache window. |
| `STALE_MAX_SECONDS` | `60` | Max age of a last-good snapshot served on upstream failure. |
| `CACHE_TILE_SIZE_DEG` | `0.25` | Grid size for bbox→tile quantization. |
| `UPSTREAM_RPS` | `0.8` | Position-feed requests per second this process may send (adsb.fi allows 1/s per IP). Per machine: two running machines share the egress IP. |
| `SITE_PROBE_URLS` | tailspot.app home + AASA file | Comma-separated URLs the API probes every 60 s for the website-down alert. `off` disables. |
| `DATABASE_URL` | — | Postgres connection string. Required for `/v1/metadata` and the ingest jobs; read lazily (the position-only endpoints don't need it). |
| `STATS_ALLOWED_ORIGINS` | — | Comma-separated extra browser origins allowed to read `/v1/stats` (tailspot.app, www, and the preview site are always allowed). |
| `CHALLENGES_ENABLED` | — (off) | `true` turns the Challenges routes on. Anything else: every challenge route except `GET /v1/challenges/config` answers 404 (the kill switch). Read once at startup. |
| `CHALLENGES_AVAILABILITY` | `testflight` | `testflight` or `public` — what `/v1/challenges/config` reports so the landing page can say "TestFlight only" during the soak. |
| `CHALLENGES_MIN_BUILD` | `0` | Minimum client `CFBundleVersion` for Challenges, reported by `/config`; the app shows "update Tailspot" below it. |
| `CHALLENGES_INVITE_BASE_URL` | `https://tailspot.app/c` | Invite links are `<base>/<CODE>`. |
| `APNS_KEY_P8` | — (push off) | Contents of the APNs auth key (`.p8`), **not** a path. Newlines may arrive as literal `\n`; they're normalised. |
| `APNS_KEY_ID` | — (push off) | The 10-character key id — the JWT's `kid`. |
| `APNS_TEAM_ID` | — (push off) | The Apple Developer team id — the JWT's `iss`. |
| `APNS_BUNDLE_ID` | `com.landesberg.Tailspot` | The `apns-topic` header. |

If any of `APNS_KEY_P8` / `APNS_KEY_ID` / `APNS_TEAM_ID` is unset the sender is
a **no-op** that logs `push disabled` once at startup — nothing else changes.
Set them with:

```sh
fly secrets set -a tailspot-api \
  APNS_KEY_P8="$(cat AuthKey_XXXXXXXXXX.p8)" \
  APNS_KEY_ID=XXXXXXXXXX \
  APNS_TEAM_ID=YYYYYYYYYY
```

The `.p8` is a credential: keep it out of the repo (nothing in `backend/`
should ever hold one) and out of shell history.

**Providers.** Both aggregators speak readsb's API. adsb.lol's (`https://api.adsb.lol`) only
geographic query is point+radius (`GET /v2/point/{lat}/{lon}/{radius}`, radius
in NM) — so the adapter fetches the smallest circle covering the bbox and
filters back to the rectangle. readsb feeds report feet / knots and don't carry
`origin_country`, so the adapter converts to meters / m·s⁻¹ and derives the
country from the icao24 via the ICAO Annex 10 24-bit allocation table. Since
2026-10-20 **adsb.fi is the primary** and adsb.lol the failover (same adapter,
different host and path): adsb.lol now enforces a 500-requests-per-day cap per
client, which one polling phone exhausts in about 80 minutes. airplanes.live
was the failover until 2026-10-19, when it turned out to refuse Fly's network
outright (HTTP 403, "email us for access"); its adapter stays in the tree behind
`POSITION_PROVIDER=airplaneslive`. Since 2026-10-24, setting `ADSBLOL_REAPI_KEY`
swaps the failover to adsb.lol's keyed re-api, readsb's own query interface: same
rows, but under `aircraft` with `now` in seconds (`adsblolReapi.ts`). Route lookups (`/v1/routes`, the catch-time
route guess, the `route` field on `/v1/aircraft`) stay on adsb.lol, the only
aggregator with a route DB. They read static per-callsign files from
`vrs-standing-data.adsb.lol` and touch api.adsb.lol (and its daily quota) only
when that host fails to connect.

### Upstream quotas (observed from response headers, 2026-10-20)

| Feed | Published limit | How we stay under it |
|---|---|---|
| adsb.lol | `x-ratelimit-limit: 4, 4;w=1, 60;w=60, 500;w=86400` — 4/s, 60/min, **500/day** per client IP | Fallback only, plus per-callsign route lookups (30 min positive / 10 min negative cache). A 429 from any bucket is logged with the headers (`rateLimitSummary`). |
| adsb.fi | 1 req/s per IP; 4xx responses count toward a temporary IP restriction; personal, non-commercial; cite with a link | Primary. The tile cache allows one fetch per 0.25° tile per 10 s, and the upstream budget caps the whole process at 0.8/s however many tiles are active; a 429 or 403 opens adsb.fi's circuit breaker so we stop asking. The canary answers from organic traffic when a phone fetched within 120 s. |
| adsb.lol re-api (keyed) | Per-key counters over 1 h and 1 month, shared by every adsb.lol endpoint the key is sent to; the request page shows only % used, and success responses carry no `x-ratelimit` headers. Every 429 carries `Retry-After`, and **repeated 429s can revoke the key**. A bad key is HTTP 401 `invalid api key`. | Failover when `ADSBLOL_REAPI_KEY` is set. The circuit breaker opens at once on 429 or 401 and honours `Retry-After`. Probed from the Fly machine 2026-10-24: re-api answers 200 there with or without a key, although the docs say feeder IPs only. Don't rely on unkeyed access. |
| airplanes.live | Access by email approval; Fly's network gets 403 | Not in the default chain. |

**Why the readiness canary matters here.** The uptime monitor probes `/readyz`
once a minute from three regions. Before 2026-10-20 every probe outside the 10 s
tile TTL was an upstream fetch — about 1,440 a day, three times adsb.lol's
daily cap, which is how the dedicated egress IP got rate-limited eight hours
after it was allocated. The canary now answers `ok` (`source: organic`) when the
tile cache saw a successful fetch within 120 s and no failure since, and only
fetches for itself when there is no such proof — see
`TileCache.lastFreshFetchAt` / `lastFailureAt`.

## Running locally

```sh
cd backend
npm install
npm run dev        # starts with --watch; restarts on file changes
```

The server binds to `0.0.0.0:8080` by default. Override with `PORT=<n>`.

## Database & ingestion (WP 1.4)

Postgres via **Drizzle ORM**; schema in `src/db/schema.ts` (two tables:
`registry`, `typecodes`). Migrations are **generated and committed** — no
raw-SQL drift.

```sh
npm run db:generate   # drizzle-kit generate → drizzle/*.sql (run after schema edits)
DATABASE_URL=… npm run db:migrate   # apply committed migrations to the target DB
```

Two ingest jobs populate the tables. Both are **runnable scripts, not cron** —
Fly.io machines (or a GitHub Action) schedule the refresh later (see the plan).
Both upsert idempotently, so re-runs are clean.

### DOC 8643 typecodes

```sh
DATABASE_URL=… npm run ingest:doc8643 -- ../ios/Tailspot/Tailspot/AircraftTypes.json
```

The **single source of truth** is the repo's `ios/Tailspot/Tailspot/AircraftTypes.json`
(2,612 entries: typecode → `{ make, model, type, rarity }`), the same table the
iOS client bundles. We deliberately do **not** copy it into `backend/`; the path
is an argument so a deploy can mount it.

> **Build-time copy note (for the Docker/Fly image):** the JSON lives outside
> `backend/`, so it isn't in the Docker build context by default. Either (a) build
> the image from the repo root with a context that includes `ios/.../AircraftTypes.json`
> and `COPY` it in, or (b) run `ingest:doc8643` from a machine/job that has the
> repo checked out and can reach `DATABASE_URL`. Until the deploy wires this, run
> the ingest manually from a checkout. The file is ~120 KB — cheap to mount.

### FAA Releasable Aircraft Database

```sh
# 1. Download + unzip (manual / cron — NOT done by the test suite).
#    IMPORTANT: the FAA's Akamai front 403s curl's DEFAULT User-Agent. Pass a
#    browser UA so the GET returns HTTP 200 with a valid ZIP body:
curl -L -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36" \
  -o ReleasableAircraft.zip \
  https://registry.faa.gov/database/ReleasableAircraft.zip
unzip ReleasableAircraft.zip -d faa/           # → faa/MASTER.txt, faa/ACFTREF.txt (~250 MB unzipped)
# 2. Stream-parse + enrich + upsert:
DATABASE_URL=… npm run ingest:faa -- ./faa            # full registry
DATABASE_URL=… npm run ingest:faa -- ./faa --limit 1000   # smoke test
```

The importer **streams** `MASTER.txt` line-by-line (the files are large) joined
against `ACFTREF.txt` (manufacturer/model), keyed by `MODE S CODE HEX` → lowercase
`icao24`. US tails only, by construction.

**Typecode enrichment (WP 1.4b).** Each row's `MFR MDL CODE` is looked up in the
committed `data/faa-typecode-map.json` to attach an ICAO type designator
(`registry.typecode`), so `/v1/metadata/{icao24}` can merge in DOC 8643's clean
names + rarity (`source: "merged"`). A code with no mapping leaves `typecode` null
(`source: "faa"`, raw FAA names). The lookup is a flat Map read at runtime — no
fuzzy matching on the hot path. See **Rebuilding the typecode map** below.

> **Download UA requirement (verified 2026-06-10):** a `GET` with curl's default
> User-Agent **403s** at the Akamai edge; a browser UA (`Mozilla/5.0 …`) returns
> HTTP 200 with a valid ZIP. A bare `HEAD` returns 503 (a HEAD-method quirk, not
> an outage). If a scripted `GET` still 403s, download the zip manually from the
> FAA registry site and point `ingest:faa` at the extracted directory — the parser
> doesn't care how the files arrived.

### Rebuilding the typecode map (`data/faa-typecode-map.json`)

The committed map (`MFR MDL CODE` → ICAO designator) is built **offline** by a
reproducible Python script; the ingest reads it at runtime. Regenerate it when
the FAA registry or `AircraftTypes.json` changes:

```sh
# Download the FAA data with a browser UA (same Akamai requirement as above):
curl -L -A "Mozilla/5.0 ... Chrome/120.0 Safari/537.36" \
  -o /tmp/ReleasableAircraft.zip https://registry.faa.gov/database/ReleasableAircraft.zip
unzip /tmp/ReleasableAircraft.zip -d /tmp/faa/
python3 tools/build-typecode-map.py \
  --acftref /tmp/faa/ACFTREF.txt \
  --master  /tmp/faa/MASTER.txt \
  --out     data/faa-typecode-map.json
```

**Three-pass mapping strategy** (documented precedence; first hit wins):
1. **Family rules** — a curated `(canonical-make, model-prefix) → designator`
   table where the tail mass lives (Cessna 172\*, Piper PA-28\*, Beech 36\* …,
   each grounded in a DOC 8643 ModelFullName).
2. **Aircraft-characteristics xlsx join** — normalized FAA-naming join against
   `tools/data/faa_aircraft_characteristics.xlsx` (carries the ICAO designator).
3. **DOC 8643 normalized join** — `(make, model)` against `AircraftTypes.json`.
4. **Overrides** — a small per-code hand table for high-tail misses.

The script **validates** every emitted designator is a key in
`AircraftTypes.json` and runs ≥20 known-pair spot-checks (fails the build on a
mismatch), then reports **code-weighted and tail-weighted coverage** (the
MASTER.txt download is only needed for the tail-weighted number — omit `--master`
to skip it). `MASTER.txt`/`ACFTREF.txt` are **never committed**; only the
generated map is.

## Operator tools

### Disabling a device (`npm run device:disable`)

Identity here is anonymous — a device registers, gets a bearer token once, and
that's the whole account. There is no email, no password, and so no "ban the
account" lever. `devices.disabled_at` (migration `0009_device-disabled-at`) is
that lever: when it's set, the device's token resolves to nothing, so **every
bearer route answers 401**, the leaderboard answers "no me", and the device
drops out of the public leaderboard entries.

**Disable, never delete.** `catches`, `weekly_champions`, `monthly_champions`
and `alltime_toppers` all reference `devices.id`, so deleting a device either
fails on the foreign key or takes real catch history with it and silently
rewrites frozen crowns other players have already seen. Disabling touches one
column; every row the device ever wrote stays exactly where it is, and the
switch is **reversible** (`--enable`) — which matters, because an anonymous
user has no way to appeal a mistake.

The device is addressed by its uuid **or** its handle (matched
case-insensitively). The script **dry-runs by default**; pass `--apply` to write.

```sh
DATABASE_URL=… npm run device:disable -- <uuid|handle>                  # dry run: show what it would do
DATABASE_URL=… npm run device:disable -- <uuid|handle> --apply          # disable
DATABASE_URL=… npm run device:disable -- <uuid|handle> --enable --apply # undo
```

Re-disabling an already-disabled device is a reported no-op, so the original
`disabled_at` timestamp (the audit trail) is never stomped.

> **Migrations are applied to production MANUALLY** — there is no Fly
> `release_command`, so a deploy does *not* run them. `0009_device-disabled-at`
> must be applied (`DATABASE_URL=… npm run db:migrate`) **before** deploying the
> code that reads `disabled_at`, or every auth lookup 500s on a missing column.
>
> The same applies to **`0011_push-tokens-overtaken`** (device push tokens +
> the challenge placement memory), and the consequence of getting the order
> wrong is bigger than "pushes don't work". Drizzle names **every** column of a
> table in its INSERT statements, whatever the values object contains — so the
> moment `apns_token` and `last_placement` exist in `src/db/schema.ts`, an
> un-migrated database fails **device registration** (`POST /v1/devices`),
> **challenge creation** and **joining**, not just notifications.
> `test/seedBaseline.test.ts` pins that, so this warning can't quietly become
> untrue. The migration itself is additive — five nullable columns, no backfill
> — so applying it ahead of the deploy is always safe, and it is the only safe
> order.

## Tests

```sh
npm test           # vitest run (in-process, no network)
```

Tests use Fastify's `app.inject()` transport — the server never opens a real TCP
socket, so tests are fast and cannot conflict with a running dev server.

Database-backed tests (metadata merge/route, the two ingest pipelines) run
against **PGlite** — an in-process WASM Postgres officially supported by Drizzle
(`drizzle-orm/pglite`) — so they exercise the real merge query, ON CONFLICT
upserts, and the registry→typecode join with **no Docker and no external DB**.
Each test builds a fresh PGlite instance and replays the committed migration SQL,
so the test schema is identical to a freshly-migrated production database. (The
combo was verified working in vitest before the service was built on it; the
in-memory `Map` fallback the plan allowed for wasn't needed.)

## Typecheck

```sh
npm run typecheck  # tsc --noEmit, reports type errors without emitting files
```

## Lint / format

```sh
npm run lint       # biome check src test
```

[Biome](https://biomejs.dev) handles both linting and formatting in a single
pass (no separate Prettier + ESLint config to keep in sync).

## Building for production

```sh
npm run build      # tsc → dist/
node dist/index.js
```

Or via Docker (multi-stage; final image uses only production deps):

```sh
docker build -t tailspot-api .
docker run -p 8080:8080 tailspot-api
```

## Deploying to Fly.io

```sh
fly deploy   # from this directory; uses fly.toml + Dockerfile
```

Primary region: `sjc` (San Jose, CA). See `fly.toml` for machine/VM config and
health-check settings. Secrets (Postgres URL, adsb.lol key, etc.) are set via
`fly secrets set KEY=value` — never committed to the repo. `DATABASE_URL` is the
Fly managed-Postgres connection string.

After provisioning Postgres and setting `DATABASE_URL`, apply migrations and seed
the metadata tables once (then on each refresh):

```sh
DATABASE_URL=… npm run db:migrate
DATABASE_URL=… npm run ingest:doc8643 -- <path-to-AircraftTypes.json>
DATABASE_URL=… npm run ingest:faa -- <extracted-FAA-dir>
```

## Alerting

What pages Noah, and why each exists (all verified firing or configured
2026-10-19 after the sixteen-day feed outage nobody was told about):

| Signal | Where | What it catches | Notes |
|---|---|---|---|
| **Product is down** | Sentry uptime monitor 8072647 on `GET /readyz`, 60 s, 3 fails → issue → email | Process dead, DB unreachable, **position feed unable to serve planes** (both upstreams failing past the cache window) | The one monitor the free plan allows, so `/readyz` folds every dependency into one URL. |
| **Feed outage (in-process)** | `SustainedFallbackAlerter` → Sentry message `Position feed DOWN: both providers failing for ~N min` (level fatal, fingerprint `position-feed-outage`) | Both feeds failing on real traffic for 5+ min; one message per hour | Driven by `FallbackProvider.onBothFailed`; clears when either feed serves. |
| **Feed degraded** | Same alerter → `Position feed fallback sustained for ~N min` (level error, fingerprint `position-feed-fallback`) | the primary (adsb.fi) down, adsb.lol carrying the product — minutes, not hours, on its 500/day quota | Informational; users still get planes. |
| **Feed rejecting us** | Circuit breaker → Sentry message `Position feed <feed> is rejecting our requests: …` (level error, fingerprint `position-feed-rejected` + feed) | A 429 or 403 from adsb.fi or adsb.lol; at most one per feed per hour | adsb.fi counts 4xx answers toward an IP ban, so the first one matters. The message carries the rate-limit headers. |
| **Feed budget saturated** | Upstream budget → `Position feed request budget saturated for ~N min` (level error, fingerprint `position-feed-budget`) | More active tiles than 0.8 requests/s can refresh, for 5+ min; users get planes up to 30 s old, and cold tiles may 503 | The capacity signal: time to raise `UPSTREAM_RPS` (if adsb.fi allows), widen tiles, or add a feed. |
| **API 5xx rate** | `ErrorRateAlerter` (onResponse hook) → `API 5xx rate N% (x of y) over 5 min: <routes>` (level error, fingerprint `api-5xx-rate`) | 10+ 5xx answers that are also 5%+ of traffic in 5 min, any route except `/readyz` and `/healthz`; at most hourly | Covers deliberate 503 replies, which Sentry's error handler never sees. |
| **Website down** | `SiteProbe` in the API process → `Website down: <url> (…)` (level error, fingerprint `site-down` + url) | tailspot.app or its apple-app-site-association file failing 3 checks in a row (60 s apart); re-alerts hourly | The site has no uptime slot of its own; the AASA file is what makes invite links open the app. Blind when the API itself is down, but then `/readyz` is paging. |
| **New error** | Sentry issue rule 3591520 "Send a notification for high priority issues" → email | The first event of any new high-priority issue | This is ALL that fired during the outage: one email on 2026-09-25, then 38 silent repeats. |
| **Ongoing error** | Sentry issue rule "Ongoing error: hourly reminder…" → email, at most hourly per issue | Any error-level issue older than 30 min that keeps producing events | The fix for the row above: a repeat is a page, not a footnote. |
| **Users see the error pill** | PostHog alert on the `adsb_fetch_error_shown` insight, unique users per hour, checked hourly → email | The client-side view: phones showing "Tailspot unreachable", whatever the cause | Independent of the backend's own opinion; also catches an app-side break. |
| **iOS crashes** | PostHog alert on `metrickit_crash` (insight qVoxt9uL) | Crashes delivered by MetricKit | From 1.2.3 the event fires once per crash (it was once per payload with `crash_count`), so event-count series step up at that version. |
| **Dead app** | PostHog zero-DAU canary (daily) | A full day with no `Application Opened` | Unchanged. |

**The 2026-10 root cause is not fixed by any of this.** The Fly machine egresses
through Fly's *shared* IPv4 address, whose reputation is set by every tenant on
that host; adsb.lol's limits are "dynamic based on the environment load" (its
README) and airplanes.live sits behind Cloudflare. Both answered this laptop
instantly while refusing the machine. airplanes.live's 403 survived the dedicated IP: its body asks projects to email
contact@airplanes.live for access (a policy gate, not reputation), so the fallback
moved to **adsb.fi** the same night (`src/providers/adsbfi.ts`; confirmed 200 from
the machine). For adsb.lol the lever is a static egress IP, **allocated 2026-10-19**
(`fly ips allocate-egress --app tailspot-api -r sjc` → IPv4 209.71.113.155 plus an
IPv6, $3.60/mo, persists across deploys; `fly ips list` shows it as type `egress`).
It is still a Fly-range address, so a Cloudflare ASN-level block would survive it. adsb.lol also answers over IPv6 and says API keys
for feeders are coming; neither is wired yet.

### Not yet configured (phase 2 of the 2026-09-06 hardening — click-through checklist)

The traffic-shape alerts below can only be set up in a browser, not from the
CLI. Fly exposes the metrics in its hosted Grafana
(`fly dashboard metrics` opens it, or https://fly-metrics.net); create each as a
Grafana alert rule on the `tailspot-api` app with a notification to email.

| Signal | Metric (Fly Grafana) | Threshold | Why |
|---|---|---|---|
| 429 volume | `fly_app_http_responses_count{status="429"}` | > 30/min for 10 min | Either abuse hitting the limiters or a shipped client in a retry storm — both need eyes. |
| API memory | `fly_instance_memory_mem_available{app="tailspot-api"}` | < 40 MB for 5 min | The VM is 256 MB; the limiter and tile-cache maps are bounded now, but this is the tripwire if anything else grows. |
| DB memory | `fly_instance_memory_mem_available{app="tailspot-db"}` | < 40 MB for 5 min | The DB OOM'd once (2026-07-11). |
| Request rate | `sum(rate(fly_app_http_responses_count[5m]))` | > 3× the trailing-7-day same-hour median for 15 min | Volumetric abuse or a runaway client. Start with a fixed threshold (e.g. > 50 req/s) if the relative rule is awkward in Grafana. |

(The 5xx-ratio row that used to lead this table is now covered in-process by
the **API 5xx rate** alert above.)

Keep the in-code signals as they are: `/readyz` for process+DB+feed, Sentry
issues for exceptions, the two alerters for the upstream feed. Do not add a
challenge-based CDN in front of the API: the iOS client's `URLSession` cannot
solve one, and Fly's edge already absorbs L3/L4 floods (see PLAN §9, 2026-09-06).
