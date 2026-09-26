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
 *   POST /v1/devices/push-token   (auth required)
 *     body { token, environment: "sandbox"|"production", build? } → 204 | 422
 *     Register the caller's APNs token (challenge "someone passed you"
 *     pushes). The same token arriving from a different device clears it from
 *     the old one — a token belongs to one install.
 *
 *   DELETE /v1/devices/push-token   (auth required)
 *     → 204. Forget the caller's token; pushes silently stop.
 *
 * Stores are injected (the IdentityStore seam); rate limiters are injected so
 * tests can drive them with a fake clock. The route is ignorant of Postgres.
 */

import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { resolveDevice } from "../identity/auth.js";
import { ipKey } from "../identity/clientIp.js";
import { containsProfanity } from "../identity/profanity.js";
import type { RateLimiter } from "../identity/rateLimiter.js";
import type { IdentityStore, PushEnvironment } from "../identity/store.js";
import { generateDeviceToken, hashToken } from "../identity/token.js";

export interface DevicesRouteOptions {
  store: IdentityStore;
  /** Per-IP limiter for POST /v1/devices (anti device-mint). */
  registerLimiter: RateLimiter;
  /** Per-device limiter for handle changes. */
  handleLimiter: RateLimiter;
  /**
   * Per-IP limiter shared by every bearer route, applied BEFORE the token
   * lookup. Without it, a bad token costs the attacker one request and costs us
   * a database round-trip — unauthenticated probing was the one path with no
   * meter on it at all. See app.ts for the shared instance.
   */
  bearerIpLimiter: RateLimiter;
  /** Per-device limiter for push-token registration (30/h, like the other mutations). */
  pushTokenLimiter: RateLimiter;
  /** Injectable clock for `apns_updated_at` (tests freeze it). */
  now?: () => Date;
}

/** Handle format: 3–20 chars of [A-Za-z0-9_]. */
const HANDLE_RE = /^[A-Za-z0-9_]{3,20}$/;

/**
 * APNs device token: hex, 64 characters today (32 bytes) but Apple has grown it
 * before and reserves the right to again, so the ceiling is generous. The point
 * of the check is not to validate Apple's format — it's to keep an arbitrary
 * string out of a column we later interpolate into a request path.
 */
const APNS_TOKEN_RE = /^[0-9a-fA-F]{64,200}$/;

export function registerDevicesRoutes(app: FastifyInstance, opts: DevicesRouteOptions): void {
  const { store, registerLimiter, handleLimiter, bearerIpLimiter, pushTokenLimiter } = opts;
  const now = opts.now ?? (() => new Date());

  // ── POST /v1/devices ───────────────────────────────────────────────────────
  app.post("/v1/devices", async (request, reply) => {
    const rl = registerLimiter.take(ipKey(request));
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
    // Per-IP meter FIRST: an unauthenticated prober must not be able to make us
    // hash-and-look-up a token for free. The per-device limiter below still
    // does its job for an authenticated caller.
    const ipRl = bearerIpLimiter.take(ipKey(request));
    if (!ipRl.allowed) {
      reply.header("Retry-After", String(ipRl.retryAfterSeconds));
      return reply.code(429).send({ error: "rate limited" });
    }

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

  // ── POST /v1/devices/push-token ─────────────────────────────────────────────
  //
  // Additive and optional in every direction: a device that never calls this
  // simply never gets a notification, and nothing else in the API changes
  // shape. 204 (no body) because there is nothing to tell the client — the
  // token was already theirs.
  app.post("/v1/devices/push-token", async (request, reply) => {
    const device = await authorize(request, reply);
    if (!device) return reply;

    const body = (request.body ?? {}) as {
      token?: unknown;
      environment?: unknown;
      build?: unknown;
    };
    if (typeof body.token !== "string" || !APNS_TOKEN_RE.test(body.token)) {
      return reply.code(422).send({ error: "token must be 64–200 hex characters" });
    }
    if (body.environment !== "sandbox" && body.environment !== "production") {
      return reply.code(422).send({ error: 'environment must be "sandbox" or "production"' });
    }
    // `build` is accepted for triage (which client build registered this
    // token) and deliberately NOT stored — the app's build number is already
    // on every analytics event, and a column would have to be migrated the
    // next time the client wants to send something else.
    if (body.build !== undefined && !Number.isFinite(body.build)) {
      return reply.code(422).send({ error: "build must be a number" });
    }

    const environment: PushEnvironment = body.environment;
    await store.setPushToken(device.id, body.token.toLowerCase(), environment, now());
    request.log.info(
      { deviceId: device.id, environment, build: body.build ?? null },
      "push token registered",
    );
    return reply.code(204).send();
  });

  // ── DELETE /v1/devices/push-token ───────────────────────────────────────────
  app.delete("/v1/devices/push-token", async (request, reply) => {
    const device = await authorize(request, reply);
    if (!device) return reply;
    await store.clearPushToken(device.id);
    request.log.info({ deviceId: device.id }, "push token cleared");
    return reply.code(204).send();
  });

  /**
   * The shared preamble for both push-token routes: per-IP meter BEFORE the
   * token lookup (an unauthenticated prober must not buy a DB round-trip for
   * free), then auth, then the per-device meter. Returns the device, or null
   * having already sent the 401/429.
   */
  async function authorize(request: FastifyRequest, reply: FastifyReply) {
    const ipRl = bearerIpLimiter.take(ipKey(request));
    if (!ipRl.allowed) {
      reply.header("Retry-After", String(ipRl.retryAfterSeconds));
      reply.code(429).send({ error: "rate limited" });
      return null;
    }
    const device = await resolveDevice(store, request.headers.authorization);
    if (!device) {
      reply.code(401).send({ error: "unauthorized" });
      return null;
    }
    const rl = pushTokenLimiter.take(`device:${device.id}`);
    if (!rl.allowed) {
      reply.header("Retry-After", String(rl.retryAfterSeconds));
      reply.code(429).send({ error: "rate limited" });
      return null;
    }
    return device;
  }
}
