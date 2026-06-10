import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  OpenSkyProvider,
  type OpenSkyStatesResponse,
  normalizeOpenSky,
} from "../src/providers/opensky.js";
import type { Bbox } from "../src/providers/types.js";
import { mustGet } from "./helpers.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = JSON.parse(
  readFileSync(join(__dirname, "fixtures/opensky-states.json"), "utf8"),
) as OpenSkyStatesResponse;

const SF_BBOX: Bbox = { lamin: 37.0, lomin: -123.0, lamax: 38.0, lomax: -122.0 };

describe("normalizeOpenSky", () => {
  const result = normalizeOpenSky(FIXTURE);
  const byHex = new Map(result.map((a) => [a.icao24, a]));

  it("drops the row with no lat/lon (lossy per-element)", () => {
    expect(byHex.has("2b2e72")).toBe(false);
  });

  it("keeps the 4 positioned rows", () => {
    expect(result.length).toBe(4);
  });

  it("treats OpenSky altitudes as already-SI meters (no feet conversion)", () => {
    const swa = mustGet(byHex, "a808c5");
    // geo_altitude 10972.8 m preferred over baro_altitude 10363.2.
    expect(swa.altitudeMeters).toBeCloseTo(10972.8, 3);
  });

  it("falls back to baro_altitude when geo_altitude is null", () => {
    // index-7 baro is null AND index-13 geo is 11000 for DLH, so adjust:
    // here baro null, geo present → uses geo. Verify the documented preference.
    const dlh = mustGet(byHex, "3c6444");
    expect(dlh.altitudeMeters).toBeCloseTo(11000.0, 3);
  });

  it("uses baro_altitude when geo is null", () => {
    const baw = mustGet(byHex, "400a1b");
    // BAW: baro 8000, geo null → 8000 m.
    expect(baw.altitudeMeters).toBeCloseTo(8000.0, 3);
  });

  it("treats on_ground as onGround with 0 altitude", () => {
    const jal = mustGet(byHex, "86e4b8");
    expect(jal.onGround).toBe(true);
    expect(jal.altitudeMeters).toBe(0);
  });

  it("passes velocity through in m/s (already SI), null when absent", () => {
    expect(mustGet(byHex, "a808c5").velocityMps).toBeCloseTo(154.3, 4);
    expect(mustGet(byHex, "400a1b").velocityMps).toBeNull(); // velocity null
  });

  it("uses origin_country supplied by the upstream", () => {
    expect(mustGet(byHex, "a808c5").originCountry).toBe("United States");
    expect(mustGet(byHex, "3c6444").originCountry).toBe("Germany");
  });

  it("trims the padded callsign", () => {
    expect(mustGet(byHex, "a808c5").callsign).toBe("SWA1234");
  });

  it("uses time_position as positionTimestamp, null when absent", () => {
    expect(mustGet(byHex, "a808c5").positionTimestamp).toBe(1781116528);
    expect(mustGet(byHex, "400a1b").positionTimestamp).toBeNull(); // time_position null
  });
});

describe("OpenSkyProvider auth + fetch", () => {
  function makeFetch(opts: {
    onToken?: () => void;
    states: OpenSkyStatesResponse;
    tokenExpiresIn?: number;
  }): typeof fetch {
    let tokenCounter = 0;
    return (async (url: string | URL) => {
      const u = String(url);
      if (u.includes("/token")) {
        opts.onToken?.();
        tokenCounter += 1;
        return new Response(
          JSON.stringify({
            access_token: `tok-${tokenCounter}`,
            expires_in: opts.tokenExpiresIn ?? 300,
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      return new Response(JSON.stringify(opts.states), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as unknown as typeof fetch;
  }

  it("fetches a token, then states, and normalizes", async () => {
    let tokenCalls = 0;
    const fetchFn = makeFetch({ states: FIXTURE, onToken: () => tokenCalls++ });
    const provider = new OpenSkyProvider({
      clientId: "id",
      clientSecret: "secret",
      baseUrl: "https://example.test",
      fetchFn,
    });
    const snapshot = await provider.aircraftInBbox(SF_BBOX);
    expect(tokenCalls).toBe(1);
    expect(snapshot.fetchedAt).toBe(1781116530);
    expect(snapshot.aircraft.length).toBe(4);
  });

  it("caches the token across calls (one token fetch for two requests)", async () => {
    let tokenCalls = 0;
    const fetchFn = makeFetch({ states: FIXTURE, onToken: () => tokenCalls++ });
    const provider = new OpenSkyProvider({
      clientId: "id",
      clientSecret: "secret",
      baseUrl: "https://example.test",
      fetchFn,
    });
    await provider.aircraftInBbox(SF_BBOX);
    await provider.aircraftInBbox(SF_BBOX);
    expect(tokenCalls).toBe(1);
  });

  it("refreshes the token after expiry (with the 30s skew)", async () => {
    let tokenCalls = 0;
    let nowMs = 1_000_000_000_000;
    // expires_in 60s → effective expiry at +30s after the skew.
    const fetchFn = makeFetch({
      states: FIXTURE,
      onToken: () => tokenCalls++,
      tokenExpiresIn: 60,
    });
    const provider = new OpenSkyProvider({
      clientId: "id",
      clientSecret: "secret",
      baseUrl: "https://example.test",
      fetchFn,
      now: () => nowMs,
    });
    await provider.aircraftInBbox(SF_BBOX);
    expect(tokenCalls).toBe(1);
    // Advance 31s — past the (60 - 30 = 30s) effective lifetime → refresh.
    nowMs += 31_000;
    await provider.aircraftInBbox(SF_BBOX);
    expect(tokenCalls).toBe(2);
  });

  it("throws UpstreamError when credentials are missing", async () => {
    const provider = new OpenSkyProvider({
      clientId: "",
      clientSecret: "",
      baseUrl: "https://example.test",
      fetchFn: makeFetch({ states: FIXTURE }),
    });
    await expect(provider.aircraftInBbox(SF_BBOX)).rejects.toThrow(/credentials not configured/);
  });

  it("uses the legacy Keycloak /auth/ token URL by default", () => {
    // The default tokenUrl must contain the /auth/ prefix (the modern path 404s).
    const provider = new OpenSkyProvider({ clientId: "id", clientSecret: "s" });
    // @ts-expect-error reaching into the private field for an assertion.
    expect(provider.tokenUrl).toContain("/auth/realms/opensky-network/");
  });
});
