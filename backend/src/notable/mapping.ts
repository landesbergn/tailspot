/**
 * Notable planes: the pure mapping from one plane-alert-db row to what
 * Tailspot says about that airframe.
 *
 * SOURCE. plane-alert-db (https://github.com/sdr-enthusiasts/plane-alert-db),
 * a community-maintained list of individually interesting airframes keyed by
 * ICAO hex. Open Database License 1.0; attribution in data/NOTICE.md.
 *
 *   $ICAO,$Registration,$Operator,$Type,$ICAO Type,#CMPG,$Tag 1,$#Tag 2,$#Tag 3,Category,$#Link
 *
 * WHAT REACHES A USER. Only three things: a `kind` (one of six), that kind's
 * fixed `label`, and optionally the `name` (the Operator column). The Tag
 * columns and the raw Category are NEVER exposed. They are the upstream
 * maintainers' in-jokes and editorial labels ("Dictator Alert", "Dirty
 * Money"), written for a hobbyist feed, not for an app's users.
 *
 * UNKNOWN CATEGORIES ARE EXCLUDED. The map below is an allow-list, so a
 * category upstream adds tomorrow does nothing until someone maps it here.
 * That keeps a regenerated snapshot's diff to rows someone chose to include.
 */

import { parseCsv } from "./csv.js";

export type NotableKind = "government" | "celebrity" | "business" | "team" | "special" | "working";

/** The user-facing label for each kind. Fixed strings: the app shows them as is. */
export const NOTABLE_LABELS: Record<NotableKind, string> = {
  government: "Head of state and government",
  celebrity: "Celebrity",
  business: "Business jet",
  team: "Team plane",
  special: "Historic and special",
  working: "Special mission",
};

/** Every kind, in a fixed order (for per-kind counts and reports). */
export const NOTABLE_KINDS = Object.keys(NOTABLE_LABELS) as NotableKind[];

/** Type guard for a kind string (used when reading the committed snapshot). */
export function isNotableKind(value: unknown): value is NotableKind {
  return typeof value === "string" && Object.hasOwn(NOTABLE_LABELS, value);
}

/** What the API says about a notable airframe (the `notable` wire object). */
export interface Notable {
  kind: NotableKind;
  label: string;
  /** The operator or owner, when upstream names one. */
  name?: string;
}

/** The read side every consumer depends on (routes, the scorer, tests' fakes). */
export interface NotableLookup {
  lookup(icao24: string): Notable | undefined;
  /**
   * How many airframes the directory holds, when it can say. Zero means the
   * directory has no data at all (the snapshot failed to load), which is different from "this plane is not notable".
   */
  readonly size?: number;
}

/**
 * Whether a directory can vouch for "not notable". An absent or EMPTY
 * directory cannot: the catch routes then omit `notable` altogether, so the
 * app treats the server as not knowing (it neither clears a star nor marks
 * its backfill of past catches done).
 */
export function notableDirectoryHasData(directory: NotableLookup | undefined): boolean {
  return directory !== undefined && (directory.size === undefined || directory.size > 0);
}

/**
 * plane-alert-db Category → kind. Matched on the trimmed category, exactly.
 *
 * Deliberately NOT mapped (so excluded), beyond the military branches:
 *   - Flying Doctors, Police Forces, UK National Police Air Service, PIA:
 *     excluded by product decision (air ambulances and police are everyday
 *     traffic, not a find).
 *   - Joe Cool: a mixed bag where 55 of 264 rows are ordinary Cirrus Vision
 *     jets, which would wear a "Historic and special" badge they haven't earned.
 *   - Da Comrade, Ukraine: mostly Soviet-era freighters, tagged upstream for
 *     sanctions and arms-embargo history. Not a "special" we want to label.
 *   - Jesus he Knows me: church and televangelist aircraft. No kind fits
 *     without the label becoming a comment on them.
 *   - Watch Me Fly (training fleets), UAV (drones).
 */
