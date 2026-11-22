// Sentry must initialize before any other module loads — keep this first.
import "./instrument.js";
import * as Sentry from "@sentry/node";

import { buildApp } from "./app.js";
import { reportToSentry } from "./monitoring/report.js";
import { DEFAULT_SITE_PROBE_URLS, SiteProbe } from "./monitoring/siteProbe.js";

const PORT = Number(process.env.PORT ?? 8080);
const HOST = "0.0.0.0";

const app = await buildApp();

// Capture unhandled errors thrown from route handlers. No-op when Sentry has
// no DSN. The factory (app.ts) stays Sentry-free so tests run untouched.
Sentry.setupFastifyErrorHandler(app);

// Watch the marketing site from here: Sentry's free plan has one uptime slot
// and it is on /readyz. SITE_PROBE_URLS (comma-separated) overrides the URL
// list; "off" disables it. Started here, not in buildApp, so tests never probe.
const siteProbeUrls = parseSiteProbeUrls(process.env.SITE_PROBE_URLS);
if (siteProbeUrls.length > 0) {
  new SiteProbe({
    urls: siteProbeUrls,
    onAlert: ({ url, consecutiveFailures, error }) => {
      const message = `Website down: ${url} (${error}, ${consecutiveFailures} checks in a row)`;
      app.log.error({ url, consecutiveFailures, error }, message);
      reportToSentry(app.log, message, "error", ["site-down", url]);
    },
    onRecovered: (url, rounds) => app.log.info({ url, rounds }, `website back up: ${url}`),
  }).start();
}

function parseSiteProbeUrls(raw: string | undefined): string[] {
  if (raw === undefined || raw.trim() === "") return DEFAULT_SITE_PROBE_URLS;
  if (raw.trim().toLowerCase() === "off") return [];
  return raw
    .split(",")
    .map((u) => u.trim())
    .filter((u) => u.length > 0);
}

try {
  await app.listen({ port: PORT, host: HOST });
  // Fastify logs the address automatically when logger is enabled.
} catch (err) {
  Sentry.captureException(err);
  app.log.error(err);
  await Sentry.flush(2000);
  process.exit(1);
}
