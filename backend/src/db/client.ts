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
  sqlClient = postgres(url, {
    max: 10,
    // Recycle connections proactively. postgres.js defaults `idle_timeout` to
    // null — idle connections are held for the process lifetime — but Fly's
    // `.flycast` proxy and Postgres itself drop idle TCP connections. Without
    // this, the next query on a server-closed socket dies with CONNECTION_CLOSED
    // → a 500 (Sentry BROKEN-DARKNESS-5055-3). Close idle connections at 30s and
    // hard-recycle every 5 min so we never hand a query a stale socket; the
    // `withDbRetry` helper covers the residual race. `connect_timeout` fails
    // fast if the DB is unreachable (default is 30s).
    idle_timeout: 30,
    max_lifetime: 60 * 5,
    connect_timeout: 10,
  });
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
