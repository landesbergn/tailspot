/**
 * Instrumented (NEVER enforced) anti-cheat for catch ingestion (WP 1.5).
 *
 * This is a PURE function: given the observer pose, the submitted aircraft
 * position, and the claimed catch time, it returns a verdict + human-readable
 * reasons. The verdict is STORED on the catch row (for later analysis / tuning)
 * but the HTTP response NEVER varies on it — see the route. The reason: we don't
 * want to give a cheater an oracle. If "implausible" produced a different status
 * code or body, an attacker could probe the validator (binary-search the
 * tolerances, learn exactly how far they can fake a pose) until their forgeries
 * read as "plausible". By accepting every well-formed catch identically and only
 * recording the verdict server-side, we keep the validator's thresholds private
 * and collect honest telemetry on real-world pose accuracy before we ever decide
 * whether/how to enforce.
 *
 * The geometry mirrors the iOS `Geo.swift` (haversine distance, initial bearing,
 * elevation) so the server reconstructs the same angles the phone projected
 * with. One deliberate refinement over the iOS version: the elevation here adds
 * an Earth-curvature term (the target sits lower than a flat-Earth model says,
 * by ~d²/2R), which matters at the tens-of-km distances we validate over. The
 * iOS elevation is flat-Earth (it notes the ~0.1° cost); on the server we have
 * no realtime-render budget pressure, so we use the more accurate form.
 */

const EARTH_RADIUS_M = 6_371_000;
const D2R = Math.PI / 180;
const R2D = 180 / Math.PI;

export interface ObserverPose {
  lat: number;
  lon: number;
  /** Compass heading the user faced, deg true. */
  headingDeg: number | null;
  /** Camera elevation above horizon, deg. */
  elevationDeg: number | null;
  /** Reported heading accuracy, deg — widens the bearing tolerance. Null = unknown. */
  headingAccuracyDeg: number | null;
}

export interface AircraftPosition {
  lat: number;
  lon: number;
  altitudeMeters: number;
  /** Unix seconds of the aircraft fix; null if unknown. */
  positionTimestamp: number | null;
}

export type Verdict = "plausible" | "implausible" | "unverifiable";

export interface ValidationResult {
  verdict: Verdict;
  reasons: string[];
}

/** Tolerances + sanity bounds. Kept here (not the response) so they stay private. */
export interface ValidateConfig {
  /** Base bearing tolerance (deg). Compass is bad → generous. Widened by headingAccuracyDeg. */
  bearingToleranceDeg: number;
  /** Elevation tolerance (deg). */
  elevationToleranceDeg: number;
  /** Allowed clock skew between caughtAt and server time (seconds). */
  caughtAtSkewSeconds: number;
  /** Allowed gap between the aircraft fix and caughtAt (seconds). */
  positionAgeSeconds: number;
  /** Max plausible slant distance to a caught aircraft (meters). */
  maxSlantDistanceMeters: number;
}

export const DEFAULT_VALIDATE_CONFIG: ValidateConfig = {
  bearingToleranceDeg: 30, // compass error is large; per the contract
  elevationToleranceDeg: 15,
  caughtAtSkewSeconds: 600, // ±10 min
  positionAgeSeconds: 300, // 5 min
  maxSlantDistanceMeters: 100_000, // 100 km
};

// ── Geometry (ported from iOS Geo.swift) ────────────────────────────────────

/** Great-circle ground distance in meters (haversine). */
export function distanceMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const p1 = lat1 * D2R;
  const p2 = lat2 * D2R;
  const dp = (lat2 - lat1) * D2R;
  const dl = (lon2 - lon1) * D2R;
  const a = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return EARTH_RADIUS_M * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/** Initial true-north bearing (0..360, clockwise) from point 1 to point 2. */
export function bearingDeg(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const p1 = lat1 * D2R;
  const p2 = lat2 * D2R;
  const dl = (lon2 - lon1) * D2R;
  const y = Math.sin(dl) * Math.cos(p2);
  const x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl);
  return (((Math.atan2(y, x) * R2D) % 360) + 360) % 360;
}

/**
 * Elevation angle (deg above horizon) of a target, with an Earth-curvature
 * correction: over the ground distance, the target's apparent height drops by
 * ~d²/(2R). Positive = above horizon.
 */
export function elevationDeg(
  observerAltMeters: number,
  targetAltMeters: number,
  groundDistanceMeters: number,
): number {
  if (groundDistanceMeters <= 0) return 0;
  const curvatureDrop = (groundDistanceMeters * groundDistanceMeters) / (2 * EARTH_RADIUS_M);
  const dh = targetAltMeters - observerAltMeters - curvatureDrop;
  return Math.atan2(dh, groundDistanceMeters) * R2D;
}

