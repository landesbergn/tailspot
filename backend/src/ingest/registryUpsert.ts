/**
 * Batched, idempotent upsert of registry rows (shared by the FAA streaming
 * import and its tests).
 *
 * One multi-row INSERT … ON CONFLICT (icao24) DO UPDATE per batch, so a re-run
 * over a fresh FAA download cleanly overwrites each airframe's fields. Split out
 * from `faa.ts` so the parser module stays free of SQL and the upsert can be
 * unit-tested directly.
 */

import { sql } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { type RegistryInsert, registry } from "../db/schema.js";

/** Reference the would-be-inserted value in an ON CONFLICT update (`excluded.col`). */
function excluded(col: string) {
  return sql.raw(`excluded.${col}`);
}

/** Upsert a batch of registry rows on the icao24 PK. Returns rows.length. */
export async function upsertRegistry(db: Database, rows: RegistryInsert[]): Promise<number> {
  if (rows.length === 0) return 0;
  await db
    .insert(registry)
    .values(rows)
    .onConflictDoUpdate({
      target: registry.icao24,
      set: {
        registration: excluded("registration"),
        manufacturerRaw: excluded("manufacturer_raw"),
        modelRaw: excluded("model_raw"),
        typecode: excluded("typecode"),
        source: excluded("source"),
        updatedAt: sql`now()`,
      },
    });
  return rows.length;
}
