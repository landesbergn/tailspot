import { describe, expect, it } from "vitest";
import {
  type AircraftPosition,
  type ObserverPose,
  bearingDeg,
  distanceMeters,
  elevationDeg,
  validateCatch,
} from "../src/catches/validateCatch.js";

/**
 * Anti-cheat validator tests.
 *
 * The fixture is HAND-DERIVED from the Geo math (the same haversine/bearing/
 * elevation ported from iOS Geo.swift, with the server's curvature term):
 *
 *   observer  = (37.80, -122.27), altitude 0
 *   aircraft  = (37.90, -122.27), altitude 3000 m   (due NORTH of the observer)
 *
 *   ground distance = R · c (haversine)         ≈ 11119.5 m
 *   bearing         = 0.000°  (exactly due north — same lon, higher lat)
 *   elevation       = atan2(3000 − d²/2R, d) ≈ 15.05°
 *                     (d²/2R ≈ 9.7 m curvature drop at 11.1 km)
 *
 * A truthful pose therefore reports headingDeg ≈ 0 and elevationDeg ≈ 15.05.
 */

const OBS = { lat: 37.8, lon: -122.27 };
const AC = { lat: 37.9, lon: -122.27, altitudeMeters: 3000 };
// A fixed server "now" near the catch time so the time-skew checks pass.
const NOW = 1_700_000_000;

describe("Geo math (ported from iOS Geo.swift)", () => {
  it("matches the hand-derived fixture", () => {
    const d = distanceMeters(OBS.lat, OBS.lon, AC.lat, AC.lon);
    const b = bearingDeg(OBS.lat, OBS.lon, AC.lat, AC.lon);
    const e = elevationDeg(0, AC.altitudeMeters, d);
    expect(d).toBeCloseTo(11119.49, 0); // ~11.1 km
    expect(b).toBeCloseTo(0, 4); // due north
    expect(e).toBeCloseTo(15.05, 1); // ~15.05° with curvature drop
  });
});

describe("validateCatch", () => {
  /** A truthful pose pointing exactly at the fixture aircraft. */
  const truthful: ObserverPose = {
    lat: OBS.lat,
    lon: OBS.lon,
    headingDeg: 0, // due north — matches the bearing
    elevationDeg: 15.05, // matches the curvature-corrected elevation
    headingAccuracyDeg: null,
  };
  const aircraft: AircraftPosition = {
    lat: AC.lat,
    lon: AC.lon,
    altitudeMeters: AC.altitudeMeters,
    positionTimestamp: NOW, // fresh fix
  };

  it("plausible: a truthful pose agrees with the geometry", () => {
    const r = validateCatch(truthful, aircraft, NOW, NOW);
    expect(r.verdict).toBe("plausible");
    expect(r.reasons).toEqual([]);
  });

  it("implausible: bearing far off the true bearing", () => {
    // Aircraft is due north (0°); claim the user faced due SOUTH (180°) — a 180°
    // error, well past the 30° tolerance.
    const bearingOff: ObserverPose = { ...truthful, headingDeg: 180 };
    const r = validateCatch(bearingOff, aircraft, NOW, NOW);
    expect(r.verdict).toBe("implausible");
    expect(r.reasons.some((reason) => reason.includes("bearing off"))).toBe(true);
  });

  it("widened tolerance: a 40° bearing error passes when headingAccuracy is 20°", () => {
    // 40° error > base 30° tol → would be implausible, but a reported ±20°
    // accuracy widens the tolerance to 50°, so it reads plausible.
    const widened: ObserverPose = { ...truthful, headingDeg: 40, headingAccuracyDeg: 20 };
    const r = validateCatch(widened, aircraft, NOW, NOW);
    expect(r.verdict).toBe("plausible");
  });

  it("unverifiable: null pose angles", () => {
    const noPose: ObserverPose = {
      lat: OBS.lat,
      lon: OBS.lon,
      headingDeg: null,
      elevationDeg: null,
      headingAccuracyDeg: null,
    };
    const r = validateCatch(noPose, aircraft, NOW, NOW);
    expect(r.verdict).toBe("unverifiable");
    expect(r.reasons[0]).toContain("unverifiable");
  });

  it("unverifiable: null aircraft (no position recorded — backfill path)", () => {
    const r = validateCatch(truthful, null, NOW, NOW);
    expect(r.verdict).toBe("unverifiable");
    expect(r.reasons).toEqual(["no aircraft position recorded"]);
  });

  it("implausible: caughtAt far outside the ±10 min skew window", () => {
    const r = validateCatch(truthful, aircraft, NOW + 3600, NOW); // 1 hr off
    expect(r.verdict).toBe("implausible");
    expect(r.reasons.some((reason) => reason.includes("caughtAt off"))).toBe(true);
  });

  it("implausible: slant distance beyond 100 km", () => {
    // An aircraft ~2° north (~222 km) is far past the 100 km cap. Heading still 0,
    // but the slant-distance reason fires.
    const farAircraft: AircraftPosition = { ...aircraft, lat: 39.8 };
    const farTruthful: ObserverPose = { ...truthful, elevationDeg: 0 };
    const r = validateCatch(farTruthful, farAircraft, NOW, NOW);
    expect(r.verdict).toBe("implausible");
    expect(r.reasons.some((reason) => reason.includes("slant distance"))).toBe(true);
  });

  it("implausible: aircraft fix far from caughtAt", () => {
    const staleFix: AircraftPosition = { ...aircraft, positionTimestamp: NOW - 3600 };
    const r = validateCatch(truthful, staleFix, NOW, NOW);
    expect(r.verdict).toBe("implausible");
    expect(r.reasons.some((reason) => reason.includes("aircraft fix"))).toBe(true);
  });

  it("the RESULT SHAPE is identical regardless of verdict (no oracle in the structure)", () => {
    const plausible = validateCatch(truthful, aircraft, NOW, NOW);
    const implausible = validateCatch({ ...truthful, headingDeg: 180 }, aircraft, NOW, NOW);
    const unverifiable = validateCatch(
      { ...truthful, headingDeg: null, elevationDeg: null },
      aircraft,
      NOW,
      NOW,
    );
    // Same keys, same value types — only the strings differ. (The HTTP response
    // doesn't even include the verdict; this asserts the function's own shape.)
    for (const r of [plausible, implausible, unverifiable]) {
      expect(Object.keys(r).sort()).toEqual(["reasons", "verdict"]);
      expect(typeof r.verdict).toBe("string");
      expect(Array.isArray(r.reasons)).toBe(true);
    }
  });
});
