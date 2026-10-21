import { describe, expect, it } from "vitest";
import type { Bbox, PositionProvider, ProviderSnapshot } from "../src/providers/types.js";
import { UpstreamBudget } from "../src/providers/upstreamBudget.js";
import { NoFreshDataError, type ThrottleEvent, TileCache } from "../src/routes/tileCache.js";

const BAY: Bbox = { lamin: 37.6, lomin: -122.5, lamax: 37.9, lomax: -122.2 };
const NYC: Bbox = { lamin: 40.6, lomin: -74.1, lamax: 40.8, lomax: -73.9 };
const LON: Bbox = { lamin: 51.4, lomin: -0.5, lamax: 51.6, lomax: -0.3 };

function setup(opts: { maxWaitMs?: number } = {}) {
  let t = 1_000_000_000;
  const calls: Bbox[] = [];
  const provider: PositionProvider = {
    name: "stub",
    async aircraftInBbox(bbox): Promise<ProviderSnapshot> {
      calls.push(bbox);
      return { fetchedAt: Math.floor(t / 1000), aircraft: [] };
    },
  };
  const events: ThrottleEvent[] = [];
  let granted = 0;
  const now = () => t;
  // Sleeping advances the shared clock, so waits are instant but real in effect.
  const budget = new UpstreamBudget({
    ratePerSecond: 1,
    now,
    sleep: async (ms) => {
      t += ms;
    },
  });
  const cache = new TileCache(
    provider,
    { ttlSeconds: 10, staleMaxSeconds: 60, tileSizeDeg: 0.25 },
    now,
    undefined,
    undefined,
    {
      budget,
      maxWaitMs: opts.maxWaitMs,
      onThrottled: (e) => events.push(e),
      onGranted: () => {
        granted++;
      },
    },
  );
  return {
    cache,
    calls,
    events,
    budget,
    granted: () => granted,
    advance: (ms: number) => {
      t += ms;
    },
  };
}

describe("TileCache with an upstream budget", () => {
  it("serves a recent cache instead of refreshing when no slot is free", async () => {
    const s = setup();
    await s.cache.get(BAY); // slot 1
    s.advance(11_000); // BAY is past its TTL
    await s.cache.get(NYC); // takes the slot that is free now
    const result = await s.cache.get(BAY); // refresh wanted, no slot
    expect(result.stale).toBe(true);
    expect(s.calls).toHaveLength(2);
    expect(s.events).toEqual([
      expect.objectContaining({ kind: "served-cache", cacheAgeSeconds: 11 }),
    ]);
  });

  it("refreshes normally when a slot is free", async () => {
    const s = setup();
    await s.cache.get(BAY);
    s.advance(11_000);
    const result = await s.cache.get(BAY);
    expect(result.stale).toBe(false);
    expect(s.calls).toHaveLength(2);
    expect(s.events).toHaveLength(0);
    expect(s.granted()).toBe(2);
  });

  it("makes a cold tile wait for the next slot rather than skip the budget", async () => {
    const s = setup();
    await s.cache.get(BAY);
    await s.cache.get(NYC); // waits one interval
    expect(s.calls).toHaveLength(2);
    expect(s.budget.granted).toBe(2);
  });

  it("answers 503-style when a cold tile cannot get a slot in time, without blaming the feed", async () => {
    const s = setup({ maxWaitMs: 500 });
    await s.cache.get(BAY);
    await expect(s.cache.get(NYC)).rejects.toBeInstanceOf(NoFreshDataError);
    expect(s.events).toEqual([expect.objectContaining({ kind: "refused" })]);
    // Load shedding is not a feed failure: /readyz must not go red over it.
    expect(s.cache.lastFailureAt).toBeUndefined();
  });

  it("treats a cache older than 30 s as cold: it waits for a slot instead of serving old planes", async () => {
    const s = setup();
    await s.cache.get(BAY);
    s.advance(31_000);
    await s.cache.get(NYC); // uses the free slot
    const result = await s.cache.get(BAY); // 31 s old: waits ~1 s and refreshes
    expect(result.stale).toBe(false);
    expect(s.calls).toHaveLength(3);
  });

  it("shares one wait among concurrent callers for the same cold tile", async () => {
    const s = setup();
    await s.cache.get(BAY);
    await Promise.all([s.cache.get(LON), s.cache.get(LON), s.cache.get(LON)]);
    expect(s.calls).toHaveLength(2);
    expect(s.budget.granted).toBe(2);
  });
});
