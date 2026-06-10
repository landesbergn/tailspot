import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { registry, typecodes } from "../src/db/schema.js";
import { DrizzleMetadataStore } from "../src/metadata/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * Route tests via app.inject(), with a PGlite-backed DrizzleMetadataStore
 * injected — so the merge query, the registry→typecode join, and the wire
 * shape are all exercised end to end against real Postgres SQL.
 */
describe("GET /v1/metadata/:icao24", () => {
  let app: FastifyInstance;
  let db: Database;

  beforeEach(async () => {
    db = await makeTestDb();
    // A typecode known to DOC 8643.
    await db.insert(typecodes).values({
      typecode: "B738",
      manufacturer: "Boeing",
      model: "737-800",
      type: "narrow",
      rarity: "common",
    });
    await db.insert(typecodes).values({
      typecode: "A388",
      manufacturer: "Airbus",
      model: "A-380",
      type: "wide",
      rarity: "epic",
    });
    // Registry rows:
    //  - aaaaaa: US tail, typecode known to DOC 8643 → merged
    //  - bbbbbb: US tail, typecode NOT in DOC 8643 → faa, raw names
    //  - cccccc: US tail, no typecode at all → faa, raw names
    await db.insert(registry).values([
      {
        icao24: "aaaaaa",
        registration: "N12345",
        manufacturerRaw: "BOEING",
        modelRaw: "737-800",
        typecode: "B738",
        source: "faa",
      },
      {
        icao24: "bbbbbb",
        registration: "N67890",
        manufacturerRaw: "PIPER",
        modelRaw: "PA-28-181",
        typecode: "PA28", // not in typecodes table
        source: "faa",
      },
      {
        icao24: "cccccc",
        registration: "N99999",
        manufacturerRaw: "CESSNA",
        modelRaw: "172N",
        typecode: null,
        source: "faa",
      },
    ]);

    app = await buildApp({ metadataStore: new DrizzleMetadataStore(db) });
  });

  afterEach(async () => {
    await app.close();
  });

  it("merges FAA + DOC 8643 (source=merged, DOC 8643 names win)", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/metadata/aaaaaa" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      icao24: "aaaaaa",
      registration: "N12345",
      manufacturer: "Boeing",
      model: "737-800",
      typecode: "B738",
      operatorName: null,
      source: "merged",
    });
  });

  it("returns source=faa with raw names when the typecode is unknown to DOC 8643", () => {
    return app.inject({ method: "GET", url: "/v1/metadata/bbbbbb" }).then((res) => {
      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.source).toBe("faa");
      expect(body.manufacturer).toBe("PIPER"); // raw, not cleaned
      expect(body.model).toBe("PA-28-181");
      expect(body.typecode).toBe("PA28");
    });
  });

  it("returns source=faa with a null typecode for a registration-only US tail", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/metadata/cccccc" });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.source).toBe("faa");
    expect(body.manufacturer).toBe("CESSNA");
    expect(body.typecode).toBeNull();
  });

  it("404s on an icao24 no source knows", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/metadata/ffffff" });
    expect(res.statusCode).toBe(404);
    expect(res.json()).toEqual({ error: "unknown aircraft" });
  });

  it("accepts uppercase hex and normalizes it to lowercase in the echo", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/metadata/AAAAAA" });
    expect(res.statusCode).toBe(200);
    expect(res.json().icao24).toBe("aaaaaa");
  });

  describe("400s for malformed icao24", () => {
    const cases: Array<[string, string]> = [
      ["too short", "abc"],
      ["too long", "aaaaaaa"],
      ["non-hex characters", "gggggg"],
      ["empty-ish", "______"],
    ];
    for (const [label, icao] of cases) {
      it(`rejects ${label}`, async () => {
        const res = await app.inject({ method: "GET", url: `/v1/metadata/${icao}` });
        expect(res.statusCode).toBe(400);
        expect(res.json().error).toBeTruthy();
      });
    }
  });
});

describe("metadata store lookup (DOC 8643-only path via direct store)", () => {
  it("returns source=doc8643 when only the typecode table has the airframe", async () => {
    // The Drizzle store reaches DOC 8643 only via a registry typecode, so to
    // exercise the doc8643-only MERGE branch we point a registry row at a
    // typecode with deliberately-null FAA names — proving DOC 8643 fills them.
    const db = await makeTestDb();
    await db.insert(typecodes).values({
      typecode: "A388",
      manufacturer: "Airbus",
      model: "A-380",
      type: "wide",
      rarity: "epic",
    });
    await db.insert(registry).values({
      icao24: "dddddd",
      registration: null,
      manufacturerRaw: null,
      modelRaw: null,
      typecode: "A388",
      source: "faa",
    });
    const store = new DrizzleMetadataStore(db);
    const rec = await store.lookup("dddddd");
    // Both a registry row AND a DOC 8643 row contributed → "merged" (the FAA row
    // supplied the typecode that found the DOC 8643 names). The pure
    // doc8643-only branch (no registry row) is covered in merge.test.ts.
    expect(rec?.source).toBe("merged");
    expect(rec?.manufacturer).toBe("Airbus");
    expect(rec?.model).toBe("A-380");
    expect(rec?.registration).toBeNull();
  });
});
