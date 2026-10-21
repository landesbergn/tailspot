import type { FastifyBaseLogger } from "fastify";

/**
 * Send one alert message to Sentry. Imported lazily so app.ts's static graph
 * stays Sentry-free (the test suite builds the app constantly and should
 * never load the SDK); `captureMessage` is itself a no-op without SENTRY_DSN.
 *
 * Delivery: Sentry rule 3591520 emails on a new high-priority issue and rule
 * 6197797 re-emails hourly while an error-level issue keeps receiving events.
 * A pinned fingerprint keeps every repeat of one incident in ONE issue.
 */
export function reportToSentry(
  log: FastifyBaseLogger,
  message: string,
  level: "warning" | "error" | "fatal",
  fingerprint: string[],
): void {
  void import("@sentry/node")
    .then((Sentry) => Sentry.captureMessage(message, { level, fingerprint }))
    .catch((err) => log.warn({ err }, `could not report to Sentry: ${message}`));
}
