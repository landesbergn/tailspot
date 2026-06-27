/**
 * Production database wiring: a postgres-js connection pool fronted by Drizzle.
 *
 * Tests do NOT go through here — they construct a Drizzle handle over an
 * in-process PGlite instance (see `test/helpers/pgliteDb.ts`). This module is
 * the production-only seam, read lazily so importing the app for an in-memory
 * test never requires a `DATABASE_URL`.
 */

import { type PostgresJsDatabase, drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as schema from "./schema.js";

export type Database = PostgresJsDatabase<typeof schema>;

let cached: Database | undefined;
let sqlClient: ReturnType<typeof postgres> | undefined;

/**
 * Build (and memoize) the production Drizzle handle from `DATABASE_URL`.
 * Throws if the env var is missing — production must have it; tests never
 * call this path.
 */
export function getDb(): Database {
  if (cached) return cached;
  const url = process.env.DATABASE_URL;
  if (!url || url.trim() === "") {
    throw new Error("DATABASE_URL is not set — required for the production database connection.");
  }
  sqlClient = postgres(url, { max: 10 });
  cached = drizzle(sqlClient, { schema });
  return cached;
}

/**
 * Close the pooled connection so the process can exit. The long-running server
 * never calls this (it wants the pool open for the process lifetime); it exists
 * for one-shot CLI scripts (e.g. `catches/rescore.ts`) that would otherwise hang
 * after their work — the open pool keeps the event loop alive. Safe to call when
 * no pool was ever opened.
 */
export async function closeDb(): Promise<void> {
  if (sqlClient) {
    await sqlClient.end({ timeout: 5 });
    sqlClient = undefined;
    cached = undefined;
  }
}
