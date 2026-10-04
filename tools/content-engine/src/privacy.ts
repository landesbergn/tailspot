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
 *
 * REAL USER CATCHES (decision: Noah, 2026-10-04). Promotional posts may
 * feature real Tailspot catches, at exactly this level of detail and no more:
 *
 *   aircraft model (+ operator / airline), city, and day.
 *
 * Never: the spotter's handle, the registration, callsign or icao24, photos,
 * coordinates, origin/destination, the time of day, or anything else
 * per-user. The real-catches template enforces this structurally: its HogQL
 * query never SELECTs those properties, `projectCatchRows` drops any column
 * outside CATCH_COLUMNS before data is used or saved as a fixture, and the
 * city is IP-derived and therefore approximate, so it is phrased as "in the
 * San Francisco area" / "near Tucson" (metro-level where we know the metro).
 * Rules 1 and 2 above still apply to catches: `isCatchSpotlightable` never
 * spotlights a privately operated GA or business aircraft (an Epic E1000, a
 * Global Express or a Gulfstream) unless its operator is an airline, cargo
 * carrier or military unit. Military types are fine.
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

// ── Real user catches (Noah's 2026-10-04 decision; see the header) ──

/**
 * The ONLY catch_performed properties the engine may read. Anything else in a
 * response (or a hand-edited fixture) is dropped before use. Deliberately
 * absent: handle, registration, callsign, icao24, origin/dest, photo, GPS,
 * timestamps finer than a day.
 */
export const CATCH_COLUMNS = ["rarity", "manufacturer", "model", "operator_name", "typecode", "city", "country", "day", "within_48h"] as const;
export type CatchColumn = (typeof CATCH_COLUMNS)[number];

/**
 * Operators that make a GA / business type a fleet aircraft rather than a
 * private one: airlines, cargo carriers, military and government flying.
 * Charter-management and fractional brands (NetJets, Flexjet, Solairus, Vista,
 * Executive Jet Management) deliberately do NOT match: from a catch we have no
 * callsign to tell a fleet leg from an owner's own trip.
 */
const FLEET_OPERATOR = /(air ?lines?|airways|cargo|express|freight|air force|navy|army|marine|coast guard|military|air mobility command|national guard|nasa)/i;

/** Military types the app's table classes as GA (no civil private fleet to protect). */
const MILITARY_TYPECODES = new Set(["T38"]);

/** A label from the data is shown only if it looks like a name, not an identifier. */
export function isPlainLabel(s: string | null | undefined, maxLen = 48): s is string {
  if (!s) return false;
  const t = s.trim();
  if (!t || t.length > maxLen) return false;
  if (/[@#<>{}\[\]|\\/]/.test(t)) return false; // handles, markup, paths
  if (!/[a-z]/.test(t)) return false; // all-caps/digits = a tail number or callsign, not a name
  return true;
}

export interface CatchIdentity {
  typecode: string | null;
  operator: string | null;
}

/** May this catch's aircraft be named on a public slide? */
export function isCatchSpotlightable(c: CatchIdentity): boolean {
  const code = c.typecode?.toUpperCase() ?? null;
  const cls = typeInfo(code)?.type ?? null;
  if (cls === "mil" || (code && MILITARY_TYPECODES.has(code))) return true;
  if (cls === "ga" || cls === "biz" || cls === null) {
    return isPlainLabel(c.operator) && FLEET_OPERATOR.test(c.operator);
  }
  return true;
}
