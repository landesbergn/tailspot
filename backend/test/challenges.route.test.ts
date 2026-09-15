import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { PrivatePointsScorer } from "../src/challenges/scorer.js";
import { DrizzleChallengeStore } from "../src/challenges/store.js";
import type { Database } from "../src/db/client.js";
import { catches, challengeResults, challenges, devices, typecodes } from "../src/db/schema.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * Challenges v1 end to end over PGlite (spec §13 "Backend").
 *
 * The clock is a mutable unix-seconds value so a test can create a challenge,
 * "wait" past its end, and read the frozen results — no timers. Devices go
 * through the real registration + handle routes; catches are seeded straight
 * into the table with explicit points / caughtAt / createdAt, since the window
 * rule is the only thing about a catch a challenge cares about.
 */

const T0_MS = Date.UTC(2026, 8, 15, 12, 0, 0); // Tue 2026-09-15T12:00Z
const HOUR = 3600;
const DAY = 24 * HOUR;

const SITE = "https://tailspot.app";

describe("Challenges v1 routes", () => {
  let app: FastifyInstance;
  let db: Database;
  let nowSec = Math.floor(T0_MS / 1000);
  let enabled = true;
  let uuidSeq = 0;

  const nowMs = () => nowSec * 1000;
  const nowDate = () => new Date(nowMs());

  function nextUuid(): string {
    uuidSeq += 1;
    return `00000000-0000-4000-8000-${uuidSeq.toString(16).padStart(12, "0")}`;
  }

  beforeEach(async () => {
    nowSec = Math.floor(T0_MS / 1000);
    enabled = true;
    uuidSeq = 0;
    db = await makeTestDb();
    await db.insert(typecodes).values({
      typecode: "B738",
      manufacturer: "Boeing",
      model: "737-800",
      type: "narrow",
      rarity: "rare",
    });
    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      challengeStore: new DrizzleChallengeStore(db, new PrivatePointsScorer(db)),
      challengesEnabled: () => enabled,
      challengesConfig: { availability: "testflight", minBuild: 95 },
      nowSeconds: () => nowSec,
      rateLimitNow: nowMs,
    });
  });

  afterEach(async () => {
    await app.close();
  });

  // ── helpers ────────────────────────────────────────────────────────────────

  type Dev = { deviceId: string; token: string; handle?: string };

  async function register(handle?: string, opts: { ip?: string } = {}): Promise<Dev> {
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices",
      headers: opts.ip ? { "fly-client-ip": opts.ip } : {},
    });
    expect(res.statusCode).toBe(201);
    const body = res.json();
    const dev: Dev = { deviceId: body.deviceId, token: body.deviceToken };
    if (handle) {
      const claim = await app.inject({
        method: "PUT",
        url: "/v1/devices/me/handle",
        headers: {
          authorization: `Bearer ${dev.token}`,
          ...(opts.ip ? { "fly-client-ip": opts.ip } : {}),
        },
        payload: { handle },
      });
      expect(claim.statusCode).toBe(200);
      dev.handle = handle;
    }
    return dev;
  }

  /** Pin a device's registration instant (the DB default is wall-clock now()). */
  async function registeredAt(dev: Dev, at: Date) {
    const { eq } = await import("drizzle-orm");
    await db.update(devices).set({ createdAt: at }).where(eq(devices.id, dev.deviceId));
  }

  function auth(dev: Dev, ip?: string) {
    return { authorization: `Bearer ${dev.token}`, ...(ip ? { "fly-client-ip": ip } : {}) };
  }

  async function createChallenge(
    dev: Dev,
    body: Record<string, unknown> = { name: "Weekend Flyoff", duration: "24h" },
  ) {
    return app.inject({ method: "POST", url: "/v1/challenges", headers: auth(dev), payload: body });
  }

  async function created(dev: Dev, body?: Record<string, unknown>) {
    const res = await createChallenge(dev, body);
    expect(res.statusCode).toBe(201);
    return res.json();
  }

  async function join(dev: Dev, code: string, ip = "10.0.0.1") {
    return app.inject({ method: "POST", url: `/v1/invites/${code}/join`, headers: auth(dev, ip) });
  }

  async function detail(dev: Dev, id: string) {
    return app.inject({ method: "GET", url: `/v1/challenges/${id}`, headers: auth(dev) });
  }

  /** Seed a catch with explicit points, caughtAt, and (optionally) createdAt. */
  async function seedCatch(
    deviceId: string,
    points: number,
    caughtAt: Date,
    opts: { createdAt?: Date; rarity?: string | null; typecode?: string | null } = {},
  ) {
    await db.insert(catches).values({
      catchUuid: nextUuid(),
      deviceId,
      icao24: "abc123",
      callsign: "UAL184", // never surfaces in a challenge payload
      typecode: opts.typecode === undefined ? "B738" : opts.typecode,
      rarity: opts.rarity === undefined ? "rare" : opts.rarity,
      points,
      scoringVersion: 5,
      firstOfType: false,
      guessKind: null,
      guessValue: null,
      guessCorrect: false,
      caughtAt,
      createdAt: opts.createdAt ?? caughtAt,
      observerLat: 37.8,
      observerLon: -122.27,
      headingDeg: 90,
      elevationDeg: 20,
      headingAccuracyDeg: 5,
      aircraftLat: 37.9,
      aircraftLon: -122.2,
      aircraftAltitudeMeters: 3000,
      aircraftPositionTimestamp: caughtAt,
      validation: { verdict: "plausible" },
    });
  }

  const secs = (s: number) => new Date(nowMs() + s * 1000);

  // ── config ─────────────────────────────────────────────────────────────────

  describe("GET /v1/challenges/config", () => {
    it("answers without auth or Origin, reports the flag and minimum build", async () => {
      const res = await app.inject({ method: "GET", url: "/v1/challenges/config" });
      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual({
        enabled: true,
        availability: "testflight",
        minBuild: 95,
        appStoreURL: expect.stringContaining("apps.apple.com"),
      });
      expect(res.headers["cache-control"]).toBe("public, max-age=60");
    });

    it("still answers when the feature is off, saying so", async () => {
      enabled = false;
      const res = await app.inject({ method: "GET", url: "/v1/challenges/config" });
      expect(res.statusCode).toBe(200);
      expect(res.json().enabled).toBe(false);
    });

    it("gates browser origins like /v1/stats", async () => {
      const bad = await app.inject({
        method: "GET",
        url: "/v1/challenges/config",
        headers: { origin: "https://evil.example" },
      });
      expect(bad.statusCode).toBe(404);
      const good = await app.inject({
        method: "GET",
        url: "/v1/challenges/config",
        headers: { origin: SITE },
      });
      expect(good.statusCode).toBe(200);
      expect(good.headers["access-control-allow-origin"]).toBe(SITE);
    });
  });

  // ── kill switch ────────────────────────────────────────────────────────────

  it("every other challenge route is 404 when the flag is off", async () => {
    const dev = await register("noah");
    const c = await created(dev);
    enabled = false;
    expect((await createChallenge(dev)).statusCode).toBe(404);
    expect((await detail(dev, c.challenge.id)).statusCode).toBe(404);
    expect(
      (
        await app.inject({
          method: "GET",
          url: `/v1/invites/${c.challenge.code}`,
          headers: auth(dev),
        })
      ).statusCode,
    ).toBe(404);
    expect((await join(dev, c.challenge.code)).statusCode).toBe(404);
  });

  // ── create ─────────────────────────────────────────────────────────────────

  describe("POST /v1/challenges", () => {
    it("creates a live challenge with the creator as first participant and an invite URL", async () => {
      const dev = await register("noah");
      const body = await created(dev, {
        name: "  Weekend   Flyoff ",
        duration: "24h",
        start: "now",
      });
      expect(body.challenge).toMatchObject({
        kind: "private",
        name: "Weekend Flyoff",
        creatorHandle: "noah",
        durationPreset: "24h",
        maxParticipants: 10,
        status: "live",
        outcome: null,
        participantCount: 1,
        isCreator: true,
        isParticipant: true,
      });
      expect(body.challenge.code).toMatch(/^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$/);
      expect(body.challenge.inviteURL).toBe(`https://tailspot.app/c/${body.challenge.code}`);
      expect(
        new Date(body.challenge.endsAt).getTime() - new Date(body.challenge.startsAt).getTime(),
      ).toBe(DAY * 1000);
      expect(body.standings).toEqual([
        { placement: 1, handle: "noah", points: 0, catches: 0, rarityBreakdown: {}, isMe: true },
      ]);
      expect(body.me).toEqual({ placement: 1, points: 0, catches: 0 });
      expect(body.winners).toEqual([]);
    });

    it("schedules a start between 15 minutes and 14 days out; rejects outside", async () => {
      const dev = await register("noah");
      const ok = await created(dev, {
        name: "Saturday",
        duration: "1h",
        start: secs(2 * HOUR).toISOString(),
      });
      expect(ok.challenge.status).toBe("upcoming");
      const tooSoon = await createChallenge(dev, {
        name: "Soon",
        duration: "1h",
        start: secs(60).toISOString(),
      });
      expect(tooSoon.statusCode).toBe(422);
      const tooFar = await createChallenge(dev, {
        name: "Far",
        duration: "1h",
        start: secs(15 * DAY).toISOString(),
      });
      expect(tooFar.statusCode).toBe(422);
      const garbage = await createChallenge(dev, {
        name: "Bad",
        duration: "1h",
        start: "tomorrow",
      });
      expect(garbage.statusCode).toBe(422);
    });

    it("requires a claimed handle (422) and rejects bad names and durations", async () => {
      const anon = await register();
      expect((await createChallenge(anon)).statusCode).toBe(422);
      const dev = await register("noah");
      expect((await createChallenge(dev, { name: "ab", duration: "24h" })).statusCode).toBe(422);
      expect(
        (await createChallenge(dev, { name: "x".repeat(25), duration: "24h" })).statusCode,
      ).toBe(422);
      expect((await createChallenge(dev, { name: "Shit Show", duration: "24h" })).statusCode).toBe(
        422,
      );
      expect((await createChallenge(dev, { name: "Fine", duration: "2h" })).statusCode).toBe(422);
      expect((await createChallenge(dev, { name: 12, duration: "24h" })).statusCode).toBe(422);
    });

    it("rejects an absent or bogus token (401)", async () => {
      const res = await app.inject({ method: "POST", url: "/v1/challenges", payload: {} });
      expect(res.statusCode).toBe(401);
    });
  });

  // ── invites + join ─────────────────────────────────────────────────────────

  describe("invites", () => {
    it("preview shows the challenge and joinability; join adds the device and returns the detail", async () => {
      const noah = await register("noah");
      const eli = await register("eli");
      const c = await created(noah);
      const code = c.challenge.code;

      const preview = await app.inject({
        method: "GET",
        url: `/v1/invites/${code}`,
        headers: auth(eli),
      });
      expect(preview.statusCode).toBe(200);
      expect(preview.json()).toMatchObject({
        challenge: { name: "Weekend Flyoff", creatorHandle: "noah", isParticipant: false },
        participants: ["noah"],
        needsHandle: false,
        alreadyIn: false,
        canJoin: true,
      });

      const joined = await join(eli, code);
      expect(joined.statusCode).toBe(200);
      expect(joined.json().challenge.participantCount).toBe(2);
      expect(joined.json().standings.map((s: { handle: string }) => s.handle)).toEqual([
        "eli",
        "noah",
      ]);
      expect(joined.json().alreadyIn).toBe(false);

      // Joining again is idempotent.
      const again = await join(eli, code);
      expect(again.statusCode).toBe(200);
      expect(again.json().alreadyIn).toBe(true);
      expect(again.json().challenge.participantCount).toBe(2);
    });

    it("accepts a lowercase, spaced code", async () => {
      const noah = await register("noah");
      const eli = await register("eli");
      const c = await created(noah);
      const code: string = c.challenge.code;
      const spaced = `${code.slice(0, 4).toLowerCase()} ${code.slice(4)}`;
      expect((await join(eli, encodeURIComponent(spaced))).statusCode).toBe(200);
    });

    it("unknown code is 404 everywhere; a handle-less device gets 422 on join", async () => {
      const noah = await register("noah");
      await created(noah);
      const anon = await register();
      expect(
        (await app.inject({ method: "GET", url: "/v1/invites/ZZZZZZZZ", headers: auth(anon) }))
          .statusCode,
      ).toBe(404);
      expect((await join(anon, "ZZZZZZZZ")).statusCode).toBe(404);
      const c = await created(noah);
      const res = await join(anon, c.challenge.code);
      expect(res.statusCode).toBe(422);
      const preview = await app.inject({
        method: "GET",
        url: `/v1/invites/${c.challenge.code}`,
        headers: auth(anon),
      });
      expect(preview.json().needsHandle).toBe(true);
    });

    it("the 11th joiner gets 409 full; the preview says so", async () => {
      const noah = await register("noah");
      const c = await created(noah);
      for (let i = 1; i <= 9; i++) {
        const d = await register(`spotter${i}`);
        expect((await join(d, c.challenge.code, `10.0.0.${i}`)).statusCode).toBe(200);
      }
      const late = await register("late");
      expect((await join(late, c.challenge.code, "10.0.1.1")).statusCode).toBe(409);
      const preview = await app.inject({
        method: "GET",
        url: `/v1/invites/${c.challenge.code}`,
        headers: auth(late, "10.0.1.1"),
      });
      expect(preview.json()).toMatchObject({ canJoin: false, reason: "full" });
    });

    it("joining after the end is 410; the preview says ended", async () => {
      const noah = await register("noah");
      const eli = await register("eli");
      const c = await created(noah, { name: "Quick", duration: "1h" });
      nowSec += HOUR; // exactly at endsAt → finished
      expect((await join(eli, c.challenge.code)).statusCode).toBe(410);
      const preview = await app.inject({
        method: "GET",
        url: `/v1/invites/${c.challenge.code}`,
        headers: auth(eli),
      });
      expect(preview.json()).toMatchObject({ canJoin: false, reason: "ended" });
    });

    it("the invite lookup is metered per IP before any token lookup (429)", async () => {
      const dev = await register("noah");
      let last = 0;
      for (let i = 0; i < 31; i++) {
        const res = await app.inject({
          method: "GET",
          url: "/v1/invites/ZZZZZZZZ",
          headers: { "fly-client-ip": "203.0.113.9", authorization: "Bearer nope" },
        });
        last = res.statusCode;
      }
      expect(last).toBe(429);
      // A different IP is unaffected.
      const other = await app.inject({
        method: "GET",
        url: "/v1/invites/ZZZZZZZZ",
        headers: { "fly-client-ip": "203.0.113.10", ...auth(dev) },
      });
      expect(other.statusCode).toBe(404);
    });

    it("public preview is Origin-gated, minimal, and never lists participants", async () => {
      const noah = await register("noah");
      const c = await created(noah);
      const noOrigin = await app.inject({
        method: "GET",
        url: `/v1/invites/${c.challenge.code}/preview`,
      });
      expect(noOrigin.statusCode).toBe(404);
      const res = await app.inject({
        method: "GET",
        url: `/v1/invites/${c.challenge.code}/preview`,
        headers: { origin: SITE },
      });
      expect(res.statusCode).toBe(200);
      expect(res.headers["access-control-allow-origin"]).toBe(SITE);
      expect(res.json()).toEqual({
        name: "Weekend Flyoff",
        creatorHandle: "noah",
        startsAt: expect.any(String),
        endsAt: expect.any(String),
        durationPreset: "24h",
        participantCount: 1,
        maxParticipants: 10,
        status: "live",
      });
      expect(JSON.stringify(res.json())).not.toContain("participants");
    });
  });

  // ── growth attribution (D19) ───────────────────────────────────────────────

  describe("referral attribution", () => {
    async function referral(deviceId: string) {
      const rows = await db
        .select({ ref: devices.referredByChallengeId })
        .from(devices)
        .where((await import("drizzle-orm")).eq(devices.id, deviceId));
      return rows[0].ref;
    }

    it("stamps a device registered within 7 days on its first join, once", async () => {
      const noah = await register("noah");
      const c1 = await created(noah, { name: "Long", duration: "7d" });
      const fresh = await register("fresh");
      await registeredAt(fresh, nowDate()); // registered "now"
      nowSec += 6 * DAY; // still inside the 7-day challenge, 6 days after registering
      const res = await join(fresh, c1.challenge.code);
      expect(res.statusCode).toBe(200);
      expect(res.json().newDevice).toBe(true);
      expect(await referral(fresh.deviceId)).toBe(c1.challenge.id);

      // A second join never re-stamps.
      const c2 = await created(noah, { name: "Second", duration: "24h" });
      const res2 = await join(fresh, c2.challenge.code);
      expect(res2.json().newDevice).toBe(false);
      expect(await referral(fresh.deviceId)).toBe(c1.challenge.id);
    });

    it("does not stamp a device older than 7 days", async () => {
      const old = await register("oldtimer");
      await registeredAt(old, nowDate());
      nowSec += 8 * DAY;
      const noah = await register("noah");
      const c = await created(noah);
      const res = await join(old, c.challenge.code);
      expect(res.json().newDevice).toBe(false);
      expect(await referral(old.deviceId)).toBeNull();
    });
  });

  // ── window + scoring ───────────────────────────────────────────────────────

  describe("standings", () => {
    it("counts catches in [startsAt, endsAt) that reached the server by endsAt — no grace", async () => {
      const noah = await register("noah");
      const eli = await register("eli");
      const c = await created(noah, { name: "Edges", duration: "1h" });
      await join(eli, c.challenge.code);
      const start = nowDate();
      const end = secs(HOUR);

      await seedCatch(noah.deviceId, 50, new Date(start.getTime() - 1000)); // 1 s before start: out
      await seedCatch(noah.deviceId, 50, start); // at start: in
      await seedCatch(noah.deviceId, 50, new Date(end.getTime() - 1000)); // 1 s before end: in
      await seedCatch(noah.deviceId, 50, end); // at end: out (half-open)
      // Caught inside, uploaded one second after the end: OUT (D9, no grace).
      await seedCatch(eli.deviceId, 500, new Date(end.getTime() - 60_000), {
        createdAt: new Date(end.getTime() + 1000),
      });
      await seedCatch(eli.deviceId, 20, new Date(end.getTime() - 30_000), { rarity: "uncommon" });

      nowSec += HOUR + 60; // finished
      const res = await detail(noah, c.challenge.id);
      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.challenge.status).toBe("finished");
      expect(body.challenge.outcome).toBe("decided");
      expect(body.standings).toEqual([
        {
          placement: 1,
          handle: "noah",
          points: 100,
          catches: 2,
          rarityBreakdown: { rare: 2 },
          isMe: true,
        },
        {
          placement: 2,
          handle: "eli",
          points: 20,
          catches: 1,
          rarityBreakdown: { uncommon: 1 },
          isMe: false,
        },
      ]);
      expect(body.winners).toEqual(["noah"]);
    });

    it("a late joiner's earlier in-window catches count (D3)", async () => {
      const noah = await register("noah");
      const eli = await register("eli");
      const c = await created(noah);
      await seedCatch(eli.deviceId, 100, secs(60)); // caught before eli joins
      nowSec += HOUR;
      await join(eli, c.challenge.code);
      const body = (await detail(eli, c.challenge.id)).json();
      expect(body.me).toEqual({ placement: 1, points: 100, catches: 1 });
    });

    it("ties share placement and both win", async () => {
      const a = await register("amy");
      const b = await register("ben");
      const z = await register("zoe");
      const c = await created(a, { name: "Tie", duration: "1h" });
      await join(b, c.challenge.code);
      await join(z, c.challenge.code);
      await seedCatch(a.deviceId, 100, secs(10));
      await seedCatch(b.deviceId, 100, secs(20));
      await seedCatch(z.deviceId, 60, secs(30));
      nowSec += HOUR;
      const body = (await detail(z, c.challenge.id)).json();
      expect(
        body.standings.map((s: { handle: string; placement: number }) => [s.handle, s.placement]),
      ).toEqual([
        ["amy", 1],
        ["ben", 1],
        ["zoe", 3],
      ]);
      expect(body.winners).toEqual(["amy", "ben"]);
    });

    it("No Contest with one participant, or when nobody scored", async () => {
      const noah = await register("noah");
      const solo = await created(noah, { name: "Solo", duration: "1h" });
      await seedCatch(noah.deviceId, 500, secs(10));
      const eli = await register("eli");
      const zoe = await register("zoe");
      const zero = await created(eli, { name: "Zero", duration: "1h" });
      await join(zoe, zero.challenge.code);
      nowSec += HOUR;
      const s = (await detail(noah, solo.challenge.id)).json();
      expect(s.challenge.outcome).toBe("no_contest");
      expect(s.winners).toEqual([]);
      const zb = (await detail(eli, zero.challenge.id)).json();
      expect(zb.challenge.outcome).toBe("no_contest");
      expect(zb.winners).toEqual([]);
    });

    it("finalization is idempotent and frozen: a later rescore does not move results", async () => {
      const noah = await register("noah");
      const eli = await register("eli");
      const c = await created(noah, { name: "Frozen", duration: "1h" });
      await join(eli, c.challenge.code);
      await seedCatch(noah.deviceId, 10, secs(10));
      await seedCatch(eli.deviceId, 50, secs(20));
      nowSec += HOUR;
      const first = (await detail(noah, c.challenge.id)).json();
      expect(first.winners).toEqual(["eli"]);
      const frozen = await db.select().from(challengeResults);
      expect(frozen).toHaveLength(2);

      // Simulate a rescore that would flip the order if results were live.
      const { eq } = await import("drizzle-orm");
      await db.update(catches).set({ points: 500 }).where(eq(catches.deviceId, noah.deviceId));
      const second = (await detail(noah, c.challenge.id)).json();
      expect(second.winners).toEqual(["eli"]);
      expect(second.standings[0]).toMatchObject({ handle: "eli", points: 50 });
      const header = await db.select().from(challenges);
      expect(header[0].finalizedAt).not.toBeNull();
      expect(header[0].outcome).toBe("decided");
    });

    it("live standings reflect current points and are not frozen", async () => {
      const noah = await register("noah");
      const eli = await register("eli");
      const c = await created(noah);
      await join(eli, c.challenge.code);
      await seedCatch(eli.deviceId, 50, secs(10));
      const body = (await detail(noah, c.challenge.id)).json();
      expect(body.challenge.status).toBe("live");
      expect(body.standings[0]).toMatchObject({ handle: "eli", placement: 1, points: 50 });
      expect(body.winners).toEqual([]); // nobody wins a live challenge
      expect(await db.select().from(challengeResults)).toHaveLength(0);
    });
  });

  // ── catch log privacy ──────────────────────────────────────────────────────

  it("catch log shows make/model, rarity, points, time and nothing identifying", async () => {
    const noah = await register("noah");
    const eli = await register("eli");
    const c = await created(noah);
    await join(eli, c.challenge.code);
    await seedCatch(eli.deviceId, 50, secs(10));
    await seedCatch(eli.deviceId, 10, secs(20), { typecode: null, rarity: null });
    const res = await app.inject({
      method: "GET",
      url: `/v1/challenges/${c.challenge.id}/log/ELI`,
      headers: auth(noah),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      handle: "eli",
      catches: [
        {
          aircraft: "Unknown aircraft",
          rarity: null,
          points: 10,
          caughtAt: secs(20).toISOString(),
        },
        {
          aircraft: "Boeing 737-800",
          rarity: "rare",
          points: 50,
          caughtAt: secs(10).toISOString(),
        },
      ],
    });
    const text = res.body;
    for (const forbidden of [
      "UAL184",
      "abc123",
      "observer",
      "lat",
      "lon",
      "heading",
      "verdict",
      "callsign",
    ]) {
      expect(text).not.toContain(forbidden);
    }
    // Unknown handle inside a real challenge → 404, not 200-empty.
    const missing = await app.inject({
      method: "GET",
      url: `/v1/challenges/${c.challenge.id}/log/nobody`,
      headers: auth(noah),
    });
    expect(missing.statusCode).toBe(404);
  });

  // ── authorization ──────────────────────────────────────────────────────────

  describe("authorization", () => {
    it("a non-participant gets 404 on detail, log, leave and cancel", async () => {
      const noah = await register("noah");
      const stranger = await register("stranger");
      const c = await created(noah);
      const id = c.challenge.id;
      expect((await detail(stranger, id)).statusCode).toBe(404);
      expect(
        (
          await app.inject({
            method: "GET",
            url: `/v1/challenges/${id}/log/noah`,
            headers: auth(stranger),
          })
        ).statusCode,
      ).toBe(404);
      expect(
        (
          await app.inject({
            method: "POST",
            url: `/v1/challenges/${id}/leave`,
            headers: auth(stranger),
          })
        ).statusCode,
      ).toBe(404);
      expect(
        (
          await app.inject({
            method: "POST",
            url: `/v1/challenges/${id}/cancel`,
            headers: auth(stranger),
          })
        ).statusCode,
      ).toBe(404);
      expect((await detail(stranger, "not-a-uuid")).statusCode).toBe(404);
    });

    it("a disabled device is 401 everywhere and vanishes from standings", async () => {
      const noah = await register("noah");
      const eli = await register("eli");
      const c = await created(noah);
      await join(eli, c.challenge.code);
      const { eq } = await import("drizzle-orm");
      await db.update(devices).set({ disabledAt: nowDate() }).where(eq(devices.id, eli.deviceId));
      expect((await detail(eli, c.challenge.id)).statusCode).toBe(401);
      const body = (await detail(noah, c.challenge.id)).json();
      expect(body.standings.map((s: { handle: string }) => s.handle)).toEqual(["noah"]);
      expect(body.challenge.participantCount).toBe(1);
    });
  });

  // ── leave / cancel ─────────────────────────────────────────────────────────

  describe("leave and cancel", () => {
    it("a participant can leave and rejoin; their catches follow them", async () => {
      const noah = await register("noah");
      const eli = await register("eli");
      const c = await created(noah);
      await join(eli, c.challenge.code);
      await seedCatch(eli.deviceId, 50, secs(10));
      const leave = await app.inject({
        method: "POST",
        url: `/v1/challenges/${c.challenge.id}/leave`,
        headers: auth(eli),
      });
      expect(leave.statusCode).toBe(204);
      expect((await detail(eli, c.challenge.id)).statusCode).toBe(404);
      expect((await detail(noah, c.challenge.id)).json().standings).toHaveLength(1);
      const rejoin = await join(eli, c.challenge.code);
      expect(rejoin.statusCode).toBe(200);
      expect(rejoin.json().me).toEqual({ placement: 1, points: 50, catches: 1 });
    });

    it("cancel is creator-only and only before start; the creator leaving an upcoming challenge cancels it", async () => {
      const noah = await register("noah");
      const eli = await register("eli");
      const live = await created(noah);
      const cancelLive = await app.inject({
        method: "POST",
        url: `/v1/challenges/${live.challenge.id}/cancel`,
        headers: auth(noah),
      });
      expect(cancelLive.statusCode).toBe(409);

      const upcoming = await created(noah, {
        name: "Later",
        duration: "1h",
        start: secs(2 * HOUR).toISOString(),
      });
      await join(eli, upcoming.challenge.code);
      const notCreator = await app.inject({
        method: "POST",
        url: `/v1/challenges/${upcoming.challenge.id}/cancel`,
        headers: auth(eli),
      });
      expect(notCreator.statusCode).toBe(404);
      const ok = await app.inject({
        method: "POST",
        url: `/v1/challenges/${upcoming.challenge.id}/cancel`,
        headers: auth(noah),
      });
      expect(ok.statusCode).toBe(204);
      expect((await detail(eli, upcoming.challenge.id)).json().challenge.status).toBe("cancelled");
      expect((await join(eli, upcoming.challenge.code)).statusCode).toBe(410);

      const another = await created(noah, {
        name: "Another",
        duration: "1h",
        start: secs(2 * HOUR).toISOString(),
      });
      const creatorLeaves = await app.inject({
        method: "POST",
        url: `/v1/challenges/${another.challenge.id}/leave`,
        headers: auth(noah),
      });
      expect(creatorLeaves.statusCode).toBe(204);
      const listed = (
        await app.inject({ method: "GET", url: "/v1/challenges", headers: auth(noah) })
      ).json();
      expect(listed.open.map((c: { name: string }) => c.name)).toEqual(["Weekend Flyoff"]);
    });

    it("leaving after the end is 409 and does not touch frozen results", async () => {
      const noah = await register("noah");
      const eli = await register("eli");
      const c = await created(noah, { name: "Done", duration: "1h" });
      await join(eli, c.challenge.code);
      await seedCatch(eli.deviceId, 50, secs(10));
      nowSec += HOUR;
      await detail(noah, c.challenge.id); // finalizes
      const res = await app.inject({
        method: "POST",
        url: `/v1/challenges/${c.challenge.id}/leave`,
        headers: auth(eli),
      });
      expect(res.statusCode).toBe(409);
      expect(await db.select().from(challengeResults)).toHaveLength(2);
    });
  });

  // ── list ───────────────────────────────────────────────────────────────────

  it("GET /v1/challenges splits open and history, with my frozen placement on history rows", async () => {
    const noah = await register("noah");
    const eli = await register("eli");
    const old = await created(noah, { name: "Old", duration: "1h" });
    await join(eli, old.challenge.code);
    await seedCatch(eli.deviceId, 50, secs(10));
    nowSec += 2 * HOUR;
    const live = await created(noah, { name: "Live", duration: "24h" });
    const soon = await created(noah, {
      name: "Soon",
      duration: "1h",
      start: secs(HOUR).toISOString(),
    });
    const res = await app.inject({ method: "GET", url: "/v1/challenges", headers: auth(noah) });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.open.map((c: { name: string; status: string }) => [c.name, c.status])).toEqual([
      ["Soon", "upcoming"],
      ["Live", "live"],
    ]);
    expect(body.history).toHaveLength(1);
    expect(body.history[0]).toMatchObject({
      name: "Old",
      status: "finished",
      outcome: "decided",
      myResult: { placement: 2, points: 0, catches: 0 },
    });
    void live;
    void soon;
  });

  // ── rate limits on the bearer routes ───────────────────────────────────────

  it("create is metered per device (30/hour → 429)", async () => {
    const noah = await register("noah");
    let last = 0;
    for (let i = 0; i < 31; i++) last = (await createChallenge(noah)).statusCode;
    expect(last).toBe(429);
  });
});
