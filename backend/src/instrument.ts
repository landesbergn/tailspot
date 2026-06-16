// instrument.ts — Sentry initialization.
//
// MUST be imported before anything else (see the first line of index.ts) so
// the SDK can instrument modules as they load.
//
// The DSN comes from the SENTRY_DSN env var — a Fly secret in production
// (`fly secrets set SENTRY_DSN=…`). When it's absent (local dev, tests, CI)
// Sentry is a no-op. We log the enabled/disabled state at startup ON PURPOSE:
// a silently-disabled monitor is exactly how the PostHog key went unnoticed,
// so the Fly logs always say which mode we're in.
import * as Sentry from "@sentry/node";

const dsn = process.env.SENTRY_DSN;

if (dsn) {
  Sentry.init({
    dsn,
    environment: process.env.SENTRY_ENVIRONMENT ?? process.env.NODE_ENV ?? "production",
    // Errors are the priority; keep performance tracing light to stay well
    // inside the free quota. Override via SENTRY_TRACES_SAMPLE_RATE if needed.
    tracesSampleRate: Number(process.env.SENTRY_TRACES_SAMPLE_RATE ?? 0.1),
  });
  console.log("Sentry: initialized");
} else {
  console.log("Sentry: disabled (no SENTRY_DSN)");
}
