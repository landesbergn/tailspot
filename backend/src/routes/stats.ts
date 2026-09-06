/**
 * Public stats for the marketing site (tailspot.app's "N planes caught" line).
 *
 *   GET /v1/stats            (no device auth; browser-origin gated)
 *     → 200 { catches: <int>, asOf: ISO-8601 }
 *     → 404 { error: "not found" }   // Origin absent or not allowlisted
 *
 * This is the shape GitHub uses for star counts: a public integer behind a
 * cache, not a secret. Two fences keep it from being a free-for-all:
 *
 *   1. Origin allowlist. Browsers attach `Origin` to cross-site fetches and
 *      page scripts cannot forge it, so no OTHER website can embed or call
 *      this endpoint. A curl with a spoofed Origin still gets the number —
 *      but the number is printed on the homepage anyway, so that's the same
 *      information exposure with a lower fence. Non-allowlisted callers get a
 *      404 (not 401/403) so the route doesn't advertise itself.
 *   2. Cache. The count is memoised in-process for `cacheTtlMs` and served
 *      with `Cache-Control: public, max-age=…`, so a burst of pageviews (or
 *      scrapers) is one `count(*)` per TTL, not one per hit. Postgres never
 *      sees site traffic.
 *
 * `Access-Control-Allow-Origin` echoes the MATCHED origin (there are two
 * allowed, and the header takes exactly one value), with `Vary: Origin` so a
 * shared cache keys on it. A plain GET needs no preflight, so there is no
 * OPTIONS handler and no CORS plugin — the two headers are the whole story.
 */

import type { FastifyInstance } from "fastify";
import type { CatchStore } from "../identity/store.js";

export interface StatsRouteOptions {
  catchStore: Pick<CatchStore, "countCatches">;
  /** Exact origins (scheme + host) allowed to read the stats. */
  allowedOrigins: readonly string[];
  /** In-process memo lifetime for the count. Default 60 s. */
  cacheTtlMs?: number;
  /** Browser / shared-cache lifetime advertised via Cache-Control. Default 300 s. */
  maxAgeSeconds?: number;
  /** Injectable clock (unix ms) so tests can expire the memo deterministically. */
  now?: () => number;
}

const DEFAULT_CACHE_TTL_MS = 60_000;
const DEFAULT_MAX_AGE_SECONDS = 300;

export function registerStatsRoute(app: FastifyInstance, opts: StatsRouteOptions): void {
  const { catchStore } = opts;
  const allowed = new Set(opts.allowedOrigins);
  const ttl = opts.cacheTtlMs ?? DEFAULT_CACHE_TTL_MS;
  const maxAge = opts.maxAgeSeconds ?? DEFAULT_MAX_AGE_SECONDS;
  const clock = opts.now ?? (() => Date.now());

  // One memo for the whole app: the value is global, not per caller. `expiresAt`
  // of 0 means "never computed"; the first request populates it.
  let memo: { catches: number; asOf: string; expiresAt: number } = {
    catches: 0,
    asOf: "",
    expiresAt: 0,
  };

  app.get("/v1/stats", async (request, reply) => {
    const origin = request.headers.origin;
    if (typeof origin !== "string" || !allowed.has(origin)) {
      return reply.code(404).send({ error: "not found" });
    }

    const t = clock();
    if (t >= memo.expiresAt) {
      const catches = await catchStore.countCatches();
      memo = { catches, asOf: new Date(t).toISOString(), expiresAt: t + ttl };
    }

    reply.header("Access-Control-Allow-Origin", origin);
    reply.header("Vary", "Origin");
    reply.header("Cache-Control", `public, max-age=${maxAge}`);
    return { catches: memo.catches, asOf: memo.asOf };
  });
}
