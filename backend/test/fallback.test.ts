import { describe, expect, it } from "vitest";
import { AirplanesLiveProvider } from "../src/providers/airplaneslive.js";
import { FallbackProvider } from "../src/providers/fallback.js";
import { selectProvider } from "../src/providers/index.js";
import {
  type Bbox,
  type PositionProvider,
  type ProviderSnapshot,
  UpstreamError,
} from "../src/providers/types.js";

const BBOX: Bbox = { lamin: 37.0, lomin: -123.0, lamax: 38.0, lomax: -122.0 };

/** A canned snapshot distinguishable by fetchedAt. */
function snapshot(fetchedAt: number): ProviderSnapshot {
  return { fetchedAt, aircraft: [] };
}

/** Stub provider: returns `result`, or throws it if it's an Error. Counts calls. */
function stub(name: string, result: ProviderSnapshot | Error) {
  const calls: Bbox[] = [];
  const provider: PositionProvider = {
    name,
    async aircraftInBbox(bbox: Bbox) {
      calls.push(bbox);
      if (result instanceof Error) throw result;
      return result;
    },
  };
  return { provider, calls };
}

describe("FallbackProvider", () => {
  it("serves the primary and never touches the secondary on success", async () => {
    const primary = stub("p", snapshot(111));
    const secondary = stub("s", snapshot(222));
    const fallback = new FallbackProvider(primary.provider, secondary.provider);

    const snap = await fallback.aircraftInBbox(BBOX);

    expect(snap.fetchedAt).toBe(111);
    expect(primary.calls).toEqual([BBOX]);
    expect(secondary.calls).toEqual([]);
  });

  it("serves the secondary when the primary throws, and reports via onFallback", async () => {
    const boom = new UpstreamError("p exploded");
    const primary = stub("p", boom);
    const secondary = stub("s", snapshot(222));
    const seen: unknown[] = [];
    const fallback = new FallbackProvider(primary.provider, secondary.provider, {
      onFallback: (err) => seen.push(err),
    });

    const snap = await fallback.aircraftInBbox(BBOX);

    expect(snap.fetchedAt).toBe(222);
    expect(secondary.calls).toEqual([BBOX]);
    expect(seen).toEqual([boom]);
  });

  it("does NOT fall back on an empty-but-successful primary response", async () => {
    // Zero aircraft is a legitimate answer (shared coverage deserts exist);
    // only a THROW engages the secondary.
    const primary = stub("p", snapshot(111)); // empty aircraft list
    const secondary = stub("s", snapshot(222));
    const fallback = new FallbackProvider(primary.provider, secondary.provider);

    const snap = await fallback.aircraftInBbox(BBOX);

    expect(snap.fetchedAt).toBe(111);
    expect(secondary.calls).toEqual([]);
  });

  it("throws an UpstreamError naming both feeds when both fail", async () => {
    const primary = stub("p", new UpstreamError("p down"));
    const secondary = stub("s", new UpstreamError("s down"));
    const fallback = new FallbackProvider(primary.provider, secondary.provider);

    const err = await fallback.aircraftInBbox(BBOX).then(
      () => null,
      (e: unknown) => e,
    );

    expect(err).toBeInstanceOf(UpstreamError);
    const message = (err as UpstreamError).message;
    expect(message).toContain("p down");
    expect(message).toContain("s down");
  });

  it("composes its name from both providers (drives the route-enricher gate)", () => {
    const fallback = new FallbackProvider(
      stub("adsblol", snapshot(1)).provider,
      stub("airplaneslive", snapshot(2)).provider,
    );
    // app.ts enables adsb.lol route enrichment via name.startsWith("adsblol").
    expect(fallback.name).toBe("adsblol+airplaneslive");
    expect(fallback.name.startsWith("adsblol")).toBe(true);
  });
});

describe("AirplanesLiveProvider", () => {
  it("hits api.airplanes.live with the same /v2/point shape as adsb.lol", async () => {
    const urls: string[] = [];
    const fetchFn = (async (url: RequestInfo | URL) => {
      urls.push(String(url));
      return new Response(JSON.stringify({ ac: [], now: 1_781_116_526_502, total: 0 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;

    const provider = new AirplanesLiveProvider({ fetchFn });
    const snap = await provider.aircraftInBbox(BBOX);

    expect(provider.name).toBe("airplaneslive");
    expect(urls).toHaveLength(1);
    expect(urls[0]).toMatch(/^https:\/\/api\.airplanes\.live\/v2\/point\/[\d.-]+\/[\d.-]+\/\d+$/);
    expect(snap.fetchedAt).toBe(Math.floor(1_781_116_526_502 / 1000));
  });

  it("names its errors after itself, not adsb.lol", async () => {
    const fetchFn = (async () => new Response("nope", { status: 500 })) as typeof fetch;
    const provider = new AirplanesLiveProvider({ fetchFn });

    await expect(provider.aircraftInBbox(BBOX)).rejects.toThrow(/airplaneslive returned HTTP 500/);
  });
});

describe("selectProvider", () => {
  it("defaults to the adsb.lol + airplanes.live fallback composite", () => {
    expect(selectProvider({}).name).toBe("adsblol+airplaneslive");
  });

  it("still selects single providers explicitly", () => {
    expect(selectProvider({ POSITION_PROVIDER: "adsblol" }).name).toBe("adsblol");
    expect(selectProvider({ POSITION_PROVIDER: "airplaneslive" }).name).toBe("airplaneslive");
    expect(selectProvider({ POSITION_PROVIDER: "opensky" }).name).toBe("opensky");
  });
});
