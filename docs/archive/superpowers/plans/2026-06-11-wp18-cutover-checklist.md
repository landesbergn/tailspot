# WP 1.8 Cutover Checklist — backend becomes the only source (→ 0.5.0)

**Trigger:** Noah's field session validates the backend A/B (planes appear on
`[TAILSPOT API]` comparably or better than OpenSky, metadata resolves, no
latency/stability complaints). Until then this is a checklist, deliberately
NOT pre-staged code — it collides with PR #13's ContentView surface and would
pay conflict tax while parked.

**Ordering matters. Steps 1–2 are Noah-facing and come FIRST.**

1. **Warn testers (Noah, before anything ships).** Standing rule: rotating the
   OpenSky secret OAuth-fails every old TestFlight build. Message to the
   Student Pilots group: "Next build switches Tailspot to our own flight-data
   service — update when it arrives; older builds will stop identifying
   planes."
2. **Merge PR #13 first** (visual confirmation) if Noah's eyeball passed —
   the cutover branch should be cut from a main that already contains it.
3. **The cutover branch** (cut from main, single PR):
   - `ADSBManager`: `liveSource` default becomes `TailspotBackendClient()`;
     delete `backendSource` + `useBackend` toggle plumbing (the toggle's
     UserDefaults key can be left orphaned); `liveSourceIsAuthed` and the
     `[AUTH]/[ANON]` debug tags go (no client creds anymore). Keep `useMock`.
   - Debug panel: SOURCE row becomes a 2-state TAILSPOT/MOCK cycle.
   - DELETE `OpenSkyClient.swift` + its tests; move `ClientError` to its own
     file (e.g. `ADSBClientError.swift`) since TailspotBackendClient throws it
     — rename references (mechanical, many files, mostly tests).
   - `Info.plist`: remove `OpenSkyClientID`/`OpenSkyClientSecret` keys;
     `Tailspot.xcconfig`: remove the OPENSKY substitution lines (keep
     POSTHOG). `ci_post_clone.sh`: drop OpenSky env-var writes (check Xcode
     Cloud workflow env vars — Noah removes them in the ASC UI).
   - Keep `MockADSBSource`, the replay system, and the FAA bundle fallback
     untouched.
   - `MARKETING_VERSION` 0.2.2 → **0.5.0** in project.pbxproj (testers should
     notice this one — the version-bump preference explicitly makes this an
     exception).
   - Release notes for testers: new data source (more aircraft: GA +
     helicopters), real leaderboard, visual confirmation (if #13 passed),
     re-tiered sets.
4. **Rotate the OpenSky secret (Noah, ~10 min, AFTER the cutover build is
   verified on his device):** opensky-network.org account console →
   regenerate client secret. Update `Tailspot.secrets.xcconfig` locally
   (values now unused by the app but the backend's fallback adapter uses
   them): `fly secrets set OPENSKY_CLIENT_ID=... OPENSKY_CLIENT_SECRET=... -a
   tailspot-api`. This retires the two historical leaks AND the
   baked-in-binary exposure in one move.
5. **Decide the OpenSky fallback question** (legal-drafts finding): either
   keep the rotated creds server-side as a break-glass fallback (current
   state — low exposure, one server) or delete the adapter entirely and point
   the ladder at airplanes.live commercial. Noah leaned "small enough not to
   worry" — keeping server-side fallback is the default unless he says
   otherwise.
6. **Ship:** merge → Xcode Cloud builds → TestFlight. Update the App Store
   Connect privacy-policy URL field to https://tailspot.app/privacy.html
   while in the UI (required for the external group anyway).
7. **Beta gate review** (program spec §6): with cutover live, the remaining
   gate items are visual-confirmation go/no-go (field data) and the
   card-style-spike decision (Noah may ship beta without cards).
