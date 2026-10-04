/**
 * Template (d) "Real catches": a rare+ plane that a real Tailspot spotter
 * actually caught in the last 48 hours (7 days at most), from the app's own
 * `catch_performed` analytics events in PostHog.
 *
 * PRIVACY (Noah's decision, 2026-10-04; see src/privacy.ts): a catch may be
 * shown as aircraft model (+ operator), city and day. Nothing else. The query
 * below never selects the handle, registration, callsign, icao24, route,
 * photo or coordinates, `projectCatchRows` drops any column outside
 * CATCH_COLUMNS, and the city (IP-derived, so approximate) is phrased at metro
 * level: "in the San Francisco area", "near Tucson". The time of day never
 * leaves PostHog either: the query returns the date plus a "within 48 h" flag,
 * and rows arrive newest first so their order stands in for recency.
 */

import { designator, displayName, RARITY_COLORS, RARITY_POINTS, rarityRank, RARITY_ORDER, shortName, TYPE_FACTS, typeInfo, type Rarity } from "../aircraftTypes.ts";
import { hogql, POSTHOG_QUERY_URL, type HogQLResult } from "../posthog.ts";
import { CATCH_COLUMNS, isCatchSpotlightable, isPlainLabel } from "../privacy.ts";
import { ctaSlide, foot, kicker, rows, tierBadge } from "../slides.ts";
import { roundedCatchCount } from "../tailspot.ts";
import { NoSubjectError, type DataSource, type Post, type Template } from "../types.ts";
import { article, esc, escName } from "../util.ts";
import { typeHashtag } from "./rareNow.ts";

/**
 * Only the columns in CATCH_COLUMNS, aliased to those names. `within_48h` is
 * computed server-side so the exact catch time is never fetched. Sky-gate
 * rejects (`notSky`, e.g. pointed at a ceiling) are excluded: a promo should
 * only feature catches we believe.
 */
export const CATCHES_QUERY = `select
  properties.rarity as rarity,
  properties.manufacturer as manufacturer,
  properties.model as model,
  properties.operator_name as operator_name,
  properties.typecode as typecode,
  properties.$geoip_city_name as city,
  properties.$geoip_country_name as country,
  toDate(timestamp) as day,
  timestamp > now() - interval 48 hour as within_48h
from events
where event = 'catch_performed'
  and timestamp > now() - interval 7 day
  and properties.rarity in ('rare', 'epic', 'legendary')
  and properties.is_duplicate != true
  and ifNull(properties.sky_verdict, '') != 'notSky'
order by timestamp desc
limit 500`;

export type RealCatchesRaw = HogQLResult;

export interface CatchRow {
  rarity: Rarity;
  typecode: string | null;
  manufacturer: string | null;
  model: string | null;
  operator: string | null;
  city: string;
  country: string | null;
  /** YYYY-MM-DD in the PostHog project's timezone. */
  day: string;
  within48h: boolean;
  /** Position in the newest-first result: lower = more recent. */
  order: number;
}

/** Keep only the allowlisted columns (also what --save-fixture writes). */
export function projectCatchRows(raw: HogQLResult): HogQLResult {
  const keep = raw.columns.map((c, i) => [c, i] as const).filter(([c]) => (CATCH_COLUMNS as readonly string[]).includes(c));
  return { columns: keep.map(([c]) => c), results: raw.results.map((r) => keep.map(([, i]) => (Array.isArray(r) ? r[i] : null))) };
}

const str = (v: unknown): string | null => (typeof v === "string" && v.trim() ? v.trim() : null);

/** Read rows by allowlisted column name only. Malformed rows are dropped. */
export function parseCatchRows(raw: HogQLResult): CatchRow[] {
  const p = projectCatchRows(raw);
  const col = (name: (typeof CATCH_COLUMNS)[number]) => p.columns.indexOf(name);
  const out: CatchRow[] = [];
  p.results.forEach((r, order) => {
    const get = (name: (typeof CATCH_COLUMNS)[number]) => (col(name) >= 0 ? r[col(name)] : null);
    const rarity = str(get("rarity"))?.toLowerCase() as Rarity | undefined;
    if (!rarity || !RARITY_ORDER.includes(rarity)) return;
    const day = str(get("day"));
    const city = str(get("city"));
    if (!day || !/^\d{4}-\d{2}-\d{2}$/.test(day) || !city) return;
    const w = get("within_48h");
    out.push({
      rarity,
      typecode: str(get("typecode"))?.toUpperCase() ?? null,
      manufacturer: str(get("manufacturer")),
      model: str(get("model")),
      operator: str(get("operator_name")),
      city,
      country: str(get("country")),
      day,
      within48h: w === true || w === 1 || w === "1" || w === "true",
      order,
    });
  });
  return out;
}

