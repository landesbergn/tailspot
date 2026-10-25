import { describe, expect, it } from "vitest";
import { SiteProbe, type SiteProbeAlert } from "../src/monitoring/siteProbe.js";

function setup(responses: Array<number | "throw">) {
  let t = 0;
  let i = 0;
  const alerts: SiteProbeAlert[] = [];
  const recovered: string[] = [];
  const fetchFn = (async () => {
    const r = responses[Math.min(i, responses.length - 1)];
    i++;
    if (r === "throw") throw new TypeError("fetch failed");
    return new Response("ok", { status: r });
  }) as typeof fetch;
  const probe = new SiteProbe({
    urls: ["https://tailspot.app/"],
    fetchFn,
    now: () => t,
    onAlert: (a) => alerts.push(a),
    onRecovered: (url) => recovered.push(url),
  });
  return {
    probe,
    alerts,
    recovered,
    advance: (ms: number) => {
      t += ms;
    },
  };
}

describe("SiteProbe", () => {
  it("is quiet while the site answers", async () => {
    const s = setup([200]);
    for (let n = 0; n < 5; n++) await s.probe.checkAll();
    expect(s.alerts).toHaveLength(0);
  });

  it("alerts on the third failed check in a row, not before", async () => {
    const s = setup([502, "throw", 502, 502]);
    await s.probe.checkAll();
    await s.probe.checkAll();
    expect(s.alerts).toHaveLength(0);
    await s.probe.checkAll();
    expect(s.alerts).toEqual([
      { url: "https://tailspot.app/", consecutiveFailures: 3, error: "HTTP 502" },
    ]);
    await s.probe.checkAll();
    expect(s.alerts).toHaveLength(1);
  });

  it("re-alerts after an hour of continued downtime", async () => {
    const s = setup([500]);
    for (let n = 0; n < 3; n++) await s.probe.checkAll();
    s.advance(60 * 60_000);
    await s.probe.checkAll();
    expect(s.alerts).toHaveLength(2);
  });

  it("a blip that recovers before the third check never alerts, and recovery is reported after an alert", async () => {
    const s = setup([500, 500, 200, 500, 500, 500, 200]);
    for (let n = 0; n < 3; n++) await s.probe.checkAll();
    expect(s.alerts).toHaveLength(0);
    expect(s.recovered).toHaveLength(0);
    for (let n = 0; n < 4; n++) await s.probe.checkAll();
    expect(s.alerts).toHaveLength(1);
    expect(s.recovered).toEqual(["https://tailspot.app/"]);
  });
});
