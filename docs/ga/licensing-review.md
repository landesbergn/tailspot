# Licensing review — Planespotters.net photos + adsb.lol data (GA gate)

Reviewed 2026-07-11 against source on `main` (221312a) and the providers'
published terms. PLAN §9 #8.

## 1. Planespotters.net photo API

### What we use

One integration point. `PlanespottersClient.swift` calls the **public, keyless
photo API** (`GET https://api.planespotters.net/pub/photos/hex/{icao24}`) and
returns at most one photo (thumbnail URLs + photographer + page link).
**Display happens in exactly one place:** `CatchDetailView` — and only when the
catch has **no user photo** of its own (the fetch is skipped otherwise,
`CatchDetailView.swift:100-108`). The large thumbnail becomes the settled
card's hero; a caption below the card reads `© {photographer} ·
planespotters.net` and opens the photo's Planespotters page on tap
(`attribution(_:)`, line 276). The reveal, Hangar lists, and share card never
use Planespotters imagery (share is text-only; lists use the user's photos).

### Their terms (Photo API Terms of Use)

The live page (`https://www.planespotters.net/photo/api`) is behind a
Cloudflare JS challenge, so the terms below are quoted from the **Wayback
Machine snapshot of 2026-06-18** (current within a month):

1. Photos "cannot be an exclusive paid, premium or member-only feature"; photo
   areas "must be publicly and freely available to all users."
2. "Thumbnail sizes … must be the same across all access levels."
3. "Each photo must be attributed to the photographer and **the thumbnail
   linked back to the original page** at Planespotters.net in accordance with
   our general Terms of Use." (General ToS attribution format: "© display
   name/author's name.")
4. "API responses must not be stored for more than 24 hours."
5. "All URLs, including image sources and links to photos, must remain
   unchanged and as provided in the API response."
6. "Image files must not be stored on your servers or inside your application
   and must be served from the original URL provided in the API response."
7. Free, no access key; "For advanced use, please contact us with details
   about your project and working implementation of our public API."

They also 403 requests with a generic library User-Agent and require an
identifying UA with a contact URL.

### Compliance scorecard

| Requirement | Status | Evidence |
|---|---|---|
| Free feature, no paywall/tiers | ✅ | App is free; no access levels. |
| Same thumbnail sizes everywhere | ✅ | One display site. |
| Photographer credit, "©" format | ✅ | `© {photographer} · planespotters.net` caption. |
| **Thumbnail linked back to the photo page** | ⚠️ **Partial** | The *caption* is tappable and opens `photo.link`; the *thumbnail itself* (the card hero) is not. The terms' letter attaches the link to the thumbnail. |
| No response storage > 24 h | ✅ | In-process, session-only cache, capped at 200 (`PlanespottersCache`); nothing persisted. |
| URLs unchanged | ✅ | URLs used verbatim from the response. |
| Images served from original URL, not stored | ✅ | `AsyncImage` loads from their CDN; only iOS's transient HTTP `URLCache` applies (honors their cache-control; no pixels written by us). |
| Identifying User-Agent | ✅ | `Tailspot/0.1 (+https://github.com/landesbergn/tailspot)` (`PlanespottersClient.defaultUserAgent`). |

### Options

- **A. Keep, with one small fix (recommended).** Make the hero image tappable
  (open `photo.link`) when — and only when — it's a Planespotters photo, in
  `CatchDetailView`/`SettledCatchCard`. ~15-line change; closes the only gap.
  Optional courtesy: email Planespotters a heads-up before GA describing the
  integration ("advanced use" invites contact; ours is squarely the basic use
  the public API is for, so this is politeness, not obligation).
- **B. Remove Planespotters photos.** Cards without a user photo fall back to
  the placeholder. Zero licensing surface, real product cost — restored
  Hangars (PR #125) have *no* user photos, so a restored collection would be
  wall-to-wall placeholders.

**Verdict: compliant except the thumbnail-link letter-of-the-terms gap.
Recommendation: Option A.** The integration was designed around these exact
terms (the constraints are documented in `PlanespottersClient.swift`'s header)
and the fix is trivial. Two housekeeping notes: bump the UA version when
`MARKETING_VERSION` goes to 1.0, and consider pointing the UA contact URL at
`https://tailspot.app` instead of the GitHub repo.

## 2. adsb.lol (live aircraft data)

### What we use

All live positions come from the Tailspot backend (`api.tailspot.app`), which
sources from **adsb.lol** (including MLAT). The app never talks to adsb.lol
directly.

### Their terms

adsb.lol publishes its data openly: "The API is available to everyone" under
the **Open Database License (ODbL) 1.0** (adsb.lol docs, `adsb.lol/docs/open-data/api/`;
historical archives on GitHub carry the same license). ODbL requires
**attribution** and **share-alike for derived databases**. The API server code
itself is BSD-3-Clause (github.com/adsblol/api) — irrelevant to data use. Their
docs note dynamic rate limits and that keyed access may come later ("obtained
by contributing data") — a post-GA watch item for the backend, not an iOS
concern.

### Compliance scorecard

| Requirement | Status | Evidence |
|---|---|---|
| Attribution | ✅ | Settings → ABOUT: "Live aircraft data — adsb.lol" (`SettingsScreen.swift:134`, comment marks it a license obligation) + tailspot.app/attributions.html carries the full ODbL attribution statement with license link. |
| Share-alike (derived DB) | ✅ (posture) | The backend caches/serves adsb.lol data unmodified-in-substance; the attributions page already states the share-alike condition publicly. We don't redistribute a derived database. |
| Rate limits | ✅ | Backend-side tile cache (~10 s TTL) is the consumer; the app hits our backend, not theirs. |

**Verdict: compliant. Recommendation: keep; no changes needed.** The one hard
dependency is that `tailspot.app/attributions.html` (the ODbL statement) and
the Settings credit row stay up — both are marked do-not-remove in source.

## 3. ICAO DOC 8643 (bundled `AircraftTypes.json`) — carried item

PLAN §9 #8 absorbs the old #15 re-check. The attributions page takes the
position that type designators are factual identifiers not subject to creative
copyright, used for identification rather than redistribution of the
publication. The ~30-minute confirmation that the doc8643.icao.int endpoint's
pre-release terms haven't changed **remains open** (the check needs the current
terms page, which wasn't fetched in this review). Fallback if terms tighten:
FAA JO 7360.1 (public domain) covers all commercial type designators, as
already documented in PLAN §9 (old #15).

## 4. Everything else (already settled, listed for completeness)

`web/public/attributions.html` (last updated 2026-06-26) also covers: FAA
Releasable Aircraft Database (public domain), YOLOX detector weights
(Apache-2.0), B612 Mono (OFL 1.1). No action needed; the page ships as the
canonical credits list and is linked from Settings.
