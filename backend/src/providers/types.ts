/**
 * The frozen wire contract for position data.
 *
 * This is the *normalized* shape every PositionProvider must emit, regardless
 * of which upstream it talks to. The iOS client is built against exactly this
 * — see the GET /v1/aircraft route. SI units throughout: meters, m/s, degrees
 * true, unix *seconds* (not milliseconds).
 *
 * Normalization is lossy per-element: an upstream row that can't be normalized
 * (e.g. no lat/lon) is dropped, never failing the whole batch.
 * Lossy-but-resilient beats all-or-nothing for live air traffic.
 */

/**
 * Origin → destination for a flight, as airport ICAO codes (e.g. "KSFO",
 * "EGLL"). Resolved from the callsign via adsb.lol's route DB; either side may
 * be absent if only one end is known. This is purely descriptive metadata —
 * it never participates in the geometric identify math.
 */
export interface AircraftRoute {
  /** Origin airport ICAO code (4-letter, e.g. "KSFO"), when known. */
  originIcao?: string;
  /** Destination airport ICAO code (4-letter, e.g. "EGLL"), when known. */
  destIcao?: string;
  /** Origin airport IATA code (3-letter, e.g. "SFO"), when the route DB
   *  carried it. The DISPLAY code — travelers read HND, not RJTT; clients
   *  fall back to the ICAO code when absent. Additive 2026-07-05. */
  originIata?: string;
  /** Destination airport IATA code (3-letter, e.g. "LHR"), when known. */
  destIata?: string;
  /** Human-readable origin airport/city (e.g. "San Francisco"), when the
   *  route DB carried it. Rendered under the ICAO code in the catch reveal. */
  originName?: string;
  /** Human-readable destination airport/city (e.g. "London"). */
  destName?: string;
}

/** A geographic bounding box in decimal degrees. */
export interface Bbox {
  /** Minimum latitude (south edge). */
  lamin: number;
  /** Minimum longitude (west edge). */
  lomin: number;
  /** Maximum latitude (north edge). */
  lamax: number;
  /** Maximum longitude (east edge). */
  lomax: number;
}

/**
 * One aircraft, normalized to SI units. Field names mirror the iOS `Aircraft`
 * model where sensible.
 */
export interface NormalizedAircraft {
  /** Lowercase hex ICAO 24-bit address. */
  icao24: string;
  /** Whitespace-trimmed callsign; null if the upstream had none/empty. */
  callsign: string | null;
  /** ISO country name derived from icao24 (or supplied by upstream); null if unknown. */
  originCountry: string | null;
  longitude: number;
  latitude: number;
  /**
   * Geometric altitude preferred, barometric fallback, 0 if unknown or on
   * ground. Meters.
   */
  altitudeMeters: number;
  /** Ground speed in m/s, or null if unknown. */
  velocityMps: number | null;
  /** True track over ground in degrees, or null if unknown. */
  trackDeg: number | null;
  onGround: boolean;
  /** Unix seconds of the last position update, or null if unknown. */
  positionTimestamp: number | null;
  /**
   * ICAO type designator the upstream DB carries for this airframe (e.g.
   * "A359"). Optional — present only when the feed knows it. Lets a catch
   * resolve make/model/type/rarity at catch time without the per-hex metadata
   * endpoint (which is FAA-only and blind to foreign tails). Omitted from the
   * JSON when absent, so the iOS client decodes it as nil.
   */
  typecode?: string;
  /** Registration / tail number from the upstream DB (e.g. "9V-SMH"). Optional,
   *  same semantics as `typecode`. */
  registration?: string;
  /**
   * ADS-B emitter category the airframe broadcasts (DO-260B), uppercased:
   * "A1" light … "A5" heavy … "A7" rotorcraft, "B1" glider, "B6" UAV. Optional,
   * same omit-when-absent semantics as `typecode`. Unlike a manufacturer
   * string, A7 is an authoritative "this is a helicopter" signal — the iOS
   * client uses it to tag rotorcraft instead of guessing from brand names.
   */
  category?: string;
  /**
   * Origin → destination airports for this flight's callsign, when adsb.lol's
   * route DB resolves it (see `AdsbLolRouteService`). Optional, same
   * omit-when-absent semantics as `typecode`: the JSON key is dropped entirely
   * when no route is known, so old `Decodable` clients (and routeless flights)
   * are unaffected — additive and backward-compatible. NOT set by the position
   * normalizer; attached at serve time from the route cache.
   */
  route?: AircraftRoute;
}

/**
 * A point-in-time snapshot from an upstream provider.
 *
 * `fetchedAt` is the unix-seconds timestamp the *upstream* reported the
 * snapshot was generated — NOT when our server served the response. Clients
 * use it to reason about staleness, so it must travel through caching
 * unchanged.
 */
export interface ProviderSnapshot {
  fetchedAt: number;
  aircraft: NormalizedAircraft[];
}

/**
 * The seam every upstream adapter implements. One method: given a bbox, return
 * a normalized snapshot. Network errors throw (the route layer decides whether
 * to serve last-good cache or 503); a successful fetch that simply has no
 * aircraft returns an empty array, not an error.
 */
export interface PositionProvider {
  /** Human-readable name for logs ("adsblol", "opensky"). */
  readonly name: string;
  aircraftInBbox(bbox: Bbox): Promise<ProviderSnapshot>;
}

/** Thrown by adapters when the upstream is unreachable or returns a non-OK status. */
export class UpstreamError extends Error {
  constructor(
    message: string,
    readonly cause?: unknown,
  ) {
    super(message);
    this.name = "UpstreamError";
  }
}
