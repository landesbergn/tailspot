import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { streakForgiveness } from "../src/db/schema.js";
import {
  DrizzleStreakForgivenessStore,
  type ForgivenDay,
  type StreakForgivenessStore,
  isValidDayLabel,
} from "../src/streaks/forgiveness.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * GET /v1/streak-forgiveness — the public list of forgiven streak days.
 *
 * Asserts the wire shape against real rows (empty, then sorted ascending
 * whatever the insert order), that it needs no auth and no Origin, the
 * in-process memo (a new row is invisible inside the TTL), the per-IP limit,
 * and that a failed refresh serves the last good list instead of a 500.
 */

describe("GET /v1/streak-forgiveness (PGlite)", () => {
  let app: FastifyInstance;
  let db: Database;
  let clockMs = 0;

  beforeEach(async () => {
    clockMs = 0;
    db = await makeTestDb();
    app = await buildApp({
      streakForgivenessStore: new DrizzleStreakForgivenessStore(db),
      rateLimitNow: () => clockMs,
    });
  });

  afterEach(async () => {
    await app.close();
  });

  const get = () => app.inject({ method: "GET", url: "/v1/streak-forgiveness" });

  it("answers an empty list when no day is forgiven", async () => {
    const res = await get();
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ days: [] });
    expect(res.headers["cache-control"]).toBe("public, max-age=60");
  });

  it("lists every day ascending, with only day and reason, no auth or Origin needed", async () => {
    await db.insert(streakForgiveness).values([
      { day: "2026-11-13", reason: "FAA ground stop" },
      { day: "2026-01-02", reason: "Winter storm" },
      { day: "2026-11-02", reason: "Volcanic ash" },
    ]);
    const res = await get();
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      days: [
        { day: "2026-01-02", reason: "Winter storm" },
        { day: "2026-11-02", reason: "Volcanic ash" },
        { day: "2026-11-13", reason: "FAA ground stop" },
      ],
    });
    // Not Origin-gated: no CORS echo, and a browser Origin changes nothing.
    expect(res.headers["access-control-allow-origin"]).toBeUndefined();
    const withOrigin = await app.inject({
      method: "GET",
      url: "/v1/streak-forgiveness",
      headers: { origin: "https://evil.example" },
    });
    expect(withOrigin.statusCode).toBe(200);
  });

  it("memoises the list until the 60 s TTL elapses", async () => {
    expect((await get()).json().days).toEqual([]);
    await db.insert(streakForgiveness).values({ day: "2026-11-13", reason: "FAA ground stop" });
    clockMs = 59_000;
    expect((await get()).json().days).toEqual([]); // still memoised
    clockMs = 60_000;
    expect((await get()).json().days).toEqual([{ day: "2026-11-13", reason: "FAA ground stop" }]);
  });
});

describe("GET /v1/streak-forgiveness (stub store)", () => {
  let app: FastifyInstance | undefined;

  afterEach(async () => {
    await app?.close();
    app = undefined;
  });

  /** A store that counts reads and can be told to fail. */
  function countingStore(days: ForgivenDay[]) {
    const state = { reads: 0, failing: false, days };
    const store: StreakForgivenessStore = {
      listDays: async () => {
        state.reads++;
        if (state.failing) throw new Error("database is down");
        return state.days;
      },
    };
    return { store, state };
  }

  it("is capped at 120/min per IP, and a burst is one database read", async () => {
    const { store, state } = countingStore([]);
    // Frozen clock: no token ever refills, so the Nth call is exact.
    app = await buildApp({ streakForgivenessStore: store, rateLimitNow: () => 0 });
    for (let i = 0; i < 120; i++) {
      const res = await app.inject({ method: "GET", url: "/v1/streak-forgiveness" });
      expect(res.statusCode).toBe(200);
    }
    const denied = await app.inject({ method: "GET", url: "/v1/streak-forgiveness" });
    expect(denied.statusCode).toBe(429);
    expect(denied.json()).toEqual({ error: "rate limited" });
    expect(denied.headers["retry-after"]).toBeTruthy();
    expect(state.reads).toBe(1);
  });

  it("serves the last good list when a refresh fails, and retries after another TTL", async () => {
    let clockMs = 0;
    const { store, state } = countingStore([{ day: "2026-11-13", reason: "FAA ground stop" }]);
    app = await buildApp({ streakForgivenessStore: store, rateLimitNow: () => clockMs });
    const get = () => app?.inject({ method: "GET", url: "/v1/streak-forgiveness" });

    expect((await get())?.json().days).toHaveLength(1);
    state.failing = true;
    clockMs = 60_000;
    const stale = await get();
    expect(stale?.statusCode).toBe(200);
    expect(stale?.json().days).toEqual([{ day: "2026-11-13", reason: "FAA ground stop" }]);
    expect(state.reads).toBe(2);
    // Inside the new TTL the dead database is left alone.
    clockMs = 90_000;
    await get();
    expect(state.reads).toBe(2);

    state.failing = false;
    state.days = [];
    clockMs = 120_000;
    expect((await get())?.json().days).toEqual([]);
  });

  it("500s when the very first read fails (nothing to fall back on)", async () => {
    const { store, state } = countingStore([]);
    state.failing = true;
    app = await buildApp({ streakForgivenessStore: store, rateLimitNow: () => 0 });
    const res = await app.inject({ method: "GET", url: "/v1/streak-forgiveness" });
    expect(res.statusCode).toBe(500);
  });
});

describe("isValidDayLabel", () => {
  it("accepts real calendar dates only", () => {
    for (const ok of ["2026-11-13", "2024-02-29", "2026-12-31", "2026-01-01"]) {
      expect(isValidDayLabel(ok), ok).toBe(true);
    }
    for (const bad of [
      "2026-02-30",
      "2026-02-29", // 2026 is not a leap year
      "2026-13-01",
      "2026-00-10",
      "2026-11-00",
      "2026-11-31",
      "2026-1-3",
      "20261113",
      "2026-11-13T00:00:00Z",
      " 2026-11-13",
      "11/13/2026",
      "",
    ]) {
      expect(isValidDayLabel(bad), bad).toBe(false);
    }
  });
});
