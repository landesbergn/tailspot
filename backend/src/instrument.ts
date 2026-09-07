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
import type { ErrorEvent } from "@sentry/node";

const dsn = process.env.SENTRY_DSN;

/**
 * Strip the two pieces of a request we never want leaving the box, no matter
 * which integration attached them.
 *
 * 1. `Authorization` — our device bearer tokens. The Fastify error handler
 *    attaches request headers to the event, so an ordinary 500 on any
 *    authenticated route ships a WORKING credential into Sentry, where it sits
 *    in issue history readable by anyone with project access. Sentry's own
 *    default scrubbing is server-side and opt-out-able; doing it here means the
 *    token never leaves this process.
 * 2. The `observer` block in a POST /v1/catches body — `{ lat, lon, ... }` is
 *    where the user was standing, which for the common case is their home.
 *    Location data is the most sensitive thing this API handles and it has no
 *    diagnostic value in a stack trace, so the coordinates are replaced with a
 *    marker rather than the block being deleted: "the body had an observer" is
 *    itself useful when reading the error.
 *
 * `sendDefaultPii` is deliberately NOT enabled (the SDK defaults it to false),
 * so IPs, cookies and user identifiers aren't attached in the first place. This
 * hook covers what remains: data the Fastify/HTTP integrations attach because
 * we asked them to instrument requests.
 *
 * Exported for the unit test — the shape Sentry hands us is a plain object.
 */
export function scrubEvent(event: ErrorEvent): ErrorEvent {
  const headers = event.request?.headers;
  if (headers) {
    for (const key of Object.keys(headers)) {
      // Header names are case-insensitive and arrive however the client sent
      // them ("Authorization", "authorization", "AUTHORIZATION").
      if (key.toLowerCase() === "authorization") headers[key] = "[redacted]";
    }
  }
  const data = event.request?.data;
  if (isRecord(data) && "observer" in data) {
    data.observer = "[redacted: observer coordinates]";
  }
  return event;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

if (dsn) {
  Sentry.init({
    dsn,
    environment: process.env.SENTRY_ENVIRONMENT ?? process.env.NODE_ENV ?? "production",
    // Errors are the priority; keep performance tracing light to stay well
    // inside the free quota. Override via SENTRY_TRACES_SAMPLE_RATE if needed.
    tracesSampleRate: Number(process.env.SENTRY_TRACES_SAMPLE_RATE ?? 0.1),
    // "Error: aborted" is Node's stock error when a client closes the TCP
    // socket mid-request (app backgrounded / network blip during an upload).
    // Nothing server-side to fix, so drop it (BROKEN-DARKNESS-5055-F).
    // Anchored regex: a plain string here would substring-match any message
    // merely containing "aborted".
    ignoreErrors: [/^aborted$/],
    // Never attach IPs / cookies / user identifiers. Stated explicitly even
    // though false is the SDK default — this is a promise, not an accident.
    sendDefaultPii: false,
    // Last stop before an event leaves the process (see scrubEvent).
    beforeSend: scrubEvent,
  });
  console.log("Sentry: initialized");
} else {
  console.log("Sentry: disabled (no SENTRY_DSN)");
}
