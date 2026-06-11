import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { registry, typecodes } from "../src/db/schema.js";
import { importFaa, parseAcftRef, parseMaster, splitFaaLine } from "../src/ingest/faa.js";
import { upsertRegistry } from "../src/ingest/registryUpsert.js";
import type { TypecodeMap } from "../src/ingest/typecodeMap.js";
import { DrizzleMetadataStore } from "../src/metadata/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = join(__dirname, "fixtures");
const MASTER = readFileSync(join(FIXTURE_DIR, "MASTER.txt"), "utf8");
const ACFTREF = readFileSync(join(FIXTURE_DIR, "ACFTREF.txt"), "utf8");

/**
 * A hermetic test typecode map (mfrMdlCode -> ICAO designator) mirroring the
 * committed `faa-typecode-map.json` for just the fixture codes. We inject this
 * instead of loading the real (large) committed map so the ingest tests stay
 * fast and don't depend on the build script having run. Codes deliberately
 * left out (05602J9 GULFSTREAM, 9999999 orphan) exercise the unmapped path.
 */
const TEST_TYPECODE_MAP: TypecodeMap = new Map<string, string>([
  ["1380530", "B738"], // BOEING 737-800
  ["2072725", "SR22"], // CIRRUS SR22
  ["0560200", "C172"], // CESSNA 172N
]);

describe("splitFaaLine", () => {
  it("splits and trims comma-separated fields", () => {
    expect(splitFaaLine("A12345 , 1380530 , BOEING ")).toEqual(["A12345", "1380530", "BOEING"]);
  });
});

describe("parseAcftRef", () => {
  it("keys by CODE and maps MFR/MODEL/TYPE columns", () => {
    const map = parseAcftRef(ACFTREF);
    expect(map.size).toBe(5);
    expect(map.get("1380530")).toEqual({
      manufacturer: "BOEING",
      model: "737-800",
      typeAircraft: "5",
      typeEngine: "5",
    });
    expect(map.get("2072725")?.manufacturer).toBe("CIRRUS DESIGN CORP");
  });
});

describe("parseMaster", () => {
  it("maps MODE S CODE HEX → lowercase icao24 and joins ACFTREF for names", () => {
    const rows = parseMaster(MASTER, parseAcftRef(ACFTREF));
    // 5 MASTER rows, all with a valid hex → 5 rows.
    expect(rows).toHaveLength(5);

    const ual = rows.find((r) => r.icao24 === "a12345");
    expect(ual).toBeDefined();
    // Hex was "A12345 " in the file (uppercase + trailing space) → normalized.
    expect(ual?.icao24).toBe("a12345");
    expect(ual?.registration).toBe("N12345");
    expect(ual?.manufacturerRaw).toBe("BOEING");
    expect(ual?.modelRaw).toBe("737-800");
    // With no typecode map injected, typecode stays null (pre-enrichment path).
    expect(ual?.typecode).toBeNull();
    expect(ual?.source).toBe("faa");
  });

  it("normalizes the icao24 hex to lowercase and trims whitespace", () => {
    const rows = parseMaster(MASTER, parseAcftRef(ACFTREF));
    for (const r of rows) {
      expect(r.icao24).toMatch(/^[0-9a-f]{6}$/);
    }
  });

  it("keeps a known US tail with no ACFTREF match as a registration-only row", () => {
    const rows = parseMaster(MASTER, parseAcftRef(ACFTREF));
    const orphan = rows.find((r) => r.icao24 === "adcafe");
    expect(orphan).toBeDefined();
    expect(orphan?.registration).toBe("N00001");
    expect(orphan?.manufacturerRaw).toBeNull();
    expect(orphan?.modelRaw).toBeNull();
  });

  it("respects the --limit cap", () => {
    const rows = parseMaster(MASTER, parseAcftRef(ACFTREF), 2);
    expect(rows).toHaveLength(2);
  });
});

