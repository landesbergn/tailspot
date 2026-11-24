---
paths:
  - "ios/**/Catch.swift"
  - "ios/**/CatchTests.swift"
  - "ios/**/CatchBackfill*.swift"
  - "ios/**/CatchCaptureDiagnostics*.swift"
  - "ios/**/CatchDetailView*.swift"
  - "ios/**/CatchUploader*.swift"
  - "ios/**/GuessRecreditSweep*.swift"
  - "ios/**/TailspotApp.swift"
  - "ios/**/ContentView.swift"
---

# The Catch model contract (iOS)

**`Catch` is a flat SwiftData `@Model`**; duplicate icao24 rows are allowed
(dedupe is a Hangar concern). `captureDiagnosticsJSON` is load-bearing:
`CatchUploader` reads the press-time pose (heading / camera elevation / heading
accuracy) and the caught plane's ADS-B fix out of it and sends them on
`POST /v1/catches`, the only thing the backend validator can correlate (no
pose → verdict "unverifiable"). Adding fields to `CatchCaptureDiagnostics`
stays JSON-only and additive (no SwiftData migration), and old blobs must keep
decoding (absent key → nil). `CatchDetailView` is a frozen-moment view: it may
backfill nil-only airframe fields (registration, typecode, manufacturer,
model, placeName, operator) but never overwrites recorded values or backfills
moment data. Deliberate exceptions: `Catch.resolvedRarity` re-derives live
(re-tiering corrects old catches on read); a fully-nil route heals via
`CatchBackfill`'s per-callsign `GET /v1/routes` lookup, which sends a position
so the server can pick the right leg of a multi-leg filing and reject a stale
one (a one-sided as-observed route is moment data and is never touched); and a
stored route whose corridor is nowhere near the catch is cleared by
`CatchBackfill.clearImplausibleRoutes` back into the fill pool.
The notable-airframe flag (`notableKind` / `notableLabel` / `notableName`,
read through `notableInfo`) is set in one place only: from the live feed at
the press. A catch made before the feature never gains it (there is no
backfill). The upload sends it as `notableClaim`, and the upload response
confirms or clears it. That response has three states (`NotableVerdict`): an
object sets the flag, an explicit JSON null clears it (the server paid no
bonus), and a missing key (a server older than the feature) leaves the row
alone. A Hangar restore reads back what the server stored. Those writers
touch only these three fields.
