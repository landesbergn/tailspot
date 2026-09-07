/**
 * The one place we decide "who is this request from?" for rate-limiting keys.
 *
 * WHY THIS EXISTS (security fix, 2026-09-06). Every per-IP limiter used to key
 * on Fastify's `request.ip` with `trustProxy: true`, which makes `request.ip`
 * the LEFTMOST entry of `X-Forwarded-For` — a header the *client* writes. That
 * turned every per-IP limit into a suggestion: verified live against production
 * on 2026-09-06, 30 GETs to /v1/handles/suggestions returned 429, then the same
 * request with `X-Forwarded-For: 10.9.8.1` returned 200 again. One header, a
 * fresh bucket, forever.
 *
 * WHAT FLY GUARANTEES (https://fly.io/docs/networking/request-headers/):
 *   - `Fly-Client-IP` is "the IP address of the client from the perspective of
 *     Fly Proxy" — the proxy SETS it from the real TCP peer on every request,
 *     so whatever the client put there is overwritten. That is the property we
 *     need: not client-controlled.
 *   - `X-Forwarded-For` is "a comma separated list of IP addresses including the
 *     address of the client that originated the request and the addresses of the
 *     proxy servers the request passed through" — Fly APPENDS to whatever the
 *     client sent, so the left of that list is attacker text. We never read it.
 *
 * The one documented caveat: if another reverse proxy (a CDN, say) is ever put
 * in FRONT of Fly, `Fly-Client-IP` becomes that proxy's address and every user
 * behind it shares one bucket. We don't have one today; if we add one, this
 * function is the single place to teach about it.
 *
 * Requests that never pass through Fly Proxy (a direct hit on the machine over
 * the private 6PN network, or a local `npm run dev`) simply have no
 * `Fly-Client-IP`, and we fall back to the real socket peer — with `trustProxy`
 * now false, `request.ip` is the TCP peer and nothing else.
 */

import type { FastifyRequest } from "fastify";

/**
 * Longest possible textual IP (IPv4-mapped IPv6 with a zone, 45 chars). A
 * header longer than this isn't an address, so we refuse it rather than let it
 * become a map key — rate-limiter buckets are keyed by this string and the map
 * is bounded by KEY COUNT, not by key size.
 */
const MAX_IP_LENGTH = 45;

/**
 * The rate-limiting identity of a request: the Fly-Proxy-observed peer when we
 * are behind Fly, else the socket peer. Never client-controlled in production.
 */
export function clientIp(request: FastifyRequest): string {
  const header = request.headers["fly-client-ip"];
  // Fastify gives string | string[] (a repeated header). A repeated
  // Fly-Client-IP can only come from a client trying to confuse us — Fly sets
  // exactly one — so take the first and let the length check do the rest.
  const raw = Array.isArray(header) ? header[0] : header;
  if (typeof raw === "string") {
    const trimmed = raw.trim();
    if (trimmed.length > 0 && trimmed.length <= MAX_IP_LENGTH) return trimmed;
  }
  return request.ip;
}

/** Prefixed key for a per-IP bucket, so IP and device keys can't ever collide. */
export function ipKey(request: FastifyRequest): string {
  return `ip:${clientIp(request)}`;
}
