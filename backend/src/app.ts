import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import Fastify, { type FastifyInstance } from "fastify";
import { getDb } from "./db/client.js";
import { RateLimiter } from "./identity/rateLimiter.js";
import {
  type CatchStore,
  DrizzleCatchStore,
  DrizzleIdentityStore,
  type IdentityStore,
} from "./identity/store.js";
import { DrizzleMetadataStore, type MetadataStore } from "./metadata/store.js";
import { type PositionProvider, selectProvider } from "./providers/index.js";
import { registerAircraftRoute } from "./routes/aircraft.js";
import { registerCatchesRoute } from "./routes/catches.js";
import { registerDevicesRoutes } from "./routes/devices.js";
import { registerLeaderboardRoute } from "./routes/leaderboard.js";
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
  /** Identity store override (devices + handles). Lazily built over Postgres in prod. */
  identityStore?: IdentityStore;
  /** Catch store override (catches + leaderboard). Lazily built over Postgres in prod. */
  catchStore?: CatchStore;
  /** Injectable clock (unix seconds) for deterministic catch-validation tests. */
  nowSeconds?: () => number;
  /** Injectable clock (unix ms) for the rate limiters (tests pass a fake). */
  rateLimitNow?: () => number;
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

  // ── Identity + catches + leaderboard (WP 1.5) ───────────────────────────────
  //
  // Stores are resolved lazily over the shared production Postgres connection
  // (same pattern as metadata): a test that builds the app without these stores
  // never touches DATABASE_URL. When overrides are injected (tests), they win.
  // Memoized lazy getters: build the Drizzle store on first use (which is the
  // only point we touch DATABASE_URL). Statement-form assignment in a block body
  // so the lazy wiring stays a statement, not an expression.
  let identityStore = options.identityStore;
  function getIdentityStore(): IdentityStore {
    if (!identityStore) identityStore = new DrizzleIdentityStore(getDb());
    return identityStore;
  }
  let catchStore = options.catchStore;
  function getCatchStore(): CatchStore {
    if (!catchStore) catchStore = new DrizzleCatchStore(getDb());
    return catchStore;
  }
  const identity: IdentityStore = {
    createDevice: (h) => getIdentityStore().createDevice(h),
    findByTokenHash: (h) => getIdentityStore().findByTokenHash(h),
    claimHandle: (id, h) => getIdentityStore().claimHandle(id, h),
  };
  const catchesStore: CatchStore = {
    resolveRarity: (icao) => getCatchStore().resolveRarity(icao),
    insertOrGet: (c) => getCatchStore().insertOrGet(c),
    leaderboard: (n) => getCatchStore().leaderboard(n),
    myStanding: (id) => getCatchStore().myStanding(id),
  };

  // Rate limiters: in-memory token buckets (single-instance caveat documented in
  // RateLimiter). One per concern, with the contract's limits. The clock is
  // injectable for deterministic tests; the limiters share one app's lifetime.
  const rlNow = options.rateLimitNow;
  const registerLimiter = new RateLimiter({ capacity: 20, windowMs: 60_000 }, rlNow); // 20/min per IP
  const handleLimiter = new RateLimiter({ capacity: 5, windowMs: 60_000 }, rlNow); // 5/min per device
  const catchLimiter = new RateLimiter({ capacity: 60, windowMs: 60_000 }, rlNow); // 60/min per device

  registerDevicesRoutes(app, { store: identity, registerLimiter, handleLimiter });
  registerCatchesRoute(app, {
    identityStore: identity,
    catchStore: catchesStore,
    catchLimiter,
    nowSeconds: options.nowSeconds,
  });
  registerLeaderboardRoute(app, { identityStore: identity, catchStore: catchesStore });

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