describe("parseMaster typecode enrichment (WP 1.4b)", () => {
  it("attaches the ICAO designator when the model code is in the map", () => {
    const rows = parseMaster(MASTER, parseAcftRef(ACFTREF), undefined, TEST_TYPECODE_MAP);
    const boeing = rows.find((r) => r.icao24 === "a12345");
    expect(boeing?.typecode).toBe("B738"); // 1380530 -> B738
    const cirrus = rows.find((r) => r.icao24 === "a6bcde");
    expect(cirrus?.typecode).toBe("SR22"); // 2072725 -> SR22
    const cessna = rows.find((r) => r.icao24 === "ababab");
    expect(cessna?.typecode).toBe("C172"); // 0560200 -> C172
  });

  it("leaves typecode null for a model code absent from the map", () => {
    const rows = parseMaster(MASTER, parseAcftRef(ACFTREF), undefined, TEST_TYPECODE_MAP);
    // 05602J9 (GULFSTREAM) is intentionally not in TEST_TYPECODE_MAP.
    const gulfstream = rows.find((r) => r.icao24 === "aabbcc");
    expect(gulfstream).toBeDefined();
    expect(gulfstream?.typecode).toBeNull();
  });

  it("leaves typecode null for a registration-only tail (no ACFTREF, no code map)", () => {
    const rows = parseMaster(MASTER, parseAcftRef(ACFTREF), undefined, TEST_TYPECODE_MAP);
    const orphan = rows.find((r) => r.icao24 === "adcafe");
    expect(orphan?.typecode).toBeNull();
  });
});

describe("upsertRegistry (idempotent)", () => {
  it("inserts then overwrites on re-run", async () => {
    const db = await makeTestDb();
    const rows = parseMaster(MASTER, parseAcftRef(ACFTREF));
    const n1 = await upsertRegistry(db, rows);
    expect(n1).toBe(5);
    // Re-run the same parse → still 5 rows (PK conflict updates in place).
    await upsertRegistry(db, rows);
    const all = await db.select().from(registry);
    expect(all).toHaveLength(5);
  });
});

describe("importFaa (streaming file → db, end-to-end)", () => {
  it("streams MASTER+ACFTREF from the fixture dir and upserts joined+enriched rows", async () => {
    const db = await makeTestDb();
    const n = await importFaa(db, FIXTURE_DIR, { typecodeMap: TEST_TYPECODE_MAP });
    expect(n).toBe(5);
    const cirrus = await db.select().from(registry).where(eq(registry.icao24, "a6bcde"));
    expect(cirrus[0]).toMatchObject({
      icao24: "a6bcde",
      registration: "N67890",
      manufacturerRaw: "CIRRUS DESIGN CORP",
      modelRaw: "SR22",
      typecode: "SR22", // enriched from the injected code map
      source: "faa",
    });
  });

  it("respects --limit when streaming", async () => {
    const db = await makeTestDb();
    const n = await importFaa(db, FIXTURE_DIR, { limit: 2, typecodeMap: TEST_TYPECODE_MAP });
    expect(n).toBe(2);
    const all = await db.select().from(registry);
    expect(all).toHaveLength(2);
  });
});

describe("typecode enrichment end-to-end (ingest → metadata route)", () => {
  it("serves source=merged with DOC 8643 clean names for a mapped tail", async () => {
    const db = await makeTestDb();
    // Seed the DOC 8643 type row the enriched typecode points at.
    await db.insert(typecodes).values({
      typecode: "SR22",
      manufacturer: "Cirrus",
      model: "SR-22",
      type: "ga",
      rarity: "common",
    });
    // Ingest the fixtures WITH the typecode map → the Cirrus tail gets typecode SR22.
    await importFaa(db, FIXTURE_DIR, { typecodeMap: TEST_TYPECODE_MAP });

    const app = await buildApp({ metadataStore: new DrizzleMetadataStore(db) });
    try {
      const res = await app.inject({ method: "GET", url: "/v1/metadata/a6bcde" });
      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual({
        icao24: "a6bcde",
        registration: "N67890",
        manufacturer: "Cirrus", // DOC 8643 clean name wins over raw "CIRRUS DESIGN CORP"
        model: "SR-22", // clean, not the raw "SR22"
        typecode: "SR22",
        operatorName: null,
        source: "merged",
      });
    } finally {
      await app.close();
    }
  });

  it("serves source=faa with raw names for an unmapped tail", async () => {
    const db = await makeTestDb();
    await importFaa(db, FIXTURE_DIR, { typecodeMap: TEST_TYPECODE_MAP });
    const app = await buildApp({ metadataStore: new DrizzleMetadataStore(db) });
    try {
      // 05602J9 GULFSTREAM is unmapped → typecode null → source=faa, raw names.
      const res = await app.inject({ method: "GET", url: "/v1/metadata/aabbcc" });
      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.source).toBe("faa");
      expect(body.typecode).toBeNull();
      expect(body.manufacturer).toBe("GULFSTREAM AEROSPACE"); // raw FAA string
    } finally {
      await app.close();
    }
  });
});