// ── Place phrasing (IP geolocation: approximate, so never finer than a metro) ──

/** Suburbs fold into their metro: coarser is both more honest and more private. */
const METROS: Record<string, string[]> = {
  "San Francisco": [
    "San Francisco", "Oakland", "Berkeley", "Concord", "San Jose", "Fremont", "Hayward", "Walnut Creek", "Richmond", "Palo Alto",
    "Mountain View", "Sunnyvale", "Santa Clara", "San Mateo", "Redwood City", "Daly City", "South San Francisco", "Alameda",
    "San Leandro", "Pleasanton", "Livermore", "Dublin", "San Ramon", "Danville", "Emeryville", "Vallejo", "Martinez", "Pleasant Hill",
    "Antioch", "Pittsburg", "Lafayette", "Orinda", "Moraga", "El Cerrito", "Albany", "Burlingame", "San Bruno", "Millbrae",
    "Menlo Park", "Cupertino", "Milpitas", "Union City", "Newark", "Castro Valley", "Novato", "San Rafael", "Sausalito",
  ],
  "Los Angeles": ["Los Angeles", "Santa Monica", "Long Beach", "Pasadena", "Burbank", "Inglewood", "Glendale", "Torrance", "Culver City", "El Segundo", "Hawthorne", "Anaheim", "Irvine", "Santa Ana", "Van Nuys"],
  "New York": ["New York", "New York City", "Brooklyn", "Queens", "Bronx", "The Bronx", "Manhattan", "Staten Island", "Jersey City", "Hoboken", "Yonkers"],
  Seattle: ["Seattle", "Bellevue", "Redmond", "Tacoma", "Renton", "Kirkland", "SeaTac", "Everett"],
  Chicago: ["Chicago", "Evanston", "Oak Park", "Schaumburg", "Naperville"],
  London: ["London", "City of London", "Westminster", "Croydon", "Hounslow", "Ealing", "Harrow", "Slough", "Hillingdon"],
  Manchester: ["Manchester", "Stockport", "Salford", "Trafford", "Wythenshawe"],
  Tokyo: ["Tokyo", "Kawasaki", "Yokohama", "Chiba", "Narita"],
  Sydney: ["Sydney", "Parramatta", "Mascot"],
};
const METRO_OF = new Map<string, string>(Object.entries(METROS).flatMap(([m, cs]) => cs.map((c) => [c.toLowerCase(), m] as [string, string])));
const COUNTRY_SHORT: Record<string, string> = { "United Kingdom": "UK", "United States": "US", "United Arab Emirates": "UAE" };

export interface Place {
  /** In a sentence: "in the San Francisco area", "near Tucson", "near Denpasar, Indonesia". */
  phrase: string;
  /** In a list row: "San Francisco area", "Near Tucson". */
  label: string;
  /** Dedupe key. */
  key: string;
}

/** null when the city isn't a usable place name. */
export function placeFor(city: string | null, country: string | null): Place | null {
  if (!isPlainLabel(city, 40) || /\d/.test(city)) return null;
  const c = city.trim();
  const metro = METRO_OF.get(c.toLowerCase());
  if (metro) return { phrase: `in the ${metro} area`, label: `${metro} area`, key: `metro:${metro}` };
  const ctry = isPlainLabel(country, 40) && country !== "United States" ? (COUNTRY_SHORT[country] ?? country) : null;
  const name = ctry ? `${c}, ${ctry}` : c;
  return { phrase: `near ${name}`, label: `Near ${name}`, key: `city:${name.toLowerCase()}` };
}

/** "2026-10-03" → "Sat, Oct 3" ("Saturday, Oct 3" long, "Oct 3" bare). */
export function fmtDay(day: string, style: "short" | "long" | "bare" = "short"): string {
  const d = new Date(`${day}T12:00:00Z`);
  return d.toLocaleDateString("en-US", { ...(style === "bare" ? {} : { weekday: style }), month: "short", day: "numeric", timeZone: "UTC" });
}

