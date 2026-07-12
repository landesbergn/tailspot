# ADS-B Position + Aircraft-Metadata Sources: When and How to Move Off OpenSky

**Date:** 2026-06-07
**Author:** research (Claude) for Noah
**Scope:** Decision document for Tailspot's two data dependencies — (1) live ADS-B
positions polled in a bbox, (2) icao24 → make/model/type/registration metadata.
**TL;DR verdict:** Keep the current stack for now (OpenSky positions +
bundled-FAA metadata fallback is the right v0). The single highest-leverage next
step is **the planned Fly.io backend** — not a position-source swap. The backend
is what simultaneously (a) fixes the shared-credential exhaustion trap, (b) makes
an MLAT-capable community source usable *under its license*, and (c) hosts a
server-side merged registry so we stop bundling a stale FAA snapshot. There is no
clean cheap on-device shortcut to better coverage that doesn't violate someone's
terms at App-Store distribution scale.

---

## 0. Two facts that reframe the whole question

Before comparing providers, two verified findings change the framing from the
original "OpenSky coverage is spotty" to something sharper:

1. **We are already on thin terms ice with OpenSky.** OpenSky's General Terms of
   Use license the data "solely for the purpose of non-profit research and
   non-profit education," and state that "use of the REST API in any operational
   capacity — including integration into a live product, service, or automated
   system (even if only internal) — requires a previous written agreement."
   ([opensky-network.org/about/terms-of-use](https://opensky-network.org/about/terms-of-use)).
   A distributed iOS app polling every 20 s is an "operational capacity" /
   "live product." Tailspot being free does not make it non-profit *research*.
   So the move off OpenSky is partly a **compliance** question, not only a
   coverage one — and that nuance favors a provider whose license actually
   permits a distributed app.

2. **The app ships ONE baked OpenSky credential.** Per CLAUDE.md's credentials
   section, the `client_id`/`client_secret` are compiled into the binary. That
   means the registered tier's **4,000 credits/day is a single global bucket
   shared across every install**, not 4,000-per-user. Two or three testers
   spotting at the same time draw down the same bucket. This is the real
   exhaustion mechanism, and it is also the cleanest argument for a backend:
   one server-side poll per region serves every user, instead of each phone
   burning the shared quota.

---

## 1. Position-data (ADS-B) providers

### 1a. Two different API *shapes* — don't compare them as drop-in equals

Tailspot needs a **live-bbox** API: "give me every anonymous aircraft in this
rectangle right now, repeated every ~20 s." Only one class of provider is shaped
that way. A second class (FlightAware AeroAPI, Flightradar24) is **flight-status**
shaped — query by flight ident / airport / route — and is priced per result.
They are covered below for completeness, but they are the *wrong shape* for
continuous AR polling regardless of price.

**Live-bbox class** (the real candidates): OpenSky, ADS-B Exchange, and the
community feed networks (airplanes.live, adsb.lol, adsb.fi).

### 1b. Comparison — live-bbox sources

Quotas normalized to **device-hours of 20 s polling** (1 poll / 20 s = 180
polls/hr). The field bbox (a local Berkeley/SFO spotting rectangle) is well under
25 sq°, so on OpenSky it costs **1 credit/poll** — that's the assumption behind
the device-hour math below.

| Source | Coverage (MLAT/GA?) | Latency | Rate limit / quota | Device-hrs @ 20 s | Cost | License for a distributed app |
|---|---|---|---|---|---|---|
| **OpenSky** (current) | ADS-B only on free tier; **no MLAT** → small GA / heli / military mostly invisible | ~5–10 s typical | 400 (anon) / 4,000 (registered) / 8,000 (feeder ≥30% uptime) / 14,400 (licensed) credits/day; ≤25 sq° bbox = 1 credit | anon ≈ **2.2 hr/day**; registered ≈ **22 hr/day** — *shared across all installs* | Free | ❌ "non-profit research/education" only; operational/live-product use needs a **written agreement** |
| **airplanes.live** | **MLAT included**, unfiltered (incl. military) | ~real-time | **1 req/s**, no key, feeding not currently required | ~unlimited at 1 poll/20 s | Free | ⚠️ "non-commercial use, no SLA"; **separate commercial agreement exists** (page exists; could not fetch — see note) |
| **adsb.lol** | **MLAT included**, unfiltered | ~real-time | dynamic (load-based); no key today; API key "in future, by feeding" | ~unlimited at 1 poll/20 s | Free | ✅ **ODbL 1.0** — *permits commercial use* with attribution + share-alike (see §1d) |
| **adsb.fi** | **MLAT included**, unfiltered | ~real-time | **1 req/s** public; no key | ~unlimited at 1 poll/20 s | Free | ❌ "personal, **non-commercial use only**… may not license, sell, rent or lease" — most restrictive |
| **ADS-B Exchange** (Community API via RapidAPI) | **MLAT included**, largest unfiltered network, 500 ms updates | sub-second | **10,000 req/mo** | ≈ **1.8 hr/day** total — tight for even one active user | **$10/mo** (Community); enterprise = quote | ⚠️ Community tier targets "non-commercial… weekend builds"; commercial needs enterprise tier |

Sources: OpenSky credits + quotas
([rest.html](https://openskynetwork.github.io/opensky-api/rest.html)), OpenSky
terms ([terms-of-use](https://opensky-network.org/about/terms-of-use)),
airplanes.live ([api-guide](https://airplanes.live/api-guide/)), adsb.fi
([opendata README](https://github.com/adsbfi/opendata/blob/main/README.md)),
adsb.lol ([API docs](https://www.adsb.lol/docs/open-data/api/),
[github](https://github.com/adsblol/api)), ADS-B Exchange
([developer hub](https://www.adsbexchange.com/community/developer-hub/)).

### 1c. The MLAT point (fixes coverage problem #1)

OpenSky's free tier excludes MLAT, which is exactly why small GA, helicopters, and
military are invisible in Berkeley. **Every community network and ADS-B Exchange
include MLAT** in their feeds — so any of them materially improves the GA/coverage
gap. This is the headline coverage win. The catch is entirely in the licensing and
distribution model (§1d, §3), not the data.

"Must you feed data to read?" — **No, for now**, on airplanes.live, adsb.lol, and
adsb.fi: public read endpoints currently require no feeder and no key. All three
warn this *could* change (adsb.lol explicitly plans a feed-gated API key). Feeding
is a contribution ask, not a present requirement.

### 1d. Licensing is the real differentiator, and the three community nets differ

Do **not** lump the community networks together. They sit on three different
licenses, and this flips the ranking for a *distributed* app:

- **adsb.fi — most restrictive.** Verbatim: "personal, non-commercial use only.
  You may not license, sell, rent, or lease any part of the data or the service."
  A public App-Store app is arguably outside "personal use." Avoid relying on it
  at distribution scale.
- **airplanes.live — non-commercial + a commercial path.** Search-confirmed as
  "non-commercial use, no SLA," with a dedicated commercial-data page for paid
  access. **Flag:** I could not fetch their primary Terms-of-Use or commercial
  pages directly (HTTP 403 to the fetch tool), so the exact wording of what
  counts as "commercial" for a free distributed app is **unverified** — treat the
  non-commercial framing as from secondary snippets, and read the page before
  committing.
- **adsb.lol — most distribution-friendly.** Licensed **ODbL 1.0**
  ([docs](https://www.adsb.lol/docs/open-data/api/)). ODbL is the OpenStreetMap
  license: it **permits commercial use**. Its conditions are *attribution*,
  *share-alike*, and *keep-open*. The share-alike catch matters for Tailspot's
  roadmap: if our planned public hangars / leaderboards derive a "produced
  database" from adsb.lol data, ODbL share-alike could attach to that derived DB.
  That's a nameable design consideration, not a blocker, and it makes adsb.lol the
  standout community source for a distributed app — *better than OpenSky's own
  research-only license*.

### 1e. Flight-status APIs (wrong shape — covered for completeness)

| Source | Why it's wrong shape | Pricing (verified) | Verdict |
|---|---|---|---|
| **FlightAware AeroAPI v4** | Query by flight ident / airport, not "all traffic in bbox." A bbox search (`/flights/search`) exists but is billed **per result set (15 records)** with paging — continuous polling of dozens of planes is cost-absurd | $5/mo free ($10 for feeders), then per-query: `/flights/{ident}` $0.005, `/flights/search` $0.050, `/flights/{id}/position` $0.010, all per result-set; **$100/mo Standard minimum** | ❌ Not for continuous AR polling |
| **Flightradar24 API** | Credit-weighted per call; live-positions calls consume credits fast | Explorer **$9/mo** (30k credits), Essential **$99/mo** (450k), Advanced **$900/mo** (4.05M). Sandbox is free for dev. **Per-bbox-call credit cost: unverified** — could not pin how many credits a live-positions bbox query consumes | ❌ Restrictive + credit cost unclear |

Sources: [AeroAPI](https://www.flightaware.com/commercial/aeroapi),
[FR24 subscriptions](https://fr24api.flightradar24.com/subscriptions-and-credits).

### 1f. Commercial feeds (Spire, etc.)

Spire Aviation, FlightAware "Firehose," and similar enterprise feeds offer
global ADS-B + satellite coverage but are sold on **annual enterprise contracts**
(typically four–five figures/yr). **Out of budget for a free hobby app — noted and
dismissed.** Not worth pricing precisely.

---

## 2. Aircraft-metadata / registry sources (icao24 → identity)

The metadata problem is separable from positions and has a different shape: it's a
**lookup table**, not a live feed, so it caches/bundles well and rarely needs to be
real-time.

| Source | Coverage | The gap | Cost / terms |
|---|---|---|---|
| **OpenSky metadata DB** (current `/metadata/aircraft/icao/{icao24}`) | Crowd-sourced, global-ish but incomplete | **Hard 404s on a real slice of US traffic** (verified in-repo: Cirrus SR20 `a9eefa`, Embraer E175 `a8d71c`). hexdb.io and adsbdb 404 the same airframes — shared lineage | Same research-only OpenSky terms as §0 |
| **FAA Releasable Aircraft DB** (what we bundled) | **313k US tails, authoritative** | **US-only by construction.** Static snapshot → staleness (new regs, re-regs, deregs drift). Refreshed daily at source | **Public domain** — "all digital products published by the FAA are in the public domain… a written release or credit is not required" ([FAA](https://www.faa.gov/licenses_certificates/aircraft_certification/aircraft_registry/releasable_aircraft_download)). Free to redistribute |
| **Other national registries** (EASA / UK CAA / Transport Canada / etc.) | Fill the foreign gap | **No single global registry.** Each is a separate download with its own format/terms; many are not as freely redistributable as the FAA's. This is the "Korean tail we couldn't resolve" problem — South Korea is not covered by FAA and has no published address algorithm | Varies; effort-heavy to merge |
| **ICAO DOC 8643** (already bundled) | typecode → type/manufacturer | Only resolves *type designators*, not individual tails. Complements registry, doesn't replace it | Public reference |
| **Commercial DBs** (planespotters.net, ch-aviation, others) | Broad, curated, photos | planespotters.net API already used for **photos**; ch-aviation is subscription | Cost + terms; planespotters is fine for images, not bulk metadata redistribution |

### 2a. The deterministic icao24 → registration decode (narrow but free)

For the **US 'A' block**, the icao24 → N-number mapping is a published
deterministic algorithm (sequential `a00001` = N1 … `adf7c7` = N99999) — no lookup
table needed ([icao-nnumber_converter](https://github.com/guillaumemichel/icao-nnumber_converter)).
A few other countries (Canada, Germany, France, Australia) have algorithmic
schemes; most do **not** publish theirs, and most countries need a registry table.

**Honest value assessment:** this decode yields **registration only, not
make/model/type** — it's a free reverse-lookup, not a metadata fix. It's worth
adding as a cheap "always show a tail number even when metadata 404s" fallback for
US aircraft, but it does not close the identity gap (you still don't know it's a
Cirrus). Low effort, marginal payoff; do it if/when the backend merge happens, not
as standalone work.

### 2b. The global gap persists even server-side — say it plainly

A server-side merged DB (OpenSky + FAA + ICAO 8643) gives near-complete **US**
identity. It does **not** solve foreign tails (the Korean airframe) unless we
also ingest each foreign registry — which is open-ended effort with mixed
redistribution terms. The merged DB raises the US hit-rate to ~100% and the
global hit-rate modestly; don't oversell it as "global identity solved."

---

## 3. Architecture: device-direct vs backend proxy/cache

### 3a. The current device-direct model

Each phone independently authenticates and polls OpenSky, and each app build
bundles the FAA snapshot. This is simple and has zero server cost — correct for
v0. Its three structural problems all converge on the same fix:

1. **Shared-credential exhaustion** (§0.2): one baked credential → one global
   4,000/day bucket → exhaustion scales *down* with user count, not up.
2. **Terms exposure** (§0.1): N phones each making "operational" OpenSky calls,
   or each hitting a "personal-use-only" community API, multiplies the
   terms-compliance problem by install count.
3. **Stale bundled metadata**: the FAA snapshot is frozen at build time; updating
   it means shipping a new app build through review.

### 3b. How a backend fixes both problems at once

A thin proxy (the PLAN.md provider-abstraction seam,
`getAircraftInBbox(...) → [Aircraft]`) addresses positions **and** metadata:

- **Positions:** one server-side polling loop per active region, cached and
  fanned out to all users. Cuts API credit/req burn from O(users) to O(regions),
  and means **one client under one license** — which is what makes an MLAT
  community source (adsb.lol under ODbL, or airplanes.live's commercial path)
  actually usable for a distributed app. This is the only path to better coverage
  that doesn't put a personal-use API key in every binary.
- **Metadata:** a server-side merged DB (OpenSky + FAA + ICAO 8643 + future
  registries) returns clean icao24 → identity without bundling a 3.6 MB snapshot
  in the app, and refreshes from the FAA daily drop without an App-Store release.

### 3c. Rough cost/perf at hobby scale (a few–dozens of users)

- **Hosting:** Fly.io's smallest always-on machine + a small managed Postgres is
  roughly **$5–15/mo** at this scale (shared-CPU 256–512 MB VM + a few-GB
  Postgres). *Flag: Fly.io pricing shifts; treat as an estimate, confirm against
  their current pricing page before committing.*
- **Polling budget:** one server polling a Berkeley bbox at 20 s on OpenSky's
  registered tier = ~22 device-hr/day equivalent for **all** users combined,
  vs. today's per-phone draw. On a community MLAT source at 1 req/s the budget is
  effectively unconstrained. Either way the backend *reduces* total external
  calls.
- **Caching:** cache the bbox response for the poll interval (~5–20 s); serve all
  users in that region from one upstream fetch. Metadata: cache per-icao24
  permanently (it's near-static), refresh registry tables from the FAA daily drop.
- **Staleness:** registry data tolerates daily refresh; positions need
  near-real-time, so don't over-cache positions.

### 3d. Where the bundled FAA snapshot fits

**Keep it as the interim and offline fallback.** It already works, ships now, and
needs no server. It should **migrate server-side when the backend lands** — at
that point the server holds the merged DB and the app can drop the 3.6 MB bundle
(or keep a smaller cached subset for offline use). Until the backend exists, the
bundle is the right call; don't build a metadata server before the position
backend it would live inside.

---

## 4. Recommendation — phased

### Now / near-term — KEEP the current stack

- **Positions: stay on OpenSky.** It's free, the coverage is adequate for
  airliner-spotting (the confirmed-sighting data in CLAUDE.md shows real catches
  are airliners ≤ 8.3 km — exactly what OpenSky's ADS-B-only feed covers well),
  and the shared-bucket exhaustion is tolerable at 1–3 testers. The terms
  exposure is real but low-risk at internal-TestFlight scale.
- **Metadata: keep bundled-FAA + OpenSky + ICAO 8643.** This is a good interim
  fix. Don't invest more in on-device metadata.
- **Cheap add (optional):** the US icao24 → N-number decode (§2a) as a
  "tail-number always shows" fallback. Small, but only if it's near-free to wire.

### Trigger conditions — move off OpenSky / device-direct when ANY of:

1. **Shared credential exhausts in normal use** — i.e. concurrent testers start
   hitting 429s during a session (the global 4,000/day bucket, not per-user). At
   ~22 device-hr/day shared, this is roughly **4+ simultaneous active spotters**.
2. **User count crosses ~5–10 installs** — past which the baked-credential model
   is both an exhaustion and a terms liability.
3. **GA/MLAT coverage becomes central to gameplay** — e.g. a "catch a Cessna /
   helicopter / military" mode. OpenSky free literally cannot see those; that
   feature *requires* an MLAT source, which *requires* the backend to use legally.
4. **Any move toward public distribution beyond TestFlight** (App Store, external
   testers at scale) — at which point OpenSky's "operational use needs a written
   agreement" and the community nets' personal-use terms become real, not
   theoretical.

### Mid-term — the backend, with these specific choices

- **Build the Fly.io + Postgres backend** (already on the roadmap; this just makes
  it the priority). It's the keystone.
- **Position source through the backend:** start with **OpenSky** behind the proxy
  (one client, easiest migration), and add an **adsb.lol adapter** as the
  MLAT-coverage upgrade — chosen specifically because **ODbL permits a distributed
  app** where adsb.fi forbids it and OpenSky restricts it. Honor ODbL attribution;
  watch share-alike if public hangars derive a database. If adsb.lol's reliability
  proves insufficient, **airplanes.live's commercial agreement** is the paid
  fallback (read their actual terms first — §1d flag). ADS-B Exchange Community
  ($10/mo, 10k req/mo) is too quota-tight for a backend serving multiple users.
- **Metadata: server-side merged DB** = FAA (daily refresh) + OpenSky + ICAO 8643,
  with foreign registries added opportunistically (not up front).

### The single highest-leverage next step

**Build the backend proxy + cache.** It is the one move that addresses *all*
problems at once: it ends the shared-credential exhaustion, it's the only
*legal* route to an MLAT source (fixing the GA coverage gap) for a distributed
app, and it lets the merged metadata DB live server-side instead of as a stale
bundle. Every other improvement (better positions, better metadata, foreign
tails) is gated behind it.

### Honest effort / cost

- **Effort:** the backend is a **multi-week** build (PLAN.md already scopes it as
  Phase 1). It's not a weekend task. But it's already planned for accounts /
  leaderboards / anti-cheat — the data-sourcing win is a *free rider* on work
  that's coming anyway. That's the real reason to do it: not new effort, just
  *sequenced first*.
- **Recurring cost:** ~**$5–15/mo** hosting (estimate — verify Fly.io's current
  pricing) + $0 data if on OpenSky/adsb.lol, or airplanes.live's commercial fee if
  reliability forces the paid path. Materially cheaper than any per-query
  commercial API.
- **Cheapest path to materially better coverage + accuracy:** there isn't a clean
  *cheap on-device* one — "just swap to a community MLAT network on the phone"
  violates personal-use terms (adsb.fi) or puts an ungoverned key in every binary,
  and ADS-B Exchange's quota is too small. The cheap win and the right win are the
  same move: the backend, pointed at adsb.lol for MLAT and hosting the merged FAA
  DB.

---

## Appendix: claims I could NOT fully verify (flagged per the brief)

- **airplanes.live primary terms** — their Terms-of-Use and commercial-use pages
  returned HTTP 403 to the fetch tool. The "non-commercial use, no SLA" framing is
  from secondary search snippets, not the primary page. Read the page before
  relying on airplanes.live.
- **FR24 per-bbox-call credit cost** — confirmed the plan prices ($9/$99/$900 mo)
  but not how many of the 30k Explorer credits a single live-positions bbox query
  consumes. Could be far fewer effective device-hours than the raw credit count
  suggests.
- **Fly.io hosting cost** — the $5–15/mo figure is a scale-based estimate, not a
  quote from their current pricing page.
- **adsb.lol exact rate limit** — documented as "dynamic, based on load"; no fixed
  number published. At 1 poll/20 s from a single backend this is a non-issue, but
  there's no hard SLA.
- **ADS-B Exchange Community tier** — $10/mo + 10k req/mo confirmed via the
  developer hub; the precise commercial-vs-non-commercial line for a free
  distributed app at the Community tier is not spelled out (enterprise tier exists
  for commercial).
