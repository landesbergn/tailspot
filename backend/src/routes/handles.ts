/**
 * Handle suggestion route (onboarding "always available" fix).
 *
 *   GET /v1/handles/suggestions?count=N
 *     → 200 { suggestions: string[] }
 *     Returns up to N (default 4, max 10) handle suggestions that are FREE to
 *     claim right now — generated from a word bank (handleSuggester) and
 *     filtered against the devices table (case-insensitive). Anonymous (no
 *     device token needed) and per-IP rate limited.
 *
 *     A suggestion can still race another device between this call and the
 *     PUT /v1/devices/me/handle that claims it — that race is handled by the
 *     409 path on the claim. So this endpoint provides FRESH suggestions, not a
 *     reservation. The point is to stop the deterministic "every chip is taken"
 *     failure, which it does.
 *
 * The generator is injectable so route tests can force candidates (including a
 * pre-claimed one) and assert the filtering; the store is the IdentityStore seam.
 */

import type { FastifyInstance, FastifyRequest } from "fastify";
import { generateHandleCandidates } from "../identity/handleSuggester.js";
import type { RateLimiter } from "../identity/rateLimiter.js";
import type { IdentityStore } from "../identity/store.js";

export interface HandlesRouteOptions {
  store: Pick<IdentityStore, "takenHandles">;
  /** Per-IP limiter for the (anonymous) suggestions endpoint. */
  suggestLimiter: RateLimiter;
  /** Candidate generator (injectable for deterministic tests). */
  generateCandidates?: (batchSize: number) => string[];
}

const DEFAULT_COUNT = 4;
const MAX_COUNT = 10;
/** Filtering rounds before we return whatever we have (guards a saturated DB). */
const MAX_ROUNDS = 4;

/** Client IP for rate limiting. Fastify's `request.ip` honors trustProxy config. */
function clientIp(request: FastifyRequest): string {
  return request.ip;
}

/** Parse + clamp the count query param to [1, MAX_COUNT], defaulting on garbage. */
function parseCount(raw: unknown): number {
  const n = typeof raw === "string" ? Number.parseInt(raw, 10) : Number.NaN;
  if (!Number.isFinite(n)) return DEFAULT_COUNT;
  return Math.min(Math.max(n, 1), MAX_COUNT);
}

export function registerHandlesRoute(app: FastifyInstance, opts: HandlesRouteOptions): void {
  const { store, suggestLimiter } = opts;
  const generate = opts.generateCandidates ?? ((n: number) => generateHandleCandidates(n));

  app.get("/v1/handles/suggestions", async (request, reply) => {
    const rl = suggestLimiter.take(`ip:${clientIp(request)}`);
    if (!rl.allowed) {
      reply.header("Retry-After", String(rl.retryAfterSeconds));
      return reply.code(429).send({ error: "rate limited" });
    }

    const count = parseCount((request.query as { count?: unknown } | undefined)?.count);

    const available: string[] = [];
    const seen = new Set<string>();
    for (let round = 0; round < MAX_ROUNDS && available.length < count; round++) {
      // Over-generate so one DB round-trip usually yields enough free names.
      const candidates = generate(count * 4).filter((h) => !seen.has(h.toLowerCase()));
      for (const c of candidates) seen.add(c.toLowerCase());
      if (candidates.length === 0) continue; // generator exhausted its space
      const taken = await store.takenHandles(candidates);
      for (const c of candidates) {
        if (available.length >= count) break;
        if (!taken.has(c.toLowerCase())) available.push(c);
      }
    }

    return reply.code(200).send({ suggestions: available.slice(0, count) });
  });
}
