// Sentry must initialize before any other module loads — keep this first.
import "./instrument.js";
import * as Sentry from "@sentry/node";

import { buildApp } from "./app.js";

const PORT = Number(process.env.PORT ?? 8080);
const HOST = "0.0.0.0";

const app = await buildApp();

// Capture unhandled errors thrown from route handlers. No-op when Sentry has
// no DSN. The factory (app.ts) stays Sentry-free so tests run untouched.
Sentry.setupFastifyErrorHandler(app);

try {
  await app.listen({ port: PORT, host: HOST });
  // Fastify logs the address automatically when logger is enabled.
} catch (err) {
  Sentry.captureException(err);
  app.log.error(err);
  await Sentry.flush(2000);
  process.exit(1);
}
