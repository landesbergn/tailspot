/**
 * Public list of forgiven streak days.
 *
 *   GET /v1/streak-forgiveness      (no auth, no Origin gate)
 *     → 200 { days: [ { day: "2026-11-13", reason: "FAA ground stop" } ] }
 *     → 429 { error: "rate limited" }
 *
 * The app fetches this and applies it locally: a missed catch on a listed day
 * does not break a streak (see `src/streaks/forgiveness.ts`). `days` is every
 * row, ascending by `day`; an empty list is the normal answer.
 *
 * NO AUTH, ON PURPOSE. The list is the same for everyone and says nothing
 * about anyone, and a client whose device registration failed (or that never
 * registered) still has a streak worth protecting. Unlike GET /v1/stats there
 * is no Origin fence either — the caller is the app, which sends no Origin.
 *
 * Two fences keep it off the database:
 *
 *   1. Per-IP rate limit, taken first, like every other route.
 *   2. Cache. The list is memoised in-process for `cacheTtlMs` (60 s — short,
 *      so a newly declared day shows up within a minute) and served with a
 *      matching `Cache-Control`, so any amount of traffic is one small SELECT
 *      per TTL per machine.
 *
 * If the refresh fails and an earlier answer is in hand, that stale answer is
 * served rather than a 500: a forgiven day only ever protects a streak, so an
 * old list is strictly better for the caller than no list. With nothing cached
 * the error propagates to the shared error handler like any other route's.
 */

import type { FastifyInstance } from "fastify";
import { ipKey } from "../identity/clientIp.js";
import type { RateLimiter } from "../identity/rateLimiter.js";
import type { ForgivenDay, StreakForgivenessStore } from "../streaks/forgiveness.js";

export interface StreakForgivenessRouteOptions {
  store: StreakForgivenessStore;
  /** Per-IP limiter, applied before the memo or the store is touched. */
  ipLimiter: RateLimiter;
  /** In-process memo lifetime, also advertised as `max-age`. Default 60 s. */
  cacheTtlMs?: number;
  /** Injectable clock (unix ms) so tests can expire the memo deterministically. */
  now?: () => number;
}

const DEFAULT_CACHE_TTL_MS = 60_000;

export function registerStreakForgivenessRoute(
  app: FastifyInstance,
  opts: StreakForgivenessRouteOptions,
): void {
  const { store, ipLimiter } = opts;
  const ttl = opts.cacheTtlMs ?? DEFAULT_CACHE_TTL_MS;
  const maxAge = Math.floor(ttl / 1000);
  const clock = opts.now ?? (() => Date.now());

  // One memo for the whole app. `days: null` means "never loaded".
  let memo: { days: ForgivenDay[] | null; expiresAt: number } = { days: null, expiresAt: 0 };

  app.get("/v1/streak-forgiveness", async (request, reply) => {
    const rl = ipLimiter.take(ipKey(request));
    if (!rl.allowed) {
      reply.header("Retry-After", String(rl.retryAfterSeconds));
      return reply.code(429).send({ error: "rate limited" });
    }

    const t = clock();
    if (memo.days === null || t >= memo.expiresAt) {
      try {
        const rows = await store.listDays();
        // Only the two public fields, whatever the store hands back.
        memo = {
          days: rows.map((r) => ({ day: r.day, reason: r.reason })),
          expiresAt: t + ttl,
        };
      } catch (err) {
        if (memo.days === null) throw err;
        // Keep serving the last good list, and don't retry the database on
        // every request while it is down — try again after another TTL.
        request.log.warn({ err }, "streak forgiveness refresh failed; serving the stale list");
        memo = { days: memo.days, expiresAt: t + ttl };
      }
    }

    reply.header("Cache-Control", `public, max-age=${maxAge}`);
    return { days: memo.days ?? [] };
  });
}
