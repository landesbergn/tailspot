import { describe, expect, it } from "vitest";
import { DEFAULT_CANARY_BBOX, parseCanaryBbox } from "../src/routes/feedProbe.js";

describe("parseCanaryBbox", () => {
  it("defaults to the Bay Area when unset or blank", () => {
    expect(parseCanaryBbox(undefined)).toEqual(DEFAULT_CANARY_BBOX);
    expect(parseCanaryBbox("")).toEqual(DEFAULT_CANARY_BBOX);
    expect(parseCanaryBbox("   ")).toEqual(DEFAULT_CANARY_BBOX);
  });

  it("the default is a valid request the aircraft route would accept", () => {
    // Re-parsing the default through the validator guards against a future
    // edit making the canary ask for something /v1/aircraft rejects.
    const { lamin, lomin, lamax, lomax } = DEFAULT_CANARY_BBOX;
    expect(parseCanaryBbox(`${lamin},${lomin},${lamax},${lomax}`)).toEqual(DEFAULT_CANARY_BBOX);
  });

  it("parses lamin,lomin,lamax,lomax with surrounding whitespace", () => {
    expect(parseCanaryBbox(" -8.9, 115.0 ,-8.5, 115.4 ")).toEqual({
      lamin: -8.9,
      lomin: 115.0,
      lamax: -8.5,
      lomax: 115.4,
    });
  });

  it("fails loudly on a malformed value instead of watching the wrong sky", () => {
    expect(() => parseCanaryBbox("37.5,-122.6,37.9")).toThrow(/CANARY_BBOX/);
    expect(() => parseCanaryBbox("a,b,c,d")).toThrow(/CANARY_BBOX/);
    expect(() => parseCanaryBbox("37.5,-122.6,,-122.2")).toThrow(/CANARY_BBOX/);
    // Inverted (south > north).
    expect(() => parseCanaryBbox("37.9,-122.6,37.5,-122.2")).toThrow(/CANARY_BBOX/);
    // Oversized (> 4 sq deg): the route would 400 this.
    expect(() => parseCanaryBbox("30,-130,40,-120")).toThrow(/CANARY_BBOX/);
  });
});
