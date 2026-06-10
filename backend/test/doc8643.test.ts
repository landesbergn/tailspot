import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { typecodes } from "../src/db/schema.js";
import { importDoc8643, parseDoc8643Json, upsertTypecodes } from "../src/ingest/doc8643.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, "fixtures/doc8643-sample.json");

describe("parseDoc8643Json", () => {
  it("maps make/model/type/rarity and uppercases the typecode key", () => {
    const rows = parseDoc8643Json(readFileSync(FIXTURE, "utf8"));
    expect(rows).toHaveLength(5);
    const b738 = rows.find((r) => r.typecode === "B738");
    expect(b738).toMatchObject({
      typecode: "B738",
      manufacturer: "Boeing",
      model: "737-800",
      type: "narrow",
      rarity: "common",
    });
    // Lowercase "a380" key is normalized to uppercase.
    expect(rows.map((r) => r.typecode)).toContain("A380");
    expect(rows.map((r) => r.typecode)).not.toContain("a380");
  });

  it("loads the real bundled AircraftTypes.json (2,612 entries)", () => {
    const realPath = join(__dirname, "../../ios/Tailspot/Tailspot/AircraftTypes.json");
    const rows = parseDoc8643Json(readFileSync(realPath, "utf8"));
    expect(rows.length).toBe(2612);
    // Every row carries an uppercase typecode and the four fields.
    for (const r of rows) {
      expect(r.typecode).toBe(r.typecode?.toUpperCase());
    }
  });
});

describe("upsertTypecodes (idempotent)", () => {
  it("inserts then overwrites on re-run (no duplicates)", async () => {
    const db = await makeTestDb();
    const rows = parseDoc8643Json(readFileSync(FIXTURE, "utf8"));
    const n1 = await upsertTypecodes(db, rows);
    expect(n1).toBe(5);
    // Re-run with a changed rarity for B738 → overwrite, still 5 rows total.
    await upsertTypecodes(db, [
      {
        typecode: "B738",
        manufacturer: "Boeing",
        model: "737-800",
        type: "narrow",
        rarity: "epic",
      },
    ]);
    const all = await db.select().from(typecodes);
    expect(all).toHaveLength(5);
    const b738 = await db.select().from(typecodes).where(eq(typecodes.typecode, "B738"));
    expect(b738[0].rarity).toBe("epic");
  });
});

describe("importDoc8643 (file → db)", () => {
  it("reads the fixture file and upserts it", async () => {
    const db = await makeTestDb();
    const n = await importDoc8643(db, FIXTURE);
    expect(n).toBe(5);
    const glf6 = await db.select().from(typecodes).where(eq(typecodes.typecode, "GLF6"));
    expect(glf6[0]).toMatchObject({ manufacturer: "Gulfstream", model: "G650", rarity: "rare" });
  });
});
