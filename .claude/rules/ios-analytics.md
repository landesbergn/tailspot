---
paths:
  - "ios/**/Analytics*.swift"
  - "ios/**/*Analytics.swift"
  - "ios/**/PostHog*.swift"
  - "ios/**/TailspotAccountClient*.swift"
  - "ios/**/DeviceID*.swift"
---

# Analytics identity (iOS)

**Analytics is one pipeline: the PostHog SDK.** `Analytics.swift` is a thin
facade over `PostHogSDK.shared` behind the `AnalyticsSink` seam (tests inject a
fake via `Analytics._testSink`); `PostHogSessionReplay.swift` owns one-time SDK
setup and the launch self-heal identify. **Identity rule:** never swap the
distinct_id under the SDK. The SDK owns the anonymous id from first launch;
`TailspotAccountClient.ensureRegistered` calls
`Analytics.identify(serverDeviceId)` exactly once and PostHog aliases the
earlier anonymous activity, so the analytics person equals the backend device
id. `DeviceID` is the backend id only; don't add a second analytics id or a
REST capture path (that split one device into several persons). posthog-ios
gotcha: `identify()` is a silent no-op (including `$set`) when the SDK is
already identified under a different distinct_id; the sink routes around it
via `AnalyticsIdentity.identifyRoute`. Never "fix" a pinned device with
`reset()`/re-identify.
