import { describe, expect, it } from "vitest";
import type { Bbox, PositionProvider, ProviderSnapshot } from "../src/providers/types.js";
import { UpstreamBudget } from "../src/providers/upstreamBudget.js";
import { NoFreshDataError, type ThrottleEvent, TileCache } from "../src/routes/tileCache.js";
import { manualClock } from "./helpers/manualClock.js";

const BAY: Bbox = { lamin: 37.6, lomin: -122.5, lamax: 37.9, lomax: -122.2 };
const NYC: Bbox = { lamin: 40.6, lomin: -74.1, lamax: 40.8, lomax: -73.9 };
const LON: Bbox = { lamin: 51.4, lomin: -0.5, lamax: 51.6, lomax: -0.3 };

/**
 * By default a wait advances the clock and resolves at once. `manual` parks
 * every wait until the test steps `clock`, so waits genuinely overlap.
 */
function setup(opts: { maxWaitMs?: number; manual?: boolean } = {}) {
  const clock = manualClock();
  const calls: Bbox[] = [];
  const provider: PositionProvider = {
    name: "stub",
    async aircraftInBbox(bbox): Promise<ProviderSnapshot> {
      calls.push(bbox);
      return { fetchedAt: Math.floor(clock.now() / 1000), aircraft: [] };
    },
  };
  const events: ThrottleEvent[] = [];
  let granted = 0;
  const now = clock.now;
  const budget = new UpstreamBudget({
    ratePerSecond: 1,
    now,
    sleep: opts.manual ? clock.sleep : async (ms) => clock.advance(ms),
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
    clock,
    advance: clock.advance,
  };
}

describe("TileCache with an upstream budget", () => {
  it("serves a recent cache at once when its turn can't come within maxWaitMs", async () => {
    const s = setup({ manual: true, maxWaitMs: 1_500 });
    await s.cache.get(BAY); // slot 1
    s.advance(11_000); // BAY is past its TTL
    // NYC takes the slot that is free now and cold LON reserves the next, so
    // BAY's refresh would wait 2 s, past its 1.5 s allowance.
    const nyc = s.cache.get(NYC);
    const lon = s.cache.get(LON);
    const bay = await s.cache.get(BAY); // answered without waiting
    expect(bay.stale).toBe(true);
    expect(s.events).toEqual([
      expect.objectContaining({ kind: "served-cache", cacheAgeSeconds: 11 }),
    ]);
    await s.clock.runAll();
    await Promise.all([nyc, lon]);
    expect(s.calls).toHaveLength(3);
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

  it("lets a cold tile go ahead of a refresh that is waiting for a slot", async () => {
    // Review of #393: had the waiting refresh reserved its slot, the cold
    // tile behind it would wait 1.9 s, past maxWaitMs, and 503.
    const s = setup({ manual: true, maxWaitMs: 1_500 });
    await s.cache.get(BAY); // cold, slot free now
    s.advance(11_000);
    await s.cache.get(NYC); // takes the slot that is free now
    s.advance(50);
    const bay = s.cache.get(BAY); // refresh: in line for the slot 950 ms away
    s.advance(50);
    const lon = s.cache.get(LON); // cold: takes that same slot, 900 ms away
    expect(s.clock.parkedWaits()).toEqual([950, 900]);
    // BAY's turn moved to 1.9 s away, past its 1.5 s: it answers from cache now.
    expect((await bay).stale).toBe(true);
    await s.clock.runAll();
    expect((await lon).stale).toBe(false);
    expect(s.events).toEqual([expect.objectContaining({ kind: "served-cache" })]);
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

  it("keeps three tiles inside one slot window fresh on every poll", async () => {
    // Review of #393: with refreshes aiming at the same unreserved slot, the
    // third of three in-step tiles lost every round.
    const s = setup({ manual: true });
    const ages: number[] = [];
    const start = s.now();
    for (let round = 0; round < 10; round++) {
      const pending = [BAY, LON, NYC].map((bbox, i) => {
        s.advance(Math.max(0, start + round * 10_300 + i * 300 - s.now()));
        return s.cache.get(bbox);
      });
      await s.clock.runAll();
      for (const result of await Promise.all(pending)) {
        expect(result.stale).toBe(false);
        ages.push(Math.floor(s.now() / 1000) - result.snapshot.fetchedAt);
      }
    }
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
