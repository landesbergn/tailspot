import type { Bbox, PositionProvider, ProviderSnapshot } from "../providers/types.js";

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

  constructor(
    private readonly provider: PositionProvider,
    config: Partial<TileCacheConfig> = {},
    /** Injectable clock (unix ms) for deterministic TTL tests. */
    now: () => number = Date.now,
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

    // 3. Start a new upstream fetch; stash it so concurrent callers share it.
    // Fetch the EXPANDED tile (not the raw request) so the cached snapshot is
    // valid for every bbox that maps to this key — see tileBbox() doc.
    const fetchPromise = this.provider
      .aircraftInBbox(this.tileBbox(bbox))
      .then((snapshot) => {
        this.entries.set(key, { snapshot, storedAt: Math.floor(this.now() / 1000) });
        return snapshot;
      })
      .finally(() => {
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

  /** Serve last-good if fresh enough; otherwise throw NoFreshDataError. */
  private fallbackOrThrow(key: string, nowSec: number, cause: unknown): TileResult {
    const cached = this.entries.get(key);
    if (cached && nowSec - cached.storedAt < this.config.staleMaxSeconds) {
      // Carry the snapshot's true fetchedAt so the client sees real staleness.
      return { snapshot: cached.snapshot, stale: true };
    }
    throw new NoFreshDataError("upstream unavailable and no fresh cache", cause);
  }
}
