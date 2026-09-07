import { sql } from "drizzle-orm";
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
import { SustainedFallbackAlerter } from "./providers/fallbackAlert.js";
import { type PositionProvider, selectProvider } from "./providers/index.js";
import { registerAircraftRoute } from "./routes/aircraft.js";
import { registerCatchesRoute } from "./routes/catches.js";
import { registerDevicesRoutes } from "./routes/devices.js";
import { registerHandlesRoute } from "./routes/handles.js";
import { registerLeaderboardRoute } from "./routes/leaderboard.js";
import { registerMetadataRoute } from "./routes/metadata.js";
import { registerRoutesRoute } from "./routes/routes.js";
import { registerStatsRoute } from "./routes/stats.js";

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
   * Browser origins allowed to read GET /v1/stats (tests override). Production
   * defaults to the marketing site and its preview deployment;
   * `STATS_ALLOWED_ORIGINS` (comma-separated) extends it without a code change.
   */
  statsAllowedOrigins?: readonly string[];
  /**
   * Handle-suggestion candidate generator override (tests force a known set,
   * including a pre-claimed handle, to assert availability filtering). Production
   * uses the default word-bank generator.
   */
  handleCandidateGenerator?: (batchSize: number) => string[];
  /**
   * Readiness probe override (tests inject success/failure). Production pings
   * Postgres (`SELECT 1`) through the shared pool — see GET /readyz.
   */
  readyProbe?: () => Promise<void>;
}

