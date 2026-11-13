---
paths:
  - "ios/**/ADSB*.swift"
  - "ios/**/ErrorCopy*.swift"
  - "ios/**/ContentView.swift"
---

# ADS-B errors (iOS)

Only the `/v1/aircraft` poll raises the status pill, and only after a grace
period (`ADSBManager.surfaceDelay`). Metadata failures never raise it: they're
logged, not cached, and retried. Cancellation is never an error
(`ErrorCopy.isCancellation`): `.task(id:)` re-keys and `stop()` cancel requests
as `URLError.cancelled`, and that must not show as "unreachable".
