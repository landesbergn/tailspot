# Tailspot content engine (v0)

Makes one ready-to-post short-form carousel a day from **real** data: 5–6 PNG
slides at 1080×1920, `caption.txt` and `post.json`. It's Loop 2 of the
growth plan (`docs/plans/2026-10-03-growth-to-1000-wau.md`, "Loop 2:
automated content engine"). v0 renders posts but doesn't publish them. A
person, or a later Postiz step, does the posting.

The rule from `web/README.md` applies here too: **never fabricate flights.**
Tailspot's whole pitch is that the identification is real. Every aircraft on a
slide comes from public ADS-B at capture time, from one of Noah's own
recorded catches, or (real-catches) from a real Tailspot user's catch, shown
only at the privacy level below.

## Run it

```sh
cd tools/content-engine
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install   # playwright is the only dependency
npm run generate                                  # today's template, live data → out/<date>-<template>/
npm run generate -- --template real-catches       # real user catches from PostHog
npm run generate -- --template over-city --city tokyo
npm run generate -- --template rare-now --dry-run # fetch + select, print JSON, no render
npm run generate -- --template guess-plane --fixture --catch b767
npm test                                          # node:test, offline, fixtures only
```

This needs Node ≥ 22.6, which runs the TypeScript directly with
`--experimental-strip-types`, the same way the backend's dev script does. There
is no build step. `npm run generate` sets `NODE_USE_ENV_PROXY=1` so Node's
built-in `fetch` honours `HTTPS_PROXY` in the cloud agent environment (a no-op
elsewhere). Rendering uses Playwright's Chromium. In the cloud agent
environment Chromium is already installed under `PLAYWRIGHT_BROWSERS_PATH`
(`/opt/pw-browsers`), so **never run `playwright install` there**. On a Mac,
run `npx playwright install chromium` once.

| Flag | Meaning |
|---|---|
| `--template <id>` | `real-catches`, `rare-now`, `over-city`, `guess-plane`. Default: rotate by date |
| `--date YYYY-MM-DD` | Post date. Drives the rotation and the seeded choices. Default: today (UTC) |
| `--out <dir>` | Output directory. Default: `out/<date>-<template>/` (gitignored) |
| `--dry-run` | Print the selection, caption and sources as JSON. Doesn't render |
| `--fixture` / `--fixture-path <f>` | Read `fixtures/<template>.json` (or `<f>`) instead of the network |
| `--save-fixture <f>` | After a live fetch, save the raw inputs as a fixture (the rotated/requested template's, even if the run then falls back) |
| `--city <id>` | over-city only: `sf-bay`, `london`, `nyc`, `tokyo`, `sydney`, `bali` |
| `--catch <id>` | guess-plane only: `b737`, `b767`, `a321`, `a220`, `bd700` |
| `--no-stats` | Skip Tailspot's `/v1/stats` |
| `--keep-html` | Also write each slide's HTML, for debugging the layout |

Exit code 0 means a carousel was written, and stdout's last line is its
directory. On failure the exit code is 1 and the message goes to stderr.

### Output

```
out/2026-10-04-rare-now/
  slide-01-hook.png … slide-06-cta.png   1080×1920 (real-catches has 5)
  caption.txt     hook as line 1, caption body, ODbL credit, then 3–5 hashtags (paste-ready)
  post.json       template, params, subject, every data source + fetch time,
                  per-slide alt text, platform modes, postable flag
```

**Check `post.json` → `postable` before posting.** It is `false` for anything
built from a synthetic fixture, and for any replay of a live fixture, because
"right now" is stale by then. It is `true` for live runs, and for guess-plane,
whose data is a fixed real catch.

## Templates (7-day rotation: day N → N mod 7)

The rotation is `real-catches, rare-now, real-catches, over-city,
real-catches, guess-plane, real-catches`: real catches are the primary format
(4 days of 7), the other three get a day each. When a rotated template can't
fetch or finds nothing worth posting, the CLI walks a fallback chain:
**real-catches → rare-now → guess-plane**, and the other live templates →
guess-plane. An explicit `--template` never falls back.

0. **`real-catches`, "Real catches".** A rare+ plane that a real Tailspot
   spotter caught, from the app's own `catch_performed` analytics events in
   PostHog. Subject: the highest tier caught in the last 48 h, then the most
   recent (the last 7 days if 48 h has nothing), skipping private GA/bizjets.
   Slides: hook ("A Lufthansa 747-8 was just caught in the San Francisco
   area.", HUD designator, tier badge + points) → the aircraft (operator, type
   code, tier, size, the `TYPE_FACTS` line and what the tier means) → how it
   was caught (phone at the sky, matched to live ADS-B, collected) → up to 5
   other rare+ catches from the week as model + place + day (one per model and
   place, distinct models first) → CTA. The caption says "caught by a
   Tailspot spotter" and carries no adsb.lol credit, because no ADS-B data is
   shown. No eligible catch throws, and the rotation falls back to rare-now.
1. **`rare-now`, "Rare right now".** Picks one notable aircraft airborne at
   capture time. It reads `GET /v2/mil` plus `GET /v2/type/{A388,B748,B744,B742,A124,IL76,AN22,MD11,DC10,L101}`
   and takes the highest Tailspot tier present (rare or above). Within that
   tier it picks a *type* first, seeded, so 20 tankers can't crowd out one
   bomber. Slides: hook (HUD designator + tier) → callsign / registration /
   country → region, altitude, speed and a heading compass → one checked fact
   + points → up to 4 other rare types airborne now → CTA.
2. **`over-city`, "What's over [city] right now".** Reads `GET /v2/point/{lat}/{lon}/30`
   around the SF Bay Area, London, NYC, Tokyo, Sydney or Bali (the city
   advances every 3 days). Slides: hook with local time → airborne count by
   kind → rarity mix and "this sky is worth N pts" → rarest *catchable* plane
   (best tier; ties go to the lowest, the one you could actually see) → top 5
   types → CTA.
3. **`guess-plane`, "Guess the plane".** Uses one of Noah's real catch photos
   from `marketing/catch-photos/`. Slides: photo → 3.2× zoom + A–D → clues
   from the recorded ADS-B → "lock it in" → answer with callsign, operator and
   route → CTA. The distractors come from the same class with lookalike
   families excluded (no 737-800 vs 737-900). This template needs no network,
   so it's the **fallback** when adsb.lol is down or a live template finds
   nothing worth posting. `post.json` records `fallbackFrom` when that happens.
   It used to advance its photo every 3 days; it now advances daily, because
   it runs on random days as the fallback. over-city advances its city once a
   week, matching its one slot in the rotation.

The last slide is always the CTA: "Catch the planes flying over you",
tailspot.app, and the App Store badge. When `/v1/stats` answers, it adds the
rounded-down catch count ("5,800+ planes caught so far").

Tiers come from the app's own `ios/Tailspot/Tailspot/AircraftTypes.json` and
points from the same ladder as `backend/src/catches/points.ts`, so the post
says what the app would say. Fact lines live in `src/aircraftTypes.ts`
(`TYPE_FACTS`). Keep them checkable.

### Design

Slides follow the brand: carbon-dark sky gradient, signature cyan, B612 Mono
for data (loaded from the app's bundled TTFs), Inter for prose (bundled in
`assets/fonts/`, SIL OFL 1.1) and the app's rarity tints. **Safe zones:** all
text sits inside left 72 / right 140 / top 150 / bottom 400 px, so the TikTok,
Reels and Shorts overlays (bottom ~20%, right ~12%) never cover it. Only the
background crosses those lines. `examples/` holds one downscaled slide per
template. The rare-now and over-city examples carry the SAMPLE DATA stamp,
because they were rendered from synthetic fixtures (see below).

## Data sources

| Source | Endpoint | Auth | Notes |
|---|---|---|---|
| adsb.lol | `/v2/mil`, `/v2/type/{T}`, `/v2/point/{lat}/{lon}/{nm≤250}` | none | ODbL 1.0. Credit "adsb.lol (ODbL)" on every data slide and in the caption. Rate limits depend on load: calls are paced 1.1 s apart, 429/5xx are retried with backoff, and two straight failures stop the run early |
| PostHog (Tailspot's own analytics) | `POST https://us.i.posthog.com/api/projects/@current/query/` with `{"query":{"kind":"HogQLQuery","query":"…"}}` | Injected by the cloud environment's egress proxy, so no key in code. If `POSTHOG_PERSONAL_API_KEY` is set (e.g. on a Mac) it is sent as a Bearer token | real-catches only. The query (`CATCHES_QUERY` in `src/templates/realCatches.ts`) selects only rarity, manufacturer, model, operator, typecode, IP-geo city and country, the **date**, and a server-computed "within 48 h" flag, for rare+ non-duplicate `catch_performed` events from the last 7 days, excluding sky-gate `notSky` rejects. Rows come newest first, so the exact time never leaves PostHog |
| Tailspot | `GET https://api.tailspot.app/v1/stats` | `Origin: https://tailspot.app` | `backend/README.md` documents that a non-browser caller sending the site's Origin is fine, because the number is on the homepage anyway. Any failure means no number, never a 0 |

The endpoint paths and response shapes were checked against adsb.lol's source
(`github.com/adsblol/api`, `src/adsb_api/utils/api_v2.py`: readsb "re-api"
JSON `{ ac: [...], now, total, msg }`) and against the backend's own adsb.lol
adapter and its fixture. They were **not** checked live: the environment this
was written in blocks `api.adsb.lol` and `api.tailspot.app` at its egress
proxy. The first live run should be a `--dry-run`.

**Not used, on purpose:** the leaderboard. Handles are public inside the app,
but putting a player's handle in a TikTok is a different kind of exposure that
nobody opted into. The engine also never touches the backend's catches,
devices, invites or anything behind a bearer token. Real catches come only
through the PostHog query above, at the level in privacy rule 6.

## Privacy rules (enforced in `src/privacy.ts`, tested)

Privacy policy §5 and the growth plan's guardrail say that user photos never
leave the phone and catch GPS is never shown. This engine therefore uses only
public ADS-B, the public aggregate count, Noah's own photos, and (rule 6) real
catches reduced to model, city and day. On top of that:

1. **Opt-outs are honoured.** Aircraft flagged FAA LADD or PIA (`dbFlags` bits
   3 and 2) are never named on a slide, even though adsb.lol still publishes
   them.
2. **No private individuals.** Privately operated GA and business aircraft are
   never spotlighted, because a private jet's tail number tracks a person.
   Fleets are fine: airline, cargo, fractional (ICAO-style callsign) and
   military. The same rule applies to Noah's photos, which is why the
   N561SR Citation is excluded from `src/catches.ts`.
3. **Region-level positions only.** Slides say "about 210 km SE of Fairbanks"
   or "over the North Atlantic", never coordinates. A test fails if a slide
   carries a 3+ decimal number.
4. **"Right now" means now.** Positions older than 60 s and aircraft on the
   ground never count as airborne.
5. **Aggregate counts** (over-city's totals) include every aircraft. A number
   identifies nobody.
6. **Real user catches: model, city, day. Nothing else.** *Decision: Noah,
   2026-10-04.* Promotional posts may feature real Tailspot user catches at
   exactly this level: the aircraft model (+ operator/airline), the city and
   the day. **Never** the spotter's handle, the registration, callsign or
   icao24, photos, coordinates, origin/destination, the time of day, or
   anything else per-user. It is enforced in layers: the HogQL query never
   selects those properties; `projectCatchRows` drops any column outside
   `CATCH_COLUMNS` (`src/privacy.ts`) before the data is used or saved as a
   fixture; operator and city strings that look like identifiers (no
   lowercase letters, `@`, digits in a city) are ignored; and a test feeds a
   malicious fixture carrying handle/registration/callsign/icao24 columns and
   asserts none of them reach any slide, caption, alt text or `post.json`.
   The city is IP geolocation, so it's approximate and phrased that way: "in
   the San Francisco area" (suburbs fold into their metro, so Concord and
   Oakland both read as San Francisco), otherwise "near Tucson" / "near
   Denpasar, Indonesia". Rows without a city are dropped. The day is in the
   PostHog project's timezone. Rule 2 applies too (`isCatchSpotlightable`):
   a GA or business type (an Epic E1000, a Global, a Gulfstream) is shown only
   when its operator is an airline, cargo carrier or military/government unit.
   Charter-management and fractional brands don't count, because a catch has
   no callsign to tell a fleet leg from an owner's trip. Military types are
   fine (the T-38, which the type table classes as GA, is treated as military).
7. **Later:** opt-in "submit to Tailspot's feed" user photos need a privacy
   policy update first. Until then, no user photos or other user content
   beyond rule 6.

## Fixtures

One per template in `fixtures/`, replayed with `--fixture`.

- `real-catches.json` is **real**: a live PostHog capture from 2026-10-04
  (`--save-fixture`). It holds only the `CATCH_COLUMNS` (model, operator,
  city, day, …), never a personal field, because those are never selected.
  It includes private bizjets (Global Express, Gulfstream G650, Epic E1000)
  that the privacy test checks never surface. A replay is not postable
  (stale "just caught").

- `guess-plane.json` is **real**: it just pins the photo. The data is Noah's
  recorded catch.
- `rare-now.json` and `over-city.json` are **synthetic** (`"synthetic": true`).
  They use the exact adsb.lol response shape, but they were hand-built because
  the dev environment couldn't reach adsb.lol. Their callsigns are
  illustrative, and they deliberately include edge cases: a LADD-flagged F-35,
  a stale B-1, a grounded E-6, and a private N-reg G650 at the same tier as
  the A380 it must lose to. Every slide rendered from them carries a
  **SAMPLE DATA · NOT A REAL SIGHTING** stamp, and `postable` is `false`.

To replace them with real captures (keep the edge-case tests passing, or move
the edge cases into inline test rows):

```sh
npm run generate -- --template rare-now  --dry-run --save-fixture fixtures/rare-now.json
npm run generate -- --template over-city --city london --dry-run --save-fixture fixtures/over-city.json
```

## The daily routine (planned, not wired yet)

```
cron (Claude Code routine, fresh session, ~07:00 PT)
  └─ cd tools/content-engine && npm ci && npm run generate          # live data, rotated template (real-catches 4 days of 7)
  └─ agent reads post.json + looks at each PNG (sanity: postable, no SAMPLE stamp, text legible)
  └─ Postiz: upload the 6 PNGs + caption.txt
       ├─ Instagram  → auto-publish carousel
       ├─ YouTube    → auto-publish Short (needs a video: slideshow the PNGs first, see below)
       └─ TikTok     → DRAFT (inbox upload). The Content Posting API only allows
                       private/self-only direct posts until TikTok audits the app,
                       so Noah opens the draft, adds a trending sound, posts (~1 min)
  └─ next morning: read each post's views via Postiz analytics, log them,
     and weight the rotation toward the hook formats that perform
```

What's still to build, in order:

1. **`post.ts`**, a small step that reads `post.json` and calls Postiz's public
   API: upload media, then create one post per channel, TikTok as draft. Check
   the current endpoint names in the Postiz docs when wiring it. It must refuse
   to post when `postable` is `false`.
2. **Shorts video.** YouTube Shorts and Reels-as-video need an MP4. Make it
   with `ffmpeg -framerate 1/3 -i slide-%02d.png -c:v libx264 -pix_fmt yuv420p -r 30 out.mp4`
   (about 3 s per slide). Instagram can take the PNGs as a carousel directly.
3. **Feedback loop.** Store per-post views, then let the rotation favour
   winners. The growth plan's kill rule applies: if 30 posts average under 1k
   views, change formats before adding volume.
4. Optional spin-off: the same renderer could drive a labeled Bluesky/Mastodon
   "notable aircraft over the Bay Area" bot.

**Cloud environment egress:** the routine's environment must allow
`api.adsb.lol`, `api.tailspot.app` and `us.i.posthog.com` (with PostHog
credentials injected by the proxy), plus the Postiz host once posting is
wired. On 2026-10-04 all three answered from the cloud sandbox (the 10-03
sandbox blocked the two API hosts). Without them, every run falls back to
guess-plane, which works but repeats five photos.

## What Noah needs to create

| What | Why |
|---|---|
| **TikTok** account for Tailspot (one avgeek-voiced account), connected in Postiz | Drafts land in its inbox. Postiz's own TikTok integration avoids needing your own TikTok developer app and audit for now |
| **Instagram Professional** (Business or Creator) account, linked to a **Facebook Page** | The Instagram Graph API, which Postiz uses, only publishes to professional accounts tied to a Page |
| **YouTube** channel (brand account) | Shorts. Connect it in Postiz with Google OAuth |
| **Postiz** account (cloud, or self-hosted on Fly) plus an **API key** | Stored as a secret in the routine's environment (for example `POSTIZ_API_KEY`), never in the repo |
| Egress allowlist for the routine's environment | `api.adsb.lol`, `api.tailspot.app`, and the Postiz API host |

No Tailspot secret is needed: adsb.lol is keyless and `/v1/stats` is public.

## Layout

```
src/cli.ts            args, fetch → build → render, fallback, post.json
src/templates/*.ts    realCatches, rareNow, overCity, guessPlane (+ index: rotation, fallback chain)
src/posthog.ts        HogQL client (real-catches)
src/adsb.ts           adsb.lol client + readsb row normaliser
src/privacy.ts        what may be named on a slide
src/aircraftTypes.ts  tiers/points (from the app's table), display names, facts
src/geo.ts            offline region naming (reference cities + ocean/area boxes)
src/catches.ts        Noah's real catches (from marketing/catch-photos/README.md)
src/slides.ts         design system: CSS, safe zone, components, CTA
src/render.ts         Playwright screenshot loop
fixtures/             one per template (see above)
examples/             one compressed slide per template
```
