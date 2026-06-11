/**
 * Runtime accessor for the committed FAA "MFR MDL CODE" -> ICAO designator map
 * (WP 1.4b). The map is built OFFLINE by `backend/tools/build-typecode-map.py`
 * (a reproducible three-pass mapping over the FAA ACFTREF + the aircraft-
 * characteristics xlsx + DOC 8643), and committed at `backend/data/
 * faa-typecode-map.json`. The FAA ingest reads it here at runtime to populate
 * `registry.typecode` so `/v1/metadata/{icao24}` can merge in DOC 8643's clean
 * names + rarity.
 *
 * Why a static committed artifact, not a fuzzy match at ingest time: the ingest
 * must be deterministic and fast (it streams ~313k MASTER rows). All the fuzzy
 * normalization/family-rule work happens once, offline, and the result is a flat
 * lookup. See the build script's header for the precedence (family rules -> xlsx
 * join -> DOC 8643 join -> overrides) and the tail-weighted coverage report.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** A frozen mfrMdlCode -> ICAO typecode lookup. */
export type TypecodeMap = ReadonlyMap<string, string>;

const __dirname = dirname(fileURLToPath(import.meta.url));

/** Default location of the committed map (relative to this compiled module). */
export const DEFAULT_TYPECODE_MAP_PATH = join(__dirname, "../../data/faa-typecode-map.json");

let cached: TypecodeMap | undefined;

/**
 * Parse the committed JSON object into a Map. Pure (string in -> Map out) so
 * the loader is unit-testable without touching disk. Keys (FAA model codes) and
 * values (designators) are trimmed; the designator is uppercased to match the
 * `typecodes` table's PK casing. Empty/non-string entries are skipped.
 */
export function parseTypecodeMap(jsonText: string): TypecodeMap {
  const parsed = JSON.parse(jsonText) as Record<string, unknown>;
  const map = new Map<string, string>();
  for (const [rawCode, rawTypecode] of Object.entries(parsed)) {
    if (typeof rawTypecode !== "string") continue;
    const code = rawCode.trim();
    const typecode = rawTypecode.trim().toUpperCase();
    if (code === "" || typecode === "") continue;
    map.set(code, typecode);
  }
  return map;
}

/**
 * Load (and memoize) the committed map from disk. `path` is overridable for
 * tests; the default resolves to `backend/data/faa-typecode-map.json`. Memoized
 * so the FAA stream import doesn't re-read the file per batch.
 */
export function loadTypecodeMap(path: string = DEFAULT_TYPECODE_MAP_PATH): TypecodeMap {
  if (cached && path === DEFAULT_TYPECODE_MAP_PATH) return cached;
  const map = parseTypecodeMap(readFileSync(path, "utf8"));
  if (path === DEFAULT_TYPECODE_MAP_PATH) cached = map;
  return map;
}
