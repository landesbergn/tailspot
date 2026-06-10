import { describe, expect, it } from "vitest";
import type { Bbox, PositionProvider, ProviderSnapshot } from "../src/providers/types.js";
import { DEFAULT_TILE_CONFIG, TileCache } from "../src/routes/tileCache.js";

/**
 * Regression tests for the tile-fetch/cache-key agreement.
 *
 * The cache keys on the quantized tile, so the FETCH must cover the full
 * tile too. If it fetched only the raw requested bbox, the first caller's
 * bbox would define the data every later same-tile caller receives —
 * silently dropping aircraft near the edges of their (different) bbox.
 */

function recordingProvider(): { provider: PositionProvider; calls: Bbox[] } {
  const calls: Bbox[] = [];
  const provider: PositionProvider = {
    name: "stub",
    async aircraftInBbox(bbox: Bbox): Promise<ProviderSnapshot> {
      calls.push(bbox);
      return { fetchedAt: 1_750_000_000, aircraft: [] };
    },
  };
  return { provider, calls };
}

describe("TileCache tile-fetch agreement", () => {
  // Berkeley-ish bbox, deliberately NOT grid-aligned.
  const bboxA: Bbox = { lamin: 37.61, lomin: -122.51, lamax: 38.11, lomax: -121.99 };
  // A different observer a few km away — same 0.25° tile, different bounds.
  const bboxB: Bbox = { lamin: 37.64, lomin: -122.53, lamax: 38.14, lomax: -121.96 };

  it("fetches the expanded tile bounds, not the raw request", async () => {
    const { provider, calls } = recordingProvider();
    const cache = new TileCache(provider, {}, () => 0);

    await cache.get(bboxA);

    expect(calls).toHaveLength(1);
    const fetched = calls[0];
    expect(fetched).toEqual(cache.tileBbox(bboxA));
    // The tile must fully contain the request.
    expect(fetched.lamin).toBeLessThanOrEqual(bboxA.lamin);
    expect(fetched.lomin).toBeLessThanOrEqual(bboxA.lomin);
    expect(fetched.lamax).toBeGreaterThanOrEqual(bboxA.lamax);
    expect(fetched.lomax).toBeGreaterThanOrEqual(bboxA.lomax);
    // Grid-aligned to the configured tile size.
    const g = DEFAULT_TILE_CONFIG.tileSizeDeg;
    for (const v of [fetched.lamin, fetched.lomin, fetched.lamax, fetched.lomax]) {
      expect(Math.abs(v / g - Math.round(v / g))).toBeLessThan(1e-9);
    }
  });

  it("a same-tile request from a different observer is a cache hit whose data covers it", async () => {
    const { provider, calls } = recordingProvider();
    const cache = new TileCache(provider, {}, () => 0);

    expect(cache.tileKey(bboxA)).toBe(cache.tileKey(bboxB)); // same tile by construction

    await cache.get(bboxA);
    await cache.get(bboxB); // within TTL → must NOT refetch

    expect(calls).toHaveLength(1);
    // The single fetch must cover BOTH observers' bboxes.
    const fetched = calls[0];
    for (const b of [bboxA, bboxB]) {
      expect(fetched.lamin).toBeLessThanOrEqual(b.lamin);
      expect(fetched.lomin).toBeLessThanOrEqual(b.lomin);
      expect(fetched.lamax).toBeGreaterThanOrEqual(b.lamax);
      expect(fetched.lomax).toBeGreaterThanOrEqual(b.lomax);
    }
  });

  it("clamps expanded tiles at the poles/antimeridian", async () => {
    const { provider, calls } = recordingProvider();
    const cache = new TileCache(provider, {}, () => 0);

    await cache.get({ lamin: 89.9, lomin: 179.9, lamax: 90, lomax: 180 });
    expect(calls[0].lamax).toBe(90);
    expect(calls[0].lomax).toBe(180);
  });
});
