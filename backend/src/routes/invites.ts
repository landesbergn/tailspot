/**
 * Invite routes (spec §10.3, §11).
 *
 *   GET  /v1/invites/:code            (bearer) → preview { challenge, participants: [handle], canJoin, reason? }
 *   POST /v1/invites/:code/join       (bearer + handle) → 200 detail | 409 full | 410 closed | 422 no handle
 *   GET  /v1/invites/:code/preview    (no auth, Origin allowlist) → { name, creatorHandle, startsAt, endsAt, participantCount, status }
 *
 * The code lookup is metered PER IP BEFORE the token lookup — codes are
 * unguessable (~40 bits) and this limiter is what keeps them that way.
 * Unknown codes are 404 on every route, so nothing can be enumerated.
 *
 * Anti-spam (spec §9.1): opening a link records nothing and notifies nobody.
 * The only write is the explicit join.
 */

import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { normalizeCode } from "../challenges/codes.js";
import { type Challenge, type ChallengeStore, challengeStatus } from "../challenges/store.js";
import { resolveDevice } from "../identity/auth.js";
import { ipKey } from "../identity/clientIp.js";
import type { RateLimiter } from "../identity/rateLimiter.js";
import type { DeviceIdentity, IdentityStore } from "../identity/store.js";
import { challengeDetail, serializeChallenge } from "./challenges.js";

export interface InvitesRouteOptions {
  identityStore: IdentityStore;
  store: ChallengeStore;
  enabled: () => boolean;
  allowedOrigins: readonly string[];
  inviteBaseURL: string;
  now: () => Date;
  /** Per-IP, before any token or DB read, on every invite route. */
  inviteIpLimiter: RateLimiter;
  /** Per-device: join (shared with leave/cancel). */
  mutateLimiter: RateLimiter;
  /** Per-device: the authenticated preview. */
  readLimiter: RateLimiter;
  /** In-process memo lifetime for the public preview. Default 60 s. */
  previewCacheTtlMs?: number;
  /** Clock (unix ms) for the memo; shares the rate limiters' clock. */
  cacheNow?: () => number;
}

type Joinability = { canJoin: true } | { canJoin: false; reason: "full" | "ended" | "cancelled" };

async function joinability(
  store: ChallengeStore,
  c: Challenge,
  now: Date,
  participantCount: number,
): Promise<Joinability> {
  const status = challengeStatus(c, now);
  if (status === "cancelled") return { canJoin: false, reason: "cancelled" };
  if (status === "finished") return { canJoin: false, reason: "ended" };
  if (participantCount >= c.maxParticipants) return { canJoin: false, reason: "full" };
  void store;
  return { canJoin: true };
}

