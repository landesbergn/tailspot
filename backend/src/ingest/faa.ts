/**
 * FAA Releasable Aircraft Database import (WP 1.4).
 *
 * Source: https://registry.faa.gov/database/ReleasableAircraft.zip (~73 MB
 * zipped, ~250 MB unzipped). Two comma-separated files with a header row:
 *
 *   ACFTREF.txt — one row per aircraft-reference "MFR MDL CODE":
 *     CODE, MFR, MODEL, TYPE-ACFT, TYPE-ENG, …  (manufacturer/model lookup)
 *   MASTER.txt  — one row per US registration:
 *     N-NUMBER, …, MFR MDL CODE, …, MODE S CODE HEX, …
 *     ("MODE S CODE HEX" is the icao24; "MFR MDL CODE" joins to ACFTREF.CODE)
 *
 * Both files have a quirk the iOS-side generator handles: a trailing comma on
 * every data row (the FAA appends an empty field), and latin-1 encoding. The
 * column LAYOUT is positional-by-header — we map header name → index from the
 * first row, exactly like `tools/generate-faa-registry.py`.
 *
 * MEMORY: the files are large, so we STREAM-parse — read line by line, never
 * load a whole file into memory. ACFTREF is small enough to hold as a Map
 * (~90k rows of make/model); MASTER is streamed straight into batched upserts.
 *
 * IDEMPOTENT: upserts on the `icao24` PK (ON CONFLICT DO UPDATE), so re-runs
 * over a fresh download cleanly overwrite. A `--limit N` flag caps the number
 * of MASTER rows processed (fast smoke tests against the real file).
 *
 * TYPECODE ENRICHMENT (WP 1.4b): each MASTER row's "MFR MDL CODE" is looked up
 * in the committed `backend/data/faa-typecode-map.json` (built offline by
 * `tools/build-typecode-map.py`) to attach an ICAO type designator. A code with
 * no mapping leaves `typecode` null (registration-only, source="faa"). The
 * lookup is a flat Map read — deterministic, no fuzzy matching on the hot path.
 *
 * Run as a script:  npm run ingest:faa -- <path-to-extracted-dir> [--limit N]
 * where the dir contains MASTER.txt and ACFTREF.txt. Download + unzip is a
 * manual / cron step — see the README. NOTE: the FAA's Akamai front 403s curl's
 * default User-Agent; pass a browser UA ("Mozilla/5.0 ...") for the GET to
 * succeed. This task ships only the parser + a fixture-backed test, never the
 * real download.
 */

import { createReadStream } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import type { Database } from "../db/client.js";
import { getDb } from "../db/client.js";
import type { RegistryInsert } from "../db/schema.js";
import { upsertRegistry } from "./registryUpsert.js";
import { type TypecodeMap, loadTypecodeMap } from "./typecodeMap.js";

/** One ACFTREF row's contribution: manufacturer + model + FAA type codes. */
export interface AcftRef {
  manufacturer: string;
  model: string;
  typeAircraft: string;
  typeEngine: string;
}

/**
 * Split one FAA CSV line into trimmed fields. FAA files are plain
 * comma-separated with no embedded commas/quotes in the columns we use, so a
 * simple split is correct (the iOS generator uses Python's csv.reader, but the
 * relevant columns — hex code, mfr-mdl code, names — never contain commas).
 * Each field is whitespace-trimmed.
 */
export function splitFaaLine(line: string): string[] {
  return line.split(",").map((f) => f.trim());
}

/** Map a header line's column names → indices (names normalized, BOM stripped). */
export function headerIndex(headerLine: string): Record<string, number> {
  const cols = splitFaaLine(headerLine);
  const ix: Record<string, number> = {};
  cols.forEach((name, i) => {
    const clean = name.replace(/﻿/g, "").replace(/ï»¿/g, "").trim();
    ix[clean] = i;
  });
  return ix;
}

/**
 * Parse the full ACFTREF text into a Map keyed by CODE (the "MFR MDL CODE").
 * Pure (string in → Map out) for unit testing; the streaming file path uses the
 * line-by-line variant below for the large download.
 */
export function parseAcftRef(text: string): Map<string, AcftRef> {
  const lines = text.split(/\r?\n/);
  const map = new Map<string, AcftRef>();
  if (lines.length === 0) return map;
  const ix = headerIndex(lines[0]);
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === "") continue;
    const f = splitFaaLine(line);
    const code = f[ix.CODE];
    if (!code) continue;
    map.set(code, {
      manufacturer: f[ix.MFR] ?? "",
      model: f[ix.MODEL] ?? "",
      typeAircraft: f[ix["TYPE-ACFT"]] ?? "",
      typeEngine: f[ix["TYPE-ENG"]] ?? "",
    });
  }
  return map;
}

/**
 * Parse the full MASTER text into registry rows, joining each against the
 * ACFTREF map. Pure variant for unit tests. icao24 is normalized to lowercase
 * hex; rows with no hex code, or whose MFR-MDL code isn't in ACFTREF, are
 * dropped (no manufacturer/model to attach).
 *
 * `typecode` (WP 1.4b): the MFR-MDL code is looked up in the optional
 * `typecodeMap` (committed `faa-typecode-map.json`). A hit attaches the ICAO
 * designator so the merge layer can reach DOC 8643's clean names + rarity; a
 * miss leaves `typecode` null (source="faa", raw FAA names — the documented
 * behaviour for a US tail of unknown type). Pass an empty map (or omit) to
 * reproduce the pre-enrichment behaviour.
 */
