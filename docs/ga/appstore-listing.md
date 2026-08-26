# App Store listing — GA draft

Drafted 2026-07-11 (PLAN §9 #8). **Submitted 2026-07-21 (v1.0.0, Waiting for Review)** — the ☐ items below were clicked through in ASC; kept for the next version's checklist. Region decision per Noah: **worldwide** —
supersedes PLAN §6.6's US + W. Europe default. Everything marked ☐ is a manual
App Store Connect step only Noah can click.

## Name and subtitle (30 chars each)

| Field | Draft | Chars |
|---|---|---|
| **Name** | `Tailspot: Catch Real Planes` | 27 |
| Name (alt, minimal) | `Tailspot` | 8 |
| **Subtitle** | `Catch the planes overhead` | 25 |
| Subtitle (alt) | `Point. Catch. Collect.` | 22 |

Recommendation: the descriptor name + "Catch the planes overhead." Name and
subtitle are the two strongest ASO fields; "Tailspot" alone spends 22 free
characters on nothing.

## Description (draft)

> That plane crossing the sky — you have about thirty seconds before it's gone.
> Tailspot tells you what it is while you can still see it. Point your phone up:
> the app matches your position and heading against live transponder data from
> thousands of community receivers and locks onto the actual aircraft overhead.
> Tap it. Caught.
>
> Every catch is real. The type, the airline, where it came from, where it's
> headed — pinned to the moment you saw it, with the photo you snapped. Catches
> earn points by rarity: an everyday A320 is common; a military transport, a
> vanishing jumbo, or a warbird is not. Guess the type or the route before the
> reveal for a bonus.
>
> Your Hangar fills up from there — sets to complete, trophies for the hard
> stuff, a leaderboard if you claim a handle. No account, no email, no ads.
> Just you, the sky, and a collection that proves you were looking up.
>
> Tailspot uses ADS-B data aggregated by adsb.lol. Coverage depends on
> community receivers in your area and is strongest near cities and airports.
> A game, not a navigation tool.

(The last paragraph is the honest coverage caveat — it matters for a worldwide
launch; it's the in-listing version of the empty-sky expectation-setting.)

## Promotional text (170 chars, editable without review)

> Point your phone at the sky. Tailspot IDs the actual plane overhead from live
> transponder data — then you catch it, score it, and build the collection.

(156 chars.)

## Keywords (100 chars)

```
planespotting,spotter,aircraft,flight,radar,aviation,avgeek,adsb,sky,catch,collect,airline,tracker
```

98 chars. Notes: don't repeat "plane" (substring of "planespotting"); "Tailspot"
and words in name/subtitle are already indexed; no competitor names.

## Category

- **Primary: Games → Casual.** The strategy is explicit that it's a collection
  *game* (catch → collect → trophies → leaderboard), and Games is where
  collection loops are judged on their own terms.
- **Secondary: Education** — the "learn what's overhead" half; also honest.
- Alternative considered: primary **Travel** (where Flightradar24 lives). Rejected:
  Tailspot would be compared to flight trackers and lose on tracker features it
  deliberately doesn't have.

## Age rating (questionnaire answers)

All content questions **None** (no violence, sexual content, profanity, drugs,
gambling, horror). Unrestricted web access: **No** (only developer-chosen links
open in Safari). Gambling/contests: **No**. Result: **4+**.

Two honest wrinkles to answer correctly if asked in the current questionnaire:

- **User-generated content:** handles are user-chosen text visible to all users
  on the leaderboard. Mitigations that exist today: server-side uniqueness +
  reset ability (ToS §3). There is **no in-app report/block mechanism** — if
  App Review pushes on Guideline 1.2, the fallback answer is that the handle is
  the *only* UGC surface (no free-text messaging, no images), and moderation is
  operator-reset. Post-GA candidate: a profanity list on the claim endpoint.
- **Location:** the questionnaire asks about precise location — yes, when-in-use
  only.

## Privacy "nutrition label" (App Privacy section)

Ground truth verified in source (see `privacy-policy.md` appendix). Data below
is what the app actually sends off-device. **"Linked to you":** every backend
and analytics record is keyed to the anonymous device ID. Apple's definition
of "linked" includes data tied to a device-level identifier, so the honest
answers are **Linked = Yes** wherever the device ID is the key. (Note: the
committed `PrivacyInfo.xcprivacy` currently declares most types
`Linked=false` — defensible only under a narrower "real-world identity"
reading. Recommend aligning the manifest to the label, one small code PR.)
Nothing is used for **Tracking** (Apple's cross-app/ad sense) — `NSPrivacyTracking=false` stands.

| Apple category | Data | Collected? | Linked | Tracking | Purpose |
|---|---|---|---|---|---|
| Location → Precise Location | Observer lat/lon uploaded with each catch; bounding-box aircraft queries while open | **Yes** | Yes | No | App Functionality |
| Identifiers → Device ID | Anonymous server-minted device ID (Keychain) | **Yes** | Yes | No | App Functionality, Analytics |
| User Content → Other User Content | Catch records (aircraft, timestamp, guess answer) | **Yes** | Yes | No | App Functionality |
| Identifiers → User ID | Optional public handle | **Yes** | Yes | No | App Functionality |
| Usage Data → Product Interaction | PostHog events + **session replay screen recordings** | **Yes** | Yes | No | Analytics |
| Diagnostics → Crash Data | MetricKit crash counts → PostHog | **Yes** | Yes | No | Analytics, App Functionality |
| Diagnostics → Performance Data | Hang rate, memory → PostHog | **Yes** | Yes | No | Analytics, App Functionality |
| Photos or Videos | Catch photos | **No** (never uploaded) | — | — | Stays on device. Caveat: replay screenshots can include a photo *as displayed in the UI* — see the camera/photo masking open item in `privacy-policy.md`; resolve it before answering this row. |
| Contact info, Financial, Health, Browsing, Search history, Contacts | — | **No** | — | — | Never collected. |

## Availability and pricing

- **Price:** Free. No IAP.
- **Region: worldwide** (Noah's call, 2026-07). PLAN §6.6's US + W. Europe
  default is superseded; the accepted risk is coverage-desert disappointment
  (Bali field data). Mitigation is expectation-setting: the description's
  coverage paragraph + the in-app empty-sky messaging.

## What's New — v1.1.0 (train opened 2026-08-25)

Covers everything since the public v1.0.0 (build 83): the never-submitted
1.0.1 accumulation plus the v1.1 "Habits & housekeeping" train.

App Store "What's New" (paste into ASC):

> Streaks are here. Catch a plane every day to keep the run alive — Tailspot
> nudges you in the late afternoon before a streak lapses.
>
> Also in this release:
> • Repeat sightings count. The same airframe on a new day (or a new flight)
>   is a fresh catch, points and all.
> • Pinch to zoom on any catch photo, from the reveal or the Hangar.
> • The guess round shows up twice as often — and no longer flashes the
>   route before you've guessed.
> • Route guesses are worth more.
> • Sets got fuller: every catchable type now fills a slot, helicopters
>   included, and McDonnell Douglas planes got their names back.
> • Sharing a catch now includes a link to the app.
> • Snappier capture: the shutter responds instantly and the reveal opens
>   while the catch finishes behind it.
> • Altitude trophies now unlock at their exact advertised heights.
> • Better battery life, friendlier error messages, and a pile of small
>   fixes — including new spotters no longer seeing a wildly wrong
>   leaderboard rank.

TestFlight "What to Test" (tester-notes voice):

> • catch me today and the streak chip lights up from day one — skip
>   tomorrow and my 5pm nudge will find you
> • spotted the same tail twice? on a new day it counts again. double
>   dipping is now legal
> • pinch a catch photo. full-res zoom, straight from the reveal
>
> (Heads-up: the App Store rating sheet never appears on TestFlight builds —
> that's Apple's behavior, not a bug.)

## First-submission checklist (one-time — DONE, kept as the record)

> **This is the v1.0 first-submission setup, completed for the 2026-08-08
> approval. Don't re-run it per release.** The recurring per-release checklist
> (version bump, soak, release notes, privacy-label re-sync, phased release)
> lives in `CONTRIBUTING.md` → "Cutting a release". What stays live here is the
> **nutrition-label table above** — re-check it against `PrivacyInfo.xcprivacy`
> whenever a release changes what data leaves the device.

Prep that must exist first:
- ☐ **Host the updated policy/terms** — port `privacy-policy.md` / `terms.md`
  into `web/public/`, deploy the `web/` Fly app. The app's Settings already
  links `tailspot.app/privacy.html` and `terms.html`.
- ☐ **Resolve the replay camera-mask open item** (see `privacy-policy.md`
  appendix) — it changes one nutrition-label row and one policy sentence.

Then, in App Store Connect (My Apps → Tailspot):
1. ☐ App Information: name, subtitle, category (Games/Casual + Education),
   content rights declaration.
2. ☐ Age rating questionnaire (answers above) → 4+.
3. ☐ App Privacy: enter the nutrition label exactly as the table above;
   set privacy policy URL `https://tailspot.app/privacy.html`.
4. ☐ Pricing & Availability: Free, **all countries/regions**.
5. ☐ Version page: description, promotional text, keywords, support URL
   (`https://tailspot.app`), marketing URL (optional), copyright
   "© 2026 Noah Landesberg".
6. ☐ Upload screenshots (see `screenshot-plan.md`) + optional app preview video.
7. ☐ **App Review notes** — critical for this app: review happens indoors at a
   desk, where the AR view shows an empty sky and catches are impossible.
   Provide: (a) a sentence explaining the app needs open sky + passing
   aircraft, (b) a link to a short screen-recording of a real outdoor catch,
   (c) note that camera + when-in-use location permission are required for the
   core flow, and the app shows a permission-recovery card if denied.
8. ☑ Export compliance: HTTPS-only → "standard encryption, exempt."
   **Resolved permanently** — `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO`
   is set on the app target (and in `Info.plist`), so the per-upload question no
   longer appears. Nothing to do per release.
9. ☑ Select the GA build (TestFlight → the build Noah cuts), submit for review.
10. ☑ After approval: release manually (recommended over auto-release, so the
    backend can be watched during the first hours), then check App Store
    Connect → Crashes and PostHog.

**Outcome:** v1.0.0 (build 83) approved and released 2026-08-08, after one
round-1 rejection under 5.1.1(iv) (onboarding CTA wording, fixed in #170).
