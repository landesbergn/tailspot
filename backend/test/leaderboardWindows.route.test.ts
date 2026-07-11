import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { alltimeToppers, catches, devices, weeklyChampions } from "../src/db/schema.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * Leaderboard WINDOWS + weekly champions (dynamic-leaderboards PR1), end to
 * end over PGlite.
 *
 * The clock is frozen at Sat 2026-07-11 12:00 UTC, so:
 *   - the CURRENT week started Mon 2026-07-06 (resets Mon 2026-07-13),
 *   - the LAST CLOSED week is Mon 2026-06-29 … Sun 2026-07-05,
 *   - the current month started 2026-07-01 (resets 2026-08-01).
 *
 * Devices register through the real API (so tokens/auth work); catches are
 * seeded DIRECTLY into the catches table with explicit points + caughtAt —
 * the windows only care about (device, points, caughtAt), and direct seeding
 * gives exact control over which calendar week each catch lands in.
 */

const NOW_MS = Date.UTC(2026, 6, 11, 12, 0, 0); // Sat 2026-07-11T12:00Z
const NOW = Math.floor(NOW_MS / 1000);

/** A UTC instant, 1-based month. */
function utc(y: number, m1: number, d: number, h = 0): Date {
  return new Date(Date.UTC(y, m1 - 1, d, h));
}

