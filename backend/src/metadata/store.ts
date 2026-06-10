/**
 * The metadata store seam (WP 1.4).
 *
 * `MetadataStore` is the one interface the `/v1/metadata/{icao24}` route depends
 * on — mirroring how the aircraft route depends on an injected `PositionProvider`.
 * Production injects `DrizzleMetadataStore` (Postgres/PGlite); the route tests
 * inject either that-over-PGlite or a trivial in-memory fake. Keeping the route
 * ignorant of storage means swapping the backing store is a one-line change in
 * the app factory.
 *
 * The merge semantics (FAA raw vs DOC 8643 canonical) live in `merge.ts`, a pure
 * function, so they can be unit-tested without any database at all.
 */

import { eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { registry, typecodes } from "../db/schema.js";
import { type RegistryFacts, type TypecodeFacts, mergeMetadata } from "./merge.js";

/**
 * The merged, client-facing metadata record (the frozen wire shape minus the
 * echoed `icao24`, which the route adds). `source` records which inputs
 * contributed: both → "merged", FAA only → "faa", DOC 8643 only → "doc8643".
 */
export interface MetadataRecord {
  registration: string | null;
  manufacturer: string | null;
  model: string | null;
  typecode: string | null;
  operatorName: string | null;
  source: "faa" | "doc8643" | "merged";
}

/**
 * The lookup seam. `lookup` returns the merged record for a known airframe, or
 * `null` when no source knows it (→ the route turns that into a 404).
 *
 * The icao24 passed in is already validated + normalized to lowercase hex by
 * the route, so implementations may assume `[0-9a-f]{6}`.
 */
export interface MetadataStore {
  lookup(icao24: string): Promise<MetadataRecord | null>;
}

/**
 * Drizzle-backed store. Two point-lookups (registry by icao24, then — if the
 * registry row carried a typecode — the matching DOC 8643 row). If the registry
 * misses entirely there is no typecode to chase, so we stop: a DOC 8643 row is
 * about a *type*, never a specific airframe, and we only reach it via the
 * registry's typecode. Pure merge logic is delegated to `mergeMetadata`.
 */
export class DrizzleMetadataStore implements MetadataStore {
  constructor(private readonly db: Database) {}

  async lookup(icao24: string): Promise<MetadataRecord | null> {
    const regRows = await this.db
      .select()
      .from(registry)
      .where(eq(registry.icao24, icao24))
      .limit(1);
    const reg = regRows[0];

    // Resolve the DOC 8643 row only when the registry pointed us at a typecode.
    let typeFacts: TypecodeFacts | null = null;
    if (reg?.typecode) {
      const tcRows = await this.db
        .select()
        .from(typecodes)
        .where(eq(typecodes.typecode, reg.typecode))
        .limit(1);
      const tc = tcRows[0];
      if (tc) {
        typeFacts = {
          typecode: tc.typecode,
          manufacturer: tc.manufacturer,
          model: tc.model,
        };
      }
    }

    const regFacts: RegistryFacts | null = reg
      ? {
          registration: reg.registration,
          manufacturerRaw: reg.manufacturerRaw,
          modelRaw: reg.modelRaw,
          typecode: reg.typecode,
        }
      : null;

    return mergeMetadata(regFacts, typeFacts);
  }
}
