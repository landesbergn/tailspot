import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { registry, typecodes } from "../src/db/schema.js";
import { makeRegistryEnrichSink, registryRowsFromSnapshot } from "../src/ingest/feedEnrich.js";
import { upsertRegistry, upsertRegistryFillMissing } from "../src/ingest/registryUpsert.js";
import { DrizzleMetadataStore } from "../src/metadata/store.js";
import type { NormalizedAircraft, ProviderSnapshot } from "../src/providers/types.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

function ac(partial: Partial<NormalizedAircraft> & { icao24: string }): NormalizedAircraft {
  return {
    callsign: null,
    originCountry: null,
    longitude: 0,
    latitude: 0,
    altitudeMeters: 0,
    velocityMps: null,
    trackDeg: null,
    onGround: false,
    positionTimestamp: null,
    ...partial,
  };
}

function snapshot(aircraft: NormalizedAircraft[]): ProviderSnapshot {
  return { fetchedAt: 1_700_000_000, aircraft };
}

describe("registryRowsFromSnapshot", () => {
  it("emits one adsblol row per aircraft that has a typecode", () => {
    const rows = registryRowsFromSnapshot(
      snapshot([
        ac({ icao24: "76cdb5", typecode: "A359", registration: "9V-SMH" }),
        ac({ icao24: "3c6444", typecode: "a346", registration: " D-AIHK " }),
      ]),
    );
    // Rows come back in icao24 order (deadlock-safe batch; see the source).
    expect(rows).toEqual([
      {
        icao24: "3c6444",
        registration: "D-AIHK", // trimmed
        manufacturerRaw: null,
        modelRaw: null,
        typecode: "A346", // upper-cased
        source: "adsblol",
      },
      {
        icao24: "76cdb5",
        registration: "9V-SMH",
        manufacturerRaw: null,
        modelRaw: null,
        typecode: "A359",
        source: "adsblol",
      },
    ]);
  });

  it("skips position-only contacts (no typecode), even with a registration", () => {
    const rows = registryRowsFromSnapshot(
      snapshot([
        ac({ icao24: "aaaaaa" }), // nothing
        ac({ icao24: "bbbbbb", registration: "N1" }), // reg but no type
        ac({ icao24: "cccccc", typecode: "  " }), // blank type
      ]),
    );
    expect(rows).toHaveLength(0);
  });
});

describe("makeRegistryEnrichSink (fire-and-forget, fault-isolated)", () => {
  it("swallows a getDb() failure and reports it via onError, never throwing", () => {
    const errors: unknown[] = [];
    const sink = makeRegistryEnrichSink(
      () => {
        throw new Error("no DATABASE_URL");
      },
      (e) => errors.push(e),
    );
    // Must not throw into the fetch path.
    expect(() => sink(snapshot([ac({ icao24: "76cdb5", typecode: "A359" })]))).not.toThrow();
    expect(errors).toHaveLength(1);
  });

  it("never touches the DB when the snapshot has no typecode-bearing aircraft", () => {
    let dbTouched = false;
    const sink = makeRegistryEnrichSink(() => {
      dbTouched = true;
      throw new Error("should not be called");
    });
    sink(snapshot([ac({ icao24: "aaaaaa", registration: "N1" })]));
    expect(dbTouched).toBe(false);
  });
});

