import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { registry, typecodes } from "../src/db/schema.js";
import { importMictronics, parseMictronics, recordToRegistry } from "../src/ingest/mictronics.js";
import { upsertRegistry, upsertRegistryFillMissing } from "../src/ingest/registryUpsert.js";
import { DrizzleMetadataStore } from "../src/metadata/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SAMPLE = join(__dirname, "fixtures/mictronics-sample.ndjson");

describe("recordToRegistry", () => {
  it("maps icao/reg/icaotype, lowercasing hex and upper-casing the typecode", () => {
    const row = recordToRegistry({ icao: "76CDB5", reg: "9V-SMH", icaotype: "a359" });
    expect(row).toEqual({
      icao24: "76cdb5",
      registration: "9V-SMH",
      manufacturerRaw: null,
      modelRaw: null,
      typecode: "A359",
      source: "mictronics",
    });
  });

  it("drops a record with an invalid Mode-S hex", () => {
    expect(recordToRegistry({ icao: "abc", reg: "BAD", icaotype: "X" })).toBeNull();
    expect(recordToRegistry({ icao: "", reg: "R", icaotype: "T" })).toBeNull();
  });

  it("drops a record carrying neither a registration nor a typecode (no signal)", () => {
    expect(recordToRegistry({ icao: "a11111" })).toBeNull();
    expect(recordToRegistry({ icao: "a11111", reg: "  ", icaotype: "" })).toBeNull();
  });

  it("keeps a registration-only or typecode-only record", () => {
    expect(recordToRegistry({ icao: "a11111", reg: "N1" })?.typecode).toBeNull();
    expect(recordToRegistry({ icao: "a11111", icaotype: "C172" })?.registration).toBeNull();
  });
});

describe("parseMictronics", () => {
  it("skips blank, malformed-JSON, invalid-hex, and no-signal lines", () => {
    const text = [
      '{"icao":"76cdb5","reg":"9V-SMH","icaotype":"A359"}',
      "",
      "not json",
      '{"icao":"abc","reg":"BAD"}', // invalid hex
      '{"icao":"a11111"}', // no signal
      '{"icao":"c01234","reg":"C-FABC","icaotype":"B789"}',
    ].join("\n");
    const rows = parseMictronics(text);
    expect(rows.map((r) => r.icao24)).toEqual(["76cdb5", "c01234"]);
  });

  it("respects the --limit cap", () => {
    const text = [
      '{"icao":"76cdb5","icaotype":"A359"}',
      '{"icao":"c01234","icaotype":"B789"}',
    ].join("\n");
    expect(parseMictronics(text, 1)).toHaveLength(1);
  });
});

describe("importMictronics (streaming, against PGlite)", () => {
  it("streams the NDJSON fixture into registry rows and resolves a foreign typecode", async () => {
    const db = await makeTestDb();
    // Seed the DOC 8643 row so the merge can canonicalize A359 → A350-900.
    await db.insert(typecodes).values({
      typecode: "A359",
      manufacturer: "Airbus",
      model: "A350-900",
      type: "wide",
      rarity: "uncommon",
    });

    const n = await importMictronics(db, SAMPLE);
    expect(n).toBe(3); // 76cdb5, 3c6444 (uppercase hex), c01234

    const rows = await db.select().from(registry).where(eq(registry.icao24, "76cdb5"));
    expect(rows[0]?.typecode).toBe("A359");
    expect(rows[0]?.source).toBe("mictronics");
    expect(rows[0]?.manufacturerRaw).toBeNull(); // canonical names come from the join
    // Uppercase hex in the file is normalized; lowercased typecode upper-cased.
    const dlh = await db.select().from(registry).where(eq(registry.icao24, "3c6444"));
    expect(dlh[0]?.typecode).toBe("A346");

    // End to end: the metadata endpoint now resolves the Singapore A350.
    const store = new DrizzleMetadataStore(db);
    const meta = await store.lookup("76cdb5");
    expect(meta?.model).toBe("A350-900");
    expect(meta?.manufacturer).toBe("Airbus");
    expect(meta?.typecode).toBe("A359");
  });
});

describe("upsertRegistryFillMissing (non-destructive)", () => {
  it("never overwrites an existing FAA row's manufacturer/model, but fills its null typecode", async () => {
    const db = await makeTestDb();
    // An FAA row: rich US make/model, but registration-only (no typecode yet).
    await upsertRegistry(db, [
      {
        icao24: "a12345",
        registration: "N123AB",
        manufacturerRaw: "CESSNA",
        modelRaw: "172",
        typecode: null,
        source: "faa",
      },
    ]);

    // A mictronics row for the SAME hex: a typecode, but no make/model.
    await upsertRegistryFillMissing(db, [
      {
        icao24: "a12345",
        registration: "N123AB",
        manufacturerRaw: null,
        modelRaw: null,
        typecode: "C172",
        source: "mictronics",
      },
    ]);

    const row = (await db.select().from(registry).where(eq(registry.icao24, "a12345")))[0];
    // FAA's canonical strings + provenance survive…
    expect(row?.manufacturerRaw).toBe("CESSNA");
    expect(row?.modelRaw).toBe("172");
    expect(row?.source).toBe("faa");
    // …and the previously-null typecode is now filled from mictronics.
    expect(row?.typecode).toBe("C172");
  });

  it("keeps an existing typecode rather than clobbering it with a thinner source", async () => {
    const db = await makeTestDb();
    await upsertRegistry(db, [
      {
        icao24: "b22222",
        registration: "N9",
        manufacturerRaw: "BOEING",
        modelRaw: "737-800",
        typecode: "B738",
        source: "faa",
      },
    ]);
    await upsertRegistryFillMissing(db, [
      {
        icao24: "b22222",
        registration: "N9",
        manufacturerRaw: null,
        modelRaw: null,
        typecode: "WRONG",
        source: "mictronics",
      },
    ]);
    const row = (await db.select().from(registry).where(eq(registry.icao24, "b22222")))[0];
    expect(row?.typecode).toBe("B738"); // existing value kept (coalesce)
  });

  it("inserts a brand-new foreign airframe the FAA registry never had", async () => {
    const db = await makeTestDb();
    await upsertRegistryFillMissing(db, [
      {
        icao24: "76cdb5",
        registration: "9V-SMH",
        manufacturerRaw: null,
        modelRaw: null,
        typecode: "A359",
        source: "mictronics",
      },
    ]);
    const row = (await db.select().from(registry).where(eq(registry.icao24, "76cdb5")))[0];
    expect(row?.typecode).toBe("A359");
    expect(row?.source).toBe("mictronics");
  });
});
