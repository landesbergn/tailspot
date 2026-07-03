import { describe, expect, it, vi } from "vitest";
import { AdsbLolRouteService, parseRoute } from "../src/providers/adsblolRoutes.js";
import type { NormalizedAircraft } from "../src/providers/types.js";

/** A minimal positioned aircraft with a given callsign. */
function plane(icao: string, callsign: string | null): NormalizedAircraft {
  return {
    icao24: icao,
    callsign,
    originCountry: "United States",
    longitude: -122.4,
    latitude: 37.7,
    altitudeMeters: 3000,
    velocityMps: 200,
    trackDeg: 90,
    onGround: false,
    positionTimestamp: 1_700_000_000,
  };
}

/** A 200 response for `GET /api/0/route/<callsign>` — the single route object.
 *  (The enricher switched from the batch POST /routeset to the per-callsign GET
 *  when adsb.lol's routeset started returning empty; return the first row.) */
function routeset(
  rows: Array<{
    callsign: string;
    airport_codes: string;
    _airports?: Array<{ icao?: string; name?: string; location?: string }>;
  }>,
): Response {
  return new Response(JSON.stringify(rows[0]), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

describe("parseRoute", () => {
  it("splits ICAO airport_codes into origin → destination", () => {
    expect(parseRoute("KSFO-EGLL")).toEqual({ originIcao: "KSFO", destIcao: "EGLL" });
  });

  it("collapses a multi-leg route to first → last", () => {
    expect(parseRoute("KSFO-KDEN-EGLL")).toEqual({ originIcao: "KSFO", destIcao: "EGLL" });
  });

  it("returns null for the 'unknown' sentinel, blanks, single codes, and non-strings", () => {
    expect(parseRoute("unknown")).toBeNull();
    expect(parseRoute("Unknown")).toBeNull();
    expect(parseRoute("")).toBeNull();
    expect(parseRoute("   ")).toBeNull();
    expect(parseRoute("KSFO")).toBeNull(); // only one airport → no journey
    expect(parseRoute(undefined)).toBeNull();
  });

  it("enriches origin/dest with airport city names from _airports", () => {
    expect(
      parseRoute("KSFO-EGLL", [
        { icao: "KSFO", name: "San Francisco International Airport", location: "San Francisco" },
        { icao: "EGLL", name: "London Heathrow Airport", location: "London" },
      ]),
    ).toEqual({
      originIcao: "KSFO",
      destIcao: "EGLL",
      originName: "San Francisco",
      destName: "London",
    });
  });

  it("prefers city (location), falling back to the airport name when location is blank", () => {
    expect(
      parseRoute("KSUU-PHIK", [
        { icao: "KSUU", name: "Travis Air Force Base", location: "" },
        { icao: "PHIK", name: "Hickam AFB", location: "Honolulu" },
      ]),
    ).toEqual({
      originIcao: "KSUU",
      destIcao: "PHIK",
      originName: "Travis Air Force Base",
      destName: "Honolulu",
    });
  });

  it("omits names when _airports is absent or has no matching ICAO", () => {
    expect(parseRoute("KSFO-EGLL")).toEqual({ originIcao: "KSFO", destIcao: "EGLL" });
    expect(parseRoute("KSFO-EGLL", [{ icao: "KZZZ", location: "Nowhere" }])).toEqual({
      originIcao: "KSFO",
      destIcao: "EGLL",
    });
  });
});

describe("AdsbLolRouteService", () => {
  it("GETs the standing-data URL first (routes/<CS[0:2]>/<CS>.json)", async () => {
    // The API's /api/0/route hop stalled ~6 s from Fly (IPv6-before-v4),
    // silently breaking all enrichment — the primary lookup now goes straight
    // to the standing-data host the API 302s to.
    let calledUrl = "";
    let method = "";
    const fetchFn = (async (url: string | URL, init?: RequestInit) => {
      calledUrl = String(url);
      method = init?.method ?? "GET";
      return routeset([{ callsign: "UAL875", airport_codes: "KSFO-EGLL" }]);
    }) as unknown as typeof fetch;

    const svc = new AdsbLolRouteService({
      baseUrl: "https://example.test",
      standingDataBaseUrl: "https://sd.example.test",
      fetchFn,
    });
    await svc.prefetch([{ callsign: "UAL875", lat: 37.82, lng: -122.45 }]);

    expect(calledUrl).toBe("https://sd.example.test/routes/UA/UAL875.json");
    expect(method).toBe("GET");
  });

  it("falls back to the API URL on a standing-data transport error — not on 404", async () => {
    const calls: string[] = [];
    const fetchFn = (async (url: string | URL) => {
      calls.push(String(url));
      if (String(url).includes("sd.example.test")) throw new Error("connect timeout");
      return routeset([{ callsign: "UAL875", airport_codes: "KSFO-EGLL" }]);
    }) as unknown as typeof fetch;
    const svc = new AdsbLolRouteService({
      baseUrl: "https://example.test",
      standingDataBaseUrl: "https://sd.example.test",
      fetchFn,
    });

    expect(await svc.resolve("UAL875")).toEqual({ originIcao: "KSFO", destIcao: "EGLL" });
    expect(calls).toEqual([
      "https://sd.example.test/routes/UA/UAL875.json",
      "https://example.test/api/0/route/UAL875",
    ]);

    // A standing-data 404 is authoritative: no API fallback call.
    const calls404: string[] = [];
    const fetch404 = (async (url: string | URL) => {
      calls404.push(String(url));
      return new Response("", { status: 404 });
    }) as unknown as typeof fetch;
    const svc404 = new AdsbLolRouteService({
      baseUrl: "https://example.test",
      standingDataBaseUrl: "https://sd.example.test",
      fetchFn: fetch404,
    });
    expect(await svc404.resolve("N4521C")).toBeNull();
    expect(calls404).toEqual(["https://sd.example.test/routes/N4/N4521C.json"]);
  });

  it("attaches origin → destination once the lookup has populated the cache", async () => {
    const fetchFn = vi.fn(async () =>
      routeset([{ callsign: "UAL875", airport_codes: "KSFO-EGLL" }]),
    ) as unknown as typeof fetch;
    const svc = new AdsbLolRouteService({ baseUrl: "https://example.test", fetchFn });

    await svc.prefetch([{ callsign: "UAL875", lat: 37.7, lng: -122.4 }]);
    const ac = [plane("a92d6d", "UAL875")];
    svc.enrich(ac);

    expect(ac[0].route).toEqual({ originIcao: "KSFO", destIcao: "EGLL" });
  });

  it("attaches human-readable city names when the routeset row carries _airports", async () => {
    const fetchFn = vi.fn(async () =>
      routeset([
        {
          callsign: "UAL875",
          airport_codes: "KSFO-EGLL",
          _airports: [
            { icao: "KSFO", location: "San Francisco" },
            { icao: "EGLL", location: "London" },
          ],
        },
      ]),
    ) as unknown as typeof fetch;
    const svc = new AdsbLolRouteService({ baseUrl: "https://example.test", fetchFn });

    await svc.prefetch([{ callsign: "UAL875", lat: 37.7, lng: -122.4 }]);
    const ac = [plane("a92d6d", "UAL875")];
    svc.enrich(ac);

    expect(ac[0].route).toEqual({
      originIcao: "KSFO",
      destIcao: "EGLL",
      originName: "San Francisco",
      destName: "London",
    });
  });

  it("enrich never blocks: cold cache attaches nothing but fires one deduped lookup", async () => {
    const fetchFn = vi.fn(async () =>
      routeset([{ callsign: "UAL875", airport_codes: "KSFO-EGLL" }]),
    ) as unknown as typeof fetch;
    const svc = new AdsbLolRouteService({ baseUrl: "https://example.test", fetchFn });

    // First pass: cache miss → no route attached, lookup scheduled in background.
    const ac = [plane("a92d6d", "UAL875")];
    svc.enrich(ac);
    expect(ac[0].route).toBeUndefined();
    expect(fetchFn).toHaveBeenCalledTimes(1);

    // Same callsign still in flight → a concurrent enrich issues no 2nd GET.
    svc.enrich([plane("bbbbbb", "UAL875")]);
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });

  it("treats a 404 as 'no route' — negative-cached, not an error", async () => {
    const errors: unknown[] = [];
    const fetchFn = vi.fn(async () => new Response("", { status: 404 })) as unknown as typeof fetch;
    const svc = new AdsbLolRouteService({
      baseUrl: "https://example.test",
      fetchFn,
      onError: (e) => errors.push(e),
    });

    await svc.prefetch([{ callsign: "GA123", lat: 37.7, lng: -122.4 }]);
    const ac = [plane("d", "GA123")];
    svc.enrich(ac);
    expect(ac[0].route).toBeUndefined();
    expect(errors).toHaveLength(0); // 404 = normal "no route", not a failure
    expect(fetchFn).toHaveBeenCalledTimes(1); // negative-cached → no repeat lookup
  });

  it("caches by callsign — a cached route is not looked up again", async () => {
    const fetchFn = vi.fn(async () =>
      routeset([{ callsign: "UAL875", airport_codes: "KSFO-EGLL" }]),
    ) as unknown as typeof fetch;
    const svc = new AdsbLolRouteService({ baseUrl: "https://example.test", fetchFn });

    await svc.prefetch([{ callsign: "UAL875", lat: 37.7, lng: -122.4 }]);
    svc.enrich([plane("a", "UAL875")]);
    svc.enrich([plane("b", "UAL875")]);
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });

  it("negative-caches a callsign with no known route (no repeat lookups)", async () => {
    const fetchFn = vi.fn(async () =>
      routeset([{ callsign: "BLOCK1", airport_codes: "unknown" }]),
    ) as unknown as typeof fetch;
    const svc = new AdsbLolRouteService({ baseUrl: "https://example.test", fetchFn });

    await svc.prefetch([{ callsign: "BLOCK1", lat: 37.7, lng: -122.4 }]);
    const ac = [plane("c", "BLOCK1")];
    svc.enrich(ac);
    expect(ac[0].route).toBeUndefined();
    expect(fetchFn).toHaveBeenCalledTimes(1); // negative cache → no new lookup
  });

  it("NEVER throws on a lookup failure and leaves the callsign uncached (retries)", async () => {
    const errors: unknown[] = [];
    const fetchFn = vi.fn(
      async () => new Response("nope", { status: 503 }),
    ) as unknown as typeof fetch;
    const svc = new AdsbLolRouteService({
      baseUrl: "https://example.test",
      fetchFn,
      onError: (e) => errors.push(e),
    });

    await expect(
      svc.prefetch([{ callsign: "UAL875", lat: 37.7, lng: -122.4 }]),
    ).resolves.toBeUndefined();
    // A total failure now surfaces TWO errors per attempt: the standing-data
    // primary, then the API fallback (both hit the same failing fetchFn here).
    expect(errors).toHaveLength(2);

    // Not cached → enrich re-attempts the lookup rather than giving up.
    // 3 calls at assert time: attempt 1's primary + fallback (awaited above),
    // plus attempt 2's primary, which enrich's detached prefetch starts
    // synchronously — its fallback lands on a later microtask.
    const ac = [plane("a92d6d", "UAL875")];
    svc.enrich(ac);
    expect(ac[0].route).toBeUndefined();
    expect(fetchFn).toHaveBeenCalledTimes(3);
  });

  it("does not throw when the network rejects (timeout/abort)", async () => {
    const fetchFn = vi.fn(async () => {
      throw new Error("network down");
    }) as unknown as typeof fetch;
    const svc = new AdsbLolRouteService({ baseUrl: "https://example.test", fetchFn });
    await expect(
      svc.prefetch([{ callsign: "UAL875", lat: 37.7, lng: -122.4 }]),
    ).resolves.toBeUndefined();
  });

  it("re-looks-up after the cache entry expires", async () => {
    let nowMs = 1_000_000;
    const fetchFn = vi.fn(async () =>
      routeset([{ callsign: "UAL875", airport_codes: "KSFO-EGLL" }]),
    ) as unknown as typeof fetch;
    const svc = new AdsbLolRouteService({
      baseUrl: "https://example.test",
      fetchFn,
      now: () => nowMs,
      ttlMs: 1000,
    });

    await svc.prefetch([{ callsign: "UAL875", lat: 37.7, lng: -122.4 }]);
    svc.enrich([plane("a", "UAL875")]); // fresh hit
    expect(fetchFn).toHaveBeenCalledTimes(1);

    nowMs += 2000; // expire the entry
    svc.enrich([plane("b", "UAL875")]); // miss → new background lookup
    expect(fetchFn).toHaveBeenCalledTimes(2);
  });

  it("skips aircraft without a callsign", async () => {
    const fetchFn = vi.fn(async () => routeset([])) as unknown as typeof fetch;
    const svc = new AdsbLolRouteService({ baseUrl: "https://example.test", fetchFn });
    svc.enrich([plane("a", null)]);
    expect(fetchFn).not.toHaveBeenCalled();
  });
});
