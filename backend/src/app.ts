import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import Fastify, { type FastifyInstance } from "fastify";
import { getDb } from "./db/client.js";
import { DrizzleMetadataStore, type MetadataStore } from "./metadata/store.js";
import { type PositionProvider, selectProvider } from "./providers/index.js";
import { registerAircraftRoute } from "./routes/aircraft.js";
import { registerMetadataRoute } from "./routes/metadata.js";

// Resolve the package.json version at startup so /healthz can report it.
// __dirname equivalent in ESM:
const __dirname = dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(readFileSync(join(__dirname, "../package.json"), "utf8")) as {
  version: string;
};

/**
 * buildApp() is an app factory — it creates and configures a Fastify instance
 * but does NOT call `.listen()`.
 *
 * Why a factory?  Tests call `buildApp()` and use Fastify's built-in
 * `app.inject()` to fire requests over a fake in-process transport — no real
 * TCP port, no port conflicts, no network needed.  The production entrypoint
 * (`src/index.ts`) calls the same factory and then adds `.listen()`.
 * This keeps test setup trivial and prevents "address already in use" races.
 */
export interface BuildAppOptions {
  /**
   * Position provider override (tests inject a stub here). Production passes
   * nothing and we select from POSITION_PROVIDER env once, at build time.
   */
  provider?: PositionProvider;
  /** Tile-cache TTL / staleness override (env-tunable in production). */
  cacheConfig?: Parameters<typeof registerAircraftRoute>[1]["cacheConfig"];
  /** Injectable clock (unix ms) for deterministic cache tests. */
  now?: () => number;
  /**
   * Metadata store override (tests inject a PGlite-backed or in-memory store
   * here). Production passes nothing and we lazily build a Drizzle store over
   * the `DATABASE_URL` Postgres connection.
   */
  metadataStore?: MetadataStore;
}

export async function buildApp(options: BuildAppOptions = {}): Promise<FastifyInstance> {
  const app = Fastify({
    logger: process.env.NODE_ENV !== "test",
  });

  // Provider is selected ONCE at build time (env read here, not per-request).
  const provider = options.provider ?? selectProvider();

  // Cache TTL / staleness from env, overridable per-build (tests pass explicit
  // values). Falls back to TileCache's documented defaults when unset.
  const cacheConfig = options.cacheConfig ?? {
    ttlSeconds: envInt("CACHE_TTL_SECONDS"),
    staleMaxSeconds: envInt("STALE_MAX_SECONDS"),
    tileSizeDeg: envFloat("CACHE_TILE_SIZE_DEG"),
  };

  // ── Routes ────────────────────────────────────────────────────────────────

  /**
   * GET /healthz
   * Kubernetes / Fly.io health check.  Returns 200 as long as the process is
   * up and can handle requests.  No DB ping here — that belongs in a separate
   * /readyz once WP 1.4 adds Postgres.
   */
  app.get("/healthz", async () => {
    return { status: "ok", version: pkg.version };
  });

  // GET /v1/aircraft — cached, single-flighted position proxy (WP 1.3).
  registerAircraftRoute(app, {
    provider,
    cacheConfig,
    now: options.now,
  });

  // GET /v1/metadata/{icao24} — FAA + DOC 8643 merged lookup (WP 1.4).
  //
  // The store is resolved lazily: when an override is injected (tests) we use
  // it; otherwise we build a Drizzle store over the production Postgres
  // connection. We only call `getDb()` (which requires DATABASE_URL) when the
  // route actually handles a request, NOT at build time — so a test that builds
  // the app without a metadata store (e.g. the aircraft-route suite, which has
  // no database) never touches DATABASE_URL.
  let metadataStore = options.metadataStore;
  registerMetadataRoute(app, {
    store: {
      lookup: (icao24) => {
        metadataStore ??= new DrizzleMetadataStore(getDb());
        return metadataStore.lookup(icao24);
      },
    },
  });

  return app;
}

/** Parse an int env var, or undefined when unset/blank (lets defaults apply). */
function envInt(name: string): number | undefined {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return undefined;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) ? n : undefined;
}

/** Parse a float env var, or undefined when unset/blank. */
function envFloat(name: string): number | undefined {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return undefined;
  const n = Number.parseFloat(raw);
  return Number.isFinite(n) ? n : undefined;
}