export function parseMaster(
  text: string,
  acftRef: Map<string, AcftRef>,
  limit?: number,
  typecodeMap?: TypecodeMap,
): RegistryInsert[] {
  const lines = text.split(/\r?\n/);
  const rows: RegistryInsert[] = [];
  if (lines.length === 0) return rows;
  const ix = headerIndex(lines[0]);
  const hexCol = ix["MODE S CODE HEX"];
  const mdlCol = ix["MFR MDL CODE"];
  const nCol = ix["N-NUMBER"];
  for (let i = 1; i < lines.length; i++) {
    if (limit !== undefined && rows.length >= limit) break;
    const line = lines[i];
    if (line.trim() === "") continue;
    const f = splitFaaLine(line);
    const row = masterRowToRegistry(f, hexCol, mdlCol, nCol, acftRef, typecodeMap);
    if (row) rows.push(row);
  }
  return rows;
}

/** Build one registry row from a split MASTER line, or null to drop it. */
function masterRowToRegistry(
  f: string[],
  hexCol: number,
  mdlCol: number,
  nCol: number,
  acftRef: Map<string, AcftRef>,
  typecodeMap?: TypecodeMap,
): RegistryInsert | null {
  const hex = (f[hexCol] ?? "").trim().toLowerCase();
  if (!/^[0-9a-f]{6}$/.test(hex)) return null; // no/invalid Mode-S → drop
  const code = (f[mdlCol] ?? "").trim();
  const ref = acftRef.get(code);
  // A registration the FAA knows but with no ACFTREF match still gets a row,
  // carrying the tail number — manufacturer/model are then null (source="faa",
  // registration-only). That's more useful than dropping a known US tail.
  const nNumber = nCol !== undefined ? (f[nCol] ?? "").trim() : "";
  const registration = nNumber ? `N${nNumber}` : null;
  // WP 1.4b: attach the ICAO designator if the model code is in the map.
  const typecode = (code && typecodeMap?.get(code)) || null;
  return {
    icao24: hex,
    registration,
    manufacturerRaw: ref?.manufacturer || null,
    modelRaw: ref?.model || null,
    typecode,
    source: "faa",
  };
}

/**
 * Stream MASTER.txt line-by-line, joining against an in-memory ACFTREF map,
 * batching registry upserts. The large file never fully loads into memory.
 * Returns the count of rows upserted.
 */
export async function importFaa(
  db: Database,
  dir: string,
  opts: { limit?: number; typecodeMap?: TypecodeMap } = {},
): Promise<number> {
  // ACFTREF is small enough to hold; read it whole, then stream MASTER.
  const acftRef = await streamAcftRef(join(dir, "ACFTREF.txt"));
  // WP 1.4b: load the committed code -> designator map once (default path), or
  // accept an injected one for tests. Misses leave typecode null.
  const typecodeMap = opts.typecodeMap ?? loadTypecodeMap();

  const rl = createInterface({
    input: createReadStream(join(dir, "MASTER.txt"), { encoding: "latin1" }),
    crlfDelay: Number.POSITIVE_INFINITY,
  });

  let ix: Record<string, number> | undefined;
  let hexCol = -1;
  let mdlCol = -1;
  let nCol = -1;
  let batch: RegistryInsert[] = [];
  let total = 0;
  const BATCH = 1000;

  for await (const line of rl) {
    if (ix === undefined) {
      ix = headerIndex(line);
      hexCol = ix["MODE S CODE HEX"];
      mdlCol = ix["MFR MDL CODE"];
      nCol = ix["N-NUMBER"];
      continue;
    }
    if (line.trim() === "") continue;
    if (opts.limit !== undefined && total + batch.length >= opts.limit) break;
    const row = masterRowToRegistry(splitFaaLine(line), hexCol, mdlCol, nCol, acftRef, typecodeMap);
    if (!row) continue;
    batch.push(row);
    if (batch.length >= BATCH) {
      total += await upsertRegistry(db, batch);
      batch = [];
    }
  }
  if (batch.length > 0) total += await upsertRegistry(db, batch);
  return total;
}

/** Stream ACFTREF.txt into a Map without holding the file text in memory. */
async function streamAcftRef(path: string): Promise<Map<string, AcftRef>> {
  const map = new Map<string, AcftRef>();
  const rl = createInterface({
    input: createReadStream(path, { encoding: "latin1" }),
    crlfDelay: Number.POSITIVE_INFINITY,
  });
  let ix: Record<string, number> | undefined;
  for await (const line of rl) {
    if (ix === undefined) {
      ix = headerIndex(line);
      continue;
    }
    if (line.trim() === "") continue;
    const f = splitFaaLine(line);
    const code = f[ix.CODE];
    if (!code) continue;
    map.set(code, {
      manufacturer: f[ix.MFR] ?? "",
      model: f[ix.MODEL] ?? "",
      typeAircraft: f[ix["TYPE-ACFT"]] ?? "",
      typeEngine: f[ix["TYPE-ENG"]] ?? "",
    });
  }
  return map;
}

/** Script entrypoint:  node dist/ingest/faa.js <extracted-dir> [--limit N] */
async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const dir = args.find((a) => !a.startsWith("--"));
  if (!dir) {
    console.error(
      "usage: ingest:faa <extracted-dir> [--limit N]\n" +
        "  <extracted-dir> contains MASTER.txt and ACFTREF.txt (unzip ReleasableAircraft.zip first).",
    );
    process.exit(2);
  }
  const limitIx = args.indexOf("--limit");
  const limit = limitIx >= 0 ? Number(args[limitIx + 1]) : undefined;
  const db = getDb();
  const n = await importFaa(db, dir, { limit });
  console.log(`faa: upserted ${n} registry rows from ${dir}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
