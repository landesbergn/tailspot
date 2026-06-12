# App Store Privacy Labels — Tailspot

This document records the App Store "App Privacy" nutrition-label answers for Tailspot, with a justification for each answer for future App Review reference.

**Last reviewed:** 2026-06-11
**For version:** 0.5.0 (public beta) and forward

> REVIEW: App Store privacy labels are self-reported. Apple's guidelines state that you must accurately reflect all data your app collects, including data collected by third-party SDKs. Have a lawyer or your technical lead confirm these answers before submitting to App Store Review, particularly after any SDK additions (e.g., PostHog, MetricKit).

---

## Data used to track you

**Answer: No** — Tailspot does not track users across apps or websites owned by other companies, and does not use data for targeted advertising.

*Justification:* No advertising SDKs, no IDFA, no third-party analytics that link behavior across apps. The anonymous device ID is used solely within Tailspot's own backend.

---

## Data linked to you

### Location — Precise location

**Collected:** Yes
**Linked to identity:** No (linked to anonymous device ID only)
**Purpose:** App functionality

*Justification:* GPS coordinates are recorded at the time of each catch and sent to the backend for catch-validation instrumentation (verifying that the plane was actually overhead at the claimed position). Location is NOT used for advertising, NOT shown publicly, and NOT used to build a location history. It is linked to an anonymous device ID, not to any personally-identifying information.

**App Review note:** iOS Location permission is `NSLocationWhenInUseUsageDescription` (when-in-use only). The app does not request always-on location. Background location is not used.

---

### Identifiers — Device ID

**Collected:** Yes
**Linked to identity:** No (anonymous, user-generated on first launch)
**Purpose:** App functionality

*Justification:* A UUID generated on first launch serves as the anonymous user identity for leaderboard scoring and catch association. It is not tied to an Apple ID, email, advertising identifier, or any other identifier that could be linked to a real person. Users can request deletion (see privacy policy).

---

### User Content — User handle (optional)

**Collected:** Yes (when user opts in by choosing a public handle)
**Linked to identity:** No (linked to anonymous device ID only; no real name or account)
**Purpose:** App functionality (leaderboard display name)

*Justification:* The handle is a self-chosen nickname, entirely optional. It is displayed publicly on the leaderboard alongside point totals. It is not linked to any real-world identity; the user can choose any handle or use the app without one.

---

## Data NOT collected (explicit negatives for App Review clarity)

The following data types are NOT collected and should be marked as "Not Collected" in the App Store privacy label:

| Data type | Not collected because… |
|---|---|
| **Health & fitness** | App has no health or fitness features. |
| **Financial info** | No payments, purchases, or financial data of any kind. |
| **Contacts** | No access to Contacts. |
| **Emails or text messages** | No messaging features. |
| **Photos or videos** | Camera is used for live AR display only; no photos are captured or uploaded. |
| **Audio data** | No microphone use. |
| **Browsing history** | No in-app browser. |
| **Search history** | No search feature. |
| **Sensitive info** | None. |
| **Other data** | No other data types. |
| **Diagnostics — crash data** | Apple's opt-in crash reporting is handled by iOS, not by an SDK we control. Per App Store guidelines, data collected solely by the operating system and not accessible to the developer does not need to be declared in the nutrition label. |

---

## Anticipated future additions (disclose now to avoid label update surprises)

**PostHog anonymous analytics (planned):**
When added, PostHog will collect:
- **Identifiers — Device ID** (same anonymous device ID already declared above)
- **Usage data — App interactions** (screen views, catch events, funnel steps)

Both will be in the **App functionality** purpose bucket, not linked to real-world identity, and not used for tracking or advertising. The privacy label will need to be updated to add "Usage data — Product interaction" at that time.

> REVIEW: Confirm with Apple's guidelines and/or a lawyer whether PostHog's anonymous-device-ID approach avoids the "tracking" definition under ATT (App Tracking Transparency). Apple's definition of "tracking" under ATT specifically covers linking data with third-party data for advertising. PostHog for product analytics with an anonymous ID and no advertising linkage should not require an ATT prompt, but confirm before submission.

---

## Notes on App Review submission process

1. The privacy label is set in App Store Connect under your app → App Privacy. It is separate from the privacy policy URL field.
2. The privacy policy URL (required for any app with a 4+ rating that collects user data) should point to the hosted version of `privacy-policy.md`. This URL must be live before submitting for review.
3. If App Review questions any data type, the justifications in this document are the first thing to reference.
