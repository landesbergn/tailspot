import type { FastifyInstance } from "fastify";
import { afterEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type {
  Bbox,
  NormalizedAircraft,
  PositionProvider,
  ProviderSnapshot,
} from "../src/providers/types.js";
import { UpstreamError } from "../src/providers/types.js";

const VALID_QS = "lamin=37.6&lomin=-122.5&lamax=37.9&lomax=-122.2";
const SECOND_TILE_QS = "lamin=40.6&lomin=-74.1&lamax=40.8&lomax=-73.9"; // different tile

function plane(icao: string): NormalizedAircraft {
  return {
    icao24: icao,
    callsign: "TEST123",
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

/** A controllable stub provider: counts calls, can be made to fail. */
class StubProvider implements PositionProvider {
  readonly name = "stub";
  calls = 0;
  shouldFail = false;
  fetchedAt = 1_700_000_100;
  /** Delay (ms) before resolving — used to exercise single-flight. */
  delayMs = 0;

  async aircraftInBbox(_bbox: Bbox): Promise<ProviderSnapshot> {
    this.calls += 1;
    if (this.delayMs > 0) await new Promise((r) => setTimeout(r, this.delayMs));
    if (this.shouldFail) throw new UpstreamError("stub upstream down");
    return { fetchedAt: this.fetchedAt, aircraft: [plane("abc123")] };
  }
}

describe("GET /v1/aircraft", () => {
  let app: FastifyInstance | undefined;

  afterEach(async () => {
    await app?.close();
    app = undefined;
  });

  async function build(provider: PositionProvider, now?: () => number): Promise<FastifyInstance> {
    app = await buildApp({
      provider,
      cacheConfig: { ttlSeconds: 10, staleMaxSeconds: 60, tileSizeDeg: 0.25 },
      now,
    });
    return app;
  }

  it("returns 200 with the frozen wire shape", async () => {
    const provider = new StubProvider();
    const a = await build(provider);
    const res = await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
    expect(res.statusCode).toBe(200);
    const body = res.json<ProviderSnapshot>();
    expect(body.fetchedAt).toBe(provider.fetchedAt);
    expect(body.aircraft).toHaveLength(1);
    const ac = body.aircraft[0];
    expect(ac.icao24).toBe("abc123");
    // Spot-check the contract field set is present.
    for (const k of [
      "icao24",
      "callsign",
      "originCountry",
      "longitude",
      "latitude",
      "altitudeMeters",
      "velocityMps",
      "trackDeg",
      "onGround",
      "positionTimestamp",
    ]) {
      expect(ac).toHaveProperty(k);
    }
    // typecode/registration travel through the cache + route untouched.
    expect(ac.typecode).toBe("B772");
    expect(ac.registration).toBe("N69020");
  });

  it("serves a cache hit within TTL (one upstream call for two requests)", async () => {
    let nowMs = 1_700_000_000_000;
    const provider = new StubProvider();
    const a = await build(provider, () => nowMs);
    await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
    nowMs += 5_000; // < 10s TTL
    await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
    expect(provider.calls).toBe(1);
  });

  it("collapses near-identical bboxes onto the same tile (one upstream call)", async () => {
    const provider = new StubProvider();
    const a = await build(provider);
    await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
    // Nudge the bbox by a hair — still within the 0.25° tile grid.
    await a.inject({
      method: "GET",
      url: "/v1/aircraft?lamin=37.61&lomin=-122.49&lamax=37.89&lomax=-122.21",
    });
    expect(provider.calls).toBe(1);
  });

  it("single-flights concurrent requests for the same tile (one upstream call)", async () => {
    const provider = new StubProvider();
    provider.delayMs = 50; // hold the fetch open so both requests overlap
    const a = await build(provider);
    const [r1, r2] = await Promise.all([
      a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` }),
      a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` }),
    ]);
    expect(r1.statusCode).toBe(200);
    expect(r2.statusCode).toBe(200);
    expect(provider.calls).toBe(1);
  });

  it("refetches after the TTL expires", async () => {
    let nowMs = 1_700_000_000_000;
    const provider = new StubProvider();
    const a = await build(provider, () => nowMs);
    await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
    nowMs += 11_000; // > 10s TTL
    await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
    expect(provider.calls).toBe(2);
  });

  it("serves last-good cache on upstream failure (with true fetchedAt)", async () => {
    let nowMs = 1_700_000_000_000;
    const provider = new StubProvider();
    const a = await build(provider, () => nowMs);
    // Prime the cache.
    const first = await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
    expect(first.statusCode).toBe(200);
    // Expire the TTL, then break upstream.
    nowMs += 11_000;
    provider.shouldFail = true;
    const res = await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
    expect(res.statusCode).toBe(200);
    // Served the stale snapshot, carrying its original fetchedAt.
    expect(res.json<ProviderSnapshot>().fetchedAt).toBe(provider.fetchedAt);
  });

  it("returns 503 when upstream fails and no cache exists", async () => {
    const provider = new StubProvider();
    provider.shouldFail = true;
    const a = await build(provider);
    const res = await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
    expect(res.statusCode).toBe(503);
    expect(res.json<{ error: string }>().error).toBe("upstream unavailable");
  });

  it("returns 503 (not 200 stale) once the last-good cache ages past STALE_MAX", async () => {
    let nowMs = 1_700_000_000_000;
    const provider = new StubProvider();
    const a = await build(provider, () => nowMs);
    await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
    nowMs += 61_000; // > 60s staleMax
    provider.shouldFail = true;
    const res = await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
    expect(res.statusCode).toBe(503);
  });

  describe("400s for bad bboxes", () => {
    const cases: Array<[string, string]> = [
      ["missing a parameter", "lamin=37.6&lomin=-122.5&lamax=37.9"],
      ["non-numeric parameter", "lamin=abc&lomin=-122.5&lamax=37.9&lomax=-122.2"],
      ["inverted bounds", "lamin=37.9&lomin=-122.5&lamax=37.6&lomax=-122.2"],
      ["oversized bbox", "lamin=30&lomin=-120&lamax=33&lomax=-117"],
      ["out-of-range latitude", "lamin=-91&lomin=-122.5&lamax=37.9&lomax=-122.2"],
    ];
    for (const [label, qs] of cases) {
      it(`rejects ${label} with 400`, async () => {
        const provider = new StubProvider();
        const a = await build(provider);
        const res = await a.inject({ method: "GET", url: `/v1/aircraft?${qs}` });
        expect(res.statusCode).toBe(400);
        expect(res.json<{ error: string }>().error).toBeTruthy();
        // A bad request must never reach the upstream.
        expect(provider.calls).toBe(0);
      });
    }
  });

  it("keys distinct tiles separately (two tiles → two upstream calls)", async () => {
    const provider = new StubProvider();
    const a = await build(provider);
    await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
    await a.inject({ method: "GET", url: `/v1/aircraft?${SECOND_TILE_QS}` });
    expect(provider.calls).toBe(2);
  });
});
