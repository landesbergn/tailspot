import { gunzipSync } from "node:zlib";
import type { FastifyInstance } from "fastify";
import { afterEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { acceptsGzip } from "../src/compression.js";
import type { NormalizedAircraft, PositionProvider } from "../src/providers/types.js";

const QS = "lamin=37.6&lomin=-122.5&lamax=37.9&lomax=-122.2";

function plane(i: number): NormalizedAircraft {
  return {
    icao24: `a${i.toString(16).padStart(5, "0")}`,
    callsign: `UAL${i}`,
    originCountry: "United States",
    longitude: -122.35,
    latitude: 37.75,
    altitudeMeters: 3000,
    velocityMps: 200,
    trackDeg: 90,
    onGround: false,
    positionTimestamp: 1_700_000_000,
    typecode: "B772",
    registration: "N69020",
  };
}

function provider(count: number): PositionProvider {
  return {
    name: "stub",
    async aircraftInBbox() {
      return {
        fetchedAt: 1_700_000_100,
        aircraft: Array.from({ length: count }, (_, i) => plane(i)),
      };
    },
  };
}

describe("response compression", () => {
  let app: FastifyInstance | undefined;
  afterEach(async () => {
    await app?.close();
    app = undefined;
  });

  it("gzips a large aircraft list when the client accepts gzip", async () => {
    app = await buildApp({ provider: provider(50) });
    const res = await app.inject({
      method: "GET",
      url: `/v1/aircraft?${QS}`,
      headers: { "accept-encoding": "gzip, deflate, br" },
    });
    expect(res.statusCode).toBe(200);
    expect(res.headers["content-encoding"]).toBe("gzip");
    expect(String(res.headers.vary)).toMatch(/accept-encoding/i);
    const body = JSON.parse(gunzipSync(res.rawPayload).toString("utf8"));
    expect(body.aircraft).toHaveLength(50);
    // The point of the exercise: far fewer bytes on the wire.
    expect(res.rawPayload.length).toBeLessThan(JSON.stringify(body).length / 3);
  });

  it("sends plain JSON to a client that does not ask for gzip", async () => {
    app = await buildApp({ provider: provider(50) });
    const res = await app.inject({ method: "GET", url: `/v1/aircraft?${QS}` });
    expect(res.headers["content-encoding"]).toBeUndefined();
    expect(res.json().aircraft).toHaveLength(50);
  });

  it("leaves small bodies alone", async () => {
    app = await buildApp({ provider: provider(0) });
    const res = await app.inject({
      method: "GET",
      url: "/healthz",
      headers: { "accept-encoding": "gzip" },
    });
    expect(res.statusCode).toBe(200);
    expect(res.headers["content-encoding"]).toBeUndefined();
  });
});

describe("acceptsGzip", () => {
  it("parses common Accept-Encoding values", () => {
    expect(acceptsGzip("gzip, deflate, br")).toBe(true);
    expect(acceptsGzip("br;q=1.0, gzip;q=0.8")).toBe(true);
    expect(acceptsGzip("*")).toBe(true);
    expect(acceptsGzip("gzip;q=0")).toBe(false);
    expect(acceptsGzip("br")).toBe(false);
    expect(acceptsGzip(undefined)).toBe(false);
  });
});