describe("GET /v1/leaderboard windows + weekly champions", () => {
  let app: FastifyInstance;
  let db: Database;
  let uuidSeq = 0;

  function nextUuid(): string {
    uuidSeq += 1;
    const n = uuidSeq.toString(16).padStart(12, "0");
    return `00000000-0000-4000-8000-${n}`;
  }

  beforeEach(async () => {
    uuidSeq = 0;
    db = await makeTestDb();
    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
    });
  });

  afterEach(async () => {
    await app.close();
  });

  async function register(): Promise<{ deviceId: string; token: string }> {
    const res = await app.inject({ method: "POST", url: "/v1/devices" });
    const body = res.json();
    return { deviceId: body.deviceId, token: body.deviceToken };
  }

  async function claim(token: string, handle: string) {
    const res = await app.inject({
      method: "PUT",
      url: "/v1/devices/me/handle",
      headers: { authorization: `Bearer ${token}` },
      payload: { handle },
    });
    expect(res.statusCode).toBe(200);
  }

  /** Seed one catch row with explicit points at an explicit instant. */
  async function seedCatch(deviceId: string, points: number, caughtAt: Date) {
    await db.insert(catches).values({
      catchUuid: nextUuid(),
      deviceId,
      icao24: "abc123",
      callsign: null,
      typecode: null,
      rarity: null,
      points,
      scoringVersion: 2,
      firstOfType: false,
      guessKind: null,
      guessValue: null,
      guessCorrect: false,
      caughtAt,
      observerLat: 37.8,
      observerLon: -122.27,
      headingDeg: null,
      elevationDeg: null,
      headingAccuracyDeg: null,
      aircraftLat: null,
      aircraftLon: null,
      aircraftAltitudeMeters: null,
      aircraftPositionTimestamp: null,
      validation: null,
    });
  }

  async function get(url: string, token?: string) {
    const res = await app.inject({
      method: "GET",
      url,
      headers: token ? { authorization: `Bearer ${token}` } : {},
    });
    expect(res.statusCode).toBe(200);
    return res.json();
  }

  // ── Window scoping ─────────────────────────────────────────────────────────

  it("week window sums and ranks only this week's catches; all-time is untouched", async () => {
    const alice = await register();
    const bob = await register();
    await claim(alice.token, "Alice");
    await claim(bob.token, "Bob");

    await seedCatch(alice.deviceId, 500, utc(2026, 6, 30)); // last week
    await seedCatch(alice.deviceId, 100, utc(2026, 7, 9)); // this week
    await seedCatch(bob.deviceId, 200, utc(2026, 7, 10)); // this week

    const week = await get("/v1/leaderboard?window=week", alice.token);
    // In-window: Bob's 200 beats Alice's 100 — her 500 from last week is out.
    expect(week.entries).toEqual([
      { rank: 1, handle: "Bob", points: 200, catches: 1 },
      { rank: 2, handle: "Alice", points: 100, catches: 1 },
    ]);
    expect(week.window).toBe("week");
    expect(week.resetsAt).toBe("2026-07-13T00:00:00.000Z");
    // `me` is scoped to the window too (Alice is #2 this week)…
    expect(week.me.rank).toBe(2);
    expect(week.me.points).toBe(100);
    // …and the decide-on-read pass just crowned her for last week (500 was the
    // week's top) and observed her at all-time #1 (600 total).
    expect(week.me.weeklyWins).toBe(1);
    expect(week.me.everToppedAllTime).toBe(true);
    expect(week.champions).toEqual([{ handle: "Alice", points: 500, weekStart: "2026-06-29" }]);

    // The all-time board still counts everything.
    const all = await get("/v1/leaderboard", alice.token);
    expect(all.entries).toEqual([
      { rank: 1, handle: "Alice", points: 600, catches: 2 },
      { rank: 2, handle: "Bob", points: 200, catches: 1 },
    ]);
    expect(all.window).toBe("all");
    expect(all.resetsAt).toBeNull();
    expect(all.champions).toBeNull();
  });

  it("month window starts on the 1st UTC and resets on the next 1st", async () => {
    const alice = await register();
    await claim(alice.token, "Alice");
    await seedCatch(alice.deviceId, 50, utc(2026, 6, 30, 23)); // June — out
    await seedCatch(alice.deviceId, 20, utc(2026, 7, 2)); // July — in

    const month = await get("/v1/leaderboard?window=month", alice.token);
    expect(month.entries).toEqual([{ rank: 1, handle: "Alice", points: 20, catches: 1 }]);
    expect(month.me.points).toBe(20);
    expect(month.window).toBe("month");
    expect(month.resetsAt).toBe("2026-08-01T00:00:00.000Z");
    expect(month.champions).toBeNull(); // champions ride the week window only
  });

  it("a device with no in-window catches drops out of entries but keeps an in-window rank in `me`", async () => {
    const alice = await register();
    const bob = await register();
    await claim(alice.token, "Alice");
    await claim(bob.token, "Bob");
    await seedCatch(alice.deviceId, 500, utc(2026, 6, 30)); // last week only
    await seedCatch(bob.deviceId, 10, utc(2026, 7, 10)); // this week

    const week = await get("/v1/leaderboard?window=week", alice.token);
    expect(week.entries).toEqual([{ rank: 1, handle: "Bob", points: 10, catches: 1 }]);
    // Alice has 0 in-window points → ranked behind Bob, not vanished.
    expect(week.me.rank).toBe(2);
    expect(week.me.points).toBe(0);
  });

  // ── Old-client compatibility ───────────────────────────────────────────────

  it("no window param and invalid values fall back to all, additive-only shape", async () => {
    const alice = await register();
    await claim(alice.token, "Alice");
    await seedCatch(alice.deviceId, 10, utc(2026, 7, 9));

    for (const url of ["/v1/leaderboard", "/v1/leaderboard?window=bogus"]) {
      const body = await get(url, alice.token);
      // The pre-windows fields, exactly as before…
      expect(body.entries).toEqual([{ rank: 1, handle: "Alice", points: 10, catches: 1 }]);
      expect(body.me.rank).toBe(1);
      expect(body.me.points).toBe(10);
      // …plus ONLY the documented additions (a Codable/lenient old client
      // ignores unknown keys, so extra top-level fields are wire-compatible).
      expect(Object.keys(body).sort()).toEqual([
        "champions",
        "entries",
        "me",
        "resetsAt",
        "window",
      ]);
      expect(Object.keys(body.me).sort()).toEqual([
        "everToppedAllTime",
        "points",
        "rank",
        "weeklyWins",
      ]);
      expect(body.window).toBe("all");
      expect(body.resetsAt).toBeNull();
      expect(body.champions).toBeNull();
    }
  });

  // ── Decide-on-read champions ───────────────────────────────────────────────

  it("shares the crown on a points tie: every tied device gets a champions row", async () => {
    const alice = await register();
    const bob = await register();
    const carol = await register();
    await claim(alice.token, "Alice");
    await claim(bob.token, "Bob");
    await claim(carol.token, "Carol");
    // Alice and Bob tie at 75 last week; Carol trails at 30.
    await seedCatch(alice.deviceId, 75, utc(2026, 6, 30));
    await seedCatch(bob.deviceId, 25, utc(2026, 7, 1));
    await seedCatch(bob.deviceId, 50, utc(2026, 7, 2));
    await seedCatch(carol.deviceId, 30, utc(2026, 7, 3));

    const week = await get("/v1/leaderboard?window=week", alice.token);
    expect(week.champions).toHaveLength(2);
    expect(new Set(week.champions.map((c: { handle: string }) => c.handle))).toEqual(
      new Set(["Alice", "Bob"]),
    );
    for (const c of week.champions) {
      expect(c.points).toBe(75);
      expect(c.weekStart).toBe("2026-06-29");
    }

    // Both crowns persisted (Carol got none) and both count as wins.
    const rows = await db.select().from(weeklyChampions);
    expect(rows).toHaveLength(2);
    expect(week.me.weeklyWins).toBe(1); // Alice
    const bobView = await get("/v1/leaderboard?window=week", bob.token);
    expect(bobView.me.weeklyWins).toBe(1);
    const carolView = await get("/v1/leaderboard?window=week", carol.token);
    expect(carolView.me.weeklyWins).toBe(0);
  });

  it("decide-on-read is idempotent: repeat requests insert nothing new", async () => {
    const alice = await register();
    await claim(alice.token, "Alice");
    await seedCatch(alice.deviceId, 40, utc(2026, 6, 30));

    await get("/v1/leaderboard?window=week");
    const after1 = await db.select().from(weeklyChampions);
    await get("/v1/leaderboard?window=week");
    await get("/v1/leaderboard?window=week");
    const after3 = await db.select().from(weeklyChampions);

    expect(after1).toHaveLength(1);
    // Byte-for-byte the same rows — same decidedAt, nothing re-decided.
    expect(after3).toEqual(after1);
  });

  it("a zero-catch last week yields NO champion and an empty champions array", async () => {
    const alice = await register();
    await claim(alice.token, "Alice");
    await seedCatch(alice.deviceId, 10, utc(2026, 7, 9)); // this week only

    const week = await get("/v1/leaderboard?window=week", alice.token);
    expect(week.champions).toEqual([]);
    expect(await db.select().from(weeklyChampions)).toHaveLength(0);
    expect(week.me.weeklyWins).toBe(0);
  });

  it("no winner floor: a single 5-point catch wins an otherwise-empty week", async () => {
    const alice = await register();
    await claim(alice.token, "Alice");
    await seedCatch(alice.deviceId, 5, utc(2026, 7, 4)); // sole catch last week

    const week = await get("/v1/leaderboard?window=week");
    expect(week.champions).toEqual([{ handle: "Alice", points: 5, weekStart: "2026-06-29" }]);
  });

  it("an anonymous (handle-less) device can be champion — served with a null handle", async () => {
    const ghost = await register(); // never claims a handle
    const named = await register();
    await claim(named.token, "Named");
    await seedCatch(ghost.deviceId, 100, utc(2026, 7, 1)); // last week, wins
    await seedCatch(named.deviceId, 10, utc(2026, 7, 9)); // this week

    const week = await get("/v1/leaderboard?window=week", ghost.token);
    expect(week.champions).toEqual([{ handle: null, points: 100, weekStart: "2026-06-29" }]);
    // The ghost's win still counts toward ITS trophy data.
    expect(week.me.weeklyWins).toBe(1);
  });

  it("backfills every never-decided closed week since the earliest catch (skipping empty ones)", async () => {
    const alice = await register();
    const bob = await register();
    await claim(alice.token, "Alice");
    await claim(bob.token, "Bob");
    await seedCatch(alice.deviceId, 100, utc(2026, 6, 17)); // week of Jun 15
    // week of Jun 22: zero catches (the gap)
    await seedCatch(bob.deviceId, 50, utc(2026, 7, 1)); // week of Jun 29

    // ONE request decides the whole history.
    const week = await get("/v1/leaderboard?window=week", alice.token);
    // `champions` on the response is the LAST closed week's (Bob's)…
    expect(week.champions).toEqual([{ handle: "Bob", points: 50, weekStart: "2026-06-29" }]);
    // …while the table now holds Alice's older crown too, and nothing for the
    // empty gap week.
    const rows = await db.select().from(weeklyChampions);
    expect(rows.map((r) => r.weekStart).sort()).toEqual(["2026-06-15", "2026-06-29"]);
    expect(week.me.weeklyWins).toBe(1); // Alice's Jun-15 crown
    const bobView = await get("/v1/leaderboard?window=week", bob.token);
    expect(bobView.me.weeklyWins).toBe(1);
  });

  it("accumulates weeklyWins across multiple won weeks", async () => {
    const alice = await register();
    await claim(alice.token, "Alice");
    await seedCatch(alice.deviceId, 10, utc(2026, 6, 16)); // wins week of Jun 15
    await seedCatch(alice.deviceId, 10, utc(2026, 6, 24)); // wins week of Jun 22
    await seedCatch(alice.deviceId, 10, utc(2026, 6, 30)); // wins week of Jun 29

    const week = await get("/v1/leaderboard?window=week", alice.token);
    expect(week.me.weeklyWins).toBe(3);
  });

  // ── All-time topper ledger ─────────────────────────────────────────────────

  it("records every device that EVER tops the all-time board; the flag never unsets", async () => {
    const alice = await register();
    const bob = await register();
    await claim(alice.token, "Alice");
    await claim(bob.token, "Bob");
    await seedCatch(alice.deviceId, 100, utc(2026, 7, 8));

    // Alice is #1 → this all-time request records her.
    const view1 = await get("/v1/leaderboard", alice.token);
    expect(view1.me.everToppedAllTime).toBe(true);
    const bobView1 = await get("/v1/leaderboard", bob.token);
    expect(bobView1.me.everToppedAllTime).toBe(false);

    // Bob overtakes; the next all-time request records HIM — and Alice keeps
    // her flag (the ledger is append-only, "ever topped").
    await seedCatch(bob.deviceId, 500, utc(2026, 7, 10));
    const bobView2 = await get("/v1/leaderboard", bob.token);
    expect(bobView2.me.everToppedAllTime).toBe(true);
    const view2 = await get("/v1/leaderboard", alice.token);
    expect(view2.me.everToppedAllTime).toBe(true);
    expect(await db.select().from(alltimeToppers)).toHaveLength(2);
  });

  it("week-decide also observes the all-time #1 (no window=all request needed)", async () => {
    const alice = await register();
    await claim(alice.token, "Alice");
    await seedCatch(alice.deviceId, 30, utc(2026, 6, 30)); // last week

    // Only a WEEK request — the decide pass records the topper as a side
    // observation.
    const week = await get("/v1/leaderboard?window=week", alice.token);
    expect(week.me.everToppedAllTime).toBe(true);
    const ledger = await db.select().from(alltimeToppers);
    expect(ledger).toHaveLength(1);
    // (Sanity: the ledger row is Alice's device.)
    const deviceRows = await db.select({ id: devices.id }).from(devices);
    expect(deviceRows.map((d) => d.id)).toContain(ledger[0].deviceId);
  });
});
