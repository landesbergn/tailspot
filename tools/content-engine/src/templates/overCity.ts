/**
 * Template (b) "What's over [city] right now": live counts, the rarity mix,
 * the rarest catchable plane and the most common types within 30 NM of a
 * major city. Cities rotate by date.
 */

import { ADSB_LOL_BASE, fetchPoint, normalizeAll, type Plane, type ReadsbResponse } from "../adsb.ts";
import { displayName, RARITY_COLORS, RARITY_ORDER, RARITY_POINTS, rarityRank, shortName, typeInfo, type Rarity } from "../aircraftTypes.ts";
import { bearingDeg, haversineKm } from "../geo.ts";
import { isFreshAirborne, isSpotlightable } from "../privacy.ts";
import { ctaSlide, foot, kicker, rows, tierBadge } from "../slides.ts";
import { roundedCatchCount } from "../tailspot.ts";
import { NoSubjectError, type BuildContext, type Post, type Template } from "../types.ts";
import { article, cardinal, esc, escName, fmtAltitudeFt, fmtInt } from "../util.ts";

export interface City {
  id: string;
  /** As used in a sentence: "over London". */
  name: string;
  /** "central London" for distance phrases. */
  centre: string;
  lat: number;
  lon: number;
  tz: string;
  hashtag: string;
}

export const CITIES: readonly City[] = [
  { id: "sf-bay", name: "the Bay Area", centre: "the Bay", lat: 37.7, lon: -122.25, tz: "America/Los_Angeles", hashtag: "#bayarea" },
  { id: "london", name: "London", centre: "central London", lat: 51.5, lon: -0.2, tz: "Europe/London", hashtag: "#london" },
  { id: "nyc", name: "New York", centre: "Manhattan", lat: 40.73, lon: -73.93, tz: "America/New_York", hashtag: "#nyc" },
  { id: "tokyo", name: "Tokyo", centre: "central Tokyo", lat: 35.62, lon: 139.75, tz: "Asia/Tokyo", hashtag: "#tokyo" },
  { id: "sydney", name: "Sydney", centre: "the CBD", lat: -33.9, lon: 151.15, tz: "Australia/Sydney", hashtag: "#sydney" },
  { id: "bali", name: "Bali", centre: "Denpasar", lat: -8.7, lon: 115.2, tz: "Asia/Makassar", hashtag: "#bali" },
];

export const RADIUS_NM = 30;
const RADIUS_KM = Math.round(RADIUS_NM * 1.852);

export function cityById(id: unknown): City {
  const c = CITIES.find((x) => x.id === id);
  if (!c) throw new Error(`unknown city "${id}" (have: ${CITIES.map((x) => x.id).join(", ")})`);
  return c;
}

export interface OverCityRaw {
  point: ReadsbResponse;
}

export type Kind = "airliner" | "bizjet" | "military" | "helicopter" | "light" | "unknown";

export function kindOf(p: Plane): Kind {
  const info = typeInfo(p.typecode);
  if (p.military || info?.type === "mil") return "military";
  if (p.category === "A7") return "helicopter";
  if (!info) return "unknown";
  if (info.type === "wide" || info.type === "narrow" || info.type === "regional") return "airliner";
  if (info.type === "biz") return "bizjet";
  return "light";
}

export interface CityStats {
  airborne: Plane[];
  onGround: number;
  kinds: Record<Kind, number>;
  tiers: Record<Rarity, number>;
  unrated: number;
  skyPoints: number;
  topTypes: Array<{ typecode: string; count: number }>;
  rarest: { plane: Plane; rarity: Rarity } | null;
}

