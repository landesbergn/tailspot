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
import { makeRegistryEnrichSink } from "./ingest/feedEnrich.js";
import { DrizzleMetadataStore, type MetadataStore } from "./metadata/store.js";
import {
  AdsbLolRouteService,
  type RouteEnricher,
  type RouteResolver,
} from "./providers/adsblolRoutes.js";
import { type PositionProvider, selectProvider } from "./providers/index.js";
import { registerAircraftRoute } from "./routes/aircraft.js";
import { registerCatchesRoute } from "./routes/catches.js";
import { registerDevicesRoutes } from "./routes/devices.js";
import { registerHandlesRoute } from "./routes/handles.js";
import { registerLeaderboardRoute } from "./routes/leaderboard.js";
import { registerMetadataRoute } from "./routes/metadata.js";
import { registerRoutesRoute } from "./routes/routes.js";

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
   * Per-fresh-fetch snapshot hook (tests inject a spy). Production defaults to
   * the registry-enrich sink when DATABASE_URL is set; left undefined in the
   * DB-less route tests so they never touch Postgres.
   */
  onFreshSnapshot?: Parameters<typeof registerAircraftRoute>[1]["onFreshSnapshot"];
  /**
   * Origin → destination route enricher (tests inject a fake or omit). Production
   * defaults to the adsb.lol routeset lookup when the adsb.lol provider is
   * active; left undefined in tests so they never hit the network.
   */
  routeEnricher?: RouteEnricher;
  /**
   * Per-callsign route resolver for GET /v1/routes/{callsign} AND for
   * POST /v1/catches route-guess verification (tests inject a fake). Production
   * defaults to the SAME AdsbLolRouteService instance as the enricher (shared
   * cache); absent both → the endpoint isn't registered and route guesses
   * verify as incorrect (never blocking the catch).
   */
  routeResolver?: RouteResolver;
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
  /**
   * Handle-suggestion candidate generator override (tests force a known set,
   * including a pre-claimed handle, to assert availability filtering). Production
   * uses the default word-bank generator.
   */
  handleCandidateGenerator?: (batchSize: number) => string[];
}