// ── Naming ──

const knownType = (r: CatchRow) => (r.typecode && typeInfo(r.typecode) ? r.typecode : null);

/** Full name: "Boeing 747-8", "Northrop T-38 Talon". */
export function aircraftName(r: CatchRow): string | null {
  const code = knownType(r);
  if (code) return displayName(code);
  if (!isPlainLabel(r.model)) return null;
  const make = isPlainLabel(r.manufacturer) ? r.manufacturer : "";
  return make && !r.model.toLowerCase().startsWith(make.toLowerCase()) ? `${make} ${r.model}` : r.model;
}

/** Without the maker: "747-8", "T-38 Talon". */
function shortAircraft(r: CatchRow): string {
  const code = knownType(r);
  if (code) return shortName(code);
  return isPlainLabel(r.model) ? r.model : (aircraftName(r) ?? "");
}

/** Operator for display, or null when absent or not name-like. */
export function operatorOf(r: CatchRow): string | null {
  return isPlainLabel(r.operator) ? r.operator : null;
}

/** "United Airlines" → "United", "Delta Air Lines" → "Delta". Only in the hook. */
function operatorShort(op: string): string {
  return op.replace(/\s+(Air Lines|Airlines|Inc\.?|LLC|Ltd\.?)$/i, "").trim() || op;
}

/** Hook subject: "Lufthansa 747-8", "FedEx Express MD-11", "Northrop T-38 Talon". */
export function hookName(r: CatchRow): string {
  const op = operatorOf(r);
  return op ? `${operatorShort(op)} ${shortAircraft(r)}` : (aircraftName(r) ?? "");
}

/** Compact, for lists: "FedEx Express MD-11", "Air Mobility Command C-130", "Sikorsky H-60 Black Hawk". */
export function listName(r: CatchRow): string {
  const op = operatorOf(r);
  const code = knownType(r);
  if (op && code) return `${operatorShort(op)} ${designator(code)}`;
  return hookName(r);
}

/** article() plus spelled-out acronyms: "a UPS 747-8", "a USAF C-17". */
function articleFor(name: string): string {
  if (/^U[A-Z]{1,4}\b/.test(name)) return "a";
  return article(name);
}

const isMilitary = (r: CatchRow) => typeInfo(r.typecode)?.type === "mil" || r.typecode === "T38";
const modelKey = (r: CatchRow) => knownType(r) ?? `model:${(r.model ?? "").toLowerCase()}`;

// ── Selection ──

export interface Eligible {
  row: CatchRow;
  place: Place;
  name: string;
}

/** Rows that may appear on a slide: named type, usable place, privacy rules. */
export function eligibleCatches(rows: CatchRow[]): Eligible[] {
  const out: Eligible[] = [];
  for (const row of rows) {
    if (rarityRank(row.rarity) < rarityRank("rare")) continue;
    if (!isCatchSpotlightable({ typecode: row.typecode, operator: row.operator })) continue;
    const place = placeFor(row.city, row.country);
    const name = aircraftName(row);
    if (!place || !name) continue;
    out.push({ row, place, name });
  }
  return out;
}

const byRarityThenRecent = (a: Eligible, b: Eligible) => rarityRank(b.row.rarity) - rarityRank(a.row.rarity) || a.row.order - b.row.order;

/** Highest tier first, then most recent; last 48 h, else the whole week. */
export function chooseSubject(cands: Eligible[]): { subject: Eligible; recent: boolean } {
  const recent = cands.filter((c) => c.row.within48h);
  const pool = recent.length ? recent : cands;
  if (pool.length === 0) throw new NoSubjectError("no eligible rare+ catch in the last 7 days");
  return { subject: pool.slice().sort(byRarityThenRecent)[0], recent: recent.length > 0 };
}

/**
 * Up to `n` other catches from the week, one per model + place (the subject's
 * own model + place excluded). Models not yet shown go first, so five MD-11s
 * in five cities can't fill the list; then any remaining model + place pairs.
 */