export async function buildApp(options: BuildAppOptions = {}): Promise<FastifyInstance> {
  const app = Fastify({
    logger: process.env.NODE_ENV !== "test",
    // ── Resource ceilings (256 MB shared-cpu VM — see fly.toml) ──────────────
    // Fastify ships with NO request timeout and NO connection timeout, so a
    // client that opens a socket and dribbles bytes (or never finishes a body)
    // holds a connection and its buffers indefinitely. On a single small VM
    // that is a free denial-of-service. Every real request here finishes in
    // tens of milliseconds; the upstream ADS-B fetch is the slow path and it
    // has its own timeout well under 15 s.
    requestTimeout: 15_000,
    // Idle-socket ceiling: kills sockets that connect and then say nothing.
    // Longer than requestTimeout so it never pre-empts a legitimate slow
    // request — it only reaps sockets that aren't making one.
    connectionTimeout: 30_000,
    // 64 KB, down from Fastify's 1 MB default. Every body this API accepts is
    // tiny: POST /v1/devices is literally `{}`, a handle claim is a few dozen
    // bytes, and POST /v1/catches is ~300–400 bytes. 64 KB leaves ~150× head-
    // room over the largest real request while making a memory-exhaustion
    // upload pointless. Raising this needs a matching look at the VM size.
    bodyLimit: 65_536,
    // DELIBERATELY FALSE (was true from 2026-06-10 until 2026-09-06).
    // `trustProxy: true` makes `request.ip` the LEFTMOST X-Forwarded-For entry
    // — a value the client writes. Verified against production on 2026-09-06:
    // 30 GETs to /v1/handles/suggestions returned 429, then the same request
    // with `X-Forwarded-For: 10.9.8.1` returned 200, and every subsequent
    // invented value bought another full bucket. Every per-IP limit was
    // decorative. With this false, `request.ip` is the real TCP peer and can't
    // be forged; the "everyone shares one bucket behind the proxy" problem the
    // 2026-06-10 fix was solving is now solved properly, by reading the
    // Fly-Proxy-set `Fly-Client-IP` header — see src/identity/clientIp.ts,
    // which is the ONLY thing rate limiters key on.
    trustProxy: false,
  });

  // Provider is selected ONCE at build time (env read here, not per-request).
  // The default is adsb.lol with an airplanes.live fallback; every engaged
  // fallback is logged — a silently-dead primary must not look healthy (the
  // client-side silent-failover lesson from the 2026-06-21 cutover).
  //
  // A log line is enough to explain an incident after the fact, but nobody
  // watches the Fly log live, so a primary that stays dead for hours reads as
  // a healthy system. The alerter turns the engage/recover edges into ONE
  // Sentry message per hour once the fallback has been continuously engaged
  // for five minutes — the timing logic lives in SustainedFallbackAlerter and
  // is unit-tested with an injected clock.
  const fallbackAlerter = new SustainedFallbackAlerter({
    // Shares the rate limiters' injectable clock (same unix-ms units), the way
    // the /v1/stats memo does — one fake clock per test, not three.
    now: options.rateLimitNow,
    onAlert: ({ engagedForMs, primaryError }) => {
      const minutes = Math.round(engagedForMs / 60_000);
      app.log.error(
        { err: primaryError, engagedForMs },
        `primary position feed has been down for ~${minutes} min; still serving the fallback`,
      );
      // Imported lazily so app.ts's static graph stays Sentry-free (the test
      // suite builds this app constantly and should never load the SDK). This
      // path only runs after a five-minute production outage; captureMessage
      // is itself a no-op when SENTRY_DSN is unset — see instrument.ts.
      void import("@sentry/node")
        .then((Sentry) =>
          Sentry.captureMessage(
            `Position feed fallback sustained for ~${minutes} min`,
            "error" as const,
          ),
        )
        .catch((err) => app.log.warn({ err }, "could not report sustained fallback to Sentry"));
    },
  });
  const provider =
    options.provider ??
    selectProvider(process.env, {
      onFallback: (err) => {
        app.log.warn({ err }, "primary position feed failed; serving airplanes.live fallback");
        fallbackAlerter.recordFallback(err);
      },
      onRecovered: () => {
        app.log.info("primary position feed recovered; fallback disengaged");
        fallbackAlerter.recordRecovery();
      },
    });

  // Cache TTL / staleness from env, overridable per-build (tests pass explicit
  // values). Falls back to TileCache's documented defaults when unset.
  const cacheConfig = options.cacheConfig ?? {
    ttlSeconds: envInt("CACHE_TTL_SECONDS"),
    staleMaxSeconds: envInt("STALE_MAX_SECONDS"),
    tileSizeDeg: envFloat("CACHE_TILE_SIZE_DEG"),
  };

  // ── Rate limiters ─────────────────────────────────────────────────────────
  //
  // In-memory token buckets, one per concern, declared here because several
  // routes share one instance. Read RateLimiter's header for the two caveats
  // that shape these numbers: limits are PER MACHINE (we run two, so the real
  // ceiling is 2× everything below — accepted), and buckets are keyed by the
  // Fly-Proxy-observed client IP (src/identity/clientIp.ts), never by anything
  // the client can set.
  //
  // Per-IP limits are deliberately generous because MANY PHONES SHARE ONE IPv4
  // (carrier CGNAT, airport and café Wi-Fi) — a limit tuned to one device would
  // 429 a whole coffee shop. Per-device limits can be tight, since a device
  // token maps to exactly one phone.
  //
  // The clock is injectable so tests drive the buckets deterministically; the
  // limiters live as long as the app instance.
  const rlNow = options.rateLimitNow;
  const registerLimiter = new RateLimiter({ capacity: 20, windowMs: 60_000 }, rlNow); // 20/min per IP
  const handleLimiter = new RateLimiter({ capacity: 5, windowMs: 60_000 }, rlNow); // 5/min per device
  const catchLimiter = new RateLimiter({ capacity: 60, windowMs: 60_000 }, rlNow); // 60/min per device
  const suggestLimiter = new RateLimiter({ capacity: 30, windowMs: 60_000 }, rlNow); // 30/min per IP
  // 120/min per IP on the position poll. The client polls every 10 s normally
  // and every 2 s when data-starved (30/min worst case per phone), so this is
  // headroom for ~4 simultaneously-starved phones on one IP — and a hard stop
  // on a runaway loop, which is what actually threatens the upstream quota.
  const aircraftLimiter = new RateLimiter({ capacity: 120, windowMs: 60_000 }, rlNow);
  // 300/min per IP on metadata. Sized off the real burst: the ambient prefetch
  // can fire 40–60 lookups in a few seconds on a first launch near SFO, and the
  // app renders a 429 as an error pill, so being stingy here is a visible bug.
  const metadataLimiter = new RateLimiter({ capacity: 300, windowMs: 60_000 }, rlNow);
  // 30/min per DEVICE on the Hangar restore read (one probe + 500-row pages per
  // launch in the honest client).
  const catchesListLimiter = new RateLimiter({ capacity: 30, windowMs: 60_000 }, rlNow);
  // 120/min per IP across ALL bearer routes, taken BEFORE the token lookup so
  // unauthenticated probing is metered — previously a bad token cost the
  // attacker one request and cost us a database round-trip, unbounded. Shared
  // by PUT /v1/devices/me/handle, GET /v1/catches and POST /v1/catches; the
  // per-device limiters still apply after auth.
  const bearerIpLimiter = new RateLimiter({ capacity: 120, windowMs: 60_000 }, rlNow);

  // ── Routes ────────────────────────────────────────────────────────────────

  /**
   * GET /healthz
   * Fly.io health check (fly.toml [[http_service.checks]]). Returns 200 as long
   * as the process is up and can handle requests. Deliberately NO DB ping: Fly
   * restarts machines that fail this check, and restarting the API because the
   * *database* is down would just add churn on top of the real outage. End-to-end
   * readiness (process + DB) lives at /readyz.
   *
   * The body is deliberately just `{ status: "ok" }`. It used to include the
   * package version, which told an unauthenticated caller exactly which build
   * is running — free reconnaissance for anyone matching a dependency CVE to a
   * release. Nothing consumed it — no deploy script, no iOS code path, and no
   * Sentry release tag (instrument.ts sets no `release`) — so it's gone rather
   * than moved behind auth. Version at a glance: `fly image show -a tailspot-api`.
   */
  app.get("/healthz", async () => {
    return { status: "ok" };
  });

  /**
   * GET /readyz
   * End-to-end readiness: 200 only when the process is up AND Postgres answers
   * a `SELECT 1` within 3 s. This is the URL the external uptime monitor watches
   * (Sentry monitor 8072647) — unlike /healthz it turns a dead/unreachable DB
   * into a visible outage instead of a slow trickle of 500s.
   *
   * The probe is resolved lazily per-request (same pattern as the stores below):
   * building the app never touches DATABASE_URL, so DB-less tests stay DB-less —
   * hitting /readyz without a database simply reports 503, which is the truth.
   * The 3 s cap keeps a hung DB connection from dragging the response past the
   * monitor's own timeout; the stray timer is cleared so injected test probes
   * don't leak into vitest's open-handle check.
   */
  const readyProbe =
    options.readyProbe ??
    (async () => {
      await getDb().execute(sql`select 1`);
    });
  app.get("/readyz", async (request, reply) => {
    let timer: NodeJS.Timeout | undefined;
    try {
      await Promise.race([
        readyProbe(),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error("readiness probe timed out")), 3_000);
        }),
      ]);
      return { status: "ok" };
    } catch (err) {
      request.log.warn({ err }, "readiness probe failed");
      return reply.code(503).send({ status: "unavailable" });
    } finally {
      clearTimeout(timer);
    }
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
    ipLimiter: aircraftLimiter,
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
    // 120/min per IP — one backfill pass over an old Hangar is ~1/callsign.
    const routeLimiter = new RateLimiter({ capacity: 120, windowMs: 60_000 }, rlNow);
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
    ipLimiter: metadataLimiter,
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
    ensureMonthsDecided: (now) => getCatchStore().ensureMonthsDecided(now),
    monthlyChampions: (monthStart) => getCatchStore().monthlyChampions(monthStart),
    monthlyWins: (id) => getCatchStore().monthlyWins(id),
    everToppedAllTime: (id) => getCatchStore().everToppedAllTime(id),
    recordAlltimeTopper: (now) => getCatchStore().recordAlltimeTopper(now),
    countCatches: () => getCatchStore().countCatches(),
  };

  registerDevicesRoutes(app, { store: identity, registerLimiter, handleLimiter, bearerIpLimiter });
  registerHandlesRoute(app, {
    store: identity,
    suggestLimiter,
    generateCandidates: options.handleCandidateGenerator,
  });
  registerCatchesRoute(app, {
    identityStore: identity,
    catchStore: catchesStore,
    catchLimiter,
    listLimiter: catchesListLimiter,
    bearerIpLimiter,
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

  // GET /v1/stats — the marketing site's catch counter. Origin-gated + cached;
  // the rate limiters' clock doubles as the memo clock so tests can expire it.
  registerStatsRoute(app, {
    catchStore: catchesStore,
    allowedOrigins: options.statsAllowedOrigins ?? statsOriginsFromEnv(),
    now: rlNow,
  });

  return app;
}

// The preview site (web/fly.preview.toml) is on the list so a staged landing
// page shows the real number — the whole point of having a preview.
const DEFAULT_STATS_ORIGINS = [
  "https://tailspot.app",
  "https://www.tailspot.app",
  "https://tailspot-www-preview.fly.dev",
];

/** The default site origins plus any from `STATS_ALLOWED_ORIGINS` (comma-separated). */
function statsOriginsFromEnv(): string[] {
  const extra = (process.env.STATS_ALLOWED_ORIGINS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  return [...DEFAULT_STATS_ORIGINS, ...extra];
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