export const CATEGORY_KINDS: Readonly<Record<string, NotableKind>> = {
  Governments: "government",
  "Dictator Alert": "government",
  "Head of State": "government",
  "Royal Aircraft": "government",

  "Don't you know who I am?": "celebrity",

  "As Seen on TV": "business",
  // Individuals' jets, but also their companies' (Norilsk Nickel's helicopters,
  // for one), so "Celebrity" would mislabel part of it.
  Oligarch: "business",
  Bizjets: "business",
  "Vanity Plate": "business",
  "Climate Crisis": "business",

  Football: "team",

  Historic: "special",
  Distinctive: "special",
  "Aerobatic Teams": "special",
  "Big Hello": "special", // Skycranes and other heavy-lift helicopters
  "Gas Bags": "special", // balloons and airships
  Nuclear: "special",
  // Judgement calls, from reading the full category list (2026-11-21):
  Radiohead: "special", // Air Force One (VC-25) and Stratolaunch's Roc
  "Jump Johnny Jump": "special", // de Havilland Chipmunks, a 1940s trainer
  "You came here in that thing?": "special", // gyrocopters, microlights, canards
  Zoomies: "special", // civil-registered fighter jets (the military rows are dropped)

  Coastguard: "working",
  "Aerial Firefighter": "working",
  "Hired Gun": "working",
  "Ptolemy would be proud": "working", // aerial survey
  "Dogs with Jobs": "working",
  "Perfectly Serviceable Aircraft": "working", // skydive operators
  Oxcart: "working", // surveillance
  "Special Forces": "working",
  // Judgement calls:
  CAP: "working", // Civil Air Patrol search and rescue
  "Fire Fighting": "working",
  Quango: "working", // United Nations aircraft
};

/**
 * Categories kept whatever their #CMPG says. Every other category drops its
 * military (`Mil`) and police (`Pol`) rows: an air force's presidential
 * transport or a display team is a find, a line fighter or a police
 * helicopter is not.
 */
export const KEPT_REGARDLESS_OF_CMPG: ReadonlySet<string> = new Set([
  "Governments",
  "Dictator Alert",
  "Head of State",
  "Royal Aircraft",
  "Historic",
  "Aerobatic Teams",
]);

const EXCLUDED_CMPG: ReadonlySet<string> = new Set(["mil", "pol"]);

/** Operator values that name nobody. Compared lowercased. */
const PLACEHOLDER_NAMES: ReadonlySet<string> = new Set([
  "private",
  "private owner",
  "privately owned",
  "corporate",
  "unknown",
  "unknown owner",
  "unknown operator",
  "operator unknown",
  "tbc",
  "tbd",
  "n/a",
  "na",
  "none",
  "-",
  "?",
]);

/** Longest `name` we send, in code points. Upstream's longest today is 50. */
export const NOTABLE_NAME_MAX_LENGTH = 60;

const ICAO24_RE = /^[0-9a-f]{6}$/;

/** The fields of one upstream row that the mapping reads. */
export interface PlaneAlertRow {
  icao: string;
  registration?: string;
  operator: string;
  cmpg: string;
  category: string;
}

/**
 * Characters that must never reach a label on someone's screen, whatever a
 * community-edited CSV contains. `Cc` is the C0/C1 control characters. `Cf`
 * is the invisible format characters: the bidirectional embedding, override
 * and isolate controls (U+202A–202E, U+2066–2069) that can reorder the text
 * around them, the directional marks, and the zero-width characters
 * (U+200B–200D, word joiner U+2060, the BOM U+FEFF, soft hyphen U+00AD).
 */
const FORMAT_CHARS = /\p{Cf}/gu;
const CONTROL_CHARS = /\p{Cc}/gu;

/**
 * The display name from an Operator value, or undefined when it names nobody.
 * In order: invisible format characters are removed (first, because JavaScript
 * counts the BOM as whitespace and it must vanish, not become a space);
 * whitespace runs, tabs and line breaks included, become one space; the
 * remaining control characters are removed; then the result is trimmed and
 * capped. The cap counts code points, so it never cuts an astral character (an
 * emoji, say) in half and leaves a lone surrogate.
 */
