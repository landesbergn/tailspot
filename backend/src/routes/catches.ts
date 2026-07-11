/**
 * Catch ingestion (WP 1.5) + catch listing for Hangar restore (issue #58).
 *
 *   GET /v1/catches?limit=500&offset=0   (auth required)
 *     → 200 { total, catches: [{ catchUuid, icao24, callsign, typecode,
 *              rarity, points, firstOfType, guessKind, guessValue,
 *              guessCorrect, caughtAt, observerLat, observerLon,
 *              aircraftAltitudeMeters, registration, manufacturer, model }…] }
 *       401 bad/absent token
 *     Returns ONLY the authenticated device's catches, oldest first. `total`
 *     is the device's full count so the client can page (limit ≤ 500) and
 *     size its restore prompt. Photos are not (and cannot be) included —
 *     they were never uploaded.
 *
 *   POST /v1/catches   (auth required)
 *     body { catchUuid, icao24, callsign|null, caughtAt, observer{…}, aircraft{…},
 *            guess?: { kind: "route"|"type", value: string } }
 *     → 201 { catchId, points, rarity, typecode, firstOfType, guessCorrect, duplicate:false }
 *       200 { …, duplicate:true }   when catchUuid was already ingested (replay)
 *       401 bad/absent token
 *       422 malformed body
 *
 * Server-side resolution: the icao24 is looked up in the metadata store →
 * typecode → rarity → points. The client sends NO points/rarity (deliberately);
 * we never trust client scoring.
 *
 * The optional `guess` block (game-layer PR1) carries the bonus-round guess
 * VALUE — the ICAO airport ident or typecode the user picked — never a verdict.
 * The server verifies it against its OWN truth ("type" → the registry-resolved
 * typecode for the icao24, the same resolution the scorer uses; "route" → the
 * RouteResolver behind GET /v1/routes/:callsign, correct iff the value matches
 * EITHER endpoint) and a correct guess earns +10% (route) / +25% (type) of the
 * base via the canonical scorer. Verification failure (resolver down, no route
 * on file, no callsign) scores the guess incorrect but NEVER fails the catch.
 *
 * Anti-cheat is INSTRUMENTED, NEVER ENFORCED: we compute a plausibility verdict,
 * store it on the row, log a counter — but the response is byte-shape-identical
 * regardless of the verdict, so a cheater gets no oracle to probe the validator.
 */

import type { FastifyInstance } from "fastify";
import { type GuessKind, isGuessKind } from "../catches/points.js";
import {
  type AircraftPosition,
  type ObserverPose,
  type ValidationResult,
  validateCatch,
} from "../catches/validateCatch.js";
import { resolveDevice } from "../identity/auth.js";
import type { RateLimiter } from "../identity/rateLimiter.js";
import type { CatchStore, IdentityStore } from "../identity/store.js";
import type { RouteResolver } from "../providers/adsblolRoutes.js";

export interface CatchesRouteOptions {
  identityStore: IdentityStore;
  catchStore: CatchStore;
  /** Per-device write limiter for catches. */
  catchLimiter: RateLimiter;
  /**
   * Route-guess verifier — the SAME resolver behind GET /v1/routes/:callsign
   * (in production the adsb.lol standing-data lookup, shared cache). Optional:
   * when absent (non-adsblol deployment, most tests), a route guess simply
   * verifies as incorrect — the catch itself is never blocked.
   */
  routeResolver?: RouteResolver;
  /** Injectable clock (unix seconds) for deterministic validation in tests. */
  nowSeconds?: () => number;
}

const ICAO24_RE = /^[0-9a-f]{6}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** A finite number, optionally bounded to ±range. */
function num(v: unknown, range?: number): number | null {
  if (typeof v !== "number" || !Number.isFinite(v)) return null;
  if (range !== undefined && (v < -range || v > range)) return null;
  return v;
}

