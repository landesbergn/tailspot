/**
 * The one-off operator backfill (src/tools/backfill-missed-catches.ts).
 *
 * This script writes to PRODUCTION and hands a real player points, so its
 * contract is pinned here against a real PGlite Postgres before it is ever
 * run for real:
 *
 *   - it refuses to write against the wrong device (the handle guard),
 *   - it scores through the canonical scorer — C5M resolves epic (100) and,
 *     as the device's first C5M, pays the +50% first-of-type bonus = 150,
 *   - it backdates `caughtAt` to the real observed instant rather than now,
 *   - a dry run writes nothing,
 *   - a re-run after an apply is a provable no-op (fixed catchUuids).
 *
 * The device id / handle / icao24s are the REAL ones the script targets, so
 * this test drifts the moment someone edits the script's constants.
 */

import { and, eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import type { Database } from "../src/db/client.js";
import { catches, devices, registry, typecodes } from "../src/db/schema.js";
import { backfillMissedCatches } from "../src/tools/backfill-missed-catches.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/** The exact values the script hardcodes — this test fails if they drift. */
const DEVICE_ID = "efb375ca-bd56-53af-9437-337feb1ec197";
const HANDLE = "jtflcntmltstlbms";
const C5_ICAO = "ae0584";
const C340_ICAO = "a3bef1";

describe("backfillMissedCatches", () => {
  let db: Database;

  /** Seed the reference tables + the device, mirroring the prod rows. */
  async function seed(opts: { handle?: string | null } = {}): Promise<void> {
    await db.insert(typecodes).values([
      {
        typecode: "C5M",
        manufacturer: "Lockheed",
        model: "C-5 Super Galaxy",
        type: "mil",
        rarity: "epic",
      },
      { typecode: "C340", manufacturer: "Cessna", model: "340", type: "ga", rarity: "common" },
    ]);
    await db.insert(registry).values([
      { icao24: C5_ICAO, registration: "87-0039", typecode: "C5M", source: "faa" },
      { icao24: C340_ICAO, registration: "N340SU", typecode: "C340", source: "faa" },
    ]);
    await db.insert(devices).values({
      id: DEVICE_ID,
      tokenHash: "seeded-token-hash",
      handle: opts.handle === undefined ? HANDLE : opts.handle,
    });
    // One pre-existing catch so the observer-position borrow has a source.
    // Portland, ME — where both missed catches happened.
    await db.insert(catches).values({
      catchUuid: "00000000-0000-4000-8000-000000000001",
      deviceId: DEVICE_ID,
      icao24: "aba155",
      typecode: "B789",
      rarity: "common",
      points: 25,
      caughtAt: new Date("2026-06-30T23:13:46.755Z"),
      observerLat: 43.6591,
      observerLon: -70.2568,
    });
  }

  const backfilled = () =>
    db.select().from(catches).where(eq(catches.deviceId, DEVICE_ID)).orderBy(catches.caughtAt);

  beforeEach(async () => {
    db = await makeTestDb();
  });

  it("refuses to write when the device's handle does not match", async () => {
    await seed({ handle: "someone-else" });
    await expect(backfillMissedCatches(db, { apply: true })).rejects.toThrow(/refusing to write/);
    // The seeded catch is untouched — nothing was credited.
    expect(await backfilled()).toHaveLength(1);
  });

  it("refuses to write when the device does not exist", async () => {
    // Reference tables only; no device row.
    await db
      .insert(typecodes)
      .values({ typecode: "C5M", type: "mil", rarity: "epic", manufacturer: null, model: null });
    await expect(backfillMissedCatches(db, { apply: true })).rejects.toThrow(/does not exist/);
  });

  it("writes nothing on a dry run", async () => {
    await seed();
    const { planned, written } = await backfillMissedCatches(db, {});
    expect(written).toBe(0);
    expect(planned).toHaveLength(2);
    expect(await backfilled()).toHaveLength(1); // just the seeded row
  });

  it("credits the C-5M as an epic first-of-type worth 150", async () => {
    await seed();
    await backfillMissedCatches(db, { apply: true });

    const rows = await db
      .select()
      .from(catches)
      .where(and(eq(catches.deviceId, DEVICE_ID), eq(catches.icao24, C5_ICAO)));

    expect(rows).toHaveLength(1);
    const c5 = rows[0];
    expect(c5.typecode).toBe("C5M");
    expect(c5.rarity).toBe("epic");
    // 100 base + 50 first-of-type. Not hardcoded in the script — this is the
    // canonical scorer's answer.
    expect(c5.points).toBe(150);
    expect(c5.firstOfType).toBe(true);
    expect(c5.callsign).toBe("RCH2067");
  });

  it("credits the Cessna 340 as a common first-of-type worth 15", async () => {
    await seed();
    await backfillMissedCatches(db, { apply: true });

    const rows = await db
      .select()
      .from(catches)
      .where(and(eq(catches.deviceId, DEVICE_ID), eq(catches.icao24, C340_ICAO)));

    expect(rows).toHaveLength(1);
    expect(rows[0].rarity).toBe("common");
    expect(rows[0].points).toBe(15); // 10 base + 5 first-of-type
  });

  it("backdates caughtAt to the real observed instants, not now", async () => {
    await seed();
    await backfillMissedCatches(db, { apply: true });

    const rows = await backfilled();
    const byIcao = new Map(rows.map((r) => [r.icao24, r]));
    const c5 = byIcao.get(C5_ICAO);
    const c340 = byIcao.get(C340_ICAO);
    expect(c5).toBeDefined();
    expect(c340).toBeDefined();
    // `?? 0` never fires (toBeDefined threw first) — it's only narrowing
    // for tsc, in place of the `!` assertions biome's lint rejects.
    expect(new Date(c5?.caughtAt ?? 0).toISOString()).toBe("2026-06-30T23:13:37.164Z");
    expect(new Date(c340?.caughtAt ?? 0).toISOString()).toBe("2026-07-18T12:20:48.796Z");
  });

  it("borrows the observer position from the nearest-in-time catch", async () => {
    await seed();
    await backfillMissedCatches(db, { apply: true });

    const rows = await backfilled();
    for (const row of rows) {
      expect(row.observerLat).toBeCloseTo(43.6591, 4);
      expect(row.observerLon).toBeCloseTo(-70.2568, 4);
    }
  });

  it("marks the rows as manual backfills so they stay auditable", async () => {
    await seed();
    await backfillMissedCatches(db, { apply: true });

    const rows = await db
      .select({ validation: catches.validation })
      .from(catches)
      .where(eq(catches.icao24, C5_ICAO));
    const validation = rows[0].validation as { verdict: string; reasons: string[] };
    expect(validation.reasons).toContain("manual-backfill");
  });

  it("is idempotent — a second apply writes nothing", async () => {
    await seed();
    const first = await backfillMissedCatches(db, { apply: true });
    expect(first.written).toBe(2);

    const second = await backfillMissedCatches(db, { apply: true });
    expect(second.written).toBe(0);
    expect(second.planned.every((p) => p.alreadyPresent)).toBe(true);

    // 1 seeded + 2 backfilled, not 5.
    expect(await backfilled()).toHaveLength(3);
  });

  it("does not re-pay first-of-type when the device already holds the type", async () => {
    await seed();
    // An organic C5M catch that landed before the backfill runs.
    await db.insert(catches).values({
      catchUuid: "00000000-0000-4000-8000-000000000002",
      deviceId: DEVICE_ID,
      icao24: "ae9999",
      typecode: "C5M",
      rarity: "epic",
      points: 100,
      caughtAt: new Date("2026-06-29T00:00:00Z"),
      observerLat: 43.6591,
      observerLon: -70.2568,
    });

    await backfillMissedCatches(db, { apply: true });

    const rows = await db
      .select()
      .from(catches)
      .where(and(eq(catches.deviceId, DEVICE_ID), eq(catches.icao24, C5_ICAO)));
    expect(rows[0].firstOfType).toBe(false);
    expect(rows[0].points).toBe(100); // base only — no bonus
  });
});
