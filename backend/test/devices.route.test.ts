import type { FastifyInstance, LightMyRequestResponse } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { disableDevice } from "../src/tools/disable-device.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/** Pull just the two leaderboard facts the revocation tests care about. */
function leaderboardOf(res: LightMyRequestResponse): {
  handles: string[];
  me: unknown;
} {
  expect(res.statusCode).toBe(200);
  const body = res.json();
  return {
    handles: (body.entries as { handle: string }[]).map((e) => e.handle),
    me: body.me ?? null,
  };
}

/**
 * Device registration + handle-claim, end to end via app.inject() with
 * PGlite-backed stores. The rate-limit clock is frozen (rateLimitNow → a fixed
 * value) so a test's many calls never trip the limiter incidentally — the
 * limiter itself is unit-tested with a fake clock in rateLimiter.test.ts.
 */
describe("devices routes", () => {
  let app: FastifyInstance;
  let db: Database;

  beforeEach(async () => {
    db = await makeTestDb();
    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      rateLimitNow: () => 0, // frozen clock; per-test calls stay under capacity
    });
  });

  afterEach(async () => {
    await app.close();
  });

  async function register(): Promise<{ deviceId: string; deviceToken: string }> {
    const res = await app.inject({ method: "POST", url: "/v1/devices" });
    expect(res.statusCode).toBe(201);
    return res.json();
  }

  it("POST /v1/devices issues a deviceId + token; the token authenticates", async () => {
    const { deviceId, deviceToken } = await register();
    expect(deviceId).toMatch(/^[0-9a-f-]{36}$/);
    expect(typeof deviceToken).toBe("string");
    expect(deviceToken.length).toBeGreaterThan(20);

    // The token works for an authenticated call (claim a handle).
    const claim = await app.inject({
      method: "PUT",
      url: "/v1/devices/me/handle",
      headers: { authorization: `Bearer ${deviceToken}` },
      payload: { handle: "Maverick" },
    });
    expect(claim.statusCode).toBe(200);
    expect(claim.json()).toEqual({ handle: "Maverick" });
  });

  it("each registration mints a distinct token", async () => {
    const a = await register();
    const b = await register();
    expect(a.deviceToken).not.toBe(b.deviceToken);
    expect(a.deviceId).not.toBe(b.deviceId);
  });

  it("garbage or absent token → 401 on an authenticated route", async () => {
    const noToken = await app.inject({
      method: "PUT",
      url: "/v1/devices/me/handle",
      payload: { handle: "Goose" },
    });
    expect(noToken.statusCode).toBe(401);

    const garbage = await app.inject({
      method: "PUT",
      url: "/v1/devices/me/handle",
      headers: { authorization: "Bearer not-a-real-token" },
      payload: { handle: "Goose" },
    });
    expect(garbage.statusCode).toBe(401);
  });

  describe("handle claim", () => {
    it("case-insensitive collision → 409 (different device)", async () => {
      const a = await register();
      const b = await register();
      const first = await app.inject({
        method: "PUT",
        url: "/v1/devices/me/handle",
        headers: { authorization: `Bearer ${a.deviceToken}` },
        payload: { handle: "Maverick" },
      });
      expect(first.statusCode).toBe(200);

      // Different device, different casing → collides.
      const collide = await app.inject({
        method: "PUT",
        url: "/v1/devices/me/handle",
        headers: { authorization: `Bearer ${b.deviceToken}` },
        payload: { handle: "maverick" },
      });
      expect(collide.statusCode).toBe(409);
      expect(collide.json()).toEqual({ error: "handle taken" });
    });

    it("the SAME device may re-claim (replace) its handle, even changing case", async () => {
      const { deviceToken } = await register();
      const headers = { authorization: `Bearer ${deviceToken}` };
      const first = await app.inject({
        method: "PUT",
        url: "/v1/devices/me/handle",
        headers,
        payload: { handle: "Iceman" },
      });
      expect(first.statusCode).toBe(200);
      // Re-claim with new casing → still 200 (it's the same owner).
      const recap = await app.inject({
        method: "PUT",
        url: "/v1/devices/me/handle",
        headers,
        payload: { handle: "ICEMAN" },
      });
      expect(recap.statusCode).toBe(200);
      expect(recap.json()).toEqual({ handle: "ICEMAN" });
      // And a different handle entirely.
      const renamed = await app.inject({
        method: "PUT",
        url: "/v1/devices/me/handle",
        headers,
        payload: { handle: "Viper" },
      });
      expect(renamed.statusCode).toBe(200);
      expect(renamed.json()).toEqual({ handle: "Viper" });
    });

    it("rejects bad formats → 422", async () => {
      // A fresh device per case so the per-device handle limiter (5/min) never
      // interferes — each bad attempt gets its own bucket.
      const cases: Array<string | number> = [
        "ab", // too short
        "a".repeat(21), // too long
        "has space", // disallowed char
        "emoji😀", // disallowed char
        "dash-no", // hyphen not allowed
        42, // non-string
      ];
      for (const handle of cases) {
        const { deviceToken } = await register();
        const res = await app.inject({
          method: "PUT",
          url: "/v1/devices/me/handle",
          headers: { authorization: `Bearer ${deviceToken}` },
          payload: { handle },
        });
        expect(res.statusCode, `handle=${String(handle)}`).toBe(422);
      }
    });

    it("rejects profanity → 422", async () => {
      const { deviceToken } = await register();
      const res = await app.inject({
        method: "PUT",
        url: "/v1/devices/me/handle",
        headers: { authorization: `Bearer ${deviceToken}` },
        payload: { handle: "shithead" },
      });
      expect(res.statusCode).toBe(422);
    });
  });

  /**
   * The operator kill switch (`devices.disabled_at`, migration 0009).
   *
   * A disabled device must go dark on every authenticated surface WITHOUT
   * losing data: its catches stay in the DB, so this suite asserts both halves
   * — the doors close, and a second, still-enabled device is untouched (the
   * switch is per-device, not a global outage).
   */
  describe("disabled devices (the revocation lever)", () => {
    const NOW_SECONDS = 1_700_000_000;

    /** A minimal valid catch body; points land on the unknown floor (10). */
    function catchBody(catchUuid: string) {
      return {
        catchUuid,
        icao24: "c0c0c0",
        callsign: null,
        caughtAt: NOW_SECONDS,
        observer: {
          lat: 37.8,
          lon: -122.27,
          headingDeg: 0,
          elevationDeg: 15.05,
          headingAccuracyDeg: 5,
        },
        aircraft: {
          lat: 37.9,
          lon: -122.27,
          altitudeMeters: 3000,
          positionTimestamp: NOW_SECONDS,
        },
      };
    }

    /** Register, claim a handle, and post one catch so the device is boardable. */
    async function boardedDevice(handle: string, catchUuid: string) {
      const { deviceId, deviceToken } = await register();
      const claim = await app.inject({
        method: "PUT",
        url: "/v1/devices/me/handle",
        headers: { authorization: `Bearer ${deviceToken}` },
        payload: { handle },
      });
      expect(claim.statusCode).toBe(200);
      const posted = await app.inject({
        method: "POST",
        url: "/v1/catches",
        headers: { authorization: `Bearer ${deviceToken}` },
        payload: catchBody(catchUuid),
      });
      expect(posted.statusCode).toBe(201);
      return { deviceId, deviceToken };
    }

    function leaderboard(token: string) {
      return app.inject({
        method: "GET",
        url: "/v1/leaderboard",
        headers: { authorization: `Bearer ${token}` },
      });
    }

    it("closes every bearer door but leaves the other device alone", async () => {
      const cheater = await boardedDevice("Cheater", "00000000-0000-4000-8000-00000000c0de");
      const honest = await boardedDevice("Honest", "00000000-0000-4000-8000-00000000600d");

      // Both are on the board and see themselves before anything is disabled.
      const before = leaderboardOf(await leaderboard(cheater.deviceToken));
      expect(before.handles).toEqual(expect.arrayContaining(["Cheater", "Honest"]));
      expect(before.me).not.toBeNull();

      const result = await disableDevice(db, "cheater", { apply: true });
      expect(result.outcome).toBe("disabled");
      expect(result.deviceId).toBe(cheater.deviceId);

      // 1. Auth-required routes 401 — the token now resolves to nothing, so a
      //    revoked token is indistinguishable from a bogus one.
      const listing = await app.inject({
        method: "GET",
        url: "/v1/catches",
        headers: { authorization: `Bearer ${cheater.deviceToken}` },
      });
      expect(listing.statusCode).toBe(401);

      const rename = await app.inject({
        method: "PUT",
        url: "/v1/devices/me/handle",
        headers: { authorization: `Bearer ${cheater.deviceToken}` },
        payload: { handle: "Cheater2" },
      });
      expect(rename.statusCode).toBe(401);

      // 2. The leaderboard treats it as anonymous ("no me") and drops its row.
      const after = leaderboardOf(await leaderboard(cheater.deviceToken));
      expect(after.me).toBeNull();
      expect(after.handles).not.toContain("Cheater");

      // 3. The still-enabled device is completely unaffected.
      const honestView = leaderboardOf(await leaderboard(honest.deviceToken));
      expect(honestView.me).not.toBeNull();
      expect(honestView.handles).toEqual(["Honest"]);
      const honestList = await app.inject({
        method: "GET",
        url: "/v1/catches",
        headers: { authorization: `Bearer ${honest.deviceToken}` },
      });
      expect(honestList.statusCode).toBe(200);
      expect(honestList.json().total).toBe(1);
    });

    it("keeps the catches and re-enables cleanly (the switch is reversible)", async () => {
      const device = await boardedDevice("Reinstated", "00000000-0000-4000-8000-0000000b0000");

      await disableDevice(db, "Reinstated", { apply: true });
      expect(leaderboardOf(await leaderboard(device.deviceToken)).handles).toEqual([]);

      const back = await disableDevice(db, device.deviceId, { enable: true, apply: true });
      expect(back.outcome).toBe("enabled");

      // The catch was never deleted, so the device returns at its real standing.
      const view = leaderboardOf(await leaderboard(device.deviceToken));
      expect(view.handles).toEqual(["Reinstated"]);
      expect(view.me).not.toBeNull();
      const listing = await app.inject({
        method: "GET",
        url: "/v1/catches",
        headers: { authorization: `Bearer ${device.deviceToken}` },
      });
      expect(listing.statusCode).toBe(200);
      expect(listing.json().total).toBe(1);
    });

    it("the operator script dry-runs by default and is a no-op when already in state", async () => {
      const device = await boardedDevice("Dryrun", "00000000-0000-4000-8000-00000000d001");

      // No --apply → reports the intent, writes nothing, token still works.
      const dry = await disableDevice(db, "dryrun");
      expect(dry.outcome).toBe("dry-run");
      expect(dry.deviceId).toBe(device.deviceId);
      const stillWorks = await app.inject({
        method: "GET",
        url: "/v1/catches",
        headers: { authorization: `Bearer ${device.deviceToken}` },
      });
      expect(stillWorks.statusCode).toBe(200);

      // Disabling twice must not stomp the original `disabled_at` timestamp.
      const first = await disableDevice(db, "dryrun", {
        apply: true,
        now: () => new Date("2026-09-06T00:00:00Z"),
      });
      expect(first.outcome).toBe("disabled");
      const second = await disableDevice(db, "dryrun", { apply: true });
      expect(second.outcome).toBe("already");
      expect(second.wasDisabledAt?.toISOString()).toBe("2026-09-06T00:00:00.000Z");

      // Enabling an already-enabled device is likewise a reported no-op.
      await disableDevice(db, "dryrun", { enable: true, apply: true });
      expect((await disableDevice(db, "dryrun", { enable: true, apply: true })).outcome).toBe(
        "already",
      );
    });

    it("an unknown selector matches nothing rather than guessing", async () => {
      const missingHandle = await disableDevice(db, "nobody-has-this-handle", { apply: true });
      expect(missingHandle.outcome).toBe("not-found");
      const missingId = await disableDevice(db, "11111111-2222-4333-8444-555555555555", {
        apply: true,
      });
      expect(missingId.outcome).toBe("not-found");
    });
  });

  it("per-IP register limiter returns 429 with Retry-After after the cap", async () => {
    // capacity is 20/min; with the clock frozen, the 21st call from the same IP
    // (all inject calls share remoteAddress 127.0.0.1) is denied.
    let last = await app.inject({ method: "POST", url: "/v1/devices" });
    for (let i = 0; i < 25; i++) {
      last = await app.inject({ method: "POST", url: "/v1/devices" });
    }
    expect(last.statusCode).toBe(429);
    expect(last.json()).toEqual({ error: "rate limited" });
    expect(last.headers["retry-after"]).toBeTruthy();
  });
});
