/**
 * Regenerate the committed notable-airframes snapshot from plane-alert-db.
 *
 *   npm run notable:snapshot                       # fetch upstream
 *   npm run notable:snapshot -- --input file.csv   # from a saved copy
 *   npm run notable:snapshot -- --output out.json  # write somewhere else
 *
 * The snapshot is only the boot-time fallback: a running server refreshes
 * itself from upstream daily (directory.ts), so this never NEEDS re-running.
 * Re-run it when the mapping in mapping.ts changes, so the first minute after
 * a deploy and every test agree with the new rules, and commit the diff.
 *
 * The CSV is read as data only. Nothing in it is executed.
 */

import { readFileSync, writeFileSync } from "node:fs";
import {
  DEFAULT_NOTABLE_SNAPSHOT_PATH,
  fetchPlaneAlertCsv,
  serializeNotableSnapshot,
} from "./directory.js";
import { type NotableKind, parsePlaneAlertCsv } from "./mapping.js";

function argValue(args: string[], flag: string): string | undefined {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const input = argValue(args, "--input");
  const output = argValue(args, "--output") ?? DEFAULT_NOTABLE_SNAPSHOT_PATH;

  const csv = input
    ? readFileSync(input, "utf8")
    : await fetchPlaneAlertCsv(AbortSignal.timeout(60_000));
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
