import { eq } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { catches, registry, typecodes } from "../src/db/schema.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import type { AircraftRoute } from "../src/providers/types.js";
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
      rarity: "rare", // rare → 50 points, distinct from the unknown floor (10)
    });
    await db.insert(registry).values({
      icao24: "aaaaaa",
      registration: "N12345",
      manufacturerRaw: "BOEING",
      modelRaw: "737-800",
      typecode: "B738",
      source: "faa",
    });
    // A SECOND rare airframe of a DIFFERENT typecode. Used by the no-oracle test
    // so its two catches are both first-of-type (distinct types) → identical
    // points, keeping the verdict the ONLY thing that could differ.
    await db.insert(typecodes).values({
      typecode: "A320",
      manufacturer: "Airbus",
      model: "A320",
      type: "narrow",
      rarity: "rare",
    });
    await db.insert(registry).values({
      icao24: "bababa",
      registration: "N54321",
      manufacturerRaw: "AIRBUS",
      modelRaw: "A320",
      typecode: "A320",
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

  it("happy path: first catch of a type resolves rarity/points + the first-of-type bonus", async () => {
    const res = await post(catchBody("aaaaaa", "11111111-1111-4111-8111-111111111111"));
    expect(res.statusCode).toBe(201);
    expect(res.json()).toEqual({
      catchId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      points: 75, // rare base 50 + first-of-type bonus round(50*0.5)=25
      rarity: "rare",
      typecode: "B738",
      firstOfType: true,
      guessCorrect: false, // no guess sent → additive key present, false
      duplicate: false,
    });
  });

  it("a SECOND catch of the same type by the same device gets NO first-of-type bonus", async () => {
    // First catch of B738 → first-of-type (75). A later B738 by the SAME device
    // is not first-of-type → base 50, no bonus, firstOfType:false.
    const first = await post(catchBody("aaaaaa", "1a1a1a1a-1a1a-4a1a-8a1a-1a1a1a1a1a1a"));
    expect(first.statusCode).toBe(201);
    expect(first.json().points).toBe(75);
    expect(first.json().firstOfType).toBe(true);

    const second = await post(catchBody("aaaaaa", "2b2b2b2b-2b2b-4b2b-8b2b-2b2b2b2b2b2b"));
    expect(second.statusCode).toBe(201);
    expect(second.json().points).toBe(50); // rare base, no bonus
    expect(second.json().rarity).toBe("rare");
    expect(second.json().typecode).toBe("B738");
    expect(second.json().firstOfType).toBe(false);
  });

  it("unknown icao24 → points 10, rarity null, typecode null, firstOfType false (still accepted)", async () => {
    const res = await post(catchBody("ffffff", "22222222-2222-4222-8222-222222222222"));
    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.points).toBe(10); // unknown floor, no type → no first-of-type bonus
    expect(body.rarity).toBeNull();
    expect(body.typecode).toBeNull();
    expect(body.firstOfType).toBe(false); // a null typecode is never first-of-type
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
    expect(replayBody.points).toBe(firstBody.points); // 75 (rare + first-of-type), not the unknown 10
    expect(replayBody.rarity).toBe("rare");
    expect(replayBody.typecode).toBe("B738");
    expect(replayBody.firstOfType).toBe(true); // the original's stored flag, read back
  });

  it("null aircraft: accepted, scored normally, verdict unverifiable (backfill path)", async () => {
    // A pre-WP-1.7 iOS catch that never recorded the aircraft's position sends
    // aircraft:null. It must succeed, score from its icao24 (B738 → rare → 50,
    // +25 first-of-type → 75), and store an "unverifiable" verdict (no position
    // to validate against).
    const body = catchBody("aaaaaa", "99999999-9999-4999-8999-999999999999");
    const nullAircraft = { ...body, aircraft: null };
    const res = await post(nullAircraft);
    expect(res.statusCode).toBe(201);
    expect(res.json()).toEqual({
      catchId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      points: 75, // rare base 50 + first-of-type bonus 25 — scored from icao24, not position
      rarity: "rare",
      typecode: "B738",
      firstOfType: true,
      guessCorrect: false,
      duplicate: false,
    });

    // The stored row carries null aircraft columns + the unverifiable verdict.
    const rows = await db
      .select({
        aircraftLat: catches.aircraftLat,
        aircraftLon: catches.aircraftLon,
        aircraftAltitudeMeters: catches.aircraftAltitudeMeters,
        aircraftPositionTimestamp: catches.aircraftPositionTimestamp,
        validation: catches.validation,
      })
      .from(catches)
      .where(eq(catches.catchUuid, nullAircraft.catchUuid))
      .limit(1);
    expect(rows[0].aircraftLat).toBeNull();
    expect(rows[0].aircraftLon).toBeNull();
    expect(rows[0].aircraftAltitudeMeters).toBeNull();
    expect(rows[0].aircraftPositionTimestamp).toBeNull();
    const validation = rows[0].validation as { verdict: string; reasons: string[] };
    expect(validation.verdict).toBe("unverifiable");
    expect(validation.reasons).toContain("no aircraft position recorded");
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
      // aircraft may be null, but a present-but-non-object value is still malformed.
      ["aircraft is a non-object scalar", { ...base, aircraft: "nope" }],
      // guess is optional, but a present-but-malformed guess is 422 (the wire
      // carries the guess VALUE — a client sending a verdict-shaped or junk
      // block is a bug, not a scoring decision).
      ["guess is a non-object scalar", { ...base, guess: "B738" }],
      ["guess.kind is not route/type", { ...base, guess: { kind: "airline", value: "UAL" } }],
      ["guess.value missing", { ...base, guess: { kind: "type" } }],
      ["guess.value empty", { ...base, guess: { kind: "type", value: "   " } }],
      ["guess.value non-string", { ...base, guess: { kind: "type", value: 738 } }],
      ["guess.value absurdly long", { ...base, guess: { kind: "route", value: "X".repeat(17) } }],
    ];
    for (const [label, body] of cases) {
      it(`rejects ${label}`, async () => {
        const res = await post(body);
        expect(res.statusCode).toBe(422);
      });
    }
  });

  describe("type guess (server-verified against the registry typecode)", () => {
    it("a correct type guess earns +25% of base and freezes the guess on the row", async () => {
      const body = {
        ...catchBody("aaaaaa", "aaaa1111-1111-4111-8111-111111111111"),
        guess: { kind: "type", value: "b738" }, // lowercase on the wire — server normalizes
      };
      const res = await post(body);
      expect(res.statusCode).toBe(201);
      const json = res.json();
      expect(json.guessCorrect).toBe(true);
      expect(json.firstOfType).toBe(true);
      expect(json.points).toBe(88); // rare 50 + first-of-type 25 + type-guess round(50*0.25)=13

      // The guess is FROZEN on the row: what was asked, the (normalized) value,
      // and the server's verdict.
      const rows = await db
        .select({
          guessKind: catches.guessKind,
          guessValue: catches.guessValue,
          guessCorrect: catches.guessCorrect,
        })
        .from(catches)
        .where(eq(catches.catchUuid, body.catchUuid))
        .limit(1);
      expect(rows[0]).toEqual({ guessKind: "type", guessValue: "B738", guessCorrect: true });
    });

    it("a wrong type guess earns no bonus but is still recorded", async () => {
      const body = {
        ...catchBody("aaaaaa", "aaaa2222-2222-4222-8222-222222222222"),
        guess: { kind: "type", value: "A320" }, // it's actually a B738
      };
      const res = await post(body);
      expect(res.statusCode).toBe(201);
      expect(res.json().guessCorrect).toBe(false);
      expect(res.json().points).toBe(75); // first-of-type only — no guess bonus
      const rows = await db
        .select({
          guessKind: catches.guessKind,
          guessValue: catches.guessValue,
          guessCorrect: catches.guessCorrect,
        })
        .from(catches)
        .where(eq(catches.catchUuid, body.catchUuid))
        .limit(1);
      expect(rows[0]).toEqual({ guessKind: "type", guessValue: "A320", guessCorrect: false });
    });

    it("a type guess on an unresolvable airframe is incorrect, never an error", async () => {
      const body = {
        ...catchBody("ffffff", "aaaa3333-3333-4333-8333-333333333333"),
        guess: { kind: "type", value: "B738" }, // no registry row → no truth to match
      };
      const res = await post(body);
      expect(res.statusCode).toBe(201);
      expect(res.json().guessCorrect).toBe(false);
      expect(res.json().points).toBe(10); // unknown floor, no bonuses
    });

    it("a no-guess row stores null kind/value and false verdict", async () => {
      const body = catchBody("aaaaaa", "aaaa4444-4444-4444-8444-444444444444");
      await post(body);
      const rows = await db
        .select({
          guessKind: catches.guessKind,
          guessValue: catches.guessValue,
          guessCorrect: catches.guessCorrect,
        })
        .from(catches)
        .where(eq(catches.catchUuid, body.catchUuid))
        .limit(1);
      expect(rows[0]).toEqual({ guessKind: null, guessValue: null, guessCorrect: false });
    });

    it("a replay echoes the ORIGINAL guess verdict", async () => {
      const uuid = "aaaa5555-5555-4555-8555-555555555555";
      const first = await post({
        ...catchBody("aaaaaa", uuid),
        guess: { kind: "type", value: "B738" },
      });
      expect(first.json().guessCorrect).toBe(true);

      // Replay without the guess block — the stored result must win.
      const replay = await post(catchBody("aaaaaa", uuid));
      expect(replay.statusCode).toBe(200);
      expect(replay.json().duplicate).toBe(true);
      expect(replay.json().guessCorrect).toBe(true);
      expect(replay.json().points).toBe(first.json().points);
    });
  });

  it("a route guess with NO resolver wired verifies incorrect, never a 500", async () => {
    // This app was built without a routeResolver (like a non-adsblol deploy):
    // the guess is simply wrong; the catch itself is untouched.
    const res = await post({
      ...catchBody("aaaaaa", "aaaa6666-6666-4666-8666-666666666666"),
      guess: { kind: "route", value: "KSFO" },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().guessCorrect).toBe(false);
    expect(res.json().points).toBe(75); // first-of-type only
  });

  it("NO ORACLE: an implausible catch returns the same status + body SHAPE as a plausible one", async () => {
    // Plausible catch (first-of-type B738 → rare → 75).
    const plausible = await post(catchBody("aaaaaa", "66666666-6666-4666-8666-666666666666"));
    // Implausible catch: the user claims to face due SOUTH (180°) at an absurd
    // elevation while the aircraft is due north. It uses a DIFFERENT rare airframe
    // (A320) so it is ALSO first-of-type → same 75 points; the verdict is the only
    // thing that differs, and the RESPONSE must stay indistinguishable.
    const liar = catchBody("bababa", "77777777-7777-4777-8777-777777777777");
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

// ── Route-guess verification (game-layer PR1) ────────────────────────────────
// The route guess is verified through the SAME RouteResolver seam behind
// GET /v1/routes/:callsign. These tests inject a controllable fake so the
// upstream behaviors (route on file, no route, resolver down) are deterministic.
describe("route guess (server-verified via the RouteResolver)", () => {
  let app: FastifyInstance;
  let db: Database;
  let token: string;
  /** Per-test resolver behavior; the injected resolver delegates here. */
  let resolveImpl: (callsign: string) => Promise<AircraftRoute | null>;
  /** Callsigns the resolver was actually asked about. */
  let resolvedCallsigns: string[];

  beforeEach(async () => {
    db = await makeTestDb();
    await db.insert(typecodes).values({
      typecode: "B738",
      manufacturer: "Boeing",
      model: "737-800",
      type: "narrow",
      rarity: "rare",
    });
    await db.insert(registry).values({ icao24: "aaaaaa", typecode: "B738", source: "faa" });

    resolveImpl = async () => ({ originIcao: "KSFO", destIcao: "EGLL" });
    resolvedCallsigns = [];
    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      routeResolver: {
        resolve: (callsign: string) => {
          resolvedCallsigns.push(callsign);
          return resolveImpl(callsign);
        },
      },
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
    });
    const reg = await app.inject({ method: "POST", url: "/v1/devices" });
    token = reg.json().deviceToken;
  });

  afterEach(async () => {
    await app.close();
  });

  function post(body: unknown) {
    return app.inject({
      method: "POST",
      url: "/v1/catches",
      headers: { authorization: `Bearer ${token}` },
      payload: body as object,
    });
  }

  function guessedBody(uuid: string, value: string) {
    return { ...catchBody("aaaaaa", uuid), guess: { kind: "route", value } };
  }

  it("a correct guess on the ORIGIN earns +10% of base (and the callsign is normalized)", async () => {
    const body = guessedBody("bbbb1111-1111-4111-8111-111111111111", "ksfo");
    body.callsign = "ual123"; // lowercase on the wire — resolver must get UAL123
    const res = await post(body);
    expect(res.statusCode).toBe(201);
    expect(res.json().guessCorrect).toBe(true);
    expect(res.json().points).toBe(80); // rare 50 + first-of-type 25 + route-guess round(50*0.1)=5
    expect(resolvedCallsigns).toEqual(["UAL123"]);
  });

  it("a correct guess on the DESTINATION also counts (either-endpoint match)", async () => {
    const res = await post(guessedBody("bbbb2222-2222-4222-8222-222222222222", "EGLL"));
    expect(res.statusCode).toBe(201);
    expect(res.json().guessCorrect).toBe(true);
    expect(res.json().points).toBe(80);
  });

  it("a wrong guess earns no bonus", async () => {
    const res = await post(guessedBody("bbbb3333-3333-4333-8333-333333333333", "KLAX"));
    expect(res.statusCode).toBe(201);
    expect(res.json().guessCorrect).toBe(false);
    expect(res.json().points).toBe(75); // first-of-type only
  });

  it("no route on file → incorrect, catch accepted", async () => {
    resolveImpl = async () => null;
    const res = await post(guessedBody("bbbb4444-4444-4444-8444-444444444444", "KSFO"));
    expect(res.statusCode).toBe(201);
    expect(res.json().guessCorrect).toBe(false);
    expect(res.json().points).toBe(75);
  });

  it("resolver DOWN → incorrect, catch accepted, never a 500", async () => {
    resolveImpl = async () => {
      throw new Error("adsb.lol unreachable");
    };
    const res = await post(guessedBody("bbbb5555-5555-4555-8555-555555555555", "KSFO"));
    expect(res.statusCode).toBe(201);
    expect(res.json().guessCorrect).toBe(false);
    expect(res.json().points).toBe(75);
    // The forfeited guess is still frozen on the row for telemetry.
    const rows = await db
      .select({ guessKind: catches.guessKind, guessCorrect: catches.guessCorrect })
      .from(catches)
      .where(eq(catches.catchUuid, "bbbb5555-5555-4555-8555-555555555555"))
      .limit(1);
    expect(rows[0]).toEqual({ guessKind: "route", guessCorrect: false });
  });

  it("a route guess on a callsign-less catch is incorrect without consulting the resolver", async () => {
    const body = guessedBody("bbbb6666-6666-4666-8666-666666666666", "KSFO");
    body.callsign = null as unknown as string;
    const res = await post(body);
    expect(res.statusCode).toBe(201);
    expect(res.json().guessCorrect).toBe(false);
    expect(resolvedCallsigns).toEqual([]);
  });
});

// ── Security-review regression (2026-06-10): idempotency is per-device ──────
// A second device submitting the SAME catchUuid must get its OWN fresh catch,
// not a replay of (or interaction with) the first device's row.
describe("catchUuid idempotency scope", () => {
  it("the same catchUuid from a different device is an independent insert", async () => {
    const db = await makeTestDb();
    const app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
    });

    const regA = await app.inject({ method: "POST", url: "/v1/devices" });
    const regB = await app.inject({ method: "POST", url: "/v1/devices" });
    const uuid = "11111111-2222-4333-8444-555555555555";
    const post = (token: string) =>
      app.inject({
        method: "POST",
        url: "/v1/catches",
        headers: { authorization: `Bearer ${token}` },
        payload: catchBody("bbbbbb", uuid),
      });

    const first = await post(regA.json().deviceToken);
    expect(first.statusCode).toBe(201);
    expect(first.json().duplicate).toBe(false);

    const second = await post(regB.json().deviceToken);
    expect(second.statusCode).toBe(201);
    expect(second.json().duplicate).toBe(false);
    expect(second.json().catchId).not.toBe(first.json().catchId);

    // And the same device replaying it is still a duplicate.
    const replay = await post(regB.json().deviceToken);
    expect(replay.statusCode).toBe(200);
    expect(replay.json().duplicate).toBe(true);
    expect(replay.json().catchId).toBe(second.json().catchId);
    await app.close();
  });
});