/** Pure aggregation over one /v2/point snapshot. */
export function cityStats(raw: OverCityRaw): CityStats {
  const all = normalizeAll(raw.point);
  const airborne = all.filter(isFreshAirborne);
  const onGround = all.filter((p) => p.onGround).length;
  const kinds: Record<Kind, number> = { airliner: 0, bizjet: 0, military: 0, helicopter: 0, light: 0, unknown: 0 };
  const tiers: Record<Rarity, number> = { common: 0, uncommon: 0, rare: 0, epic: 0, legendary: 0 };
  let unrated = 0;
  let skyPoints = 0;
  const typeCounts = new Map<string, number>();
  for (const p of airborne) {
    kinds[kindOf(p)]++;
    const info = typeInfo(p.typecode);
    if (info) {
      tiers[info.rarity]++;
      skyPoints += RARITY_POINTS[info.rarity];
      typeCounts.set(p.typecode!, (typeCounts.get(p.typecode!) ?? 0) + 1);
    } else {
      unrated++;
      skyPoints += RARITY_POINTS.common; // the app's floor for an unresolved type
    }
  }
  const topTypes = [...typeCounts.entries()]
    .map(([typecode, count]) => ({ typecode, count }))
    .sort((a, b) => b.count - a.count || a.typecode.localeCompare(b.typecode))
    .slice(0, 5);

  // Rarest *catchable*: best tier among privacy-safe aircraft; ties go to the
  // LOWEST one (the easiest to actually see and catch from the ground).
  let rarest: CityStats["rarest"] = null;
  for (const p of airborne) {
    if (!isSpotlightable(p)) continue;
    const info = typeInfo(p.typecode);
    if (!info) continue;
    const better =
      !rarest ||
      rarityRank(info.rarity) > rarityRank(rarest.rarity) ||
      (info.rarity === rarest.rarity && (p.altFt ?? 0) < (rarest.plane.altFt ?? 0));
    if (better) rarest = { plane: p, rarity: info.rarity };
  }
  return { airborne, onGround, kinds, tiers, unrated, skyPoints, topTypes, rarest };
}

export function localTime(d: Date, tz: string): string {
  return new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "short", hour: "numeric", minute: "2-digit" }).format(d);
}

const KIND_LABELS: Record<Kind, [string, string]> = {
  airliner: ["airliner", "airliners"],
  bizjet: ["business jet", "business jets"],
  military: ["military", "military"],
  helicopter: ["helicopter", "helicopters"],
  light: ["light aircraft", "light aircraft"],
  unknown: ["unlisted type", "unlisted types"],
};
const kindLabel = (k: Kind, n: number) => KIND_LABELS[k][n === 1 ? 0 : 1];

