import type { Bbox, PositionProvider, ProviderSnapshot } from "../providers/types.js";
import type { UpstreamBudget } from "../providers/upstreamBudget.js";

/**
 * Region-tile in-memory cache with single-flight dedup and bounded-staleness
 * last-good fallback.
 *
 * WHY tile quantization: clients (one per phone, many phones) request slightly
 * different bboxes as they pan/zoom. If we keyed the cache on the exact bbox,
 * near-identical requests would each miss and each hammer the upstream. By
 * snapping the bbox bounds to a coarse grid (default 0.25°) we collapse a
 * cloud of almost-identical viewports onto ONE cache key — so a whole
 * neighbourhood of users over the same airspace shares a single upstream
 * fetch. The served snapshot covers the requested bbox because the upstream
 * fetch uses the *original* (un-quantized) bbox; the tile key is only the
 * cache identity, not the fetched region.
 *
 * WHY single-flight: even with quantization, two requests for the same tile
 * can arrive within the ~hundreds-of-ms it takes the upstream to answer. The
 * naive cache would let both miss and both fetch. Instead we stash the
 * in-flight Promise keyed by tile; the second caller awaits the same Promise.
 * One upstream call serves the thundering herd. This matters most exactly when
 * load is highest (everyone opening the app over a busy airport at once).
 *
 * WHY last-good fallback: live air traffic is better-served slightly stale than
 * not at all. On upstream failure we return the previous good snapshot for the
 * tile as long as it's younger than STALE_MAX — carrying its *true* fetchedAt
 * so the client can see how old it is. Only when there's no acceptably-fresh
 * cache do we surface the failure (the route maps that to 503).
 *
 * WHY THE CACHE IS BOUNDED (hardening, 2026-09-06): the tile key is derived from
 * a CLIENT-SUPPLIED bbox, so the number of distinct keys is chosen by whoever is
 * calling. At 0.25° there are ~1.04M tiles covering the planet, each holding a
 * whole aircraft snapshot — walking them all would exhaust the 256 MB VM long
 * before it finished. Two rules keep the map small, both applied on insert (the
 * only moment it can grow):
 *   1. Drop entries older than `staleMaxSeconds`. Such an entry can NEVER be
 *      served — it's past the fresh TTL and past the last-good window — so it is
 *      pure garbage; the fallback path already rejects it on age.
 *   2. Hard cap at MAX_TILE_ENTRIES, evicting least-recently-written first.
 * Real traffic doesn't notice: a busy metro is a handful of tiles, and rule 1
 * usually empties the map on its own between bursts.
 */

export interface TileCacheConfig {
  /** Grid size in degrees for quantizing bbox bounds to a tile key. */
  tileSizeDeg: number;
  /** Fresh-cache TTL in seconds: within this, serve cache without refetch. */
  ttlSeconds: number;
  /** Max age in seconds a last-good snapshot may be served on upstream failure. */
  staleMaxSeconds: number;
}

export const DEFAULT_TILE_CONFIG: TileCacheConfig = {
  tileSizeDeg: 0.25,
  ttlSeconds: 10,
  staleMaxSeconds: 60,
};

/**
 * Ceiling on cached tiles. 500 × one metro-sized snapshot (a few hundred KB at
 * the very worst) is single-digit MB — safe on the 256 MB VM — while being far
 * more than the handful of tiles any real population of users occupies. It is a
 * backstop for a deliberate bbox walk, not a tuning knob for normal traffic.
 */
export const MAX_TILE_ENTRIES = 500;

interface CacheEntry {
  snapshot: ProviderSnapshot;
  /** unix seconds when WE stored this (independent of upstream fetchedAt). */
  storedAt: number;
}

/** What the route needs to know to shape its HTTP response. */
export interface TileResult {
  snapshot: ProviderSnapshot;
  /** True when served from a last-good entry after an upstream failure. */
  stale: boolean;
}

/**
 * One genuine upstream fetch that succeeded — the unit of "which feed is
 * serving right now". Cache hits and last-good serves never produce one, so
 * the stream is bounded by the tile TTL (≤ 1 per tile per 10 s), which makes
 * it cheap enough to log every one. app.ts does exactly that.
 */
export interface UpstreamFetchEvent {
  /** The adapter that answered ("adsbfi", "adsblol") — the member, never the composite. */
  provider: string;
  /** Cache key of the tile fetched. */
  tile: string;
  /** Aircraft in the snapshot. */
  aircraft: number;
  /** Upstream snapshot time (unix seconds). */
  fetchedAt: number;
  /** Wall-clock duration of the upstream call (ms, from the injected clock). */
  upstreamMs: number;
}