export function alsoCaught(cands: Eligible[], subject: Eligible, n = 5): Eligible[] {
  const key = (c: Eligible) => `${modelKey(c.row)}|${c.place.key}`;
  const sorted = cands.slice().sort(byRarityThenRecent);
  const usedKeys = new Set([key(subject)]);
  const usedModels = new Set([modelKey(subject.row)]);
  const out: Eligible[] = [];
  for (const pass of [0, 1]) {
    for (const c of sorted) {
      if (out.length >= n) break;
      if (usedKeys.has(key(c))) continue;
      if (pass === 0 && usedModels.has(modelKey(c.row))) continue;
      usedKeys.add(key(c));
      usedModels.add(modelKey(c.row));
      out.push(c);
    }
  }
  return out.sort(byRarityThenRecent);
}

const TIER_PLACE: Record<Rarity, string> = {
  legendary: "the highest of Tailspot's five tiers",
  epic: "the second-highest of Tailspot's five tiers",
  rare: "the middle of Tailspot's five tiers",
  uncommon: "the second-lowest of Tailspot's five tiers",
  common: "the lowest of Tailspot's five tiers",
};

const upperFirst = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

export const realCatches: Template<RealCatchesRaw> = {
  id: "real-catches",
  label: "Real catches",
  needsNetwork: true,
  params: () => ({}),

  async fetch() {
    const fetchedAt = new Date().toISOString();
    const raw = projectCatchRows(await hogql(CATCHES_QUERY));
    const sources: DataSource[] = [{ name: "Tailspot catch_performed events (PostHog HogQL; model, operator, city, day only)", url: POSTHOG_QUERY_URL, fetchedAt }];
    return { raw, sources };
  },

  build(raw, ctx): Post {
    const cands = eligibleCatches(parseCatchRows(raw));
    const { subject, recent } = chooseSubject(cands);
    const others = alsoCaught(cands, subject);
    const r = subject.row;
    const code = knownType(r);
    const info = typeInfo(code);
    const name = subject.name;
    const hName = hookName(r);
    const op = operatorOf(r);
    const pts = RARITY_POINTS[r.rarity];
    const day = fmtDay(r.day);
    const verb = recent ? "was just caught" : "was caught this week";
    const hook = `${upperFirst(articleFor(hName))} ${hName} ${verb} ${subject.place.phrase}.`;
    const desig = code ? designator(code) : shortAircraft(r).split(" ")[0];
    const designatorSize = Math.min(230, Math.floor(760 / (Math.max(desig.length, 3) * 0.62)));
    const fact = code ? TYPE_FACTS[code] : undefined;
    const tierLine = `Tailspot rates how often a type shows up in the sky. ${r.rarity.toUpperCase()} is ${TIER_PLACE[r.rarity]}, worth ${pts} points.`;
    const src = `REAL TAILSPOT CATCH · ${day.toUpperCase()} · CITY APPROXIMATE`;
    const military = isMilitary(r);
    const ftRow = (k: string, v: number | undefined): Array<[string, string]> => (v ? [[k, `${Math.round(v)} ft`]] : []);

    const slides = [
      {
        name: "hook",
        html: `<div class="body">
  ${kicker("Caught in Tailspot")}
  <div class="hud"><span class="c1"></span><span class="c2"></span><div class="designator" style="font-size:${designatorSize}px">${esc(desig)}</div></div>
  ${tierBadge(r.rarity)}
  <h1 style="font-size:88px">${esc(upperFirst(articleFor(hName)))} <span class="accent">${escName(hName)}</span> ${esc(verb)} ${esc(subject.place.phrase)}.</h1>
  <div class="lede">A real catch by a Tailspot spotter on <b>${esc(fmtDay(r.day, "long"))}</b>.</div>
</div>${foot(src)}`,
      },
      {
        name: "aircraft",
        html: `<div class="body">
  ${kicker("The aircraft")}
  <h2>${escName(name)}</h2>
  <div class="card">${rows([
    ["Operator", op ?? (military ? "Military" : "—"), "wide"],
    ...(code ? ([["Type code", code]] as Array<[string, string]>) : []),
    ["Tier", r.rarity.toUpperCase()],
    ...ftRow("Length", info?.lengthFt),
    ...ftRow("Wingspan", info?.wingspanFt),
  ])}</div>
  ${fact ? `<div class="lede" style="color:var(--text); font-weight:600">${esc(fact)}</div>` : ""}
  <div class="lede" style="font-size:36px"><span style="color:${RARITY_COLORS[r.rarity]}; font-weight:700">${esc(r.rarity.toUpperCase())}</span> is ${esc(TIER_PLACE[r.rarity])}, worth ${pts} points. Tiers rate how often a type shows up in the sky.</div>
</div>${foot(src)}`,
      },
      {
        name: "how",
        html: `<div class="body">
  ${kicker("How it was caught")}
  <h2>No guessing. <span class="accent">Real data.</span></h2>
  <div class="steps">
    <div class="step"><div class="n">1</div><div><div class="t">Pointed a phone at the sky</div><div class="d">The camera, GPS and compass tell Tailspot exactly where the spotter is looking.</div></div></div>
    <div class="step"><div class="n">2</div><div><div class="t">Matched to live ADS-B</div><div class="d">The app lines that view up with the positions aircraft are broadcasting right now.</div></div></div>
    <div class="step"><div class="n">3</div><div><div class="t">Caught and collected</div><div class="d">The ${escName(shortAircraft(r))} went into the spotter's hangar: ${esc(r.rarity.toUpperCase())}, ${pts} points.</div></div></div>
  </div>
</div>${foot(src)}`,
      },
      {
        name: "also-caught",
        html: `<div class="body">
  ${kicker("Also caught this week")}
  <h2>More real catches</h2>
  <div class="list">${
    others.length
      ? others
          .map((o) => {
            return `<div class="item" style="--c:${RARITY_COLORS[o.row.rarity]}"><div class="name">${escName(listName(o.row))}</div><div class="tier">${esc(o.row.rarity)}</div><div class="meta">${esc(o.place.label)} · ${esc(fmtDay(o.row.day, "bare"))}</div></div>`;
          })
          .join("")
      : `<div class="lede">Nothing else this rare was caught this week. That's how rare.</div>`
  }</div>
</div>${foot("REAL TAILSPOT CATCHES · LAST 7 DAYS · CITIES APPROXIMATE")}`,
      },
      { name: "cta", html: ctaSlide(ctx.stats ? roundedCatchCount(ctx.stats.catches) : null) },
    ];

    const otherLine = others.length
      ? ` Also caught this week: ${others
          .slice(0, 3)
          .map((o) => `${articleFor(listName(o.row))} ${listName(o.row)} ${o.place.phrase}`)
          .join(", ")}.`
      : "";
    const caption = [
      hook,
      "",
      `Caught by a Tailspot spotter on ${fmtDay(r.day, "long")}: ${articleFor(r.rarity.toUpperCase())} ${r.rarity.toUpperCase()} catch, worth ${pts} points.${otherLine}`,
      "",
      "Tailspot names the real plane over you from live ADS-B, then you add it to your collection. Free on iPhone, link in bio.",
    ].join("\n");

    const hashtags = ["#avgeek", "#planespotting", "#aviation", ...(code ? [typeHashtag(code)] : []), ...(military ? ["#militaryaviation"] : [])].slice(0, 5);

    return {
      template: "real-catches",
      hook,
      caption,
      hashtags,
      slides,
      // Model, operator, place, day: nothing else (Noah's 2026-10-04 rule).
      subject: {
        typecode: code,
        name,
        operator: op,
        rarity: r.rarity,
        points: pts,
        place: subject.place.phrase,
        day: r.day,
        window: recent ? "48h" : "7d",
        alsoCaught: others.map((o) => ({ typecode: knownType(o.row), name: o.name, operator: operatorOf(o.row), rarity: o.row.rarity, place: o.place.phrase, day: o.row.day })),
      },
      privacyNote:
        "Real Tailspot catches at the level Noah approved on 2026-10-04: aircraft model (+ operator), approximate city (IP geolocation, metro level) and day. No handles, registrations, callsigns, icao24, photos, coordinates, routes or times. Privately operated GA/business aircraft never spotlighted.",
      altText: [
        `${name}, ${r.rarity} tier, ${pts} points: "${hook}"`,
        `Aircraft: ${name}${op ? `, operated by ${op}` : ""}. ${fact ?? ""} ${tierLine}`.trim(),
        "How it was caught: a phone pointed at the sky, matched to live ADS-B, added to the spotter's collection.",
        `Also caught this week: ${others.map((o) => `${o.name} ${o.place.phrase}, ${fmtDay(o.row.day)}`).join("; ") || "nothing else this rare"}.`,
        "Tailspot: catch the planes flying over you. Free on the App Store. tailspot.app",
      ],
    };
  },
};
