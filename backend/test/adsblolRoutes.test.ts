import { describe, expect, it, vi } from "vitest";
import {
  AdsbLolRouteService,
  parseRoute,
  parseRouteCandidates,
} from "../src/providers/adsblolRoutes.js";
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

/** A positioned aircraft with an explicit lat/lng and ground track — for the
 *  round-trip leg-pick, which reads position + track. `track` null models a
 *  feed with no reported track. */
function planeAt(
  callsign: string,
  latitude: number,
  longitude: number,
  track: number | null,
): NormalizedAircraft {
  return { ...plane("aaf968", callsign), latitude, longitude, trackDeg: track };
}

/** A 200 response for `GET /api/0/route/<callsign>` — the single route object.
 *  (The enricher switched from the batch POST /routeset to the per-callsign GET
 *  when adsb.lol's routeset started returning empty; return the first row.) */
function routeset(
  rows: Array<{
    callsign: string;
    airport_codes: string;
    _airports?: Array<{
      icao?: string;
      iata?: string;
      name?: string;
      location?: string;
      lat?: number;
      lon?: number;
    }>;
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

  it("returns null for a degenerate round trip (first == last)", () => {
    // An out-and-back filing collapses to the same airport at both ends —
    // which leg was being flown is unknowable, and "KLGA → KLGA" on a card
    // is worse than nothing (field report, 2026-07-05).
    expect(parseRoute("KLGA-KTEB-KLGA")).toBeNull();
    expect(parseRoute("KLGA-KLGA")).toBeNull();
  });

  it("carries IATA display codes from _airports, uppercased", () => {
    expect(
      parseRoute("RJTT-KSFO", [
        { icao: "RJTT", iata: "hnd", location: "Tokyo" },
        { icao: "KSFO", iata: "SFO", location: "San Francisco" },
      ]),
    ).toEqual({
      originIcao: "RJTT",
      destIcao: "KSFO",
      originIata: "HND",
      destIata: "SFO",
      originName: "Tokyo",
      destName: "San Francisco",
    });
    // Missing/blank iata → field omitted, ICAO remains the fallback.
    expect(parseRoute("RJTT-KSFO", [{ icao: "RJTT", iata: " " }])).toEqual({
      originIcao: "RJTT",
      destIcao: "KSFO",
    });
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

describe("round-trip leg disambiguation (A ⇄ B filings)", () => {
  // RPA5715's real adsb.lol filing: an out-and-back under one callsign. KPIT is
  // ~330 mi west of KLGA, so the two legs are near-reciprocal — the plane's
  // ground track cleanly separates outbound (westbound) from inbound (eastbound).
  const RPA5715_ROW = {
    callsign: "RPA5715",
    airport_codes: "KLGA-KPIT-KLGA",
    _airports: [
      { icao: "KLGA", iata: "LGA", location: "New York", lat: 40.777199, lon: -73.872597 },
      { icao: "KPIT", iata: "PIT", location: "Pittsburgh", lat: 40.491501, lon: -80.232903 },
      { icao: "KLGA", iata: "LGA", location: "New York", lat: 40.777199, lon: -73.872597 },
    ],
  };

  it("parseRouteCandidates yields a round trip with both legs + turnaround/home coords", () => {
    expect(parseRouteCandidates(RPA5715_ROW.airport_codes, RPA5715_ROW._airports)).toEqual({
      kind: "roundTrip",
      away: {
        originIcao: "KLGA",
        destIcao: "KPIT",
        originIata: "LGA",
        destIata: "PIT",
        originName: "New York",
        destName: "Pittsburgh",
      },
      back: {
        originIcao: "KPIT",
        destIcao: "KLGA",
        originIata: "PIT",
        destIata: "LGA",
        originName: "Pittsburgh",
        destName: "New York",
      },
      awayDest: { lat: 40.491501, lon: -80.232903 },
      backDest: { lat: 40.777199, lon: -73.872597 },
    });
  });

  it("parseRoute still collapses a round trip to null (one-shot resolver contract)", () => {
    expect(parseRoute(RPA5715_ROW.airport_codes, RPA5715_ROW._airports)).toBeNull();
  });

  it("an A-B-A without airport coordinates is not disambiguable → none", () => {
    expect(parseRouteCandidates("KLGA-KPIT-KLGA")).toEqual({ kind: "none" });
    expect(
      parseRouteCandidates("KLGA-KPIT-KLGA", [
        { icao: "KLGA", iata: "LGA" }, // no lat/lon
        { icao: "KPIT", iata: "PIT" },
      ]),
    ).toEqual({ kind: "none" });
  });

  it("a longer round trip (A-B-C-A) stays null — no single leg reduction", () => {
    expect(
      parseRouteCandidates("KLGA-KPIT-KORD-KLGA", [
        { icao: "KLGA", lat: 40.78, lon: -73.87 },
        { icao: "KPIT", lat: 40.49, lon: -80.23 },
        { icao: "KORD", lat: 41.98, lon: -87.9 },
      ]),
    ).toEqual({ kind: "none" });
  });

  /** A service with RPA5715's round-trip filing already cached. */
  async function warmService() {
    const fetchFn = vi.fn(async () => routeset([RPA5715_ROW])) as unknown as typeof fetch;
    const svc = new AdsbLolRouteService({ baseUrl: "https://example.test", fetchFn });
    await svc.prefetch([{ callsign: "RPA5715", lat: 40.75, lng: -74.1 }]);
    return svc;
  }

  it("enrich picks the outbound leg (LGA → PIT) for a westbound plane", async () => {
    const svc = await warmService();
    const ac = [planeAt("RPA5715", 40.75, -74.1, 260)]; // track points at PIT
    svc.enrich(ac);
    expect(ac[0].route).toMatchObject({ originIcao: "KLGA", destIcao: "KPIT", destIata: "PIT" });
  });

  it("enrich picks the inbound leg (PIT → LGA) for an eastbound plane", async () => {
    const svc = await warmService();
    const ac = [planeAt("RPA5715", 40.75, -74.5, 85)]; // track points back at LGA
    svc.enrich(ac);
    expect(ac[0].route).toMatchObject({ originIcao: "KPIT", destIcao: "KLGA", destIata: "LGA" });
  });

  it("enrich attaches nothing when the track points at neither end (ambiguous)", async () => {
    const svc = await warmService();
    const ac = [planeAt("RPA5715", 40.75, -74.3, 0)]; // northbound — neither airport
    svc.enrich(ac);
    expect(ac[0].route).toBeUndefined();
  });

  it("enrich attaches nothing when the feed reports no track", async () => {
    const svc = await warmService();
    const ac = [planeAt("RPA5715", 40.75, -74.1, null)];
    svc.enrich(ac);
    expect(ac[0].route).toBeUndefined();
  });

  it("resolve() (backfill, no live position) leaves a round trip null", async () => {
    const svc = await warmService();
    expect(await svc.resolve("RPA5715")).toBeNull();
  });

  it("the same cached round trip yields opposite legs as the plane turns around", async () => {
    const svc = await warmService();
    const outbound = [planeAt("RPA5715", 40.75, -74.1, 260)];
    const inbound = [planeAt("RPA5715", 40.75, -74.5, 85)];
    svc.enrich(outbound);
    svc.enrich(inbound);
    expect(outbound[0].route).toMatchObject({ destIcao: "KPIT" });
    expect(inbound[0].route).toMatchObject({ destIcao: "KLGA" });
  });
});
