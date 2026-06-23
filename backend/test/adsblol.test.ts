import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  AdsbLolProvider,
  type AdsbLolResponse,
  normalizeAdsbLol,
} from "../src/providers/adsblol.js";
import type { Bbox } from "../src/providers/types.js";
import { mustGet } from "./helpers.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = JSON.parse(
  readFileSync(join(__dirname, "fixtures/adsblol-point.json"), "utf8"),
) as AdsbLolResponse;

const FEET_TO_M = 0.3048;
const KNOTS_TO_MPS = 0.514444;

// fetchedAt derived from fixture `now` (ms → s): 1781116526502 / 1000 floored.
const FETCHED_AT = Math.floor((FIXTURE.now as number) / 1000);

// A bbox covering the SF-area fixture entries but NOT the mid-Atlantic decoy.
const SF_BBOX: Bbox = { lamin: 37.0, lomin: -123.0, lamax: 38.0, lomax: -122.0 };

describe("normalizeAdsbLol", () => {
  const result = normalizeAdsbLol(FIXTURE, FETCHED_AT, SF_BBOX);
  const byHex = new Map(result.map((a) => [a.icao24, a]));

  it("drops the '~'-prefixed (non-ICAO TIS-B) entry", () => {
    expect([...byHex.keys()].some((h) => h.startsWith("~"))).toBe(false);
    expect(byHex.has("2b2e72")).toBe(false);
  });

  it("drops entries with no lat/lon (lossy per-element)", () => {
    expect(byHex.has("ad4f29")).toBe(false);
  });

  it("filters out aircraft outside the requested bbox", () => {
    // RYR1234 at 12.5N/-50W is well outside the SF bbox.
    expect(byHex.has("4ca8e1")).toBe(false);
  });

  it("keeps the in-bbox aircraft (3 of 6 fixture rows survive)", () => {
    expect(result.length).toBe(3);
    expect(byHex.has("a92d6d")).toBe(true);
    expect(byHex.has("86e4b8")).toBe(true);
    expect(byHex.has("3c6444")).toBe(true);
  });

  it("converts geometric altitude FEET → meters (preferred over baro)", () => {
    const ua = mustGet(byHex, "a92d6d");
    // alt_geom 10900 ft preferred over alt_baro 10400.
    expect(ua.altitudeMeters).toBeCloseTo(10900 * FEET_TO_M, 3);
  });

  it("falls back to barometric altitude when alt_geom is null", () => {
    const dlh = mustGet(byHex, "3c6444");
    // alt_geom null → use alt_baro 36000 ft.
    expect(dlh.altitudeMeters).toBeCloseTo(36000 * FEET_TO_M, 3);
  });

  it("treats alt_baro 'ground' as onGround with 0 altitude", () => {
    const jal = mustGet(byHex, "86e4b8");
    expect(jal.onGround).toBe(true);
    expect(jal.altitudeMeters).toBe(0);
  });

  it("converts ground speed KNOTS → m/s", () => {
    const ua = mustGet(byHex, "a92d6d");
    expect(ua.velocityMps).toBeCloseTo(291.7 * KNOTS_TO_MPS, 3);
  });

  it("passes track through in degrees, null when absent", () => {
    expect(mustGet(byHex, "a92d6d").trackDeg).toBeCloseTo(311.94, 4);
    expect(mustGet(byHex, "86e4b8").trackDeg).toBeNull(); // ground row, track null
  });

  it("trims the padded callsign, null when blank", () => {
    expect(mustGet(byHex, "a92d6d").callsign).toBe("UAL875");
    expect(mustGet(byHex, "86e4b8").callsign).toBe("JAL58");
  });

  it("passes the readsb DB typecode + registration through (incl. foreign tails)", () => {
    const ua = mustGet(byHex, "a92d6d");
    expect(ua.typecode).toBe("B772");
    expect(ua.registration).toBe("N69020");
    // A German A340 — proves a foreign (non-US) airframe carries type + reg,
    // the exact case the FAA-only metadata endpoint can't resolve.
    const dlh = mustGet(byHex, "3c6444");
    expect(dlh.typecode).toBe("A346");
    expect(dlh.registration).toBe("D-AIHK");
  });

  it("omits typecode/registration when the upstream row lacks them or they're blank", () => {
    const resp: AdsbLolResponse = {
      now: FIXTURE.now,
      ac: [
        // no t/r at all
        { hex: "abc123", flight: "NONE1", lat: 37.5, lon: -122.5, alt_baro: 30000, seen_pos: 1.0 },
        // blank-string t/r → trimmed away to undefined (never "" on the wire)
        {
          hex: "def456",
          flight: "NONE2",
          lat: 37.6,
          lon: -122.4,
          alt_baro: 30000,
          seen_pos: 1.0,
          t: "  ",
          r: "",
        },
      ],
    };
    const m = new Map(normalizeAdsbLol(resp, FETCHED_AT, SF_BBOX).map((a) => [a.icao24, a]));
    expect(mustGet(m, "abc123").typecode).toBeUndefined();
    expect(mustGet(m, "abc123").registration).toBeUndefined();
    expect(mustGet(m, "def456").typecode).toBeUndefined();
    expect(mustGet(m, "def456").registration).toBeUndefined();
  });

  it("lowercases the hex", () => {
    for (const a of result) expect(a.icao24).toBe(a.icao24.toLowerCase());
  });

  it("derives positionTimestamp = fetchedAt - seen_pos (seconds)", () => {
    const ua = mustGet(byHex, "a92d6d"); // seen_pos 0.6
    expect(ua.positionTimestamp).toBe(Math.round(FETCHED_AT - 0.6));
    const dlh = mustGet(byHex, "3c6444"); // seen_pos 2.0
    expect(dlh.positionTimestamp).toBe(FETCHED_AT - 2);
  });

  it("derives originCountry from icao24 (US, Germany, Japan)", () => {
    expect(mustGet(byHex, "a92d6d").originCountry).toBe("United States");
    expect(mustGet(byHex, "3c6444").originCountry).toBe("Germany");
    expect(mustGet(byHex, "86e4b8").originCountry).toBe("Japan");
  });

  it("with bbox=null, keeps all positioned rows including the decoy", () => {
    const all = normalizeAdsbLol(FIXTURE, FETCHED_AT, null);
    const hexes = all.map((a) => a.icao24);
    expect(hexes).toContain("4ca8e1"); // mid-Atlantic, kept when not geo-filtered
    expect(hexes).not.toContain("ad4f29"); // still dropped (no position)
    expect(hexes.some((h) => h.startsWith("~"))).toBe(false); // ~ still dropped
  });
});