export function registerInvitesRoutes(app: FastifyInstance, opts: InvitesRouteOptions): void {
  const { identityStore, store, enabled, now, inviteBaseURL } = opts;
  const allowedOrigins = new Set(opts.allowedOrigins);
  const ttl = opts.previewCacheTtlMs ?? 60_000;
  const clock = opts.cacheNow ?? (() => Date.now());

  function limited(reply: FastifyReply, limiter: RateLimiter, key: string): boolean {
    const rl = limiter.take(key);
    if (rl.allowed) return false;
    reply.header("Retry-After", String(rl.retryAfterSeconds));
    reply.code(429).send({ error: "rate limited" });
    return true;
  }

  /** Flag + per-IP meter + code parse. Null when the reply was already sent. */
  function gate(request: FastifyRequest, reply: FastifyReply): string | null {
    if (!enabled()) {
      reply.code(404).send({ error: "not found" });
      return null;
    }
    if (limited(reply, opts.inviteIpLimiter, ipKey(request))) return null;
    const code = normalizeCode((request.params as { code: string }).code);
    if (!code) {
      reply.code(404).send({ error: "not found" });
      return null;
    }
    return code;
  }

  async function authed(
    request: FastifyRequest,
    reply: FastifyReply,
    deviceLimiter: RateLimiter,
  ): Promise<DeviceIdentity | null> {
    const device = await resolveDevice(identityStore, request.headers.authorization);
    if (!device) {
      reply.code(401).send({ error: "unauthorized" });
      return null;
    }
    if (limited(reply, deviceLimiter, `device:${device.id}`)) return null;
    return device;
  }

  // ── GET /v1/invites/:code — the Join sheet's preview ──────────────────────
  app.get("/v1/invites/:code", async (request, reply) => {
    const code = gate(request, reply);
    if (!code) return reply;
    const device = await authed(request, reply, opts.readLimiter);
    if (!device) return reply;

    const raw = await store.findByCode(code);
    if (!raw) return reply.code(404).send({ error: "not found" });
    const t = now();
    const c = await store.finalizeIfDue(raw, t);
    const participants = await store.participants(c.id);
    const isParticipant = participants.some((p) => p.deviceId === device.id);
    const join = await joinability(store, c, t, participants.length);
    return {
      challenge: serializeChallenge(c, t, {
        participantCount: participants.length,
        isCreator: c.creatorDeviceId === device.id,
        isParticipant,
        inviteBaseURL,
      }),
      participants: participants.map((p) => p.handle),
      needsHandle: !device.handle,
      alreadyIn: isParticipant,
      ...join,
    };
  });

  // ── POST /v1/invites/:code/join ───────────────────────────────────────────
  app.post("/v1/invites/:code/join", async (request, reply) => {
    const code = gate(request, reply);
    if (!code) return reply;
    const device = await authed(request, reply, opts.mutateLimiter);
    if (!device) return reply;

    // Unknown code → 404 BEFORE the handle check, so a handle-less device
    // learns nothing a handled one wouldn't (every route 404s on a bad code).
    const raw = await store.findByCode(code);
    if (!raw) return reply.code(404).send({ error: "not found" });
    if (!device.handle) return reply.code(422).send({ error: "handle required" });
    const t = now();
    const c = await store.finalizeIfDue(raw, t);
    const result = await store.join(c, device.id, t);
    if (!result.ok) {
      if (result.reason === "full") return reply.code(409).send({ error: "challenge is full" });
      if (result.reason === "closed") {
        return reply.code(410).send({ error: "challenge has ended or was cancelled" });
      }
      return reply.code(401).send({ error: "unauthorized" });
    }
    request.log.info(
      { challengeId: c.id, deviceId: device.id, newDevice: result.newDevice },
      "challenge joined",
    );
    const detail = await challengeDetail(store, c, device, t, inviteBaseURL);
    return reply
      .code(200)
      .send({ ...detail, alreadyIn: result.alreadyIn, newDevice: result.newDevice });
  });

  // ── GET /v1/invites/:code/preview — the web landing page ──────────────────
  // Same fence as /v1/stats: browser Origin allowlist, 404 otherwise, memoised
  // per code. Returns the minimum the page needs and never a participant list.
  const memo = new Map<string, { body: unknown; expiresAt: number }>();
  app.get("/v1/invites/:code/preview", async (request, reply) => {
    const code = gate(request, reply);
    if (!code) return reply;
    const origin = request.headers.origin;
    if (typeof origin !== "string" || !allowedOrigins.has(origin)) {
      return reply.code(404).send({ error: "not found" });
    }
    const tms = clock();
    let hit = memo.get(code);
    if (!hit || tms >= hit.expiresAt) {
      const raw = await store.findByCode(code);
      if (!raw) return reply.code(404).send({ error: "not found" });
      const t = now();
      const c = await store.finalizeIfDue(raw, t);
      const participantCount = await store.participantCount(c.id);
      hit = {
        body: {
          name: c.name,
          creatorHandle: c.creatorHandle,
          startsAt: c.startsAt.toISOString(),
          endsAt: c.endsAt.toISOString(),
          durationPreset: c.durationPreset,
          participantCount,
          maxParticipants: c.maxParticipants,
          status: challengeStatus(c, t),
        },
        expiresAt: tms + ttl,
      };
      // Bound the memo: codes are attacker-guessable strings only up to the
      // limiter, but a long-lived process should not grow without limit.
      if (memo.size > 1_000) memo.clear();
      memo.set(code, hit);
    }
    reply.header("Access-Control-Allow-Origin", origin);
    reply.header("Vary", "Origin");
    reply.header("Cache-Control", "public, max-age=60");
    return hit.body;
  });
}