/**
 * Optional cap on upstream requests (see providers/upstreamBudget.ts). With it,
 * a tile past its TTL is refreshed only when a slot is free; otherwise the
 * cached snapshot is served a little longer (up to `maxThrottledAgeSeconds`).
 * A tile with nothing servable waits up to `maxWaitMs` for a slot.
 */
export interface TileCacheThrottle {
  budget: UpstreamBudget;
  /** Longest a request with nothing servable waits for a slot. Default 2000 ms. */
  maxWaitMs?: number;
  /**
   * Oldest cached tile served instead of a refresh when no slot is free.
   * Default 30 s. Kept well under the 60 s last-good window: the app shows
   * planes where the snapshot says they were, and an airliner covers ~7 km
   * in 30 s. Past this age the refresh waits for a slot like a cold tile.
   */
  maxThrottledAgeSeconds?: number;
  /** Fired each time the budget makes us serve cache or refuse a request. */
  onThrottled?: (event: ThrottleEvent) => void;
  /** Fired each time the budget grants an upstream request. */
  onGranted?: () => void;
}

export interface ThrottleEvent {
  /** `served-cache`: a refresh was skipped and cache served. `refused`: no slot within maxWaitMs. */
  kind: "served-cache" | "refused";
  tile: string;
  /** Age of the cached snapshot that was served (s), when one was. */
  cacheAgeSeconds?: number;
}

export const DEFAULT_THROTTLE_MAX_WAIT_MS = 2_000;
export const DEFAULT_MAX_THROTTLED_AGE_SECONDS = 30;

/** The budget had no slot within maxWaitMs. Not an upstream failure. */
export class BudgetExhaustedError extends Error {
  constructor(message = "position feed request budget exhausted") {
    super(message);
    this.name = "BudgetExhaustedError";
  }
}

/** Thrown when upstream failed AND no acceptably-fresh cache exists → 503. */
export class NoFreshDataError extends Error {
  constructor(
    message: string,
    readonly cause?: unknown,
  ) {
    super(message);
    this.name = "NoFreshDataError";
  }
}

export class TileCache {
  private readonly entries = new Map<string, CacheEntry>();
  private readonly inFlight = new Map<string, Promise<ProviderSnapshot>>();
  private readonly config: TileCacheConfig;
  private readonly now: () => number;
  /** Unix ms of the last genuine upstream fetch that succeeded (any tile). */
  private lastFreshFetchAtMs: number | undefined;
  /** Unix ms of the last upstream fetch that failed (any tile), whether or
   *  not last-good data covered it. */
  private lastFailureAtMs: number | undefined;
  /** `provider` of the last genuine fetch that succeeded — what /readyz names. */
  private lastFreshProviderName: string | undefined;

  /**
   * Feed health as organic traffic proves it. The readiness canary reads these
   * so it can answer "the feed works" from the phones' own fetches instead of
   * spending an upstream request of its own every minute — adsb.lol caps a
   * client at 500 requests a DAY (x-ratelimit-limit, observed 2026-10-20),
   * and a once-a-minute canary alone is 1,440. Undefined until the first
   * fetch of each kind.
   */
  get lastFreshFetchAt(): number | undefined {
    return this.lastFreshFetchAtMs;
  }
  get lastFailureAt(): number | undefined {
    return this.lastFailureAtMs;
  }
  get lastFreshProvider(): string | undefined {
    return this.lastFreshProviderName;
  }

  constructor(
    private readonly provider: PositionProvider,
    config: Partial<TileCacheConfig> = {},
    /** Injectable clock (unix ms) for deterministic TTL tests. */
    now: () => number = Date.now,
    /**
     * Best-effort hook fired ONCE per genuine upstream fetch (not on cache hits
     * or last-good fallback), with the fresh snapshot. Used to opportunistically
     * enrich the airframe registry from the feed's type/registration — see
     * `makeRegistryEnrichSink`. Must never throw into the fetch path (wrapped).
     */
    private readonly onFreshSnapshot?: (snapshot: ProviderSnapshot) => void,
    /**
     * Fired once per genuine upstream fetch that succeeded, after the snapshot
     * is stored, with who answered and how long it took. The per-fetch log
     * line in production. Same never-throws-into-the-fetch rule as above.
     */
    private readonly onUpstreamFetch?: (event: UpstreamFetchEvent) => void,
    /** Optional upstream request cap. Omitted → every refresh fetches (tests). */
    private readonly throttle?: TileCacheThrottle,
  ) {
    // Merge defaults, ignoring explicit `undefined` overrides (env-derived
    // config passes undefined for unset vars — those must NOT clobber defaults).
    this.config = {
      tileSizeDeg: config.tileSizeDeg ?? DEFAULT_TILE_CONFIG.tileSizeDeg,
      ttlSeconds: config.ttlSeconds ?? DEFAULT_TILE_CONFIG.ttlSeconds,
      staleMaxSeconds: config.staleMaxSeconds ?? DEFAULT_TILE_CONFIG.staleMaxSeconds,
    };
    this.now = now;
  }

