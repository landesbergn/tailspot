/**
 * Privacy rules for anything that becomes a public post.
 *
 * Tailspot's privacy policy (§5) and the growth plan's guardrail: user photos
 * never leave the phone, catch GPS is never shown, no user-identifying data.
 * This engine reads ONLY public ADS-B + public aggregates + Noah's own photos,
 * and on top of that applies these rules to the aircraft it puts on a slide:
 *
 *  1. Owners who opted out of display (FAA LADD, Privacy ICAO Address) are
 *     never spotlighted — even though adsb.lol still publishes them.
 *  2. Privately operated GA / business aircraft are never spotlighted: a
 *     private jet's tail number tracks a person. Airline, cargo, fractional
 *     (ICAO-callsign) and military aircraft are fine — they're fleets.
 *  3. Positions are named at REGION level only (see geo.ts), never coordinates.
 *  4. Stale (> 60 s) or on-ground positions are not "in the sky right now".
 *
 * Aggregate COUNTS may include every aircraft (a number identifies nobody).
 */

import type { Plane } from "./adsb.ts";
import { typeInfo } from "./aircraftTypes.ts";

/** ICAO airline-style callsign: 3 letters then a digit (UAL875, LXJ506, RCH123). */
const OPERATOR_CALLSIGN = /^[A-Z]{3}\d/;

export const MAX_POSITION_AGE_S = 60;
export const MIN_AIRBORNE_FT = 500;

export function isFreshAirborne(p: Plane): boolean {
  if (p.onGround || p.altFt === null || p.altFt < MIN_AIRBORNE_FT) return false;
  if (p.seenPosS !== null && p.seenPosS > MAX_POSITION_AGE_S) return false;
  return true;
}

/** True when the callsign is just the tail number (typical of private flights). */
function callsignIsRegistration(p: Plane): boolean {
  if (!p.callsign || !p.registration) return false;
  return p.callsign.replace(/-/g, "") === p.registration.replace(/-/g, "");
}

/** May this aircraft be named on a public slide? */
export function isSpotlightable(p: Plane): boolean {
  if (p.privacyListed) return false;
  if (!p.callsign) return false;
  if (!isFreshAirborne(p)) return false;
  if (p.military) return true;
  const cls = typeInfo(p.typecode)?.type ?? null;
  const isLight = cls === "ga" || cls === "biz" || cls === null || p.category === "A1" || p.category === "A7";
  if (isLight) {
    // Only fleet operators (airline-style callsign) — never a private tail number.
    return OPERATOR_CALLSIGN.test(p.callsign) && !callsignIsRegistration(p);
  }
  return !callsignIsRegistration(p);
}
