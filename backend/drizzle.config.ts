import { defineConfig } from "drizzle-kit";

/**
 * drizzle-kit config — generates SQL migrations from `src/db/schema.ts` into
 * `drizzle/`. Migrations are committed (no raw-SQL drift). Generation does NOT
 * need a live database; applying them (drizzle-kit migrate / push) reads
 * DATABASE_URL at deploy time.
 */
export default defineConfig({
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dialect: "postgresql",
  dbCredentials: {
    url: process.env.DATABASE_URL ?? "postgres://localhost/tailspot",
  },
});