  /**
   * Expand a bbox to its enclosing grid tile: floor the mins and ceil the
   * maxes to the grid. Every bbox inside the same grid cell expands to the
   * SAME tile bounds — and the tile bounds always contain the requested bbox.
   *
   * The expanded tile is BOTH the cache identity and the fetched region.
   * They must match: if we cached under the tile key but fetched only the
   * requested bbox, the first caller's bbox would define the data every
   * later caller on that tile receives — silently missing aircraft near the
   * edges of *their* (different) bbox. Fetching the full tile makes the
   * cached snapshot valid for every request that maps to it; clients receive
   * a superset of their bbox, which they already tolerate (the bbox is a
   * coarse pre-filter — the app computes per-aircraft distance itself).
   */
  tileBbox(bbox: Bbox): Bbox {
    const g = this.config.tileSizeDeg;
    const snap = (v: number, fn: (n: number) => number) => {
      // Round to 4 decimals to kill float noise (0.25 * 3 → 0.7500000000000001).
      const snapped = fn(v / g) * g;
      return Math.round(snapped * 10_000) / 10_000;
    };
    return {
      lamin: Math.max(-90, snap(bbox.lamin, Math.floor)),
      lomin: Math.max(-180, snap(bbox.lomin, Math.floor)),
      lamax: Math.min(90, snap(bbox.lamax, Math.ceil)),
      lomax: Math.min(180, snap(bbox.lomax, Math.ceil)),
    };
  }

  /** Stable cache key: the tile bounds themselves. */
  tileKey(bbox: Bbox): string {
    const t = this.tileBbox(bbox);
    return [t.lamin, t.lomin, t.lamax, t.lomax].map((v) => v.toFixed(4)).join(",");
  }

  /**
   * Get a snapshot for the bbox: fresh cache hit, shared in-flight fetch, or a
   * new upstream fetch. On upstream failure, fall back to last-good if it's
   * within STALE_MAX; otherwise throw NoFreshDataError.
   */
  async get(bbox: Bbox): Promise<TileResult> {
    const key = this.tileKey(bbox);
    const nowSec = Math.floor(this.now() / 1000);

    // 1. Fresh cache hit — serve without touching upstream.
    const cached = this.entries.get(key);
    if (cached && nowSec - cached.storedAt < this.config.ttlSeconds) {
      return { snapshot: cached.snapshot, stale: false };
    }

    // 2. Single-flight: if a fetch for this tile is already running, await it.
    const existing = this.inFlight.get(key);
    if (existing) {
      try {
        const snapshot = await existing;
        return { snapshot, stale: false };
      } catch (err) {
        return this.fallbackOrThrow(key, nowSec, err);
      }
    }

    // 3. Budget check (when configured). A refresh with a recent-enough cache
    // takes a slot only if one is free right now, else serves the cache; a
    // request with nothing servable waits for a slot inside the shared fetch
    // below, so concurrent callers for the same tile wait once, together.
    let waitForSlot = false;
    if (this.throttle) {
      const maxAge = Math.min(
        this.throttle.maxThrottledAgeSeconds ?? DEFAULT_MAX_THROTTLED_AGE_SECONDS,
        this.config.staleMaxSeconds,
      );
      const age = cached ? nowSec - cached.storedAt : undefined;
      if (cached && age !== undefined && age < maxAge) {
        if (!this.throttle.budget.tryTake()) {
          this.notifyThrottled({ kind: "served-cache", tile: key, cacheAgeSeconds: age });
          return { snapshot: cached.snapshot, stale: true };
        }
        this.notifyGranted();
      } else {
        waitForSlot = true;
      }
    }

    // 4. Start a new upstream fetch; stash it so concurrent callers share it.
    // Fetch the EXPANDED tile (not the raw request) so the cached snapshot is
    // valid for every bbox that maps to this key — see tileBbox() doc.
    const fetchPromise = (async () => {
      if (waitForSlot && this.throttle) {
        const ok = await this.throttle.budget.take(
          this.throttle.maxWaitMs ?? DEFAULT_THROTTLE_MAX_WAIT_MS,
        );
        if (!ok) throw new BudgetExhaustedError();
        this.notifyGranted();
      }
      const startedMs = this.now();
      const raw = await this.provider.aircraftInBbox(this.tileBbox(bbox));
      // Every served snapshot names its feed. Real adapters stamp themselves
      // (and the composite stamps its member); this only covers a provider
      // that didn't, so the name is never missing downstream.
      const provider = raw.provider ?? this.provider.name;
      const snapshot = raw.provider === undefined ? { ...raw, provider } : raw;
      this.store(key, snapshot);
      try {
        this.onUpstreamFetch?.({
          provider,
          tile: key,
          aircraft: snapshot.aircraft.length,
          fetchedAt: snapshot.fetchedAt,
          upstreamMs: this.now() - startedMs,
        });
      } catch {
        /* swallow: a broken log sink must not affect the served response */
      }
      // Opportunistic registry enrichment — best-effort, never breaks the fetch.
      try {
        this.onFreshSnapshot?.(snapshot);
      } catch {
        /* swallow: background enrichment must not affect the served response */
      }
      return snapshot;
    })().finally(() => {
      this.inFlight.delete(key);
    });
    this.inFlight.set(key, fetchPromise);

    try {
      const snapshot = await fetchPromise;
      return { snapshot, stale: false };
    } catch (err) {
      return this.fallbackOrThrow(key, nowSec, err);
    }
  }

