import type { FastifyInstance } from "fastify";
import type { MetadataStore } from "../metadata/store.js";

/**
 * GET /v1/metadata/{icao24}
 *
 * Per-airframe metadata: FAA registry merged with ICAO DOC 8643. The wire
 * contract (frozen — the iOS client is built against it):
 *
 *   200 {
 *     icao24, registration, manufacturer, model, typecode, operatorName,
 *     source: "faa" | "doc8643" | "merged"
 *   }
 *   404 { error: "unknown aircraft" }   // no source knows the airframe
 *   400 { error }                       // malformed icao24
 *
 * Storage is injected as a `MetadataStore` (mirrors the aircraft route's
 * injected `PositionProvider`), so the route is ignorant of Postgres vs. an
 * in-memory fake.
 */

export interface MetadataRouteOptions {
  store: MetadataStore;
}

/** A lowercase 24-bit hex Mode-S address: exactly six hex digits. */
const ICAO24_RE = /^[0-9a-f]{6}$/;

export function registerMetadataRoute(app: FastifyInstance, opts: MetadataRouteOptions): void {
  const { store } = opts;

  app.get("/v1/metadata/:icao24", async (request, reply) => {
    const { icao24: raw } = request.params as { icao24: string };

    // Normalize to lowercase before validating so an uppercase-hex request is
    // accepted (clients may send either), but reject anything that isn't six
    // hex digits — including too-short, too-long, or non-hex input.
    const icao24 = raw.toLowerCase();
    if (!ICAO24_RE.test(icao24)) {
      return reply.code(400).send({ error: "malformed icao24" });
    }

    const record = await store.lookup(icao24);
    if (!record) {
      return reply.code(404).send({ error: "unknown aircraft" });
    }

    return reply.code(200).send({ icao24, ...record });
  });
}