/** Smallest absolute difference between two compass bearings (0..180). */
export function angularDifferenceDeg(a: number, b: number): number {
  const d = Math.abs((((a - b) % 360) + 360) % 360);
  return d > 180 ? 360 - d : d;
}

/**
 * Validate a catch. Returns the verdict + reasons; NEVER throws on bad geometry
 * (it reports it). `serverNowSeconds` is injected so tests are deterministic.
 */
export function validateCatch(
  observer: ObserverPose,
  aircraft: AircraftPosition,
  caughtAt: number,
  serverNowSeconds: number,
  config: ValidateConfig = DEFAULT_VALIDATE_CONFIG,
): ValidationResult {
  const reasons: string[] = [];

  // Coordinate sanity first — if the inputs are garbage, nothing downstream is
  // meaningful, and we can't compute angles. Treat as implausible.
  if (
    !isFiniteCoord(observer.lat, 90) ||
    !isFiniteCoord(observer.lon, 180) ||
    !isFiniteCoord(aircraft.lat, 90) ||
    !isFiniteCoord(aircraft.lon, 180) ||
    !Number.isFinite(aircraft.altitudeMeters)
  ) {
    return { verdict: "implausible", reasons: ["coordinates out of range or non-finite"] };
  }

  // ── Sanity checks (independent of pose) ──────────────────────────────────
  const caughtSkew = Math.abs(caughtAt - serverNowSeconds);
  if (caughtSkew > config.caughtAtSkewSeconds) {
    reasons.push(`caughtAt off by ${Math.round(caughtSkew)}s (max ${config.caughtAtSkewSeconds}s)`);
  }
  if (aircraft.positionTimestamp !== null) {
    const posAge = Math.abs(caughtAt - aircraft.positionTimestamp);
    if (posAge > config.positionAgeSeconds) {
      reasons.push(
        `aircraft fix ${Math.round(posAge)}s from caughtAt (max ${config.positionAgeSeconds}s)`,
      );
    }
  }

  const ground = distanceMeters(observer.lat, observer.lon, aircraft.lat, aircraft.lon);
  const slant = Math.hypot(ground, aircraft.altitudeMeters);
  if (slant > config.maxSlantDistanceMeters) {
    reasons.push(
      `slant distance ${Math.round(slant)}m exceeds max ${config.maxSlantDistanceMeters}m`,
    );
  }

  // ── Angular consistency (needs heading + elevation) ──────────────────────
  // When either pose angle is missing, the catch is UNVERIFIABLE for the angular
  // check. Sanity reasons (above) still get recorded, but the overall verdict is
  // "unverifiable" — we lack the signal to call it plausible or not.
  const poseComplete = observer.headingDeg !== null && observer.elevationDeg !== null;

  if (poseComplete) {
    const expectedBearing = bearingDeg(observer.lat, observer.lon, aircraft.lat, aircraft.lon);
    const expectedElevation = elevationDeg(0, aircraft.altitudeMeters, ground);

    // Widen the bearing tolerance by the reported heading accuracy when present.
    const bearingTol = config.bearingToleranceDeg + (observer.headingAccuracyDeg ?? 0);
    const bearingErr = angularDifferenceDeg(expectedBearing, observer.headingDeg as number);
    if (bearingErr > bearingTol) {
      reasons.push(
        `bearing off by ${bearingErr.toFixed(1)}° (expected ~${expectedBearing.toFixed(
          1,
        )}°, tol ${bearingTol.toFixed(1)}°)`,
      );
    }

    const elevationErr = Math.abs(expectedElevation - (observer.elevationDeg as number));
    if (elevationErr > config.elevationToleranceDeg) {
      reasons.push(
        `elevation off by ${elevationErr.toFixed(1)}° (expected ~${expectedElevation.toFixed(
          1,
        )}°, tol ${config.elevationToleranceDeg}°)`,
      );
    }

    return {
      verdict: reasons.length === 0 ? "plausible" : "implausible",
      reasons,
    };
  }

  // Missing pose → unverifiable. Prepend the reason; keep any sanity reasons.
  return {
    verdict: "unverifiable",
    reasons: ["missing observer heading/elevation — angular consistency unverifiable", ...reasons],
  };
}

/** Finite and within ±range. */
function isFiniteCoord(v: number, range: number): boolean {
  return Number.isFinite(v) && v >= -range && v <= range;
}
