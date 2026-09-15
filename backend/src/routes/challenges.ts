/**
 * Challenges v1 routes (spec §10.3). Every bearer route follows the hardening
 * pattern: per-IP limiter BEFORE the token lookup, `resolveDevice`, per-device
 * limiter, then work. Non-participants get 404 (never 403) so a challenge id
 * cannot be probed for existence.
 *
 *   GET  /v1/challenges/config             (no auth)  → { enabled, availability, minBuild, appStoreURL }
 *   POST /v1/challenges                    (bearer + handle) → 201 { challenge }
 *   GET  /v1/challenges                    (bearer)   → { open: [...], history: [...] }
 *   GET  /v1/challenges/:id                (bearer, participant) → { challenge, standings, me, winners }
 *   GET  /v1/challenges/:id/log/:handle    (bearer, participant) → { handle, catches: [...] }
 *   POST /v1/challenges/:id/leave          (bearer, participant) → 204
 *   POST /v1/challenges/:id/cancel         (bearer, creator, before start) → 204
 *
 * Kill switch: when `enabled()` is false every route except /config answers
 * 404, and /config says `enabled: false` so the client can explain itself
 * (spec §11.2).
 */

import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import {
  type Challenge,
  type ChallengeStore,
  type Standing,
  challengeStatus,
  isDurationPreset,
} from "../challenges/store.js";
import { resolveDevice } from "../identity/auth.js";
import { ipKey } from "../identity/clientIp.js";
import { containsProfanity } from "../identity/profanity.js";
import type { RateLimiter } from "../identity/rateLimiter.js";
import type { DeviceIdentity, IdentityStore } from "../identity/store.js";

export type ChallengesAvailability = "testflight" | "public";

export interface ChallengesConfig {
  availability: ChallengesAvailability;
  /** CFBundleVersion the client must meet to use Challenges. */
  minBuild: number;
  appStoreURL: string;
}