export async function buildApp(options: BuildAppOptions = {}): Promise<FastifyInstance> {
  const app = Fastify({
    logger: process.env.NODE_ENV !== "test",
    // Behind Fly.io's edge proxy the TCP peer is the proxy, not the client.
    // trustProxy makes request.ip read X-Forwarded-For — without it the
    // per-IP rate limit on POST /v1/devices would put EVERY client in one
    // bucket (a global 429 the moment two users register in the same minute).
    // Security-review fix, 2026-06-10.
    trustProxy: true,
  });

  // Provider is selected ONCE at build time (env read here, not per-request).
  // The default is adsb.lol with an airplanes.live fallback; every engaged
  // fallback is logged — a silently-dead primary must not look healthy (the
  // client-side silent-failover lesson from the 2026-06-21 cutover).
  const provider =
    options.provider ??
    selectProvider(process.env, {
      onFallback: (err) =>
        app.log.warn({ err }, "primary position feed failed; serving airplanes.live fallback"),
    });

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
  //
  // Opportunistic registry enrichment: each fresh upstream fetch carries the
  // typecode/registration for foreign airframes the FAA registry can't resolve,
  // so we fire-and-forget those into the registry (non-destructive). Gated on
  // DATABASE_URL so the DB-less route tests never touch Postgres; an injected
  // override (tests) always wins. getDb()/Sentry stay untouched until a snapshot
  // actually arrives.
  const onFreshSnapshot =
    options.onFreshSnapshot ??
    (process.env.DATABASE_URL
      ? makeRegistryEnrichSink(getDb, (err) =>
          app.log.warn({ err }, "opportunistic registry enrich failed"),
        )
      : undefined);
  // Opportunistic origin → destination enrichment: adsb.lol carries route only
  // via a separate routeset POST, so each served snapshot is passed through a
  // per-callsign-cached lookup that attaches `route` without blocking the
  // position response (see AdsbLolRouteService). Enabled whenever adsb.lol is
  // the (primary) provider — `startsWith` also matches the default
  // "adsblol+airplaneslive" fallback composite — and outside tests (so the
  // route suite never hits the network); an injected override (tests) always
  // wins. Route lookups deliberately stay adsb.lol-direct even when positions
  // are served by the fallback: routes are cached, non-blocking metadata.
  const routeEnricher =
    options.routeEnricher ??
    (process.env.NODE_ENV !== "test" && provider.name.startsWith("adsblol")
      ? new AdsbLolRouteService({
          onError: (err) => app.log.warn({ err }, "route lookup failed"),
        })
      : undefined);
  registerAircraftRoute(app, {
    provider,
    cacheConfig,
    now: options.now,
    onFreshSnapshot,
    routeEnricher,
  });

  // GET /v1/routes/{callsign} — per-callsign route lookup for the iOS catch
  // route backfill (2026-07-04). Shares the enricher's cache when the default
  // AdsbLolRouteService is in play (a hot flight is a map read); an injected
  // resolver (tests) always wins. Registered only when a resolver exists —
  // a non-adsblol deployment simply has no route data to serve.
  const routeResolver =
    options.routeResolver ??
    (routeEnricher instanceof AdsbLolRouteService ? routeEnricher : undefined);
  if (routeResolver) {
    const routeLimiter = new RateLimiter({ capacity: 120, windowMs: 60_000 }, options.rateLimitNow); // 120/min per IP — one backfill pass over an old Hangar is ~1/callsign
    registerRoutesRoute(app, { resolver: routeResolver, routeLimiter });
  }

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
    takenHandles: (hs) => getIdentityStore().takenHandles(hs),
  };
  const catchesStore: CatchStore = {
    resolveRarity: (icao) => getCatchStore().resolveRarity(icao),
    scoreCatch: (icao, opts) => getCatchStore().scoreCatch(icao, opts),
    isFirstOfType: (deviceId, typecode) => getCatchStore().isFirstOfType(deviceId, typecode),
    insertOrGet: (c) => getCatchStore().insertOrGet(c),
    listCatches: (id, limit, offset) => getCatchStore().listCatches(id, limit, offset),
    leaderboard: (n, since) => getCatchStore().leaderboard(n, since),
    myStanding: (id, since) => getCatchStore().myStanding(id, since),
    ensureWeeksDecided: (now) => getCatchStore().ensureWeeksDecided(now),
    champions: (weekStart) => getCatchStore().champions(weekStart),
    weeklyWins: (id) => getCatchStore().weeklyWins(id),
    everToppedAllTime: (id) => getCatchStore().everToppedAllTime(id),
    recordAlltimeTopper: (now) => getCatchStore().recordAlltimeTopper(now),
  };

  // Rate limiters: in-memory token buckets (single-instance caveat documented in
  // RateLimiter). One per concern, with the contract's limits. The clock is
  // injectable for deterministic tests; the limiters share one app's lifetime.
  const rlNow = options.rateLimitNow;
  const registerLimiter = new RateLimiter({ capacity: 20, windowMs: 60_000 }, rlNow); // 20/min per IP
  const handleLimiter = new RateLimiter({ capacity: 5, windowMs: 60_000 }, rlNow); // 5/min per device
  const catchLimiter = new RateLimiter({ capacity: 60, windowMs: 60_000 }, rlNow); // 60/min per device
  const suggestLimiter = new RateLimiter({ capacity: 30, windowMs: 60_000 }, rlNow); // 30/min per IP

  registerDevicesRoutes(app, { store: identity, registerLimiter, handleLimiter });
  registerHandlesRoute(app, {
    store: identity,
    suggestLimiter,
    generateCandidates: options.handleCandidateGenerator,
  });
  registerCatchesRoute(app, {
    identityStore: identity,
    catchStore: catchesStore,
    catchLimiter,
    // Route-guess verification shares the /v1/routes resolver (same cache).
    routeResolver,
    nowSeconds: options.nowSeconds,
  });
  // The leaderboard's window math shares the catch-validation clock
  // (`nowSeconds`, unix seconds) so window tests are deterministic; production
  // passes nothing and both fall back to wall time.
  const nowSeconds = options.nowSeconds;
  registerLeaderboardRoute(app, {
    identityStore: identity,
    catchStore: catchesStore,
    now: nowSeconds ? () => new Date(nowSeconds() * 1000) : undefined,
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