/** A finite number OR explicit null (for nullable fields). undefined → "missing". */
function numOrNull(v: unknown): number | null | undefined {
  if (v === null) return null;
  if (typeof v === "number" && Number.isFinite(v)) return v;
  return undefined; // signals malformed (present but not number|null)
}

/** Guess values are short idents (4-char ICAO airports, ≤4-char typecodes);
 *  anything longer is garbage we refuse to store. */
const GUESS_VALUE_MAX_LENGTH = 16;

/** Page-size bounds for GET /v1/catches. A 500 cap comfortably covers the
 *  biggest real device today (<100 catches) in one page while still bounding
 *  a pathological request; the client pages by offset until it has `total`. */
const LIST_DEFAULT_LIMIT = 500;
const LIST_MAX_LIMIT = 500;

/** Parse a non-negative int query param, with a default and an optional cap. */
function intParam(v: unknown, fallback: number, max?: number): number {
  const n = typeof v === "string" ? Number.parseInt(v, 10) : typeof v === "number" ? v : Number.NaN;
  if (!Number.isFinite(n) || n < 0) return fallback;
  const floored = Math.floor(n);
  return max === undefined ? floored : Math.min(floored, max);
}

export function registerCatchesRoute(app: FastifyInstance, opts: CatchesRouteOptions): void {
  const { identityStore, catchStore, catchLimiter, routeResolver } = opts;
  const nowSeconds = opts.nowSeconds ?? (() => Math.floor(Date.now() / 1000));

  // ── GET /v1/catches — the device's own catches, for Hangar restore ────────
  // Auth REQUIRED (the bearer token both authenticates and scopes: a device
  // can only ever list itself — there is no deviceId parameter to probe).
  // No rate limiter, matching the read-only GET pattern (leaderboard).
  app.get("/v1/catches", async (request, reply) => {
    const device = await resolveDevice(identityStore, request.headers.authorization);
    if (!device) {
      return reply.code(401).send({ error: "unauthorized" });
    }
    const q = request.query as Record<string, unknown>;
    const limit = Math.max(1, intParam(q.limit, LIST_DEFAULT_LIMIT, LIST_MAX_LIMIT));
    const offset = intParam(q.offset, 0);

    const page = await catchStore.listCatches(device.id, limit, offset);
    return reply.code(200).send(page);
  });

  app.post("/v1/catches", async (request, reply) => {
    const device = await resolveDevice(identityStore, request.headers.authorization);
    if (!device) {
      return reply.code(401).send({ error: "unauthorized" });
    }

    const rl = catchLimiter.take(`device:${device.id}`);
    if (!rl.allowed) {
      reply.header("Retry-After", String(rl.retryAfterSeconds));
      return reply.code(429).send({ error: "rate limited" });
    }

    // ── Parse + validate the body shape (422 on malformed) ──────────────────
    const body = (request.body ?? {}) as Record<string, unknown>;

    const catchUuid = body.catchUuid;
    if (typeof catchUuid !== "string" || !UUID_RE.test(catchUuid)) {
      return reply.code(422).send({ error: "catchUuid must be a uuid" });
    }
    const icao24Raw = body.icao24;
    if (typeof icao24Raw !== "string" || !ICAO24_RE.test(icao24Raw.toLowerCase())) {
      return reply.code(422).send({ error: "icao24 must be six hex digits" });
    }
    const icao24 = icao24Raw.toLowerCase();

    const callsignRaw = body.callsign;
    if (callsignRaw !== null && typeof callsignRaw !== "string") {
      return reply.code(422).send({ error: "callsign must be a string or null" });
    }
    const callsign = typeof callsignRaw === "string" ? callsignRaw.trim() || null : null;

    const caughtAt = num(body.caughtAt);
    if (caughtAt === null) {
      return reply.code(422).send({ error: "caughtAt must be a unix-seconds number" });
    }

    const observerRaw = body.observer;
    const aircraftRaw = body.aircraft;
    if (typeof observerRaw !== "object" || observerRaw === null) {
      return reply.code(422).send({ error: "observer object required" });
    }
    // The aircraft block is NULLABLE (the whole object may be null). iOS Catch
    // rows recorded before WP 1.7 never stored the aircraft's position; they're
    // backfilled with aircraft:null. A present-but-non-object aircraft is still
    // malformed (422). Null → no angular validation, verdict "unverifiable".
    if (aircraftRaw !== null && typeof aircraftRaw !== "object") {
      return reply.code(422).send({ error: "aircraft must be an object or null" });
    }
    const o = observerRaw as Record<string, unknown>;

    const obsLat = num(o.lat, 90);
    const obsLon = num(o.lon, 180);
    if (obsLat === null || obsLon === null) {
      return reply.code(422).send({ error: "observer.lat/lon must be valid coordinates" });
    }
    // Pose angles are nullable (a catch from a device without a heading fix is
    // valid — it just validates as "unverifiable"). present-but-not-number → 422.
    const headingDeg = numOrNull(o.headingDeg);
    const elevationDeg = numOrNull(o.elevationDeg);
    const headingAccuracyDeg = numOrNull(o.headingAccuracyDeg);
    if (
      headingDeg === undefined ||
      elevationDeg === undefined ||
      headingAccuracyDeg === undefined
    ) {
      return reply.code(422).send({ error: "observer pose angles must be numbers or null" });
    }

    // Parse the aircraft block only when present. Null → all aircraft fields null.
    let aircraft: AircraftPosition | null = null;
    if (aircraftRaw !== null) {
      const a = aircraftRaw as Record<string, unknown>;
      const acLat = num(a.lat, 90);
      const acLon = num(a.lon, 180);
      const acAlt = num(a.altitudeMeters);
      if (acLat === null || acLon === null || acAlt === null) {
        return reply
          .code(422)
          .send({ error: "aircraft.lat/lon/altitudeMeters must be valid numbers" });
      }
      const aircraftPositionTimestamp = numOrNull(a.positionTimestamp);
      if (aircraftPositionTimestamp === undefined) {
        return reply
          .code(422)
          .send({ error: "aircraft.positionTimestamp must be a number or null" });
      }
      aircraft = {
        lat: acLat,
        lon: acLon,
        altitudeMeters: acAlt,
        positionTimestamp: aircraftPositionTimestamp,
      };
    }

    // ── Optional guess block: the guess VALUE, never a verdict ──────────────
    // Absent (or explicit null) = no guess. Present-but-malformed = 422, same
    // posture as every other body field. The value is normalized to uppercase
    // once here — both the verification compares and the stored audit copy use
    // the normalized form.
    const guessRaw = body.guess;
    let guess: { kind: GuessKind; value: string } | null = null;
    if (guessRaw !== undefined && guessRaw !== null) {
      if (typeof guessRaw !== "object") {
        return reply.code(422).send({ error: "guess must be an object" });
      }
      const g = guessRaw as Record<string, unknown>;
      if (!isGuessKind(g.kind)) {
        return reply.code(422).send({ error: 'guess.kind must be "route" or "type"' });
      }
      const value = typeof g.value === "string" ? g.value.trim().toUpperCase() : "";
      if (value === "" || value.length > GUESS_VALUE_MAX_LENGTH) {
        return reply.code(422).send({ error: "guess.value must be a short non-empty string" });
      }
      guess = { kind: g.kind, value };
    }

    // ── Server-side scoring (typecode → rarity → points, regime-stamped) ────
    // First-of-type is server-authoritative (un-spoofable): resolve the typecode,
    // then check whether THIS device already holds a catch of it BEFORE inserting
    // — the new row is first-of-type iff none exists. The flag is frozen onto the
    // row and fed into the ONE canonical scorer (the same `scoreCatch` the
    // re-score job calls), which adds the +50%-of-base bonus. (The deliberate
    // double-resolve — once here, once inside `scoreCatch` — keeps the scorer the
    // single owner of the rarity→points mapping; the lookups are small + indexed.)
    const { typecode: resolvedTypecode } = await catchStore.resolveRarity(icao24);
    const firstOfType = await catchStore.isFirstOfType(device.id, resolvedTypecode);

    // ── Verify the guess against SERVER truth (never the client's) ──────────
    // "type": compare against the registry-resolved typecode — the same
    // resolution path the scorer uses, so the guess is checked against exactly
    // what the catch will be scored as. "route": resolve the callsign through
    // the standing-data RouteResolver; correct iff the value matches EITHER
    // endpoint (absorbs the asked-endpoint ambiguity — see the plan's §A4).
    // Any verification gap — no resolver wired, no callsign, no route on file,
    // resolver failure — scores the guess incorrect and NEVER blocks the catch.
    let guessCorrect = false;
    if (guess?.kind === "type") {
      guessCorrect = resolvedTypecode !== null && guess.value === resolvedTypecode.toUpperCase();
    } else if (guess?.kind === "route") {
      if (routeResolver && callsign !== null) {
        try {
          const route = await routeResolver.resolve(callsign.toUpperCase());
          // Either-endpoint match; the endpoints are optional on the wire type
          // and guess.value is non-empty, so a missing endpoint never matches.
          guessCorrect =
            route !== null &&
            (guess.value === route.originIcao?.toUpperCase() ||
              guess.value === route.destIcao?.toUpperCase());
        } catch (err) {
          // Resolver transport failure: the bonus is forfeit (we can't verify,
          // and we never trust the client), but the catch goes through. Logged
          // for telemetry — a spike here means honest guesses are being eaten.
          request.log.warn({ err, callsign, icao24 }, "route-guess verification failed");
        }
      } else {
        request.log.info({ callsign, icao24 }, "route guess unverifiable (no resolver/callsign)");
      }
    }

    const { typecode, rarity, points, scoringVersion } = await catchStore.scoreCatch(icao24, {
      firstOfType,
      guess: guess ? { kind: guess.kind, correct: guessCorrect } : undefined,
    });

    // ── Instrumented anti-cheat (stored, never enforced) ────────────────────
    const observer: ObserverPose = {
      lat: obsLat,
      lon: obsLon,
      headingDeg,
      elevationDeg,
      headingAccuracyDeg,
    };
    const validation: ValidationResult = validateCatch(observer, aircraft, caughtAt, nowSeconds());
    // A counter for telemetry — NOT a gate. We want to know the real-world
    // distribution of verdicts before deciding whether/how to ever enforce.
    request.log.info(
      { verdict: validation.verdict, icao24, deviceId: device.id },
      "catch validation verdict",
    );

    // ── Persist (idempotent on catchUuid) ───────────────────────────────────
    const { result, duplicate } = await catchStore.insertOrGet({
      catchUuid,
      deviceId: device.id,
      icao24,
      callsign,
      typecode,
      rarity,
      points,
      scoringVersion,
      firstOfType,
      guessKind: guess?.kind ?? null,
      guessValue: guess?.value ?? null,
      guessCorrect,
      caughtAt: new Date(caughtAt * 1000),
      observerLat: obsLat,
      observerLon: obsLon,
      headingDeg,
      elevationDeg,
      headingAccuracyDeg,
      aircraftLat: aircraft?.lat ?? null,
      aircraftLon: aircraft?.lon ?? null,
      aircraftAltitudeMeters: aircraft?.altitudeMeters ?? null,
      aircraftPositionTimestamp:
        aircraft?.positionTimestamp == null ? null : new Date(aircraft.positionTimestamp * 1000),
      validation,
    });

    // Response NEVER varies on the verdict (no oracle). The only difference
    // between a fresh insert and a replay is the status code + `duplicate` flag.
    return reply.code(duplicate ? 200 : 201).send({
      catchId: result.catchId,
      points: result.points,
      rarity: result.rarity,
      typecode: result.typecode,
      firstOfType: result.firstOfType,
      guessCorrect: result.guessCorrect,
      duplicate,
    });
  });
}
