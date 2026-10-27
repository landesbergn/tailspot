import { describe, expect, it } from "vitest";
import type { Bbox, PositionProvider, ProviderSnapshot } from "../src/providers/types.js";
import { UpstreamBudget } from "../src/providers/upstreamBudget.js";
import { NoFreshDataError, type ThrottleEvent, TileCache } from "../src/routes/tileCache.js";

const BAY: Bbox = { lamin: 37.6, lomin: -122.5, lamax: 37.9, lomax: -122.2 };
const NYC: Bbox = { lamin: 40.6, lomin: -74.1, lamax: 40.8, lomax: -73.9 };
const LON: Bbox = { lamin: 51.4, lomin: -0.5, lamax: 51.6, lomax: -0.3 };

/**
 * `holdClock` makes waits resolve without moving time, so callers started
 * together really are queued at once; by default a wait advances the clock.
 */
function setup(opts: { maxWaitMs?: number; holdClock?: boolean } = {}) {
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
      if (!opts.holdClock) t += ms;
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
    now,
    advance: (ms: number) => {
      t += ms;
    },
  };
}

describe("TileCache with an upstream budget", () => {
  it("serves a recent cache instead of refreshing when another request is already waiting", async () => {
    const s = setup({ holdClock: true });
    await s.cache.get(BAY); // slot 1
    s.advance(11_000); // BAY is past its TTL
    // Started together: NYC takes the slot that is free now, LON queues for
    // the next one, so BAY's refresh would be third in line.
    const [, , bay] = await Promise.all([s.cache.get(NYC), s.cache.get(LON), s.cache.get(BAY)]);
    expect(bay.stale).toBe(true);
    expect(s.calls).toHaveLength(3);
    expect(s.events).toEqual([
      expect.objectContaining({ kind: "served-cache", cacheAgeSeconds: 11 }),
    ]);
  });

  it("waits out a request that just went out instead of serving the old cache", async () => {
    const s = setup();
    await s.cache.get(BAY);
    s.advance(11_000);
    await s.cache.get(NYC); // takes the slot that is free now
    const result = await s.cache.get(BAY); // next slot is 1 s away: waits for it
    expect(result.stale).toBe(false);
    expect(s.calls).toHaveLength(3);
    expect(s.events).toHaveLength(0);
  });

  it("keeps two tiles polled half a slot apart fresh on every poll", async () => {
    // 2026-10-26: phones in the East Bay and London polled every 10 s, less
    // than a slot apart. The second refresh lost every time, and London got
    // new planes only every 30 s.
    const s = setup();
    const ages: number[] = [];
    const poll = async (bbox: Bbox) => {
      const result = await s.cache.get(bbox);
      expect(result.stale).toBe(false);
      ages.push(Math.floor(s.now() / 1000) - result.snapshot.fetchedAt);
    };
    // A phone sleeps 10 s after each answer, so it polls every ~10.3 s.
    const start = s.now();
    const at = (ms: number) => s.advance(Math.max(0, start + ms - s.now()));
    for (let round = 0; round < 10; round++) {
      at(round * 10_300);
      await poll(BAY);
      at(round * 10_300 + 500);
      await poll(LON); // a refresh waits the other 500 ms
    }
    // Never older than one TTL; before the fix LON reached 20 s and 30 s.
    expect(Math.max(...ages)).toBeLessThanOrEqual(10);
    expect(s.events).toHaveLength(0);
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

  it("reports one refusal for a shared wait, however many callers share it", async () => {
    const s = setup({ maxWaitMs: 500 });
    await s.cache.get(BAY);
    const results = await Promise.allSettled([
      s.cache.get(NYC),
      s.cache.get(NYC),
      s.cache.get(NYC),
    ]);
    expect(results.every((r) => r.status === "rejected")).toBe(true);
    expect(s.events.filter((e) => e.kind === "refused")).toHaveLength(1);
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
