import { eq } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { devices } from "../src/db/schema.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * POST / DELETE /v1/devices/push-token, end to end over PGlite.
 *
 * The interesting behaviour isn't the happy path — it's that a token belongs to
 * exactly ONE install. A restore or reinstall can hand the same APNs token to a
 * second anonymous device row, and if both kept it, one phone would receive
 * another identity's notifications. The "moves between devices" test is the
 * guard on that.
 */

const T0_MS = Date.UTC(2026, 8, 26, 12, 0, 0);
/** A plausible APNs token: 64 hex characters. */
const TOKEN_A = "a".repeat(64);
const TOKEN_B = "b1".repeat(32);

describe("push-token routes", () => {
  let app: FastifyInstance;
  let db: Database;

  beforeEach(async () => {
    db = await makeTestDb();
    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      // Frozen clocks: the rate limiters never trip incidentally, and
      // `apns_updated_at` is a known value.
      rateLimitNow: () => T0_MS,
      nowSeconds: () => Math.floor(T0_MS / 1000),
    });
  });

  afterEach(async () => {
    await app.close();
  });

  async function register(): Promise<{ deviceId: string; token: string }> {
    const res = await app.inject({ method: "POST", url: "/v1/devices" });
    expect(res.statusCode).toBe(201);
    const body = res.json();
    return { deviceId: body.deviceId, token: body.deviceToken };
  }

  function post(token: string, payload: unknown) {
    return app.inject({
      method: "POST",
      url: "/v1/devices/push-token",
      headers: { authorization: `Bearer ${token}` },
      payload: payload as Record<string, unknown>,
    });
  }

  async function row(deviceId: string) {
    const rows = await db
      .select({
        apnsToken: devices.apnsToken,
        apnsEnvironment: devices.apnsEnvironment,
        apnsUpdatedAt: devices.apnsUpdatedAt,
      })
      .from(devices)
      .where(eq(devices.id, deviceId));
    return rows[0];
  }

  it("stores the token, environment and timestamp", async () => {
    const dev = await register();
    const res = await post(dev.token, { token: TOKEN_A, environment: "production", build: 96 });
    expect(res.statusCode).toBe(204);
    expect(res.body).toBe("");

    const stored = await row(dev.deviceId);
    expect(stored.apnsToken).toBe(TOKEN_A);
    expect(stored.apnsEnvironment).toBe("production");
    expect(new Date(stored.apnsUpdatedAt ?? 0).getTime()).toBe(T0_MS);
  });

  it("accepts a sandbox token and normalises hex casing", async () => {
    const dev = await register();
    const upper = "AbCd".repeat(16);
    expect((await post(dev.token, { token: upper, environment: "sandbox" })).statusCode).toBe(204);
    const stored = await row(dev.deviceId);
    expect(stored.apnsToken).toBe(upper.toLowerCase());
    expect(stored.apnsEnvironment).toBe("sandbox");
  });

  it("re-registering replaces the device's own token", async () => {
    const dev = await register();
    await post(dev.token, { token: TOKEN_A, environment: "sandbox" });
    await post(dev.token, { token: TOKEN_B, environment: "production" });
    const stored = await row(dev.deviceId);
    expect(stored.apnsToken).toBe(TOKEN_B);
    expect(stored.apnsEnvironment).toBe("production");
  });

  it("the same token from another device moves — it never lives on two rows", async () => {
    const first = await register();
    const second = await register();
    expect((await post(first.token, { token: TOKEN_A, environment: "sandbox" })).statusCode).toBe(
      204,
    );
    expect((await post(second.token, { token: TOKEN_A, environment: "sandbox" })).statusCode).toBe(
      204,
    );

    expect((await row(first.deviceId)).apnsToken).toBeNull();
    expect((await row(first.deviceId)).apnsEnvironment).toBeNull();
    expect((await row(second.deviceId)).apnsToken).toBe(TOKEN_A);
  });

  it("DELETE clears the token", async () => {
    const dev = await register();
    await post(dev.token, { token: TOKEN_A, environment: "production" });
    const res = await app.inject({
      method: "DELETE",
      url: "/v1/devices/push-token",
      headers: { authorization: `Bearer ${dev.token}` },
    });
    expect(res.statusCode).toBe(204);
    const stored = await row(dev.deviceId);
    expect(stored.apnsToken).toBeNull();
    expect(stored.apnsEnvironment).toBeNull();
    expect(stored.apnsUpdatedAt).toBeNull();
  });

  it("DELETE with no token stored is a no-op 204", async () => {
    const dev = await register();
    const res = await app.inject({
      method: "DELETE",
      url: "/v1/devices/push-token",
      headers: { authorization: `Bearer ${dev.token}` },
    });
    expect(res.statusCode).toBe(204);
  });

  it("422s a malformed body", async () => {
    const dev = await register();
    const bad: unknown[] = [
      {},
      { environment: "production" },
      { token: TOKEN_A },
      { token: "not-hex".repeat(10), environment: "production" },
      { token: "abcd", environment: "production" }, // too short
      { token: "a".repeat(201), environment: "production" }, // too long
      { token: TOKEN_A, environment: "staging" },
      { token: TOKEN_A, environment: "production", build: "96" },
      { token: 12345, environment: "production" },
    ];
    for (const payload of bad) {
      const res = await post(dev.token, payload);
      expect(res.statusCode, JSON.stringify(payload)).toBe(422);
      expect(res.json().error).toBeTypeOf("string");
    }
    expect((await row(dev.deviceId)).apnsToken).toBeNull();
  });

  it("401s without a usable bearer token", async () => {
    const noAuth = await app.inject({
      method: "POST",
      url: "/v1/devices/push-token",
      payload: { token: TOKEN_A, environment: "production" },
    });
    expect(noAuth.statusCode).toBe(401);

    const garbage = await post("not-a-real-token", { token: TOKEN_A, environment: "production" });
    expect(garbage.statusCode).toBe(401);

    const del = await app.inject({ method: "DELETE", url: "/v1/devices/push-token" });
    expect(del.statusCode).toBe(401);
  });

  it("is metered at 30/h per device", async () => {
    const dev = await register();
    for (let i = 0; i < 30; i++) {
      expect((await post(dev.token, { token: TOKEN_A, environment: "sandbox" })).statusCode).toBe(
        204,
      );
    }
    const limited = await post(dev.token, { token: TOKEN_A, environment: "sandbox" });
    expect(limited.statusCode).toBe(429);
    expect(limited.headers["retry-after"]).toBeDefined();
  });
});