  private notifyThrottled(event: ThrottleEvent): void {
    try {
      this.throttle?.onThrottled?.(event);
    } catch {
      /* swallow: an alert sink must not affect the served response */
    }
  }

  private notifyGranted(): void {
    try {
      this.throttle?.onGranted?.();
    } catch {
      /* swallow: an alert sink must not affect the served response */
    }
  }

  /** How many tiles are currently cached. Exposed for tests + future metrics. */
  get size(): number {
    return this.entries.size;
  }

  /**
   * Store a fresh snapshot and enforce the two bounds (see the header comment).
   *
   * The delete-then-set is deliberate: `Map.set` on an existing key keeps its
   * ORIGINAL insertion position, so without the delete the iteration order would
   * drift away from write recency and the oldest-first eviction would start
   * throwing out hot tiles. With it, iteration order is exactly
   * least-recently-written first, which is what both bounds want.
   */
  private store(key: string, snapshot: ProviderSnapshot): void {
    const nowMs = this.now();
    const nowSec = Math.floor(nowMs / 1000);
    this.lastFreshFetchAtMs = nowMs;
    this.lastFreshProviderName = snapshot.provider;
    this.entries.delete(key);
    this.entries.set(key, { snapshot, storedAt: nowSec });

    // 1. Un-servable by age. Full scan rather than "stop at the first young
    // entry": it costs nothing at this size, and it stays correct even if the
    // injected clock ever moves backwards (tests do that).
    for (const [k, entry] of this.entries) {
      if (nowSec - entry.storedAt >= this.config.staleMaxSeconds) this.entries.delete(k);
    }

    // 2. Hard cap, least-recently-written first.
    if (this.entries.size > MAX_TILE_ENTRIES) {
      for (const k of this.entries.keys()) {
        if (this.entries.size <= MAX_TILE_ENTRIES) break;
        this.entries.delete(k);
      }
    }
  }

  /** Serve last-good if fresh enough; otherwise throw NoFreshDataError. */
  private fallbackOrThrow(key: string, nowSec: number, cause: unknown): TileResult {
    const budgetRefused = cause instanceof BudgetExhaustedError;
    // A refused budget slot is our own load shedding, not a feed failure: it
    // must not make /readyz distrust the feed (feedProbe reads lastFailureAt).
    if (budgetRefused) {
      this.notifyThrottled({ kind: "refused", tile: key });
    } else {
      this.lastFailureAtMs = this.now();
    }
    const cached = this.entries.get(key);
    if (cached && nowSec - cached.storedAt < this.config.staleMaxSeconds) {
      // Carry the snapshot's true fetchedAt so the client sees real staleness.
      return { snapshot: cached.snapshot, stale: true };
    }
    throw new NoFreshDataError(
      budgetRefused
        ? "position feed request budget exhausted and no fresh cache"
        : "upstream unavailable and no fresh cache",
      cause,
    );
  }
}
