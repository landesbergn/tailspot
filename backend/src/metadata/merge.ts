/**
 * Pure merge semantics for the metadata service (WP 1.4).
 *
 * The two sources:
 *   - FAA registry (authoritative for *which airframe* a US tail is) provides
 *     registration + raw manufacturer/model + an optional typecode.
 *   - ICAO DOC 8643 (authoritative for *clean type naming*) provides canonical
 *     manufacturer/model for a typecode.
 *
 * The rule (frozen contract): when the FAA row carries a typecode that DOC 8643
 * knows, prefer DOC 8643's manufacturer/model — they're canonical, whereas FAA
 * strings are messy ALL-CAPS ("CIRRUS DESIGN CORP" / "SR22T"). registration and
 * the typecode itself always come from the FAA row. `source`:
 *
 *   - "merged"  — both contributed (FAA airframe + DOC 8643 names)
 *   - "faa"     — only the FAA knew it (typecode absent or unknown to DOC 8643)
 *   - "doc8643" — only DOC 8643 knew it (no registry row at all)
 *
 * `null` is returned when neither source has anything → the route 404s.
 *
 * This is a pure function (no DB, no I/O) so the merge rules are unit-tested in
 * isolation; the store just feeds it rows.
 */

import type { MetadataRecord } from "./store.js";

/** What the FAA registry row contributes. */
export interface RegistryFacts {
  registration: string | null;
  manufacturerRaw: string | null;
  modelRaw: string | null;
  typecode: string | null;
}

/** What a DOC 8643 typecode row contributes. */
export interface TypecodeFacts {
  typecode: string;
  manufacturer: string | null;
  model: string | null;
}

/**
 * Merge a (possibly-null) registry row with a (possibly-null) DOC 8643 row into
 * the client-facing record, or `null` if neither source knows the airframe.
 *
 * operatorName is always null for now — live operator/livery lookups are a later
 * seam (a community/route data source). See the TODO at the injection point.
 */
export function mergeMetadata(
  reg: RegistryFacts | null,
  type: TypecodeFacts | null,
): MetadataRecord | null {
  // Neither source knows it.
  if (!reg && !type) return null;

  // DOC 8643 only (no registry row). We never reach this from the Drizzle store
  // today — a DOC 8643 row is keyed by typecode, and we only look it up via the
  // registry's typecode — but the merge function honors it for completeness and
  // for a future "lookup-by-typecode" seam, and the doc8643-only path is tested.
  if (!reg && type) {
    return {
      registration: null,
      manufacturer: type.manufacturer,
      model: type.model,
      typecode: type.typecode,
      operatorName: operatorNameSeam(),
      source: "doc8643",
    };
  }

  // From here, reg is non-null.
  const r = reg as RegistryFacts;

  // FAA only — no DOC 8643 contribution (typecode absent or unknown there).
  if (!type) {
    return {
      registration: r.registration,
      manufacturer: r.manufacturerRaw,
      model: r.modelRaw,
      typecode: r.typecode,
      operatorName: operatorNameSeam(),
      source: "faa",
    };
  }

  // Both contributed → merged: FAA registration + DOC 8643 canonical names win.
  return {
    registration: r.registration,
    manufacturer: type.manufacturer,
    model: type.model,
    // typecode always from the FAA row (it's why we found the DOC 8643 row);
    // identical to type.typecode by construction.
    typecode: r.typecode,
    operatorName: operatorNameSeam(),
    source: "merged",
  };
}

/**
 * Injection point for live operator/livery lookups.
 *
 * TODO(WP-later): wire a community operator source here (e.g. a route/operator
 * dataset keyed by callsign or registration). The wire contract already exposes
 * `operatorName`; for now it's intentionally null so the iOS client can build
 * against the field without us guessing an operator. Replace this stub — and
 * give `mergeMetadata` the operator input it needs — when that source lands.
 */
function operatorNameSeam(): string | null {
  return null;
}
