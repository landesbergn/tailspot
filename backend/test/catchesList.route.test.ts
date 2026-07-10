import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { registry, typecodes } from "../src/db/schema.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * GET /v1/catches — the Hangar-restore listing (issue #58) — end to end via
 * app.inject() + PGlite stores. Catches are seeded through the REAL POST
 * ingest path so the listed rows carry genuine server-scored values, exactly
 * what a restoring client will receive in production.
 */

const NOW = 1_700_000_000; // fixed server "now" (unix seconds)
const OBS = { lat: 37.8, lon: -122.27 };

/** A valid catch body. caughtAt is offset per-catch so ordering is testable. */
function catchBody(icao24: string, catchUuid: string, caughtAtOffset = 0) {
  return {
    catchUuid,
    icao24,
    callsign: "UAL123",
    caughtAt: NOW + caughtAtOffset,
    observer: {
      lat: OBS.lat,
      lon: OBS.lon,
      headingDeg: null,
      elevationDeg: null,
      headingAccuracyDeg: null,
    },
    aircraft: null, // matches the real iOS uploader (always sends null)
  };
}

/** uuid helper: "00000000-0000-4000-8000-0000000000NN". */
function uuid(n: number) {
  return `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
}

describe("GET /v1/catches", () => {
  let app: FastifyInstance;
  let db: Database;
  let token: string;

  beforeEach(async () => {
    db = await makeTestDb();
    // A known airframe: registry row (registration) + typecode row (clean
    // names + rarity) so the airframe joins are exercised.
    await db.insert(typecodes).values({
      typecode: "B738",
      manufacturer: "Boeing",
      model: "737-800",
      type: "narrow",
      rarity: "rare",
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
      rateLimitNow: () => 0,
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
      headers: { authorization: `Bearer ${auth}` },
      payload: body as object,
    });
  }

  function list(query = "", auth: string | null = token) {
    return app.inject({
      method: "GET",
      url: `/v1/catches${query}`,
      headers: auth ? { authorization: `Bearer ${auth}` } : {},
    });
  }

  it("requires auth: 401 without a token and with a bogus one", async () => {
    const anonymous = await list("", null);
    expect(anonymous.statusCode).toBe(401);
    const bogus = await list("", "not-a-real-token");
    expect(bogus.statusCode).toBe(401);
  });

  it("returns an empty page for a device with no catches", async () => {
    const res = await list();
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ total: 0, catches: [] });
  });

  it("returns the device's catches with server-scored + joined airframe fields", async () => {
    const posted = await post(catchBody("aaaaaa", uuid(1)));
    expect(posted.statusCode).toBe(201);

    const res = await list();
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.total).toBe(1);
    expect(body.catches).toHaveLength(1);
    expect(body.catches[0]).toEqual({
      catchUuid: uuid(1),
      icao24: "aaaaaa",
      callsign: "UAL123",
      typecode: "B738",
      rarity: "rare",
      points: 75, // rare base 50 + first-of-type 25, as the POST scored it
      firstOfType: true,
      guessKind: null,
      guessValue: null,
      guessCorrect: false,
      caughtAt: NOW,
      observerLat: OBS.lat,
      observerLon: OBS.lon,
      aircraftAltitudeMeters: null, // the uploader sends aircraft: null
      registration: "N12345", // joined from registry
      manufacturer: "Boeing", // joined from typecodes (clean DOC 8643 names)
      model: "737-800",
    });
  });

  it("an unknown airframe restores with null typecode/rarity/registration/names", async () => {
    // icao24 with NO registry row: scored at the unknown floor, joins all null.
    await post(catchBody("bbbbbb", uuid(2)));

    const res = await list();
    const row = res.json().catches[0];
    expect(row.icao24).toBe("bbbbbb");
    expect(row.typecode).toBeNull();
    expect(row.rarity).toBeNull();
    expect(row.points).toBe(10); // the unknown floor
    expect(row.registration).toBeNull();
    expect(row.manufacturer).toBeNull();
    expect(row.model).toBeNull();
  });

  it("returns ONLY the authenticated device's rows", async () => {
    // Device A (the beforeEach token) catches one plane…
    await post(catchBody("aaaaaa", uuid(3)));

    // …device B registers and catches a different one.
    const regB = await app.inject({ method: "POST", url: "/v1/devices" });
    const tokenB = regB.json().deviceToken;
    await post(catchBody("bbbbbb", uuid(4)), tokenB);

    const forA = (await list()).json();
    expect(forA.total).toBe(1);
    expect(forA.catches.map((c: { icao24: string }) => c.icao24)).toEqual(["aaaaaa"]);

    const forB = (await list("", tokenB)).json();
    expect(forB.total).toBe(1);
    expect(forB.catches.map((c: { icao24: string }) => c.icao24)).toEqual(["bbbbbb"]);
  });

  it("paginates oldest-first with a stable total across pages", async () => {
    // Five catches at one-minute intervals, posted OUT of caughtAt order to
    // prove ordering comes from caughtAt, not insertion.
    const offsets = [240, 0, 120, 60, 180];
    for (const [i, off] of offsets.entries()) {
      const posted = await post(catchBody("aaaaaa", uuid(10 + i), off));
      expect(posted.statusCode).toBe(201);
    }

    const page1 = (await list("?limit=2&offset=0")).json();
    expect(page1.total).toBe(5);
    expect(page1.catches.map((c: { caughtAt: number }) => c.caughtAt)).toEqual([NOW, NOW + 60]);

    const page2 = (await list("?limit=2&offset=2")).json();
    expect(page2.total).toBe(5);
    expect(page2.catches.map((c: { caughtAt: number }) => c.caughtAt)).toEqual([
      NOW + 120,
      NOW + 180,
    ]);

    const page3 = (await list("?limit=2&offset=4")).json();
    expect(page3.catches.map((c: { caughtAt: number }) => c.caughtAt)).toEqual([NOW + 240]);

    // Past the end → empty page, total still reported.
    const past = (await list("?limit=2&offset=6")).json();
    expect(past).toEqual({ total: 5, catches: [] });
  });

  it("clamps garbage limit/offset to sane defaults", async () => {
    await post(catchBody("aaaaaa", uuid(20)));
    for (const q of ["?limit=-5", "?limit=banana", "?offset=-1", "?limit=999999&offset=abc"]) {
      const res = await list(q);
      expect(res.statusCode).toBe(200);
      expect(res.json().total).toBe(1);
      expect(res.json().catches).toHaveLength(1);
    }
  });

  it("a stored guess restores with kind, value, and the frozen verdict", async () => {
    // A type guess verifies against the registry-resolved typecode — no route
    // resolver needed, so the correct verdict is deterministic here.
    await post({
      ...catchBody("aaaaaa", uuid(30)),
      guess: { kind: "type", value: "B738" },
    });

    const row = (await list()).json().catches[0];
    expect(row.guessKind).toBe("type");
    expect(row.guessValue).toBe("B738");
    expect(row.guessCorrect).toBe(true);
  });
});
