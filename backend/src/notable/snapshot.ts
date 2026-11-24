/**
 * Regenerate the committed notable-airframes snapshot from plane-alert-db.
 *
 *   npm run notable:snapshot                       # fetch upstream
 *   npm run notable:snapshot -- --input file.csv   # from a saved copy
 *   npm run notable:snapshot -- --output out.json  # write somewhere else
 *
 * The snapshot is the ONLY notable data the server has (directory.ts): there
 * is no runtime refresh. Re-run this when a release train opens, or when the
 * mapping in mapping.ts changes, then read the diff before committing it:
 * every added line is a name that will appear in the app.
 *
 * The CSV is read as data only. Nothing in it is executed.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { DEFAULT_NOTABLE_SNAPSHOT_PATH, serializeNotableSnapshot } from "./directory.js";
import { type NotableKind, parsePlaneAlertCsv } from "./mapping.js";

/** The upstream file. */
export const PLANE_ALERT_DB_CSV_URL =
  "https://raw.githubusercontent.com/sdr-enthusiasts/plane-alert-db/main/plane-alert-db.csv";

async function fetchPlaneAlertCsv(): Promise<string> {
  const res = await fetch(PLANE_ALERT_DB_CSV_URL, { signal: AbortSignal.timeout(60_000) });
  if (!res.ok) throw new Error(`plane-alert-db fetch failed: HTTP ${res.status}`);
  return res.text();
}

function argValue(args: string[], flag: string): string | undefined {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const input = argValue(args, "--input");
  const output = argValue(args, "--output") ?? DEFAULT_NOTABLE_SNAPSHOT_PATH;

  const csv = input ? readFileSync(input, "utf8") : await fetchPlaneAlertCsv();
  const entries = parsePlaneAlertCsv(csv);
  if (entries.size === 0) {
    throw new Error("no notable airframes parsed: is this the plane-alert-db CSV?");
  }

  const generatedAt = new Date().toISOString().slice(0, 10);
  writeFileSync(output, serializeNotableSnapshot(entries, generatedAt));

  const perKind = new Map<NotableKind, number>();
  let named = 0;
  for (const n of entries.values()) {
    perKind.set(n.kind, (perKind.get(n.kind) ?? 0) + 1);
    if (n.name !== undefined) named++;
  }
  console.log(`notable snapshot: ${entries.size} airframe(s), ${named} named -> ${output}`);
  for (const [kind, n] of [...perKind.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`  ${kind.padEnd(11)} ${String(n).padStart(5)}`);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
