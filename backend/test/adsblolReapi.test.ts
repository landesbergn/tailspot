import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import type { AdsbLolResponse } from "../src/providers/adsblol.js";
import { AdsbLolReApiProvider } from "../src/providers/adsblolReapi.js";
import type { Bbox } from "../src/providers/types.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
// Trimmed from a live re-api.adsb.lol ?circle=37.8,-122.3,25 answer on
// 2026-10-24: rows under `aircraft`, `now` in SECONDS. The fourth row is a
// decoy moved to the mid-Atlantic, outside the bbox.
const FIXTURE = JSON.parse(
  readFileSync(join(__dirname, "fixtures/adsblol-reapi-circle.json"), "utf8"),
) as AdsbLolResponse;

const SF_BBOX: Bbox = { lamin: 37.0, lomin: -123.0, lamax: 38.0, lomax: -122.0 };

/** A fetch stub that records the URL and headers of the one call it answers. */
function recordingFetch(body: unknown, status = 200) {
  const seen: { url: string; headers: Headers } = { url: "", headers: new Headers() };
  const fetchFn = (async (url: string | URL, init?: RequestInit) => {
    seen.url = String(url);
    seen.headers = new Headers(init?.headers);
    return new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  }) as unknown as typeof fetch;
  return { fetchFn, seen };
}

/** A fetch that never answers; it rejects the way Node's does when aborted. */
function hangUntilAborted(init: RequestInit): Promise<Response> {
  return new Promise((_resolve, reject) => {
    init.signal?.addEventListener("abort", () =>
      reject(new DOMException("This operation was aborted", "AbortError")),
    );
  });
}

describe("AdsbLolReApiProvider.aircraftInBbox", () => {
  it("queries ?circle= at the bbox center and sends the key as x-api-key", async () => {
    const { fetchFn, seen } = recordingFetch(FIXTURE);
    const provider = new AdsbLolReApiProvider({ apiKey: "test-key", fetchFn });
    await provider.aircraftInBbox(SF_BBOX);

    expect(seen.url).toMatch(/^https:\/\/re-api\.adsb\.lol\/\?circle=37\.5,-122\.5,\d+$/);
    expect(seen.headers.get("x-api-key")).toBe("test-key");
    // The shared client's headers survive the merge.
    expect(seen.headers.get("user-agent")).toBe("tailspot-backend");
  });

  it("reads rows from `aircraft` and treats `now` as seconds", async () => {
    const { fetchFn } = recordingFetch(FIXTURE);
    const provider = new AdsbLolReApiProvider({ apiKey: "k", fetchFn });
    const snapshot = await provider.aircraftInBbox(SF_BBOX);

    // 1792881555.296 s, floored; read as ms it would land in January 1970.
    expect(snapshot.fetchedAt).toBe(1792881555);
    // Three Bay Area rows survive; the mid-Atlantic decoy is filtered out.
    expect(snapshot.aircraft.map((a) => a.icao24).sort()).toEqual(["a011be", "a178a5", "a4d44a"]);
    expect(snapshot.provider).toBe("adsblolreapi");

    const byf = snapshot.aircraft.find((a) => a.icao24 === "a4d44a");
    if (!byf) throw new Error("expected a4d44a in the snapshot");
    expect(byf.callsign).toBe("BYF18");
    expect(byf.registration).toBe("N410BS");
    expect(byf.typecode).toBe("C172");
    expect(byf.altitudeMeters).toBeCloseTo(3025 * 0.3048, 6);
    expect(byf.positionTimestamp).toBe(Math.round(1792881555 - 0.073));
  });

  it("treats a 200 without an aircraft array as an error, not an empty sky", async () => {
    const { fetchFn } = recordingFetch({ error: "quota exceeded" });
    const provider = new AdsbLolReApiProvider({ apiKey: "k", fetchFn });
    await expect(provider.aircraftInBbox(SF_BBOX)).rejects.toThrow(/no aircraft array/);
  });

  it("keeps an empty aircraft array as a real empty sky", async () => {
    const { fetchFn } = recordingFetch({ now: 1792881555.296, aircraft: [] });
    const provider = new AdsbLolReApiProvider({ apiKey: "k", fetchFn });
    expect((await provider.aircraftInBbox(SF_BBOX)).aircraft).toEqual([]);
  });

  it("keeps the key out of a serialized provider", () => {
    const provider = new AdsbLolReApiProvider({ apiKey: "secret-key-123" });
    expect(JSON.stringify(provider)).not.toContain("secret-key-123");
  });

  it("retries once on a fresh attempt when the first one stalls", async () => {
    let calls = 0;
    const fetchFn = ((_url: string, init: RequestInit) => {
      calls++;
      if (calls === 1) return hangUntilAborted(init);
      return Promise.resolve(new Response(JSON.stringify(FIXTURE), { status: 200 }));
    }) as unknown as typeof fetch;
    const provider = new AdsbLolReApiProvider({
      apiKey: "k",
      fetchFn,
      timeoutMs: 1000,
      stallRetryAfterMs: 20,
    });
    const started = Date.now();
    const snapshot = await provider.aircraftInBbox(SF_BBOX);
    expect(calls).toBe(2);
    expect(snapshot.aircraft.length).toBe(3);
    // Abandoned at the stall limit, not the full deadline.
    expect(Date.now() - started).toBeLessThan(500);
  });

  it("gives up when the retry stalls too, within the one deadline", async () => {
    let calls = 0;
    const fetchFn = ((_url: string, init: RequestInit) => {
      calls++;
      return hangUntilAborted(init);
    }) as unknown as typeof fetch;
    const provider = new AdsbLolReApiProvider({
      apiKey: "k",
      fetchFn,
      timeoutMs: 80,
      stallRetryAfterMs: 20,
    });
    const started = Date.now();
    await expect(provider.aircraftInBbox(SF_BBOX)).rejects.toThrow(/request failed/);
    expect(calls).toBe(2);
    expect(Date.now() - started).toBeLessThan(500);
  });

  it("does not retry an HTTP answer", async () => {
    let calls = 0;
    const fetchFn = (async () => {
      calls++;
      return new Response("slow down", { status: 429 });
    }) as unknown as typeof fetch;
    const provider = new AdsbLolReApiProvider({ apiKey: "k", fetchFn, stallRetryAfterMs: 20 });
    await expect(provider.aircraftInBbox(SF_BBOX)).rejects.toThrow(/HTTP 429/);
    expect(calls).toBe(1);
  });

  it("throws UpstreamError on a rejected key, without the key in the message", async () => {
    const { fetchFn } = recordingFetch({ error: "bad key" }, 401);
    const provider = new AdsbLolReApiProvider({ apiKey: "secret-key-123", fetchFn });
    const err = await provider.aircraftInBbox(SF_BBOX).catch((e: unknown) => e);
    expect(String(err)).toMatch(/adsblolreapi returned HTTP 401/);
    expect(String(err)).not.toContain("secret-key-123");
  });
});
