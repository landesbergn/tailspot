import { eq } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { GUESS_RECREDIT_CUTOVER, ROUTE_GUESS_REBALANCE_CUTOVER } from "../src/catches/points.js";
import { rescoreCatches } from "../src/catches/rescore.js";
import type { Database } from "../src/db/client.js";
import { catches, registry, typecodes } from "../src/db/schema.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * POST /v1/catches/:catchUuid/guess, the one-time re-credit of bonus-round
 * guesses that 1.1.0 to 1.2.2 clients never uploaded. End to end on PGlite.
 *
 * Every row's `created_at` is set explicitly so the tests don't depend on the
 * wall clock's distance from GUESS_RECREDIT_CUTOVER.
 */

const NOW = 1_786_752_000; // 2026-08-15: after the route re-balance (POST_REBALANCE catches are not future-dated), before the recredit cutover
const BEFORE_CUTOVER = new Date(GUESS_RECREDIT_CUTOVER.getTime() - 86_400_000);
const AFTER_CUTOVER = new Date(GUESS_RECREDIT_CUTOVER.getTime() + 1_000);
// caughtAt on either side of the 2026-08-13 route re-balance (+10% → +25%).
const PRE_REBALANCE = ROUTE_GUESS_REBALANCE_CUTOVER.getTime() / 1000 - 86_400;
const POST_REBALANCE = ROUTE_GUESS_REBALANCE_CUTOVER.getTime() / 1000 + 86_400;

function catchBody(icao24: string, catchUuid: string, caughtAt: number) {
  return {
    catchUuid,
    icao24,
    callsign: "UAL123",
    caughtAt,
    observer: { lat: 37.8, lon: -122.27, headingDeg: 0, elevationDeg: 15, headingAccuracyDeg: 5 },
    aircraft: null,
  };
}

const U1 = "11111111-1111-4111-8111-111111111111";
const U2 = "22222222-2222-4222-8222-222222222222";