export interface ChallengesRouteOptions {
  identityStore: IdentityStore;
  store: ChallengeStore;
  /** Feature flag, read per request so tests (and a future admin flip) can toggle it. */
  enabled: () => boolean;
  config: ChallengesConfig;
  /** Browser origins allowed to read /config (the landing page). No-Origin callers (the app) are always allowed. */
  allowedOrigins: readonly string[];
  /** `https://tailspot.app/c` — the invite URL is `${inviteBaseURL}/${code}`. */
  inviteBaseURL: string;
  now: () => Date;
  /** Shared pre-auth per-IP meter (the same instance every bearer route uses). */
  bearerIpLimiter: RateLimiter;
  /** Per-device: POST /v1/challenges. */
  createLimiter: RateLimiter;
  /** Per-device: every GET. */
  readLimiter: RateLimiter;
  /** Per-device: leave / cancel (and join, shared with invites.ts). */
  mutateLimiter: RateLimiter;
  /** Per-IP: /config. */
  configIpLimiter: RateLimiter;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NAME_MIN = 3;
const NAME_MAX = 24;
const SCHEDULE_MIN_LEAD_MS = 15 * 60 * 1000;
const SCHEDULE_MAX_LEAD_MS = 14 * 24 * 60 * 60 * 1000;

/** Wire shape of a challenge, as every route serves it. */
export function serializeChallenge(
  c: Challenge,
  now: Date,
  extra: {
    participantCount: number;
    isCreator: boolean;
    isParticipant: boolean;
    inviteBaseURL: string;
  },
) {
  return {
    id: c.id,
    kind: c.kind,
    code: c.code,
    inviteURL: c.code ? `${extra.inviteBaseURL}/${c.code}` : null,
    name: c.name,
    creatorHandle: c.creatorHandle,
    startsAt: c.startsAt.toISOString(),
    endsAt: c.endsAt.toISOString(),
    durationPreset: c.durationPreset,
    maxParticipants: c.maxParticipants,
    status: challengeStatus(c, now),
    outcome: c.outcome,
    participantCount: extra.participantCount,
    isCreator: extra.isCreator,
    isParticipant: extra.isParticipant,
  };
}

export function serializeStanding(s: Standing, me: string) {
  return {
    placement: s.placement,
    handle: s.handle,
    points: s.points,
    catches: s.catches,
    rarityBreakdown: s.rarityBreakdown,
    isMe: s.deviceId === me,
  };
}

/** The full detail payload (also returned by a successful join). */
export async function challengeDetail(
  store: ChallengeStore,
  c: Challenge,
  device: DeviceIdentity,
  now: Date,
  inviteBaseURL: string,
) {
  const { challenge, standings, outcome } = await store.standings(c, now);
  const mine = standings.find((s) => s.deviceId === device.id) ?? null;
  const winners =
    challenge.finalizedAt && outcome === "decided"
      ? standings.filter((s) => s.placement === 1).map((s) => s.handle)
      : [];
  return {
    challenge: serializeChallenge(challenge, now, {
      participantCount: standings.length,
      isCreator: challenge.creatorDeviceId === device.id,
      isParticipant: mine !== null,
      inviteBaseURL,
    }),
    standings: standings.map((s) => serializeStanding(s, device.id)),
    me: mine ? { placement: mine.placement, points: mine.points, catches: mine.catches } : null,
    winners,
  };
}

export function registerChallengesRoutes(app: FastifyInstance, opts: ChallengesRouteOptions): void {
  const { identityStore, store, enabled, config, now, inviteBaseURL } = opts;
  const allowedOrigins = new Set(opts.allowedOrigins);

  function limited(reply: FastifyReply, limiter: RateLimiter, key: string): boolean {
    const rl = limiter.take(key);
    if (rl.allowed) return false;
    reply.header("Retry-After", String(rl.retryAfterSeconds));
    reply.code(429).send({ error: "rate limited" });
    return true;
  }

  /**
   * The shared prologue: flag → per-IP meter → token → per-device meter.
   * Returns the device, or null when the reply has already been sent.
   */
  async function authed(
    request: FastifyRequest,
    reply: FastifyReply,
    deviceLimiter: RateLimiter,
  ): Promise<DeviceIdentity | null> {
    if (!enabled()) {
      reply.code(404).send({ error: "not found" });
      return null;
    }
    if (limited(reply, opts.bearerIpLimiter, ipKey(request))) return null;
    const device = await resolveDevice(identityStore, request.headers.authorization);
    if (!device) {
      reply.code(401).send({ error: "unauthorized" });
      return null;
    }
    if (limited(reply, deviceLimiter, `device:${device.id}`)) return null;
    return device;
  }

  /** Load a challenge the caller is an ACTIVE participant of, else 404. */
  async function participantChallenge(
    request: FastifyRequest,
    reply: FastifyReply,
    device: DeviceIdentity,
  ): Promise<Challenge | null> {
    const { id } = request.params as { id: string };
    if (!UUID_RE.test(id)) {
      reply.code(404).send({ error: "not found" });
      return null;
    }
    const c = await store.findById(id);
    if (!c || !(await store.isActiveParticipant(c.id, device.id))) {
      reply.code(404).send({ error: "not found" });
      return null;
    }
    return c;
  }

  // ── GET /v1/challenges/config ─────────────────────────────────────────────
  // No auth. The app sends no Origin; a browser (the landing page) must be on
  // the allowlist, else 404 like /v1/stats. Answers even when disabled — that
  // is the whole point: the client learns WHY from here, not from a 404.
  app.get("/v1/challenges/config", async (request, reply) => {
    if (limited(reply, opts.configIpLimiter, ipKey(request))) return reply;
    const origin = request.headers.origin;
    if (typeof origin === "string") {
      if (!allowedOrigins.has(origin)) return reply.code(404).send({ error: "not found" });
      reply.header("Access-Control-Allow-Origin", origin);
      reply.header("Vary", "Origin");
    }
    reply.header("Cache-Control", "public, max-age=60");
    return {
      enabled: enabled(),
      availability: config.availability,
      minBuild: config.minBuild,
      appStoreURL: config.appStoreURL,
    };
  });

  // ── POST /v1/challenges ───────────────────────────────────────────────────
  app.post("/v1/challenges", async (request, reply) => {
    const device = await authed(request, reply, opts.createLimiter);
    if (!device) return reply;
    if (!device.handle) return reply.code(422).send({ error: "handle required" });

    const body = (request.body ?? {}) as Record<string, unknown>;
    const nameRaw = body.name;
    if (typeof nameRaw !== "string")
      return reply.code(422).send({ error: "name must be a string" });
    const name = nameRaw.trim().replace(/\s+/g, " ");
    if (name.length < NAME_MIN || name.length > NAME_MAX) {
      return reply.code(422).send({ error: `name must be ${NAME_MIN}–${NAME_MAX} characters` });
    }
    if (containsProfanity(name)) return reply.code(422).send({ error: "name not allowed" });

    if (!isDurationPreset(body.duration)) {
      return reply.code(422).send({ error: 'duration must be "1h", "24h", "3d" or "7d"' });
    }

    const t = now();
    let startsAt: Date;
    if (body.start === "now" || body.start === undefined) {
      startsAt = t;
    } else if (typeof body.start === "string") {
      const parsed = new Date(body.start);
      if (Number.isNaN(parsed.getTime())) {
        return reply.code(422).send({ error: 'start must be "now" or an ISO-8601 instant' });
      }
      const lead = parsed.getTime() - t.getTime();
      if (lead < SCHEDULE_MIN_LEAD_MS || lead > SCHEDULE_MAX_LEAD_MS) {
        return reply
          .code(422)
          .send({ error: "start must be between 15 minutes and 14 days from now" });
      }
      startsAt = parsed;
    } else {
      return reply.code(422).send({ error: 'start must be "now" or an ISO-8601 instant' });
    }

    const created = await store.create(
      { name, creatorDeviceId: device.id, startsAt, durationPreset: body.duration },
      t,
    );
    request.log.info({ challengeId: created.id, deviceId: device.id }, "challenge created");
    return reply.code(201).send(await challengeDetail(store, created, device, t, inviteBaseURL));
  });

  // ── GET /v1/challenges ────────────────────────────────────────────────────
  // Everything the device is in, split into open (upcoming + live) and history
  // (finished + cancelled). Finished ones get finalized on the way through so
  // a placement is always available for the history row.
  app.get("/v1/challenges", async (request, reply) => {
    const device = await authed(request, reply, opts.readLimiter);
    if (!device) return reply;
    const t = now();
    const mine = await store.listForDevice(device.id);
    const open: unknown[] = [];
    const history: unknown[] = [];
    for (const raw of mine) {
      const c = await store.finalizeIfDue(raw, t);
      const status = challengeStatus(c, t);
      const participantCount = await store.participantCount(c.id);
      const base = serializeChallenge(c, t, {
        participantCount,
        isCreator: c.creatorDeviceId === device.id,
        isParticipant: true,
        inviteBaseURL,
      });
      if (status === "upcoming" || status === "live") {
        open.push(base);
      } else {
        const result = c.finalizedAt ? await store.myResult(c.id, device.id) : null;
        history.push({ ...base, myResult: result });
      }
    }
    // Open: soonest end first (the live one you care about is on top).
    open.sort((a, b) =>
      String((a as { endsAt: string }).endsAt).localeCompare(
        String((b as { endsAt: string }).endsAt),
      ),
    );
    return { open, history };
  });

  // ── GET /v1/challenges/:id ────────────────────────────────────────────────
  app.get("/v1/challenges/:id", async (request, reply) => {
    const device = await authed(request, reply, opts.readLimiter);
    if (!device) return reply;
    const c = await participantChallenge(request, reply, device);
    if (!c) return reply;
    return challengeDetail(store, c, device, now(), inviteBaseURL);
  });

  // ── GET /v1/challenges/:id/log/:handle ────────────────────────────────────
  app.get("/v1/challenges/:id/log/:handle", async (request, reply) => {
    const device = await authed(request, reply, opts.readLimiter);
    if (!device) return reply;
    const c = await participantChallenge(request, reply, device);
    if (!c) return reply;
    const { handle } = request.params as { handle: string };
    const target = (await store.participants(c.id)).find(
      (p) => p.handle.toLowerCase() === handle.toLowerCase(),
    );
    if (!target) return reply.code(404).send({ error: "not found" });
    const rows = await store.catchLog(c, target.deviceId);
    return {
      handle: target.handle,
      catches: rows.map((r) => ({
        aircraft: r.aircraft,
        rarity: r.rarity,
        points: r.points,
        caughtAt: r.caughtAt.toISOString(),
      })),
    };
  });

  // ── POST /v1/challenges/:id/leave ─────────────────────────────────────────
  app.post("/v1/challenges/:id/leave", async (request, reply) => {
    const device = await authed(request, reply, opts.mutateLimiter);
    if (!device) return reply;
    const c = await participantChallenge(request, reply, device);
    if (!c) return reply;
    const result = await store.leave(c, device.id, now());
    if (result === "closed") return reply.code(409).send({ error: "challenge has ended" });
    if (result === "not_participant") return reply.code(404).send({ error: "not found" });
    return reply.code(204).send();
  });

  // ── POST /v1/challenges/:id/cancel ────────────────────────────────────────
  app.post("/v1/challenges/:id/cancel", async (request, reply) => {
    const device = await authed(request, reply, opts.mutateLimiter);
    if (!device) return reply;
    const c = await participantChallenge(request, reply, device);
    if (!c) return reply;
    if (c.creatorDeviceId !== device.id) return reply.code(404).send({ error: "not found" });
    const ok = await store.cancel(c, now());
    if (!ok) return reply.code(409).send({ error: "challenge already started" });
    return reply.code(204).send();
  });
}
