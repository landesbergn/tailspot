import { defineConfig } from "vitest/config";

/**
 * The DB-backed suites each spin up a fresh in-process PGlite (WASM Postgres)
 * instance and replay the migration SQL. When all suites run in parallel, the
 * first PGlite cold-boot in a file can exceed vitest's 5 s default under CPU
 * contention — a startup artifact, not a slow test. Raise the per-test and
 * per-hook timeouts so the suite is robust on a cold/busy machine.
 */
export default defineConfig({
  test: {
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
});
