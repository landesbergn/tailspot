import type { FastifyInstance } from "fastify";
import { afterEach, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import type { Bbox, PositionProvider, ProviderSnapshot } from "../src/providers/types.js";
import { UpstreamError } from "../src/providers/types.js";
import { DEFAULT_CANARY_BBOX, type FeedProbeResult } from "../src/routes/feedProbe.js";

/**
 * /readyz is the ONE URL the external uptime monitor watches, so it has to
 * answer for the database AND the position feed. Every case here injects a
 * stub provider: without one, buildApp() selects the real adsb.lol client and
 * the canary would hit the network from the test suite.
 */

interface ReadyBody {
  status: "ok" | "unavailable";
  checks: { db: string; feed: string };
}

/** Controllable stub feed: counts calls, records bboxes, can fail or hang. */
class StubProvider implements PositionProvider {
  readonly name = "stub";
  calls: Bbox[] = [];
  shouldFail = false;
  hang = false;
  fetchedAt = 1_700_000_100;

  async aircraftInBbox(bbox: Bbox): Promise<ProviderSnapshot> {
    this.calls.push(bbox);
    if (this.hang) return new Promise(() => {});
    if (this.shouldFail) throw new UpstreamError("stub upstream down");
    return { fetchedAt: this.fetchedAt, aircraft: [] };
  }
}

describe("GET /readyz", () => {
  let app: FastifyInstance | undefined;

  afterEach(async () => {
    vi.useRealTimers();
    await app?.close();
    app = undefined;
  });

  const dbOk = async () => {};
  const dbDown = async () => {
    throw new Error("connection refused");
  };

  async function build(opts: {
    db?: () => Promise<void>;
    provider?: PositionProvider;
    now?: () => number;
    canaryBbox?: Bbox;
  }): Promise<FastifyInstance> {
    app = await buildApp({
      readyProbe: opts.db ?? dbOk,
      provider: opts.provider ?? new StubProvider(),
      cacheConfig: { ttlSeconds: 10, staleMaxSeconds: 60, tileSizeDeg: 0.25 },
      now: opts.now,
      canaryBbox: opts.canaryBbox,
    });
    return app;
  }

  it("responds 200 with both checks ok when the DB answers and the feed serves", async () => {
    const a = await build({});
    const res = await a.inject({ method: "GET", url: "/readyz" });
    expect(res.statusCode).toBe(200);
    expect(res.json<ReadyBody>()).toEqual({ status: "ok", checks: { db: "ok", feed: "ok" } });
  });

  it("responds 503 and names the DB when the DB probe rejects, even with a healthy feed", async () => {
    const a = await build({ db: dbDown });
    const res = await a.inject({ method: "GET", url: "/readyz" });
    expect(res.statusCode).toBe(503);
    expect(res.json<ReadyBody>()).toEqual({
      status: "unavailable",
      checks: { db: "unavailable", feed: "ok" },
    });
  });

  it("responds 503 and names the feed when the upstream fails with no cache (the 2026-10 outage)", async () => {
    // This is exactly the state that stayed green for sixteen days: process up,
    // DB fine, every /v1/aircraft call 503. /readyz must be red here.
    const provider = new StubProvider();
    provider.shouldFail = true;
    const a = await build({ provider });
    const res = await a.inject({ method: "GET", url: "/readyz" });
    expect(res.statusCode).toBe(503);
    expect(res.json<ReadyBody>()).toEqual({
      status: "unavailable",
      checks: { db: "ok", feed: "unavailable" },
    });
  });

  it("stays 200 but reports 'stale' while the cache's last-good window covers an upstream failure", async () => {
    let nowMs = 1_700_000_000_000;
    const provider = new StubProvider();
    const a = await build({ provider, now: () => nowMs });

    const first = await a.inject({ method: "GET", url: "/readyz" });
    expect(first.json<ReadyBody>().checks.feed).toBe("ok");

    // Past the 10 s fresh TTL, inside the 60 s stale window, upstream now dead.
    provider.shouldFail = true;
    nowMs += 15_000;
    const second = await a.inject({ method: "GET", url: "/readyz" });
    expect(second.statusCode).toBe(200);
    expect(second.json<ReadyBody>()).toEqual({ status: "ok", checks: { db: "ok", feed: "stale" } });

    // Past the stale window there is nothing left to serve.
    nowMs += 60_000;
    const third = await a.inject({ method: "GET", url: "/readyz" });
    expect(third.statusCode).toBe(503);
    expect(third.json<ReadyBody>().checks.feed).toBe("unavailable");
  });

  it("probes through the shared tile cache: repeated checks inside the TTL cost one upstream call", async () => {
    // The uptime monitor hits this once a minute from three regions; the cache
    // is what keeps that from becoming three upstream requests per minute.
    const provider = new StubProvider();
    const a = await build({ provider });
    await a.inject({ method: "GET", url: "/readyz" });
    await a.inject({ method: "GET", url: "/readyz" });
    await a.inject({ method: "GET", url: "/readyz" });
    expect(provider.calls).toHaveLength(1);
  });

  it("shares its tile with phones looking at the same sky (no second upstream code path)", async () => {
    const provider = new StubProvider();
    const a = await build({ provider });
    await a.inject({ method: "GET", url: "/readyz" });
    const { lamin, lomin, lamax, lomax } = DEFAULT_CANARY_BBOX;
    const res = await a.inject({
      method: "GET",
      url: `/v1/aircraft?lamin=${lamin}&lomin=${lomin}&lamax=${lamax}&lomax=${lomax}`,
    });
    expect(res.statusCode).toBe(200);
    expect(provider.calls).toHaveLength(1);
  });

  it("fetches the configured canary bbox (expanded to its cache tile)", async () => {
    const provider = new StubProvider();
    const canary: Bbox = { lamin: -8.9, lomin: 115.0, lamax: -8.5, lomax: 115.4 }; // Bali
    const a = await build({ provider, canaryBbox: canary });
    await a.inject({ method: "GET", url: "/readyz" });
    expect(provider.calls).toHaveLength(1);
    const fetched = provider.calls[0];
    // The cache fetches the tile that covers the request, never less than it.
    expect(fetched.lamin).toBeLessThanOrEqual(canary.lamin);
    expect(fetched.lomin).toBeLessThanOrEqual(canary.lomin);
    expect(fetched.lamax).toBeGreaterThanOrEqual(canary.lamax);
    expect(fetched.lomax).toBeGreaterThanOrEqual(canary.lomax);
    // And it is nowhere near the default: a misrouted canary would be useless.
    expect(fetched.lamin).toBeLessThan(0);
  });

  it("responds 503 with no DB probe injected and no DATABASE_URL (default probe can't reach a DB)", async () => {
    // The default probe calls getDb(), which throws without DATABASE_URL —
    // /readyz must report that as 503-not-ready, never crash the process.
    app = await buildApp({ provider: new StubProvider() });
    const res = await app.inject({ method: "GET", url: "/readyz" });
    expect(res.statusCode).toBe(503);
    expect(res.json<ReadyBody>().checks.db).toBe("unavailable");
  });

  it("responds 503 when the DB probe hangs past its 3 s budget (fake timers)", async () => {
    // A hung DB socket must not drag /readyz past the uptime monitor's own
    // request timeout — the race turns "hanging" into a fast 503.
    vi.useFakeTimers();
    const a = await build({ db: () => new Promise(() => {}) });
    const pending = a.inject({ method: "GET", url: "/readyz" });
    await vi.advanceTimersByTimeAsync(3_100);
    const res = await pending;
    expect(res.statusCode).toBe(503);
    expect(res.json<ReadyBody>().checks.db).toBe("unavailable");
  });

  it("responds 503 'timeout' when the feed probe hangs past its 4 s budget (fake timers)", async () => {
    // An upstream that accepts the connection and never answers is the other
    // way to be down; the 4 s budget keeps the whole answer inside 5 s.
    vi.useFakeTimers();
    const provider = new StubProvider();
    provider.hang = true;
    const a = await build({ provider });
    const pending = a.inject({ method: "GET", url: "/readyz" });
    await vi.advanceTimersByTimeAsync(4_100);
    const res = await pending;
    expect(res.statusCode).toBe(503);
    expect(res.json<ReadyBody>()).toEqual({
      status: "unavailable",
      checks: { db: "ok", feed: "timeout" },
    });
  });

  it("accepts an injected feed probe result verbatim (test seam)", async () => {
    app = await buildApp({
      readyProbe: dbOk,
      provider: new StubProvider(),
      feedProbe: async () => ({ status: "unavailable", error: new Error("canned") }),
    });
    const res = await app.inject({ method: "GET", url: "/readyz" });
    expect(res.statusCode).toBe(503);
    expect(res.json<ReadyBody>().checks.feed).toBe("unavailable");
  });
});

describe("GET /readyz probe robustness", () => {
  it("treats a probe that throws synchronously as 503, not 500", async () => {
    const app = await buildApp({
      readyProbe: () => {
        throw new Error("sync misconfiguration");
      },
      provider: new StubProvider(),
      feedProbe: (() => {
        throw new Error("sync misconfiguration");
      }) as unknown as () => Promise<FeedProbeResult>,
    });
    try {
      const res = await app.inject({ method: "GET", url: "/readyz" });
      expect(res.statusCode).toBe(503);
      expect(res.json<ReadyBody>().checks).toEqual({ db: "unavailable", feed: "unavailable" });
    } finally {
      await app.close();
    }
  });
});
