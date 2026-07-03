/**
 * Route lookup endpoint (catch route backfill, 2026-07-04).
 *
 *   GET /v1/routes/:callsign
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

    try {
      const route = await resolver.resolve(callsign);
      return reply.code(200).send({ callsign, route });
    } catch (err) {
      request.log.warn({ err, callsign }, "route resolve failed");
      return reply.code(502).send({ error: "route lookup unavailable" });
    }
  });
}
