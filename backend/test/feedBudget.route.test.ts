import type { FastifyInstance } from "fastify";
import { afterEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { PositionProvider, ProviderSnapshot } from "../src/providers/types.js";
import { UpstreamBudget } from "../src/providers/upstreamBudget.js";

/**
 * App-level wiring: the budget passed to buildApp actually gates the aircraft
 * route's upstream fetches, and a refusal is a 503 that does not turn /readyz
 * red (load shedding is not a feed failure).
 */
const BAY = "lamin=37.6&lomin=-122.5&lamax=37.9&lomax=-122.2";
const NYC = "lamin=40.6&lomin=-74.1&lamax=40.8&lomax=-73.9";

describe("upstream budget wired through buildApp", () => {
  let app: FastifyInstance | undefined;
  afterEach(async () => {
    await app?.close();
    app = undefined;
  });

  async function build() {
    let t = 1_700_000_000_000;
    let calls = 0;
    const provider: PositionProvider = {
      name: "stub",
      async aircraftInBbox(): Promise<ProviderSnapshot> {
        calls++;
        return { fetchedAt: Math.floor(t / 1000), aircraft: [] };
      },
    };
    const now = () => t;
    // A budget that never waits: maxWait is 2 s, the interval 10 s, so a
    // second cold tile inside the interval is refused at once.
    const budget = new UpstreamBudget({ ratePerSecond: 0.1, now, sleep: async () => {} });
    app = await buildApp({
      provider,
      now,
      upstreamBudget: budget,
      cacheConfig: { ttlSeconds: 10, staleMaxSeconds: 60, tileSizeDeg: 0.25 },
      readyProbe: async () => {},
      canaryBbox: { lamin: 37.6, lomin: -122.5, lamax: 37.9, lomax: -122.2 },
    });
    return {
      app,
      calls: () => calls,
      advance: (ms: number) => {
        t += ms;
      },
    };
  }

  it("serves cache instead of refreshing when the budget is spent", async () => {
    const h = await build();
    expect((await h.app.inject(`/v1/aircraft?${BAY}`)).statusCode).toBe(200);
    h.advance(11_000);
    // No slot until t+10 s from the first grant... which has just arrived, so
    // spend it on another tile first.
    expect((await h.app.inject(`/v1/aircraft?${NYC}`)).statusCode).toBe(200);
    const res = await h.app.inject(`/v1/aircraft?${BAY}`);
    expect(res.statusCode).toBe(200);
    expect(h.calls()).toBe(2);
  });

  it("503s a cold tile it cannot fetch, without failing readiness", async () => {
    const h = await build();
    expect((await h.app.inject(`/v1/aircraft?${BAY}`)).statusCode).toBe(200);
    const res = await h.app.inject(`/v1/aircraft?${NYC}`);
    expect(res.statusCode).toBe(503);
    expect(h.calls()).toBe(1);
    const ready = await h.app.inject("/readyz");
    expect(ready.statusCode).toBe(200);
  });
});
