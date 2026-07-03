import type { FastifyInstance } from "fastify";
import { afterEach, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import { AdsbLolRouteService } from "../src/providers/adsblolRoutes.js";
import type { AircraftRoute } from "../src/providers/types.js";

/**
 * GET /v1/routes/:callsign — the catch route-backfill endpoint, end to end via
 * app.inject() with an injected fake resolver (no network, no DB). The
 * resolver seam is what production wires to AdsbLolRouteService; its resolve()
 * behaviour has its own unit test below.
 */
describe("GET /v1/routes/:callsign", () => {
  let app: FastifyInstance;

  afterEach(async () => {
    await app?.close();
  });

  const route: AircraftRoute = {
    originIcao: "RJTT",
    destIcao: "KSFO",
    originName: "Tokyo",
    destName: "San Francisco",
  };

  it("returns the resolved route, uppercasing the callsign", async () => {
    const resolve = vi.fn(async () => route);
    app = await buildApp({ routeResolver: { resolve }, rateLimitNow: () => 0 });
    const res = await app.inject({ method: "GET", url: "/v1/routes/ana858" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ callsign: "ANA858", route });
    expect(resolve).toHaveBeenCalledWith("ANA858");
  });

  it("returns route: null as a normal 200 when nothing is on file", async () => {
    app = await buildApp({
      routeResolver: { resolve: async () => null },
      rateLimitNow: () => 0,
    });
    const res = await app.inject({ method: "GET", url: "/v1/routes/N4521C" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ callsign: "N4521C", route: null });
  });

  it("rejects garbage callsigns without touching the resolver", async () => {
    const resolve = vi.fn(async () => null);
    app = await buildApp({ routeResolver: { resolve }, rateLimitNow: () => 0 });
    for (const bad of ["a", "waytoolongcallsign", "AN%858"]) {
      const res = await app.inject({
        method: "GET",
        url: `/v1/routes/${encodeURIComponent(bad)}`,
      });
      expect(res.statusCode, bad).toBe(400);
    }
    expect(resolve).not.toHaveBeenCalled();
  });

  it("maps a resolver failure to 502 (client retries a later pass)", async () => {
    app = await buildApp({
      routeResolver: {
        resolve: async () => {
          throw new Error("upstream down");
        },
      },
      rateLimitNow: () => 0,
    });
    const res = await app.inject({ method: "GET", url: "/v1/routes/ANA858" });
    expect(res.statusCode).toBe(502);
  });

  it("rate limits per IP with Retry-After", async () => {
    app = await buildApp({
      routeResolver: { resolve: async () => null },
      rateLimitNow: () => 0, // frozen clock → the bucket never refills
    });
    let limited = 0;
    for (let i = 0; i < 125; i++) {
      const res = await app.inject({ method: "GET", url: "/v1/routes/ANA858" });
      if (res.statusCode === 429) {
        limited++;
        expect(res.headers["retry-after"]).toBeDefined();
      }
    }
    expect(limited).toBe(5); // capacity 120/min
  });

  it("is absent when no resolver is configured", async () => {
    app = await buildApp({ rateLimitNow: () => 0 }); // NODE_ENV=test → no default service
    const res = await app.inject({ method: "GET", url: "/v1/routes/ANA858" });
    expect(res.statusCode).toBe(404);
  });
});

describe("AdsbLolRouteService.resolve", () => {
  it("cache-first: one upstream GET, then map reads", async () => {
    const fetchFn = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            callsign: "ANA858",
            airport_codes: "RJTT-KSFO",
            _airports: [
              { icao: "RJTT", location: "Tokyo" },
              { icao: "KSFO", location: "San Francisco" },
            ],
          }),
          { status: 200 },
        ),
    );
    const svc = new AdsbLolRouteService({ baseUrl: "https://example.test", fetchFn });
    const first = await svc.resolve("ANA858");
    expect(first).toEqual({
      originIcao: "RJTT",
      destIcao: "KSFO",
      originName: "Tokyo",
      destName: "San Francisco",
    });
    const second = await svc.resolve("ANA858");
    expect(second).toEqual(first);
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });

  it("negative-caches a 404 as null", async () => {
    const fetchFn = vi.fn(async () => new Response("", { status: 404 }));
    const svc = new AdsbLolRouteService({ baseUrl: "https://example.test", fetchFn });
    expect(await svc.resolve("N4521C")).toBeNull();
    expect(await svc.resolve("N4521C")).toBeNull();
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });
});
