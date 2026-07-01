/**
 * Re-scoring: the "points are a re-derivable projection" lever.
 *
 * Exercises the two ways a catch's projection goes stale — reference DATA growth
 * (a foreign airframe the registry learned after upload) and a scoring-LOGIC
 * version bump — plus the dry-run/apply/idempotency contract, against a real
 * PGlite Postgres so the registry→typecode join and the UPDATE run for real.
 */

import { eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import { CURRENT_SCORING_VERSION } from "../src/catches/points.js";
import { rescoreCatches } from "../src/catches/rescore.js";
import type { Database } from "../src/db/client.js";
import { catches, devices, registry, typecodes } from "../src/db/schema.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

describe("rescoreCatches", () => {
  let db: Database;
  let deviceId: string;

  // A foreign widebody the registry learned AFTER these catches were frozen at
  // the unknown floor; and a US airframe that scored correctly from the start.
  const FOREIGN = "aaa111";
  const KNOWN = "bbb222";

  let uuidSeq = 0;
  const uuid = () => `00000000-0000-4000-8000-${String(++uuidSeq).padStart(12, "0")}`;

  async function insertCatch(opts: {
    icao24: string;
    typecode?: string | null;
    rarity?: string | null;
    points: number;
    scoringVersion?: number;
    firstOfType?: boolean;
  }): Promise<string> {
    const rows = await db
      .insert(catches)
      .values({
        catchUuid: uuid(),
        deviceId,
        icao24: opts.icao24,
        typecode: opts.typecode ?? null,
        rarity: opts.rarity ?? null,
        points: opts.points,
        scoringVersion: opts.scoringVersion ?? CURRENT_SCORING_VERSION,
        // Default false: these are FROZEN historical rows, not first-of-type
        // (the column default + the "no historical bonus" semantics).
        firstOfType: opts.firstOfType ?? false,
        caughtAt: new Date("2026-06-11T00:00:00Z"),
        observerLat: 37.8,
        observerLon: -122.3,
      })
      .returning({ id: catches.id });
    return rows[0].id;
  }

  beforeEach(async () => {
    uuidSeq = 0;
    db = await makeTestDb();
    await db.insert(typecodes).values([
      { typecode: "C172", manufacturer: "Cessna", model: "172", type: "ga", rarity: "common" },
      { typecode: "A388", manufacturer: "Airbus", model: "A-380", type: "wide", rarity: "epic" },
    ]);
    await db.insert(registry).values([
      { icao24: KNOWN, typecode: "C172", source: "faa" },
      { icao24: FOREIGN, typecode: "A388", source: "faa" },
    ]);
    const dev = await db
      .insert(devices)
      .values({ tokenHash: "hash-1" })
      .returning({ id: devices.id });
    deviceId = dev[0].id;
  });

  it("re-resolves a catch frozen at the unknown floor (reference data grew)", async () => {
    const id = await insertCatch({ icao24: FOREIGN, rarity: null, typecode: null, points: 10 });

    // Dry run: full delta computed, nothing written.
    const dry = await rescoreCatches(db, { dryRun: true });
    expect(dry.scanned).toBe(1);
    expect(dry.changed).toBe(1);
    expect(dry.pointsBefore).toBe(10);
    expect(dry.pointsAfter).toBe(100);
    expect(dry.applied).toBe(false);
    expect(dry.transitions).toEqual([{ from: "unknown", to: "epic", catches: 1, pointsDelta: 90 }]);
    const untouched = await db.select().from(catches).where(eq(catches.id, id));
    expect(untouched[0].points).toBe(10);
    expect(untouched[0].rarity).toBeNull();

    // Apply: new projection persisted.
    const applied = await rescoreCatches(db, {});
    expect(applied.changed).toBe(1);
    expect(applied.written).toBe(1);
    expect(applied.applied).toBe(true);
    const after = await db.select().from(catches).where(eq(catches.id, id));
    expect(after[0].points).toBe(100);
    expect(after[0].rarity).toBe("epic");
    expect(after[0].typecode).toBe("A388");
    expect(after[0].scoringVersion).toBe(CURRENT_SCORING_VERSION);
  });

  it("re-scores a STORED first-of-type catch to base + 50% (the bonus floats with the re-derived base)", async () => {
    // A first-of-type catch frozen at the unknown floor. Re-score resolves it to
    // epic (base 100) and adds the +50% first-of-type bonus → 150. The stored
    // flag is READ off the row, never recomputed from history.
    const id = await insertCatch({
      icao24: FOREIGN,
      rarity: null,
      typecode: null,
      points: 10,
      firstOfType: true,
    });
    const applied = await rescoreCatches(db, {});
    expect(applied.changed).toBe(1);
    expect(applied.pointsAfter).toBe(150); // 100 base + round(100*0.5) bonus
    const after = await db.select().from(catches).where(eq(catches.id, id));
    expect(after[0].points).toBe(150);
    expect(after[0].rarity).toBe("epic");
    expect(after[0].firstOfType).toBe(true); // flag preserved, not recomputed
    expect(after[0].scoringVersion).toBe(CURRENT_SCORING_VERSION);
  });

  it("is idempotent — a second run over settled data changes nothing", async () => {
    await insertCatch({ icao24: FOREIGN, rarity: null, points: 10 });
    await rescoreCatches(db, {});
    const second = await rescoreCatches(db, {});
    expect(second.scanned).toBe(0); // resolved + current → no longer stale
    expect(second.changed).toBe(0);
  });

  it("leaves correctly-scored, current rows untouched in the default scope", async () => {
    const id = await insertCatch({ icao24: KNOWN, typecode: "C172", rarity: "common", points: 10 });
    const report = await rescoreCatches(db, {});
    expect(report.scanned).toBe(0); // rarity set + version current → not stale
    const after = await db.select().from(catches).where(eq(catches.id, id));
    expect(after[0].points).toBe(10);
  });

  it("--all re-scans resolved rows but reports no change when scoring is unchanged", async () => {
    await insertCatch({ icao24: KNOWN, typecode: "C172", rarity: "common", points: 10 });
    const report = await rescoreCatches(db, { all: true });
    expect(report.scanned).toBe(1);
    expect(report.changed).toBe(0);
    expect(report.written).toBe(0);
  });

  it("restamps an older-regime row whose points don't change", async () => {
    // scoringVersion 0 < CURRENT → selected as stale; re-resolves to the same
    // common/10, so the projection is identical but the version is restamped.
    const id = await insertCatch({
      icao24: KNOWN,
      typecode: "C172",
      rarity: "common",
      points: 10,
      scoringVersion: 0,
    });
    const report = await rescoreCatches(db, {});
    expect(report.scanned).toBe(1);
    expect(report.changed).toBe(0); // projection identical
    expect(report.written).toBe(1); // but a version restamp was written
    const after = await db.select().from(catches).where(eq(catches.id, id));
    expect(after[0].scoringVersion).toBe(CURRENT_SCORING_VERSION);
  });

  it("resolves each airframe once and batches its catches", async () => {
    await insertCatch({ icao24: FOREIGN, rarity: null, points: 10 });
    await insertCatch({ icao24: FOREIGN, rarity: null, points: 10 });
    const report = await rescoreCatches(db, {});
    expect(report.scanned).toBe(2);
    expect(report.distinctIcaos).toBe(1);
    expect(report.changed).toBe(2);
    expect(report.pointsAfter).toBe(200);
    expect(report.transitions[0]).toEqual({
      from: "unknown",
      to: "epic",
      catches: 2,
      pointsDelta: 180,
    });
  });
});