describe("AdsbLolProvider.aircraftInBbox", () => {
  it("calls /v2/point with the bbox center + covering radius and normalizes", async () => {
    let calledUrl = "";
    const fetchFn = (async (url: string | URL) => {
      calledUrl = String(url);
      return new Response(JSON.stringify(FIXTURE), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as unknown as typeof fetch;

    const provider = new AdsbLolProvider({ baseUrl: "https://example.test", fetchFn });
    const snapshot = await provider.aircraftInBbox(SF_BBOX);

    // URL is /v2/point/{lat}/{lon}/{radius}; center of SF_BBOX is 37.5/-122.5.
    expect(calledUrl).toMatch(/^https:\/\/example\.test\/v2\/point\/37\.5\/-122\.5\/\d+$/);
    expect(snapshot.fetchedAt).toBe(FETCHED_AT);
    // 3 in-bbox survivors (UA, JAL, DLH); decoy 4ca8e1 is outside the bbox.
    expect(snapshot.aircraft.length).toBe(3);
  });

  it("throws UpstreamError on a non-OK upstream status", async () => {
    const fetchFn = (async () => new Response("nope", { status: 502 })) as unknown as typeof fetch;
    const provider = new AdsbLolProvider({ baseUrl: "https://example.test", fetchFn });
    await expect(provider.aircraftInBbox(SF_BBOX)).rejects.toThrow(/HTTP 502/);
  });
});