describe("POST /v1/catches/:catchUuid/guess", () => {
  let app: FastifyInstance;
  let db: Database;
  let token: string;
  let otherToken: string;

  beforeEach(async () => {
    db = await makeTestDb();
    // aaaaaa → B738 → rare (base 50). bbbbbb → A320 → rare.
    await db.insert(typecodes).values([
      {
        typecode: "B738",
        manufacturer: "Boeing",
        model: "737-800",
        type: "narrow",
        rarity: "rare",
      },
      { typecode: "A320", manufacturer: "Airbus", model: "A320", type: "narrow", rarity: "rare" },
    ]);
    await db.insert(registry).values([
      {
        icao24: "aaaaaa",
        registration: "N1",
        manufacturerRaw: "BOEING",
        modelRaw: "737-800",
        typecode: "B738",
        source: "faa",
      },
      {
        icao24: "bbbbbb",
        registration: "N2",
        manufacturerRaw: "AIRBUS",
        modelRaw: "A320",
        typecode: "A320",
        source: "faa",
      },
    ]);
    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
    });
    token = (await app.inject({ method: "POST", url: "/v1/devices" })).json().deviceToken;
    otherToken = (await app.inject({ method: "POST", url: "/v1/devices" })).json().deviceToken;
  });

  afterEach(async () => {
    await app.close();
  });

  /** Upload a guess-less catch (the 1.1.0-1.2.2 shape) and pin its created_at. */
  async function uploadOld(
    uuid: string,
    opts: { icao24?: string; caughtAt?: number; createdAt?: Date; auth?: string } = {},
  ) {
    const res = await app.inject({
      method: "POST",
      url: "/v1/catches",
      headers: { authorization: `Bearer ${opts.auth ?? token}` },
      payload: catchBody(opts.icao24 ?? "aaaaaa", uuid, opts.caughtAt ?? POST_REBALANCE),
    });
    expect(res.statusCode).toBe(201);
    await db
      .update(catches)
      .set({ createdAt: opts.createdAt ?? BEFORE_CUTOVER })
      .where(eq(catches.catchUuid, uuid));
    return res.json();
  }

  function recredit(uuid: string, body: unknown, auth = token) {
    return app.inject({
      method: "POST",
      url: `/v1/catches/${uuid}/guess`,
      headers: auth ? { authorization: `Bearer ${auth}` } : {},
      payload: body as object,
    });
  }

  async function storedRow(uuid: string) {
    const rows = await db
      .select({
        points: catches.points,
        guessKind: catches.guessKind,
        guessValue: catches.guessValue,
        guessCorrect: catches.guessCorrect,
        scoringVersion: catches.scoringVersion,
      })
      .from(catches)
      .where(eq(catches.catchUuid, uuid));
    return rows[0];
  }

  it("route guess: trusts localCorrect, stores the guess, adds +25% after the re-balance", async () => {
    const up = await uploadOld(U1);
    expect(up.points).toBe(75); // rare 50 + first-of-type 25

    const res = await recredit(U1, { kind: "route", value: "ksfo", localCorrect: true });
    expect(res.statusCode).toBe(200);
    // + round(50 * 0.25) = 13
    expect(res.json()).toEqual({
      applied: true,
      points: 88,
      guessKind: "route",
      guessCorrect: true,
    });
    expect(await storedRow(U1)).toMatchObject({
      points: 88,
      guessKind: "route",
      guessValue: "KSFO",
      guessCorrect: true,
    });
  });

  it("route guess before 2026-08-13 earns the legacy +10%", async () => {
    await uploadOld(U1, { caughtAt: PRE_REBALANCE });
    const res = await recredit(U1, { kind: "route", value: "KSFO", localCorrect: true });
    expect(res.json().points).toBe(80); // 75 + round(50 * 0.10)
  });

  it("route guess with localCorrect:false is stored, no bonus", async () => {
    await uploadOld(U1);
    const res = await recredit(U1, { kind: "route", value: "KOAK", localCorrect: false });
    expect(res.json()).toEqual({
      applied: true,
      points: 75,
      guessKind: "route",
      guessCorrect: false,
    });
  });

  it("type guess is verified on the server: correct typecode earns the bonus", async () => {
    await uploadOld(U1);
    // localCorrect is ignored for type guesses.
    const res = await recredit(U1, { kind: "type", value: "b738", localCorrect: false });
    expect(res.json()).toEqual({
      applied: true,
      points: 88,
      guessKind: "type",
      guessCorrect: true,
    });
  });

  it("type guess is verified on the server: a wrong typecode earns nothing even if the phone said correct", async () => {
    await uploadOld(U1);
    const res = await recredit(U1, { kind: "type", value: "A320", localCorrect: true });
    expect(res.json()).toEqual({
      applied: true,
      points: 75,
      guessKind: "type",
      guessCorrect: false,
    });
  });

  it("a type guess before the route re-balance still gets +25%", async () => {
    await uploadOld(U1, { caughtAt: PRE_REBALANCE });
    const res = await recredit(U1, { kind: "type", value: "B738", localCorrect: true });
    expect(res.json().points).toBe(88);
  });

  it("keeps the frozen first-of-type flag: a second catch of a type scores base + guess only", async () => {
    await uploadOld(U1);
    const second = await uploadOld(U2);
    expect(second.points).toBe(50);
    const res = await recredit(U2, { kind: "route", value: "KSFO", localCorrect: true });
    expect(res.json().points).toBe(63); // 50 + 13
  });

  it("a catch that already has a guess is a no-op returning the current state", async () => {
    const res0 = await app.inject({
      method: "POST",
      url: "/v1/catches",
      headers: { authorization: `Bearer ${token}` },
      payload: {
        ...catchBody("aaaaaa", U1, POST_REBALANCE),
        guess: { kind: "type", value: "B738" },
      },
    });
    expect(res0.json().points).toBe(88);
    await db.update(catches).set({ createdAt: BEFORE_CUTOVER }).where(eq(catches.catchUuid, U1));

    const res = await recredit(U1, { kind: "route", value: "KSFO", localCorrect: true });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      applied: false,
      points: 88,
      guessKind: "type",
      guessCorrect: true,
    });
    expect(await storedRow(U1)).toMatchObject({ guessKind: "type", guessValue: "B738" });
  });

  it("is idempotent: the second call changes nothing", async () => {
    await uploadOld(U1);
    const first = await recredit(U1, { kind: "route", value: "KSFO", localCorrect: true });
    expect(first.json()).toMatchObject({ applied: true, points: 88 });
    // A retry, even with a different verdict, reports the stored state.
    const second = await recredit(U1, { kind: "route", value: "KSFO", localCorrect: false });
    expect(second.statusCode).toBe(200);
    expect(second.json()).toEqual({
      applied: false,
      points: 88,
      guessKind: "route",
      guessCorrect: true,
    });
  });

  it("refuses every call once the re-credit window has closed (409 after_cutover)", async () => {
    await uploadOld(U1);
    // Same database and tokens, but the endpoint's close date has passed.
    const closed = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
      guessRecreditCloses: new Date(NOW * 1000),
    });
    try {
      const res = await closed.inject({
        method: "POST",
        url: `/v1/catches/${U1}/guess`,
        headers: { authorization: `Bearer ${token}` },
        payload: { kind: "route", value: "KSFO", localCorrect: true },
      });
      expect(res.statusCode).toBe(409);
      expect(res.json().code).toBe("after_cutover");
      expect((await storedRow(U1)).guessKind).toBeNull();
    } finally {
      await closed.close();
    }
  });

  it("rejects a catch the server inserted after the cutover (409 after_cutover)", async () => {
    await uploadOld(U1, { createdAt: AFTER_CUTOVER });
    const res = await recredit(U1, { kind: "route", value: "KSFO", localCorrect: true });
    expect(res.statusCode).toBe(409);
    expect(res.json().code).toBe("after_cutover");
    expect(await storedRow(U1)).toMatchObject({ points: 75, guessKind: null, guessCorrect: false });
  });

  it("another device's catch is a 404 catch_not_found and stays untouched", async () => {
    await uploadOld(U1, { auth: otherToken });
    const res = await recredit(U1, { kind: "route", value: "KSFO", localCorrect: true });
    expect(res.statusCode).toBe(404);
    expect(res.json().code).toBe("catch_not_found");
    expect(await storedRow(U1)).toMatchObject({ points: 75, guessKind: null });
  });

  it("an unknown catch is a 404 catch_not_found", async () => {
    const res = await recredit(U1, { kind: "route", value: "KSFO", localCorrect: true });
    expect(res.statusCode).toBe(404);
    expect(res.json().code).toBe("catch_not_found");
  });

  it("401 without a token", async () => {
    const res = await recredit(U1, { kind: "route", value: "KSFO", localCorrect: true }, "");
    expect(res.statusCode).toBe(401);
  });

  it("422 on a malformed body", async () => {
    await uploadOld(U1);
    for (const body of [
      { kind: "airline", value: "UAL", localCorrect: true },
      { kind: "route", value: "", localCorrect: true },
      { kind: "route", value: "X".repeat(17), localCorrect: true },
      { kind: "route", value: "KSFO" },
      { kind: "route", value: "KSFO", localCorrect: "yes" },
    ]) {
      const res = await recredit(U1, body);
      expect(res.statusCode).toBe(422);
    }
    expect(
      (await recredit("not-a-uuid", { kind: "route", value: "KSFO", localCorrect: true }))
        .statusCode,
    ).toBe(422);
    expect(await storedRow(U1)).toMatchObject({ guessKind: null });
  });

  it("stamps the current scoring version, and a later rescore keeps the re-credited bonus", async () => {
    await uploadOld(U1, { caughtAt: PRE_REBALANCE });
    await db.update(catches).set({ scoringVersion: 1 }).where(eq(catches.catchUuid, U1));
    await recredit(U1, { kind: "route", value: "KSFO", localCorrect: true });
    const row = await storedRow(U1);
    expect(row.points).toBe(80);
    const fresh = await new DrizzleCatchStore(db).scoreCatch("aaaaaa");
    expect(row.scoringVersion).toBe(fresh.scoringVersion);

    const report = await rescoreCatches(db, { all: true });
    expect(report.pointsAfter).toBe(report.pointsBefore);
    expect((await storedRow(U1)).points).toBe(80);
  });
});

describe("guess re-credit rate limit", () => {
  it("is metered: the 121st call in a minute gets 429 with Retry-After", async () => {
    const db = await makeTestDb();
    const app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
    });
    const tok = (await app.inject({ method: "POST", url: "/v1/devices" })).json().deviceToken;
    let last = 0;
    for (let i = 0; i < 121; i++) {
      const res = await app.inject({
        method: "POST",
        url: `/v1/catches/${U1}/guess`,
        headers: { authorization: `Bearer ${tok}` },
        payload: { kind: "route", value: "KSFO", localCorrect: true },
      });
      last = res.statusCode;
      if (i < 120) expect(res.statusCode).toBe(404);
      else expect(res.headers["retry-after"]).toBeDefined();
    }
    expect(last).toBe(429);
    await app.close();
  });
});
