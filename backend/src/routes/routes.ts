/**
 * Route lookup endpoint (catch route backfill, 2026-07-04).
 *
 *   GET /v1/routes/:callsign?lat=&lng=&track=
 *     → 200 { callsign, route: { originIcao, destIcao, originName?, destName? } | null }
 *
 * Lets the iOS `CatchBackfill` heal fill origin → destination onto catches
 * made before route capture shipped (2026-06-29) — or whose flight the feed
 * had no route for at catch time. Anonymous + per-IP rate limited, mirroring
 * the handles-suggestions endpoint.
 *
 * Semantics: the resolver answers with the route CURRENTLY on file for the
 * callsign (adsb.lol route DB), which for scheduled traffic is almost always
 * the same city pair the flight flew historically — the same best-effort
 * caveat as the operatorName backfill. `route: null` is a normal 200 (no
 * route on file), NOT an error; upstream transport failures are a 502 so the
 * client can retry a later pass.
 *
 * `lat`/`lng` (+ optional `track`, degrees true) are the plane's observed
 * position at/near the moment the caller cares about (2026-07-19): with them
 * the resolver picks the current leg of a multi-leg filing and rejects a
 * filing whose corridor the plane was nowhere near (stale route DB — the
 * SWA1067 MAF→DAL case). Without them a multi-leg filing resolves to null.
 * Malformed values are ignored (position is an enhancement, never a 400).
 */

import type { FastifyInstance, FastifyRequest } from "fastify";
import type { RateLimiter } from "../identity/rateLimiter.js";
import type { RouteResolver } from "../providers/adsblolRoutes.js";

export interface RoutesRouteOptions {
  resolver: RouteResolver;
  /** Per-IP limiter (anonymous endpoint; backfill passes are bursty). */
  routeLimiter: RateLimiter;
}

/** Callsigns are short alphanumerics (ICAO flight IDs, tail numbers). The
 *  pattern gates obvious garbage before it reaches the upstream lookup. */
const CALLSIGN_PATTERN = /^[A-Za-z0-9]{2,10}$/;

function clientIp(request: FastifyRequest): string {
  return request.ip;
}

/** The query value as a finite number within [lo, hi], else undefined. */
function finiteInRange(v: unknown, lo: number, hi: number): number | undefined {
  if (typeof v !== "string" || v.trim() === "") return undefined;
  const n = Number(v);
  return Number.isFinite(n) && n >= lo && n <= hi ? n : undefined;
}

export function registerRoutesRoute(app: FastifyInstance, opts: RoutesRouteOptions): void {
  const { resolver, routeLimiter } = opts;

  app.get("/v1/routes/:callsign", async (request, reply) => {
    const rl = routeLimiter.take(`ip:${clientIp(request)}`);
    if (!rl.allowed) {
      reply.header("Retry-After", String(rl.retryAfterSeconds));
      return reply.code(429).send({ error: "rate limited" });
    }

    const raw = (request.params as { callsign?: unknown }).callsign;
    const callsign = typeof raw === "string" ? raw.trim().toUpperCase() : "";
    if (!CALLSIGN_PATTERN.test(callsign)) {
      return reply.code(400).send({ error: "invalid callsign" });
    }

    // Optional observed position (+ track) for leg picking / corridor gating.
    // Best-effort: anything malformed simply degrades to a position-less
    // resolve — the params are an enhancement, not part of the contract.
    const q = request.query as { lat?: unknown; lng?: unknown; track?: unknown };
    const lat = finiteInRange(q.lat, -90, 90);
    const lng = finiteInRange(q.lng, -180, 180);
    const track = finiteInRange(q.track, 0, 360);
    const plane =
      lat !== undefined && lng !== undefined
        ? { latitude: lat, longitude: lng, trackDeg: track ?? null }
        : undefined;

    try {
      const route = await resolver.resolve(callsign, plane);
      return reply.code(200).send({ callsign, route });
    } catch (err) {
      request.log.warn({ err, callsign }, "route resolve failed");
      return reply.code(502).send({ error: "route lookup unavailable" });
    }
  });
}