describe("feed enrichment end to end (snapshot → registry → metadata)", () => {
  it("is non-destructive and resolves a foreign airframe through the merge", async () => {
    const db = await makeTestDb();
    await db.insert(typecodes).values({
      typecode: "A359",
      manufacturer: "Airbus",
      model: "A350-900",
      type: "wide",
      rarity: "uncommon",
    });
    // An existing FAA US tail with rich names but no typecode yet.
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

    // A fresh feed snapshot: a foreign A350 + the US tail. The US row's feed
    // registration deliberately DIFFERS from the stored FAA one ("N999XX" vs
    // "N123AB") so the assertion below proves the existing registration is kept,
    // not silently overwritten by the (present, non-null) incoming value.
    const rows = registryRowsFromSnapshot(
      snapshot([
        ac({ icao24: "76cdb5", typecode: "A359", registration: "9V-SMH" }),
        ac({ icao24: "a12345", typecode: "C172", registration: "N999XX" }),
      ]),
    );
    await upsertRegistryFillMissing(db, rows);

    // Foreign airframe is now resolvable by /v1/metadata.
    const store = new DrizzleMetadataStore(db);
    expect((await store.lookup("76cdb5"))?.model).toBe("A350-900");

    // The US tail kept its FAA names/source/registration and gained ONLY the
    // previously-null typecode — coalesce(existing, incoming) on every column.
    const us = (await db.select().from(registry).where(eq(registry.icao24, "a12345")))[0];
    expect(us?.manufacturerRaw).toBe("CESSNA");
    expect(us?.source).toBe("faa");
    expect(us?.registration).toBe("N123AB"); // existing kept, not the feed's N999XX
    expect(us?.typecode).toBe("C172"); // was null → filled
  });
});

describe("registryRowsFromSnapshot source label", () => {
  it("tags rows with the feed that produced the snapshot (adsb.fi since 2026-10-20)", () => {
    const rows = registryRowsFromSnapshot({
      ...snapshot([ac({ icao24: "76cdb5", typecode: "A359" })]),
      provider: "adsbfi",
    });
    expect(rows.map((r) => r.source)).toEqual(["adsbfi"]);
  });

  it("falls back to 'adsblol' for an unstamped snapshot (every row before 2026-10-20)", () => {
    const rows = registryRowsFromSnapshot(snapshot([ac({ icao24: "76cdb5", typecode: "A359" })]));
    expect(rows.map((r) => r.source)).toEqual(["adsblol"]);
  });
});

describe("fill-missing upsert write volume", () => {
  const a350 = {
    icao24: "76cdb5",
    registration: "9V-SMH",
    manufacturerRaw: null,
    modelRaw: null,
    typecode: "A359",
    source: "adsbfi",
  };

  it("leaves an already-complete row untouched (no updated_at bump, no new tuple)", async () => {
    const db = await makeTestDb();
    await upsertRegistryFillMissing(db, [a350]);
    const old = new Date("2026-01-01T00:00:00Z");
    await db.update(registry).set({ updatedAt: old }).where(eq(registry.icao24, "76cdb5"));

    // Re-sighting the same complete airframe is a no-op write…
    await upsertRegistryFillMissing(db, [a350]);
    let row = (await db.select().from(registry).where(eq(registry.icao24, "76cdb5")))[0];
    expect(row?.updatedAt.getTime()).toBe(old.getTime());

    // …while a row with a real gap still gets filled.
    await db.update(registry).set({ registration: null }).where(eq(registry.icao24, "76cdb5"));
    await upsertRegistryFillMissing(db, [a350]);
    row = (await db.select().from(registry).where(eq(registry.icao24, "76cdb5")))[0];
    expect(row?.registration).toBe("9V-SMH");
    expect(row?.updatedAt.getTime()).toBeGreaterThan(old.getTime());
  });

  it("dedupes a snapshot that lists the same airframe twice (one batch, one key)", async () => {
    const db = await makeTestDb();
    const rows = registryRowsFromSnapshot(
      snapshot([
        // MLAT copy with no registration first, ADS-B copy with one second.
        ac({ icao24: "76cdb5", typecode: "A359", registration: null }),
        ac({ icao24: "76cdb5", typecode: "A359", registration: "9V-SMH" }),
      ]),
    );
    expect(rows).toHaveLength(1);
    expect(rows[0].registration).toBe("9V-SMH"); // merged, not first-wins
    await expect(upsertRegistryFillMissing(db, rows)).resolves.toBe(1);
  });

  it("emits rows in icao24 order so concurrent batches lock in one order", () => {
    const rows = registryRowsFromSnapshot(
      snapshot([
        ac({ icao24: "c0ffee", typecode: "B738" }),
        ac({ icao24: "0abc12", typecode: "A320" }),
        ac({ icao24: "76cdb5", typecode: "A359" }),
      ]),
    );
    expect(rows.map((r) => r.icao24)).toEqual(["0abc12", "76cdb5", "c0ffee"]);
  });
});