export function notableName(operator: string, registration = ""): string | undefined {
  const name = operator
    .replace(FORMAT_CHARS, "")
    .replace(/\s+/g, " ")
    .replace(CONTROL_CHARS, "")
    .replace(/ {2,}/g, " ")
    .trim();
  if (name === "") return undefined;
  const lower = name.toLowerCase();
  if (PLACEHOLDER_NAMES.has(lower)) return undefined;
  // Some rows repeat the registration as the operator. That is not a name.
  if (lower === registration.trim().toLowerCase()) return undefined;
  const codePoints = Array.from(name);
  return codePoints.length > NOTABLE_NAME_MAX_LENGTH
    ? codePoints.slice(0, NOTABLE_NAME_MAX_LENGTH).join("").trimEnd()
    : name;
}

/**
 * Map one upstream row. Null means "not notable": a malformed hex, an unmapped
 * or excluded category, or a military/police row outside the kept categories.
 */
export function mapPlaneAlertRow(row: PlaneAlertRow): { icao24: string; notable: Notable } | null {
  const icao24 = row.icao.trim().toLowerCase();
  if (!ICAO24_RE.test(icao24)) return null;

  const category = row.category.trim();
  if (!Object.hasOwn(CATEGORY_KINDS, category)) return null;
  // Upstream files the presidential VC-25s under a catch-all category;
  // a government-operated row there is a head-of-state aircraft.
  const isGovRadiohead = category === "Radiohead" && row.cmpg.trim().toLowerCase() === "gov";
  const kind = isGovRadiohead ? "government" : CATEGORY_KINDS[category];

  if (EXCLUDED_CMPG.has(row.cmpg.trim().toLowerCase()) && !KEPT_REGARDLESS_OF_CMPG.has(category)) {
    return null;
  }

  return { icao24, notable: makeNotable(kind, notableName(row.operator, row.registration)) };
}

/** Build the wire object with a stable key order and no `name` key when absent. */
export function makeNotable(kind: NotableKind, name?: string): Notable {
  return name === undefined
    ? { kind, label: NOTABLE_LABELS[kind] }
    : { kind, label: NOTABLE_LABELS[kind], name };
}

/** The upstream header names of the columns we read. */
const COLUMNS = {
  icao: "$ICAO",
  registration: "$Registration",
  operator: "$Operator",
  cmpg: "#CMPG",
  category: "Category",
} as const;

/**
 * Parse the whole upstream CSV into icao24 → notable. Columns are found by
 * header NAME, not position, so an upstream column reorder still parses and a
 * renamed or missing column yields an empty map (which snapshot.ts refuses)
 * instead of silently reading the wrong field. When a hex appears twice the
 * first row wins.
 */
export function parsePlaneAlertCsv(text: string): Map<string, Notable> {
  const out = new Map<string, Notable>();
  const rows = parseCsv(text);
  const header = rows[0]?.map((h) => h.trim());
  if (!header) return out;

  const col = {
    icao: header.indexOf(COLUMNS.icao),
    registration: header.indexOf(COLUMNS.registration),
    operator: header.indexOf(COLUMNS.operator),
    cmpg: header.indexOf(COLUMNS.cmpg),
    category: header.indexOf(COLUMNS.category),
  };
  // Registration only refines the name, so it alone may be absent.
  if (col.icao < 0 || col.operator < 0 || col.cmpg < 0 || col.category < 0) return out;

  for (let i = 1; i < rows.length; i++) {
    const r = rows[i];
    const mapped = mapPlaneAlertRow({
      icao: r[col.icao] ?? "",
      registration: col.registration >= 0 ? (r[col.registration] ?? "") : "",
      operator: r[col.operator] ?? "",
      cmpg: r[col.cmpg] ?? "",
      category: r[col.category] ?? "",
    });
    if (mapped && !out.has(mapped.icao24)) out.set(mapped.icao24, mapped.notable);
  }
  return out;
}
