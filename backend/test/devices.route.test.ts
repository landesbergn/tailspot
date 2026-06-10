import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

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
