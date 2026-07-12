# Privacy Policy — Tailspot (GA draft)

> **Draft status.** This is the GA-gate revision of the policy already hosted at
> `https://tailspot.app/privacy.html` (effective June 11, 2026 — source in
> `web/public/privacy.html`). The hosted version is **stale against the shipped
> app** in four material ways; this draft corrects them. Once approved, port this
> text into `web/public/privacy.html`, bump the effective date, and note the
> changes at the top per the policy's own §10. What changed since June 11:
>
> 1. **PostHog is now an embedded SDK with session replay** (screen recordings of
>    the app's UI). The hosted policy says "No third-party tracking or analytics
>    SDKs are embedded in the app" — no longer true since the 2026-06-27 SDK
>    cutover.
> 2. **Location is used continuously while the app is open** (to fetch nearby
>    aircraft), not "only at the moment you make a catch."
> 3. **Hangar restore** (PR #125): catch records are now restorable from the
>    server after a reinstall — "deleting the app deletes this data permanently;
>    we cannot recover it" is now only true of photos.
> 4. New minor processors: Apple (reverse geocoding of catch coordinates) and
>    Planespotters.net (photo loads).

---

**Operator:** Noah Landesberg (sole developer)
**Contact:** privacy@tailspot.app
**Effective date:** _[set on publish]_

Tailspot is a free plane-spotting game. This policy explains what information the
app collects, why, and what happens to it. It is written to be read, not lawyered
around.

## 1. What Tailspot collects — and what it does not

### What the app collects

| What | Why | Where it goes |
|---|---|---|
| **Anonymous device ID** | Ties your catches and leaderboard score to your device without an account or email. Minted by our server on first launch; stored in your device's Keychain so it survives reinstalls. Never tied to your name. | Our backend (api.tailspot.app, hosted on Fly.io in the US). Also used as your anonymous analytics ID. |
| **Public handle** (optional) | If you claim one, it appears next to your score on the leaderboard. Entirely optional. | Our backend. |
| **Catch records** | Each catch stores: the aircraft's ICAO 24-bit address (a public radio identifier), callsign, timestamp, your GPS coordinates at the moment of the catch, and — if you played the bonus round — the answer you picked. | Our backend, for catch validation, the leaderboard, and so we can restore your collection if you reinstall (see §5). |
| **Your approximate area, while the app is open** | The app asks our server "what aircraft are near this bounding box?" every ~10 seconds so the sky view stays live. The box is derived from your location. It is used to answer the query, not to build a movement history. | Our backend. |
| **Usage analytics + session replay** | Anonymous product events (e.g. "app opened", "catch uploaded" — with the aircraft's identity and a coarse place name, never your coordinates) and **recordings of the app's screens** as you use them, so we can find and fix problems. See §3. | PostHog (our analytics processor), keyed to the anonymous device ID. |
| **Crash and performance data** | Crash counts, hang rate, peak memory (Apple's on-device MetricKit, summarized). | PostHog. |

### What the app does NOT collect

- No account, email address, or real name — ever.
- **Your camera's live view is never uploaded.** Identification is geometric
  (GPS + compass + public flight data), not image recognition in the cloud.
  The photo snapped when you catch a plane stays on your device (see §3 for the
  one nuance: session replay records the app's *screens*, which can include a
  catch photo while you're looking at it).
- No background location. The app uses location only while it's open
  ("While Using the App" permission) and does not build a location history.
- No advertising identifiers (IDFA), no ad networks, no data brokers.

## 2. How we use your data

| Data | Used for | NOT used for |
|---|---|---|
| Device ID + catches | Your collection, catch validation (were you really under that plane?), leaderboard score, reinstall restore. | Advertising, profiling, sale to anyone. |
| GPS catch coordinates | Catch validation only — compared against public flight tracks. | Public display, sharing with third parties, location history. |
| Approximate area while open | Fetching the aircraft near you. | Anything else. |
| Public handle | The leaderboard. | Anything else. |
| Analytics + replay | Understanding usage, fixing bugs. | Advertising or tracking across apps. |

## 3. Analytics, session replay, and diagnostics

The app embeds the **PostHog SDK** (posthog.com), our analytics processor.
It collects, keyed to the anonymous device ID:

- **Product events** — things like "app opened," "catch uploaded," "trophy
  unlocked." Catch events include the aircraft's identity (a public fact) and a
  coarse place name like "Berkeley, US" — never your GPS coordinates.
- **Session replay** — periodic screenshots of the app's interface while you use
  it, replayed as a recording. This shows what any user of the app sees: aircraft
  labels, your collection, your handle. If a screen displays one of your catch
  photos, that photo appears in the recording of that screen. The live camera
  view is excluded from recordings. We use replays to find broken flows; they
  are visible only to the developer and PostHog as processor.
- **Diagnostics** — crash counts, hang rate, and memory summaries from Apple's
  on-device MetricKit.

Separately, **Apple's own opt-in crash reporting** (part of iOS, governed by
Apple's privacy policy) may reach us via App Store Connect if you've opted in on
your device.

## 4. Data sharing

We do not sell your data. Full stop.

Data is shared only with processors, solely to operate the app:

- **Fly.io** — backend hosting (US).
- **PostHog** — analytics and session replay (see §3).
- **Apple** — (a) opt-in crash reporting; (b) when you catch a plane, the catch
  coordinates are sent to Apple's geocoding service to turn them into a place
  name ("Oakland, US") for your collection card.
- **Planespotters.net** — when your collection shows a stock photo of an
  aircraft, the image loads directly from Planespotters' servers, which
  necessarily see your IP address (like any image on any website). The request
  identifies the aircraft, not you.

## 5. Data retention, restore, and deletion

**On your device:** your catch collection and all catch photos live in the app's
local database. **Photos exist only on your phone** — they are never uploaded,
and deleting the app deletes them permanently; we cannot recover them.

**On our server:** your device ID, optional handle, and catch records are
retained while your device is active. Because catch records are on the server,
reinstalling the app on the same device can **restore your collection** (cards
and scores — not photos).

**Deletion:** email privacy@tailspot.app with subject "Data deletion request."
We will delete your device ID, handle, and all associated catch records within
30 days and confirm by reply. There is currently no in-app deletion flow for
backend data; we plan to add one. Analytics deletion requests are forwarded to
PostHog for the same device ID.

## 6. GDPR / EEA residents

You have the rights of **access**, **erasure**, **portability** (your catch
records in machine-readable form), and **objection** (your catches then stay
on-device only). Email privacy@tailspot.app; we respond within 30 days. Legal
basis: legitimate interest (operating a game whose core mechanic records
catches; understanding and fixing the app) and, for the handle, contract
performance.

## 7. CCPA (California residents)

We do not sell personal information. California residents may request access or
deletion via privacy@tailspot.app.

## 8. Children

Tailspot is rated 4+ and suitable for all ages. No account or email is required,
so no age verification is performed. If you believe a child under 13 submitted
data (e.g., a handle), contact us and we will delete it promptly.

## 9. Security

All transmission is HTTPS. The backend holds anonymous device IDs and catch
records — no passwords, payment data, or government identifiers, because we
never collect any. No system is perfectly secure; we take reasonable precautions.

## 10. Changes

Material changes get a new effective date and a note at the top of this
document; significant ones get an in-app or App Store notice.

## 11. Contact

Noah Landesberg — privacy@tailspot.app

---

## Appendix (not for publication): claims verified against source, and open items

Every claim above was verified in the repo on 2026-07-11:

- Catches/photos local SwiftData; photos never uploaded — `Catch.swift`,
  `CatchPhotoStore` usage, PR #125 body.
- Upload payload = uuid, icao24, callsign, caughtAt, **observerLat/Lon**,
  guessKind/guessValue (pose fields sent nil) — `CatchUploader.swift:95-112`.
- Registration sends an **empty body** (`POST /v1/devices`, `{}`) — no device
  model/OS fingerprint — `TailspotAccountClient.swift:325-330`. Device ID in
  Keychain — `DeviceID.swift`.
- ~10 s bounding-box aircraft polls — `TailspotBackendClient.swift:170-178`,
  `ADSBManager` pollTask.
- PostHog SDK, screenshot-mode replay, `maskAllTextInputs = false`,
  `maskAllImages = false`, `flushAt = 1` — `PostHogSessionReplay.swift`.
- Catch telemetry sends coarse `place_name`, no coordinates —
  `CatchTelemetry.swift` (header comment + `uploadedProperties`).
- MetricKit → PostHog — `MetricsSubscriber.swift`, `PrivacyInfo.xcprivacy`.
- Reverse geocoding via Apple — `ReverseGeocode.swift` (CLGeocoder family).
- Planespotters fetch by icao24, in-session cache only — `PlanespottersClient.swift`.
- Hangar restore — PR #125 (`GET /v1/catches`, token-scoped).

**⚠ Open item — camera masking in session replay.** The policy line "the live
camera view is excluded from recordings" reflects the *intent* documented in
`PostHogSessionReplay.swift`, but the actual `.postHogMask()` on the camera
preview was **removed** during the all-black-replay diagnosis
(`ContentView.swift` ~line 215, "EXPERIMENT") and never re-added — today **no
view in the app is masked**. `AVCaptureVideoPreviewLayer` likely renders black
in screenshot capture anyway (that was the bug being diagnosed), but that is an
artifact, not a control. **Before GA: either re-add a scoped mask on
`CameraPreview` or verify in live PostHog replays that camera frames render
black — otherwise soften the policy line.** Same check decides whether catch
photos should be masked (`maskAllImages = false` today; the policy discloses it
either way).
