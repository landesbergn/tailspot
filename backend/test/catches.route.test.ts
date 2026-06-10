import { eq } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { catches, registry, typecodes } from "../src/db/schema.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * Catch ingestion end to end via app.inject() + PGlite stores. The catch-time
 * is anchored to a fixed serverNow (nowSeconds) so the anti-cheat time checks
 * are deterministic. The fixture geometry is the SAME hand-derived setup as
 * validateCatch.test.ts (observer at 37.80/-122.27, aircraft due north at
 * 37.90/-122.27, 3000 m → bearing 0°, elevation ~15.05°).
 */

const NOW = 1_700_000_000; // fixed server "now" (unix seconds)
const OBS = { lat: 37.8, lon: -122.27 };
const AC = { lat: 37.9, lon: -122.27, altitudeMeters: 3000 };

/** A valid, plausible catch body for a given icao24 + catchUuid. */
function catchBody(icao24: string, catchUuid: string) {
  return {
    catchUuid,
    icao24,
    callsign: "UAL123",
    caughtAt: NOW,
    observer: {
      lat: OBS.lat,
      lon: OBS.lon,
      headingDeg: 0,
      elevationDeg: 15.05,
      headingAccuracyDeg: 5,
    },
    aircraft: {
      lat: AC.lat,
      lon: AC.lon,
      altitudeMeters: AC.altitudeMeters,
      positionTimestamp: NOW,
    },
  };
}

describe("POST /v1/catches", () => {
  let app: FastifyInstance;
  let db: Database;
  let token: string;

  beforeEach(async () => {
    db = await makeTestDb();
    // Seed metadata: a known airframe (icao24 aaaaaa → B738 → rare in this test
    // so points are unambiguous) and a typecode WITHOUT a registry row.
    await db.insert(typecodes).values({
      typecode: "B738",
      manufacturer: "Boeing",
      model: "737-800",
      type: "narrow",
      rarity: "rare", // rare → 100 points, distinct from the unknown floor (10)
    });
    await db.insert(registry).values({
      icao24: "aaaaaa",
      registration: "N12345",
      manufacturerRaw: "BOEING",
      modelRaw: "737-800",
      typecode: "B738",
      source: "faa",
    });

    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      nowSeconds: () => NOW,
      rateLimitNow: () => 0, // frozen — stay under the 60/min catch cap
    });

    const reg = await app.inject({ method: "POST", url: "/v1/devices" });
    token = reg.json().deviceToken;
  });

  afterEach(async () => {
    await app.close();
  });

  function post(body: unknown, auth = token) {
    return app.inject({
      method: "POST",
      url: "/v1/catches",
      headers: auth ? { authorization: `Bearer ${auth}` } : {},
      payload: body as object,
    });
  }

  it("happy path: resolves typecode/rarity/points from seeded metadata", async () => {
    const res = await post(catchBody("aaaaaa", "11111111-1111-4111-8111-111111111111"));
    expect(res.statusCode).toBe(201);
    expect(res.json()).toEqual({
      catchId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      points: 100, // rare
      rarity: "rare",
      typecode: "B738",
      duplicate: false,
    });
  });

  it("unknown icao24 → points 10, rarity null, typecode null (still accepted)", async () => {
    const res = await post(catchBody("ffffff", "22222222-2222-4222-8222-222222222222"));
    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.points).toBe(10);
    expect(body.rarity).toBeNull();
    expect(body.typecode).toBeNull();
    expect(body.duplicate).toBe(false);
  });

  it("idempotent replay: same catchUuid returns the ORIGINAL result, 200, duplicate:true", async () => {
    const uuid = "33333333-3333-4333-8333-333333333333";
    const first = await post(catchBody("aaaaaa", uuid));
    expect(first.statusCode).toBe(201);
    const firstBody = first.json();

    // Replay with the same uuid but a DIFFERENT icao24 — the original result
    // must win (we never re-score a replay).
    const replay = await post(catchBody("ffffff", uuid));
    expect(replay.statusCode).toBe(200);
    const replayBody = replay.json();
    expect(replayBody.duplicate).toBe(true);
    expect(replayBody.catchId).toBe(firstBody.catchId);
    expect(replayBody.points).toBe(firstBody.points); // 100, not the unknown 10
    expect(replayBody.rarity).toBe("rare");
    expect(replayBody.typecode).toBe("B738");
  });

  it("401 when the token is bad or absent", async () => {
    const noAuth = await post(catchBody("aaaaaa", "44444444-4444-4444-8444-444444444444"), "");
    expect(noAuth.statusCode).toBe(401);
    const badAuth = await post(catchBody("aaaaaa", "44444444-4444-4444-8444-444444444444"), "nope");
    expect(badAuth.statusCode).toBe(401);
  });

  describe("422 on malformed bodies", () => {
    const base = catchBody("aaaaaa", "55555555-5555-4555-8555-555555555555");
    const cases: Array<[string, unknown]> = [
      ["missing catchUuid", { ...base, catchUuid: undefined }],
      ["non-uuid catchUuid", { ...base, catchUuid: "not-a-uuid" }],
      ["bad icao24", { ...base, icao24: "xyz" }],
      ["missing caughtAt", { ...base, caughtAt: undefined }],
      ["missing observer", { ...base, observer: undefined }],
      ["observer out of range", { ...base, observer: { ...base.observer, lat: 999 } }],
      ["pose angle wrong type", { ...base, observer: { ...base.observer, headingDeg: "north" } }],
      [
        "missing aircraft altitude",
        { ...base, aircraft: { ...base.aircraft, altitudeMeters: undefined } },
      ],
    ];
    for (const [label, body] of cases) {
      it(`rejects ${label}`, async () => {
        const res = await post(body);
        expect(res.statusCode).toBe(422);
      });
    }
  });

  it("NO ORACLE: an implausible catch returns the same status + body SHAPE as a plausible one", async () => {
    // Plausible catch.
    const plausible = await post(catchBody("aaaaaa", "66666666-6666-4666-8666-666666666666"));
    // Implausible catch: same airframe, but the user claims to face due SOUTH
    // (180°) at an absurd elevation while the aircraft is due north. The verdict
    // is stored as "implausible" — but the RESPONSE must be indistinguishable.
    const liar = catchBody("aaaaaa", "77777777-7777-4777-8777-777777777777");
    liar.observer.headingDeg = 180;
    liar.observer.elevationDeg = -45;
    const implausible = await post(liar);

    expect(plausible.statusCode).toBe(implausible.statusCode); // both 201
    expect(Object.keys(plausible.json()).sort()).toEqual(Object.keys(implausible.json()).sort());
    // Same server-resolved scoring too — the verdict doesn't dock points.
    expect(implausible.json().points).toBe(plausible.json().points);
    expect(implausible.json().rarity).toBe(plausible.json().rarity);
  });

  it("stores the verdict on the row even though the response hides it", async () => {
    const liar = catchBody("aaaaaa", "88888888-8888-4888-8888-888888888888");
    liar.observer.headingDeg = 180; // implausible bearing
    await post(liar);
    // The response never reveals the verdict, but the row carries it as jsonb.
    const rows = await db
      .select({ validation: catches.validation })
      .from(catches)
      .where(eq(catches.catchUuid, liar.catchUuid))
      .limit(1);
    const validation = rows[0]?.validation as { verdict: string; reasons: string[] } | null;
    expect(validation).toBeTruthy();
    expect(validation?.verdict).toBe("implausible");
    expect(validation?.reasons.some((r) => r.includes("bearing off"))).toBe(true);
  });
});
