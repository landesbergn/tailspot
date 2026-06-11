# Privacy Policy

**Operator:** Noah Landesberg (sole developer)
**Contact:** privacy@tailspot.app
**Effective date:** June 11, 2026

---

Tailspot is a free plane-spotting app. This policy explains what information the app collects, why, and what happens to it. It is written to be read, not lawyered around.

---

## 1. What Tailspot collects — and what it does not

### What the app collects

| What | Why | Where it goes |
|---|---|---|
| **Anonymous device ID** | Ties your catches and leaderboard score to your device without requiring an account or email address. Generated on first launch; never tied to your name or any personally-identifying information. | Sent to our backend (api.tailspot.app, hosted on Fly.io in the US). |
| **Public handle** (optional) | If you choose one, your handle appears next to your score on the leaderboard. Choosing a handle is entirely optional. | Sent to and stored on our backend. |
| **Catch records** | Each "catch" stores: the aircraft's ICAO 24-bit address (a public radio identifier), callsign, timestamp, and your GPS coordinates and compass orientation at the moment of the catch. | Sent to and stored on our backend for catch validation and your personal collection. |

### What the app does NOT collect

- No account, email address, or real name — ever.
- Camera frames never leave your device. AR identification is done on-device against public flight data; no images are uploaded.
- Location is used only at the moment you make a catch. The app does not run in the background, does not track your movement over time, and does not build a location history.
- No advertising identifiers (IDFA). No third-party tracking or analytics SDKs are embedded in the app.

---

## 2. How we use your data

| Data | How it is used | What it is NOT used for |
|---|---|---|
| Device ID + catches | Powering your personal collection, validating that catches are genuine (not fabricated coordinates), and computing your leaderboard score. | Advertising, profiling, sale to third parties. |
| GPS catch coordinates | Catch-validation instrumentation only. Coordinates are compared against public flight-track data to verify the plane was actually overhead. | Displayed publicly, shared with third parties, or used to build a location history. |
| Public handle | Showing your chosen display name on the leaderboard. | Anything else. |

---

## 3. Crash reports and diagnostics

The app uses **Apple's opt-in crash reporting** (part of iOS, governed by Apple's own privacy policy). If you have opted in to share app diagnostics with developers on your device, anonymized crash data may reach us via App Store Connect. This is standard iOS behavior; we do not add any crash-reporting SDK on top of it.

### Product analytics (PostHog)

The app sends anonymous product-usage events (for example, "app opened" or "catch uploaded") to PostHog, our analytics processor, using the same anonymous device ID described above. These events contain no name, no email, no precise location, and no advertising identifiers, and are used solely to understand how the app is used and to fix problems. PostHog is listed as a processor in §4.

---

## 4. Data sharing

We do not sell your data. Full stop.

Data is shared with the following processors, solely to operate the app:

- **Fly.io** (fly.io) — backend hosting. Our server runs on Fly.io infrastructure in the United States. Fly.io's data-processing terms apply.
- **Apple** — crash/diagnostic data if you have opted into sharing with developers (see §3 above).
- **PostHog** (posthog.com) — anonymous product analytics (see §3 above). Events are keyed to the anonymous device ID only.

We do not share data with advertisers, data brokers, or analytics companies beyond the anonymous crash reporting noted above.

---

## 5. Data retention and deletion

**On-device data:** Your personal catch collection is stored in the app's local database (SwiftData). It lives entirely on your device. Deleting the app deletes this data permanently; we cannot recover it.

**Backend data:** Your device ID, optional handle, and catch records are retained on our server for as long as your device is active on the leaderboard. If you would like your backend data deleted, email us at **privacy@tailspot.app** with the subject line "Data deletion request." We will delete your device ID, handle, and all associated catch records within 30 days and confirm by reply.

There is currently no in-app deletion flow for backend data. We plan to add one.

> REVIEW: If you anticipate significant EU user volume, the 30-day response window satisfies GDPR Article 12(3). Consider whether you want to offer a shorter window (e.g. 14 days) to set a higher bar.

---

## 6. GDPR / EEA residents

If you are in the European Economic Area, you have rights under the General Data Protection Regulation (GDPR):

- **Access:** request a copy of the data we hold about your device ID.
- **Erasure:** request deletion (see §5).
- **Portability:** request your catch records in a machine-readable format.
- **Objection:** object to processing for the leaderboard (your catches will then only be stored locally on-device, not submitted to the backend).

To exercise any of these rights, email **privacy@tailspot.app**. We will respond within 30 days.

Our legal basis for processing is **legitimate interest** (operating a game whose core mechanic requires recording catches) and, where you have provided a handle, **contract performance** (displaying your score under your chosen name).

> REVIEW: Legitimate interest as the legal basis for processing catch GPS coordinates warrants specific review. A lawyer should confirm whether the "catch validation" purpose is proportionate under GDPR Article 6(1)(f) and whether a legitimate-interest assessment (LIA) should be documented internally, even if not published.

---

## 7. CCPA (California residents)

We do not sell personal information as defined by the California Consumer Privacy Act. California residents have the right to know what personal information we collect and to request deletion. Contact **privacy@tailspot.app** to exercise these rights.

---

## 8. Children

Tailspot is rated 4+ on the App Store and is suitable for all ages. We do not knowingly collect personal information from children under 13. Because the app does not require an account or email address, no age verification is performed. If you believe a child under 13 has submitted data through the app (for example, a chosen handle), contact us at **privacy@tailspot.app** and we will delete it promptly.

> REVIEW: COPPA (US) applies if the app is "directed to children." A 4+ rating alone is not a COPPA safe harbor if the app's theme or marketing attracts a primarily under-13 audience. Plane-spotting is generally adult-leaning, but confirm this framing with a lawyer before the App Store submission.

---

## 9. Security

Your catch data is transmitted over HTTPS. The backend stores anonymous device IDs and catch records; it does not store passwords, payment information, or government identifiers, because we never collect any of those. No system is perfectly secure; we take reasonable precautions.

---

## 10. Changes to this policy

If we make a material change — for example, adding a new data type or a new third-party processor — we will update the effective date and note what changed at the top of this document. For significant changes, we will post a notice in the app or on the App Store listing.

---

## 11. Contact

Questions, deletion requests, or data-access requests:

**Noah Landesberg**
privacy@tailspot.app
