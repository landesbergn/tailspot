import { describe, expect, it } from "vitest";
import {
  bboxCenter,
  bboxCoveringRadiusNm,
  haversineNm,
  isInsideBbox,
  validateBbox,
} from "../src/providers/geo.js";
import type { Bbox } from "../src/providers/types.js";

const SF_BBOX: Bbox = { lamin: 37.6, lomin: -122.5, lamax: 37.9, lomax: -122.2 };

describe("validateBbox", () => {
  it("accepts a valid small bbox", () => {
    expect(validateBbox(SF_BBOX)).toBeNull();
  });

  it("rejects missing parameters", () => {
    expect(validateBbox({ lamin: 37.6, lomin: -122.5, lamax: 37.9 })?.reason).toMatch(
      /missing or non-numeric/,
    );
  });

  it("rejects non-numeric (NaN) parameters", () => {
    expect(
      validateBbox({ lamin: Number.NaN, lomin: -122.5, lamax: 37.9, lomax: -122.2 })?.reason,
    ).toMatch(/missing or non-numeric/);
  });

  it("rejects out-of-range bounds", () => {
    expect(validateBbox({ lamin: -91, lomin: -122.5, lamax: 37.9, lomax: -122.2 })?.reason).toMatch(
      /out of range/,
    );
  });

  it("rejects inverted latitude bounds", () => {
    expect(
      validateBbox({ lamin: 37.9, lomin: -122.5, lamax: 37.6, lomax: -122.2 })?.reason,
    ).toMatch(/inverted/);
  });

  it("rejects inverted longitude bounds", () => {
    expect(
      validateBbox({ lamin: 37.6, lomin: -122.2, lamax: 37.9, lomax: -122.5 })?.reason,
    ).toMatch(/inverted/);
  });

  it("rejects a bbox larger than 4 square degrees", () => {
    // 3° x 3° = 9 sq deg.
    expect(validateBbox({ lamin: 30, lomin: -120, lamax: 33, lomax: -117 })?.reason).toMatch(
      /too large/,
    );
  });

  it("accepts a bbox exactly at the 4 sq deg boundary", () => {
    // 2° x 2° = 4 sq deg — allowed (boundary is inclusive, > rejects).
    expect(validateBbox({ lamin: 30, lomin: -120, lamax: 32, lomax: -118 })).toBeNull();
  });
});

describe("bbox geometry", () => {
  it("computes the center", () => {
    const c = bboxCenter(SF_BBOX);
    expect(c.lat).toBeCloseTo(37.75, 5);
    expect(c.lon).toBeCloseTo(-122.35, 5);
  });

  it("covering radius covers the corners (>= center-to-corner distance)", () => {
    const c = bboxCenter(SF_BBOX);
    const cornerDist = haversineNm(c.lat, c.lon, SF_BBOX.lamin, SF_BBOX.lomin);
    const r = bboxCoveringRadiusNm(SF_BBOX);
    expect(r).toBeGreaterThanOrEqual(cornerDist - 1e-9);
    // Sanity: a ~0.3° x 0.3° box near 37.75°N is on the order of ~12 NM corner.
    expect(r).toBeGreaterThan(8);
    expect(r).toBeLessThan(20);
  });

  it("isInsideBbox includes interior points and excludes outside points", () => {
    expect(isInsideBbox(37.75, -122.35, SF_BBOX)).toBe(true);
    expect(isInsideBbox(37.95, -122.35, SF_BBOX)).toBe(false); // north of bbox
    expect(isInsideBbox(37.75, -123.0, SF_BBOX)).toBe(false); // west of bbox
  });

  it("isInsideBbox includes the edges", () => {
    expect(isInsideBbox(SF_BBOX.lamin, SF_BBOX.lomin, SF_BBOX)).toBe(true);
    expect(isInsideBbox(SF_BBOX.lamax, SF_BBOX.lomax, SF_BBOX)).toBe(true);
  });
});

describe("haversineNm", () => {
  it("is zero for identical points", () => {
    expect(haversineNm(37.75, -122.35, 37.75, -122.35)).toBeCloseTo(0, 6);
  });

  it("matches a known distance (1 degree of latitude ≈ 60 NM)", () => {
    expect(haversineNm(37.0, -122.0, 38.0, -122.0)).toBeCloseTo(60, 0);
  });
});
