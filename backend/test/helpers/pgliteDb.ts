/**
 * Hermetic test database: in-process PGlite (WASM Postgres) fronted by the SAME
 * Drizzle schema production uses. No Docker, no external Postgres, no network.
 *
 * Why PGlite (not an in-memory Map fake): the merge query, the upsert
 * ON CONFLICT semantics, and the registry→typecode join all run against REAL
 * Postgres SQL — so the tests exercise the production code paths end to end, not
 * a hand-rolled stand-in that could diverge. PGlite is officially supported by
 * Drizzle (`drizzle-orm/pglite`) and the combo was verified working in vitest
 * before this was built on. (The WP prompt's fallback — an in-memory Map
 * implementing `MetadataStore` — was not needed.)
 *
 * Schema is materialized by replaying the committed drizzle-generated migration
 * SQL, so the test DB and a freshly-migrated production DB are byte-identical.
 */

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import type { Database } from "../../src/db/client.js";
import * as schema from "../../src/db/schema.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

/** Build a fresh PGlite-backed Drizzle handle with the schema applied. */
export async function makeTestDb(): Promise<Database> {
  const client = new PGlite();
  // Replay EVERY committed migration in filename order so the test schema ==
  // the migrated prod schema. (We replay the raw SQL rather than running
  // drizzle-kit's migrator so the test stays offline and deterministic.)
  // drizzle splits statements on `--> statement-breakpoint`.
  const migrationsDir = join(__dirname, "../../drizzle");
  const migrationFiles = readdirSync(migrationsDir)
    .filter((f) => f.endsWith(".sql"))
    .sort(); // 0000_, 0001_, … apply in lexical order, which is chronological.
  for (const file of migrationFiles) {
    const sqlText = readFileSync(join(migrationsDir, file), "utf8");
    for (const stmt of sqlText.split("--> statement-breakpoint")) {
      const trimmed = stmt.trim();
      if (trimmed !== "") await client.exec(trimmed);
    }
  }
  // The Drizzle PGlite driver's type doesn't structurally match the postgres-js
  // `Database` type, but both satisfy the query surface the store/ingest use.
  return drizzle(client, { schema }) as unknown as Database;
}
