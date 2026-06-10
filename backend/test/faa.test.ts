import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { registry } from "../src/db/schema.js";
import { importFaa, parseAcftRef, parseMaster, splitFaaLine } from "../src/ingest/faa.js";
import { upsertRegistry } from "../src/ingest/registryUpsert.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = join(__dirname, "fixtures");
const MASTER = readFileSync(join(FIXTURE_DIR, "MASTER.txt"), "utf8");
const ACFTREF = readFileSync(join(FIXTURE_DIR, "ACFTREF.txt"), "utf8");

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
    expect(ual?.typecode).toBeNull(); // MASTER carries no ICAO designator
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
  it("streams MASTER+ACFTREF from the fixture dir and upserts joined rows", async () => {
    const db = await makeTestDb();
    const n = await importFaa(db, FIXTURE_DIR);
    expect(n).toBe(5);
    const cirrus = await db.select().from(registry).where(eq(registry.icao24, "a6bcde"));
    expect(cirrus[0]).toMatchObject({
      icao24: "a6bcde",
      registration: "N67890",
      manufacturerRaw: "CIRRUS DESIGN CORP",
      modelRaw: "SR22",
      source: "faa",
    });
  });

  it("respects --limit when streaming", async () => {
    const db = await makeTestDb();
    const n = await importFaa(db, FIXTURE_DIR, { limit: 2 });
    expect(n).toBe(2);
    const all = await db.select().from(registry);
    expect(all).toHaveLength(2);
  });
});
