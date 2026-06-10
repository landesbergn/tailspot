/**
 * Device identity routes (WP 1.5).
 *
 *   POST /v1/devices
 *     → 201 { deviceId, deviceToken }
 *     Anonymous registration; no input body. The server mints a 256-bit token,
 *     stores ONLY its SHA-256 hash, and returns the raw token exactly once. Per-IP
 *     rate-limited (anti device-mint).
 *
 *   PUT /v1/devices/me/handle   (auth required)
 *     body { handle } → 200 { handle } | 409 { error:"handle taken" } | 422 { error }
 *     Claim/replace the caller's public handle. Validation: 3–20 chars,
 *     [A-Za-z0-9_], case-insensitive uniqueness, profanity blocklist.
 *
 * Stores are injected (the IdentityStore seam); rate limiters are injected so
 * tests can drive them with a fake clock. The route is ignorant of Postgres.
 */

import type { FastifyInstance, FastifyRequest } from "fastify";
import { resolveDevice } from "../identity/auth.js";
import { containsProfanity } from "../identity/profanity.js";
import type { RateLimiter } from "../identity/rateLimiter.js";
import type { IdentityStore } from "../identity/store.js";
import { generateDeviceToken, hashToken } from "../identity/token.js";

export interface DevicesRouteOptions {
  store: IdentityStore;
  /** Per-IP limiter for POST /v1/devices (anti device-mint). */
  registerLimiter: RateLimiter;
  /** Per-device limiter for handle changes. */
  handleLimiter: RateLimiter;
}

/** Handle format: 3–20 chars of [A-Za-z0-9_]. */
const HANDLE_RE = /^[A-Za-z0-9_]{3,20}$/;

/** Client IP for rate limiting. Fastify's `request.ip` honors trustProxy config. */
function clientIp(request: FastifyRequest): string {
  return request.ip;
}

export function registerDevicesRoutes(app: FastifyInstance, opts: DevicesRouteOptions): void {
  const { store, registerLimiter, handleLimiter } = opts;

  // ── POST /v1/devices ───────────────────────────────────────────────────────
  app.post("/v1/devices", async (request, reply) => {
    const ip = clientIp(request);
    const rl = registerLimiter.take(`ip:${ip}`);
    if (!rl.allowed) {
      reply.header("Retry-After", String(rl.retryAfterSeconds));
      return reply.code(429).send({ error: "rate limited" });
    }

    // Mint a token, persist only its hash, return the token ONCE.
    const token = generateDeviceToken();
    const { id } = await store.createDevice(hashToken(token));
    request.log.info({ deviceId: id }, "device registered");
    return reply.code(201).send({ deviceId: id, deviceToken: token });
  });

  // ── PUT /v1/devices/me/handle ────────────────────────────────────────────────
  app.put("/v1/devices/me/handle", async (request, reply) => {
    const device = await resolveDevice(store, request.headers.authorization);
    if (!device) {
      return reply.code(401).send({ error: "unauthorized" });
    }

    const rl = handleLimiter.take(`device:${device.id}`);
    if (!rl.allowed) {
      reply.header("Retry-After", String(rl.retryAfterSeconds));
      return reply.code(429).send({ error: "rate limited" });
    }

    const body = (request.body ?? {}) as { handle?: unknown };
    const handle = body.handle;
    if (typeof handle !== "string") {
      return reply.code(422).send({ error: "handle must be a string" });
    }
    if (!HANDLE_RE.test(handle)) {
      return reply
        .code(422)
        .send({ error: "handle must be 3–20 characters of letters, digits, or underscore" });
    }
    if (containsProfanity(handle)) {
      return reply.code(422).send({ error: "handle not allowed" });
    }

    const result = await store.claimHandle(device.id, handle);
    if (!result.ok) {
      return reply.code(409).send({ error: "handle taken" });
    }
    return reply.code(200).send({ handle: result.handle });
  });
}
