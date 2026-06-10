import type { Bbox } from "./types.js";

/**
 * Geographic helpers shared between the route (validation) and the adsb.lol
 * adapter (point+radius conversion). Pure functions, no I/O — unit-tested
 * directly.
 */

/** Earth radius in nautical miles (mean). Used for the covering-circle radius. */
const EARTH_RADIUS_NM = 3440.065;
const DEG_TO_RAD = Math.PI / 180;

export interface BboxValidationError {
  reason: string;
}

/**
 * Validate a bbox against the frozen contract:
 *  - all four bounds must be finite numbers in range,
 *  - bounds must not be inverted (min < max),
 *  - the area must not exceed 4 square degrees (abuse / upstream-load guard).
 *
 * Returns null when valid, or a { reason } describing the first failure. We
 * return rather than throw so the route can map it straight to a 400 body.
 */
export function validateBbox(bbox: Partial<Bbox>): BboxValidationError | null {
  const { lamin, lomin, lamax, lomax } = bbox;
  for (const [name, v] of [
    ["lamin", lamin],
    ["lomin", lomin],
    ["lamax", lamax],
    ["lomax", lomax],
  ] as const) {
    if (v === undefined || v === null || !Number.isFinite(v)) {
      return { reason: `missing or non-numeric bbox parameter: ${name}` };
    }
  }
  // Non-null assertions are safe: the loop above proved each is a finite number.
  const la0 = lamin as number;
  const lo0 = lomin as number;
  const la1 = lamax as number;
  const lo1 = lomax as number;

  if (la0 < -90 || la1 > 90 || lo0 < -180 || lo1 > 180) {
    return { reason: "bbox bounds out of range (lat ±90, lon ±180)" };
  }
  if (la0 >= la1 || lo0 >= lo1) {
    return { reason: "inverted bbox bounds (require lamin < lamax and lomin < lomax)" };
  }
  const area = (la1 - la0) * (lo1 - lo0);
  if (area > 4) {
    return { reason: `bbox too large: ${area.toFixed(2)} sq deg (max 4)` };
  }
  return null;
}

/** Center point of a bbox (decimal degrees). */
export function bboxCenter(bbox: Bbox): { lat: number; lon: number } {
  return {
    lat: (bbox.lamin + bbox.lamax) / 2,
    lon: (bbox.lomin + bbox.lomax) / 2,
  };
}

/**
 * Radius in nautical miles of the smallest circle (centered on the bbox
 * center) that fully covers the bbox — i.e. the great-circle distance from the
 * center to a corner. adsb.lol's /v2/point endpoint is point+radius, not bbox,
 * so we over-fetch this covering circle and then filter back to the rectangle.
 *
 * Distance uses the haversine formula. We take the max corner distance to be
 * safe near the poles / wide longitudes where corners aren't equidistant.
 */
export function bboxCoveringRadiusNm(bbox: Bbox): number {
  const c = bboxCenter(bbox);
  const corners: Array<[number, number]> = [
    [bbox.lamin, bbox.lomin],
    [bbox.lamin, bbox.lomax],
    [bbox.lamax, bbox.lomin],
    [bbox.lamax, bbox.lomax],
  ];
  let maxNm = 0;
  for (const [lat, lon] of corners) {
    const d = haversineNm(c.lat, c.lon, lat, lon);
    if (d > maxNm) maxNm = d;
  }
  return maxNm;
}

/** Great-circle distance in nautical miles between two lat/lon points. */
export function haversineNm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dLat = (lat2 - lat1) * DEG_TO_RAD;
  const dLon = (lon2 - lon1) * DEG_TO_RAD;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * DEG_TO_RAD) * Math.cos(lat2 * DEG_TO_RAD) * Math.sin(dLon / 2) ** 2;
  return EARTH_RADIUS_NM * 2 * Math.asin(Math.min(1, Math.sqrt(a)));
}

/** True when a point falls inside (or on the edge of) the bbox. */
export function isInsideBbox(lat: number, lon: number, bbox: Bbox): boolean {
  return lat >= bbox.lamin && lat <= bbox.lamax && lon >= bbox.lomin && lon <= bbox.lomax;
}
