import { describe, expect, it } from "vitest";
import { AdsbFiProvider } from "../src/providers/adsbfi.js";
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

  it("reports onBothFailed with the composite error, and only then", async () => {
    // The hard-outage edge: with both feeds dead the phone gets a 503 once the
    // tile cache's last-good window closes. This is the signal the outage
    // alerter in app.ts turns into "Position feed DOWN".
    const primary = stub("p", new UpstreamError("p down"));
    const secondary = stub("s", new UpstreamError("s down"));
    const both: UpstreamError[] = [];
    const served: number[] = [];
    const fallback = new FallbackProvider(primary.provider, secondary.provider, {
      onBothFailed: (err) => both.push(err),
      onSecondaryServed: () => served.push(1),
    });

    const thrown = await fallback.aircraftInBbox(BBOX).then(
      () => null,
      (e: unknown) => e,
    );

    expect(both).toHaveLength(1);
    expect(both[0]).toBe(thrown);
    expect(both[0].message).toContain("p down");
    expect(both[0].message).toContain("s down");
    expect(served).toEqual([]);
  });

  it("reports onSecondaryServed when the backup feed carries the request (the all-clear for an outage)", async () => {
    const primary = stub("p", new UpstreamError("p down"));
    const secondary = stub("s", snapshot(222));
    const both: unknown[] = [];
    const served: number[] = [];
    const fallback = new FallbackProvider(primary.provider, secondary.provider, {
      onBothFailed: (err) => both.push(err),
      onSecondaryServed: () => served.push(1),
    });

    await fallback.aircraftInBbox(BBOX);
    await fallback.aircraftInBbox(BBOX);

    expect(served).toEqual([1, 1]); // level-triggered: every served request
    expect(both).toEqual([]);
  });

  it("never reports onSecondaryServed or onBothFailed while the primary is healthy", async () => {
    const primary = stub("p", snapshot(111));
    const secondary = stub("s", snapshot(222));
    const calls: string[] = [];
    const fallback = new FallbackProvider(primary.provider, secondary.provider, {
      onBothFailed: () => calls.push("both"),
      onSecondaryServed: () => calls.push("secondary"),
    });

    await fallback.aircraftInBbox(BBOX);

    expect(calls).toEqual([]);
  });

  it("composes its name from both providers (drives the route-enricher gate)", () => {
    const fallback = new FallbackProvider(
      stub("adsblol", snapshot(1)).provider,
      stub("airplaneslive", snapshot(2)).provider,
    );
    // app.ts enables adsb.lol route enrichment when "adsblol" is any member
    // of the "+"-joined composite name (it is the FALLBACK half by default).
    expect(fallback.name).toBe("adsblol+airplaneslive");
    expect(fallback.name.split("+").includes("adsblol")).toBe(true);
    expect("adsbfi+adsblol".split("+").includes("adsblol")).toBe(true);
    expect("adsbfi+adsbone".split("+").includes("adsblol")).toBe(false);
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

describe("AdsbFiProvider", () => {
  it("hits opendata.adsb.fi's v3 lat/lon/dist path and parses the shared readsb shape", async () => {
    const urls: string[] = [];
    const fetchFn = (async (url: RequestInfo | URL) => {
      urls.push(String(url));
      // The real v3 response, trimmed: same `ac` rows and ms `now` as adsb.lol.
      return new Response(
        JSON.stringify({
          ac: [
            {
              hex: "a0cb44",
              flight: "POD2    ",
              r: "N150MB",
              t: "CL30",
              category: "A2",
              alt_baro: 16325,
              alt_geom: 16500,
              gs: 333.5,
              track: 167.01,
              lat: 37.5,
              lon: -122.5,
              seen_pos: 0.452,
            },
          ],
          msg: "No error",
          now: 1_792_475_184_001,
          total: 1,
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }) as typeof fetch;

    const provider = new AdsbFiProvider({ fetchFn });
    const snap = await provider.aircraftInBbox(BBOX);

    expect(provider.name).toBe("adsbfi");
    expect(urls).toHaveLength(1);
    expect(urls[0]).toMatch(
      /^https:\/\/opendata\.adsb\.fi\/api\/v3\/lat\/[\d.-]+\/lon\/[\d.-]+\/dist\/\d+$/,
    );
    expect(snap.fetchedAt).toBe(Math.floor(1_792_475_184_001 / 1000));
    expect(snap.aircraft).toHaveLength(1);
    expect(snap.aircraft[0]).toMatchObject({
      icao24: "a0cb44",
      callsign: "POD2",
      registration: "N150MB",
      typecode: "CL30",
      category: "A2",
    });
  });

  it("names its errors after itself", async () => {
    const fetchFn = (async () => new Response("nope", { status: 429 })) as typeof fetch;
    const provider = new AdsbFiProvider({ fetchFn });
    await expect(provider.aircraftInBbox(BBOX)).rejects.toThrow(/adsbfi returned HTTP 429/);
  });
});

describe("selectProvider", () => {
  it("defaults to adsb.fi primary with adsb.lol as the fallback", () => {
    // adsb.lol caps a client at 500 requests a day (2026-10-20); one polling
    // phone exhausts that in ~80 minutes, so it can only ever be the backup.
    // airplanes.live refuses Fly's network outright (HTTP 403, policy).
    expect(selectProvider({}).name).toBe("adsbfi+adsblol");
  });

  it("still selects single providers explicitly", () => {
    expect(selectProvider({ POSITION_PROVIDER: "adsblol" }).name).toBe("adsblol");
    expect(selectProvider({ POSITION_PROVIDER: "adsbfi" }).name).toBe("adsbfi");
    expect(selectProvider({ POSITION_PROVIDER: "airplaneslive" }).name).toBe("airplaneslive");
  });

  it("throws on an unknown provider instead of silently degrading", () => {
    expect(() => selectProvider({ POSITION_PROVIDER: "opensky" })).toThrow(
      /Unknown POSITION_PROVIDER "opensky"/,
    );
  });
});