export const overCity: Template<OverCityRaw> = {
  id: "over-city",
  label: "What's over [city] right now",
  needsNetwork: true,
  params: (dayIndex) => ({ city: CITIES[Math.floor(dayIndex / 3) % CITIES.length].id }),

  async fetch(params) {
    const city = cityById(params.city);
    const fetchedAt = new Date().toISOString();
    const point = await fetchPoint(city.lat, city.lon, RADIUS_NM);
    const url = `${ADSB_LOL_BASE}/v2/point/${city.lat}/${city.lon}/${RADIUS_NM}`;
    return { raw: { point }, sources: [{ name: "adsb.lol /v2/point", url, fetchedAt, license: "ODbL-1.0" }] };
  },

  build(raw, ctx): Post {
    const city = cityById(ctx.params.city);
    const s = cityStats(raw);
    const n = s.airborne.length;
    if (n < 3) throw new NoSubjectError(`only ${n} aircraft airborne over ${city.id}; not worth a post`);
    const when = localTime(ctx.capturedAt, city.tz);
    const src = `LIVE ADS-B · ADSB.LOL (ODbL) · ${when.toUpperCase()} LOCAL`;
    const hook = `What's flying over ${city.name} right now?`;
    const maxTier = Math.max(1, ...RARITY_ORDER.map((r) => s.tiers[r]));
    const maxType = Math.max(1, ...s.topTypes.map((t) => t.count));
    const kindsShown = (Object.keys(KIND_LABELS) as Kind[]).filter((k) => s.kinds[k] > 0);

    const r = s.rarest;
    let rarestHtml = `<div class="lede">No catchable standouts in this snapshot.</div>`;
    let rarestText = "";
    if (r) {
      const km = haversineKm(city.lat, city.lon, r.plane.lat, r.plane.lon);
      const dir = cardinal(bearingDeg(city.lat, city.lon, r.plane.lat, r.plane.lon));
      const where = km < 5 ? `right over ${city.centre}` : `${Math.round(km)} km ${dir} of ${city.centre}`;
      const nm = displayName(r.plane.typecode!);
      rarestText = `${article(nm)} ${nm} (${r.plane.callsign}) at ${r.plane.altFt !== null ? fmtAltitudeFt(r.plane.altFt) : "?"}, ${where}`;
      rarestHtml = `${tierBadge(r.rarity)}
  <h2>${escName(nm)}</h2>
  <div class="card">${rows([
    ["Callsign", r.plane.callsign ?? "—"],
    ["Altitude", r.plane.altFt !== null ? fmtAltitudeFt(r.plane.altFt) : "—"],
    ["Where", where, "wide"],
  ])}</div>`;
    }

    const slides = [
      {
        name: "hook",
        html: `<div class="body">
  ${kicker(`Live · ${when} in ${city.name.replace(/^the /, "")}`, true)}
  <h1>What's flying over <span class="accent">${esc(city.name)}</span> right now?</h1>
  <div class="lede">Every aircraft in a ${RADIUS_KM} km circle, from the live public ADS-B feed. Swipe.</div>
</div>${foot(src)}`,
      },
      {
        name: "count",
        html: `<div class="body">
  ${kicker("In the air right now")}
  <div class="big" style="font-size:${n >= 1000 ? 260 : 320}px">${fmtInt(n)}</div>
  <div class="lede"><b>aircraft airborne</b> within ${RADIUS_NM} nm (${RADIUS_KM} km) of ${esc(city.centre)}${s.onGround ? `, plus ${fmtInt(s.onGround)} on the ground` : ""}.</div>
  <div class="chips">${kindsShown.map((k) => `<div class="chip"><b>${s.kinds[k]}</b>${kindLabel(k, s.kinds[k])}</div>`).join("")}</div>
</div>${foot(src)}`,
      },
      {
        name: "rarity",
        html: `<div class="body">
  ${kicker("The rarity mix")}
  <h2>This sky is worth <span class="accent">${fmtInt(s.skyPoints)} pts</span> in Tailspot.</h2>
  <div class="bars">${[...RARITY_ORDER]
    .reverse()
    .map(
      (t) =>
        `<div class="bar" style="--c:${RARITY_COLORS[t]}"><div class="l">${t}</div><div class="t">${s.tiers[t] ? `<div class="f" style="width:${Math.max(3, (s.tiers[t] / maxTier) * 100)}%"></div>` : ""}</div><div class="n">${s.tiers[t]}</div></div>`,
    )
    .join("")}</div>
  <div class="lede">Base points if you caught every plane up there right now.</div>
</div>${foot(src)}`,
      },
      {
        name: "rarest",
        html: `<div class="body">
  ${kicker("Rarest one you could catch")}
  ${rarestHtml}
</div>${foot(src)}`,
      },
      {
        name: "top-types",
        html: `<div class="body">
  ${kicker("Most common up there")}
  <h2>The usual suspects</h2>
  <div class="bars">${s.topTypes
    .map((t) => {
      return `<div class="bar" style="grid-template-columns: 300px 1fr 90px"><div class="l" style="font-family:var(--sans); font-weight:800; font-size:46px; letter-spacing:-.01em; text-transform:none; color:var(--text)">${escName(shortName(t.typecode))}</div><div class="t"><div class="f" style="width:${(t.count / maxType) * 100}%; background:linear-gradient(90deg, #0090BB, var(--cyan))"></div></div><div class="n">${t.count}</div></div>`;
    })
    .join("")}</div>
  <div class="lede">Common catches fill your Hangar. The rare ones are why you look up.</div>
</div>${foot(src)}`,
      },
      { name: "cta", html: ctaSlide(ctx.stats ? roundedCatchCount(ctx.stats.catches) : null) },
    ];

    const caption = [
      hook,
      "",
      `${when} local: ${n} aircraft airborne within ${RADIUS_NM} nm of ${city.centre}.${rarestText ? ` Rarest catchable: ${rarestText}.` : ""} The whole sky is worth ${fmtInt(s.skyPoints)} points in Tailspot.`,
      "",
      "Tailspot names the real plane over you from live ADS-B, then you add it to your collection. Free on iPhone, link in bio.",
      "",
      "Flight data: adsb.lol (ODbL).",
    ].join("\n");

    return {
      template: "over-city",
      hook,
      caption,
      hashtags: ["#avgeek", "#planespotting", "#aviation", city.hashtag],
      slides,
      subject: {
        city: city.id,
        radiusNm: RADIUS_NM,
        airborne: n,
        onGround: s.onGround,
        kinds: s.kinds,
        tiers: s.tiers,
        unrated: s.unrated,
        skyPoints: s.skyPoints,
        topTypes: s.topTypes,
        rarest: r ? { typecode: r.plane.typecode, callsign: r.plane.callsign, rarity: r.rarity, altitudeFt: r.plane.altFt } : null,
      },
      altText: [
        hook,
        `${n} aircraft airborne within ${RADIUS_NM} nautical miles of ${city.centre}.`,
        `Rarity mix: ${RARITY_ORDER.map((t) => `${s.tiers[t]} ${t}`).join(", ")}. Worth ${s.skyPoints} points.`,
        r ? `Rarest catchable: ${rarestText}.` : "No standout rare aircraft.",
        `Most common types: ${s.topTypes.map((t) => `${shortName(t.typecode)} ×${t.count}`).join(", ")}.`,
        "Tailspot: catch the planes flying over you. Free on the App Store. tailspot.app",
      ],
    };
  },
};
