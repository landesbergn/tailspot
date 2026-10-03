/**
 * Template (a) "Rare right now": one notable aircraft that is airborne at
 * capture time, somewhere in the world, with its real callsign, type,
 * altitude and region — and what it would be worth in Tailspot.
 */

import { ADSB_LOL_BASE, fetchMil, fetchType, normalizeAll, PACE_MS, sleep, type Plane, type ReadsbResponse } from "../adsb.ts";
import {
  designator,
  displayName,
  RARITY_COLORS,
  RARITY_POINTS,
  rarityRank,
  shortName,
  TYPE_FACTS,
  typeInfo,
  type Rarity,
  type TypeInfo,
} from "../aircraftTypes.ts";
import { regionFor } from "../geo.ts";
import { isFreshAirborne, isSpotlightable } from "../privacy.ts";
import { compass, ctaSlide, foot, kicker, rows, tierBadge } from "../slides.ts";
import { roundedCatchCount } from "../tailspot.ts";
import { NoSubjectError, type BuildContext, type DataSource, type Post, type Template } from "../types.ts";
import { article, cardinal, esc, escName, fmtAltitudeFt, fmtSpeedKt, seededRandom, pick } from "../util.ts";

/**
 * Civil headline types queried by type (military ones arrive via /v2/mil).
 * Each is one paced request; keep the list short.
 */
export const HEADLINE_TYPES = ["A388", "B748", "B744", "B742", "A124", "IL76", "AN22", "MD11", "DC10", "L101"] as const;

export interface RareNowRaw {
  mil: ReadsbResponse | null;
  types: Record<string, ReadsbResponse | null>;
}

export interface Candidate {
  plane: Plane;
  info: TypeInfo;
  rarity: Rarity;
}

/** Every distinct aircraft in the raw data (deduped by hex). */
export function allPlanes(raw: RareNowRaw): Plane[] {
  const byHex = new Map<string, Plane>();
  for (const resp of [raw.mil, ...Object.values(raw.types)]) {
    for (const p of normalizeAll(resp)) if (!byHex.has(p.hex)) byHex.set(p.hex, p);
  }
  return [...byHex.values()];
}

/** Airborne, privacy-safe aircraft with a known type of tier rare or above. */
export function candidates(raw: RareNowRaw): Candidate[] {
  const out: Candidate[] = [];
  for (const p of allPlanes(raw)) {
    if (!isSpotlightable(p)) continue;
    const info = typeInfo(p.typecode);
    if (!info || rarityRank(info.rarity) < rarityRank("rare")) continue;
    out.push({ plane: p, info, rarity: info.rarity });
  }
  return out;
}

/**
 * Pick the subject: the highest tier present; within it, pick a TYPE first
 * (seeded, so twenty tankers don't crowd out one bomber), preferring types we
 * have a fact line for; then the highest-flying aircraft of that type.
 */
export function chooseSubject(cands: Candidate[], seed: string): Candidate {
  if (cands.length === 0) throw new NoSubjectError("no rare+ aircraft airborne in the data");
  const top = Math.max(...cands.map((c) => rarityRank(c.rarity)));
  const tier = cands.filter((c) => rarityRank(c.rarity) === top);
  const types = [...new Set(tier.map((c) => c.plane.typecode!))].sort();
  const withFacts = types.filter((t) => TYPE_FACTS[t]);
  const rand = seededRandom(`rare-now:${seed}`);
  const type = pick(withFacts.length ? withFacts : types, rand);
  return tier
    .filter((c) => c.plane.typecode === type)
    .sort((a, b) => (b.plane.altFt ?? 0) - (a.plane.altFt ?? 0) || a.plane.hex.localeCompare(b.plane.hex))[0];
}

/** Up to `n` other notable aircraft of different types, best tier first. */
export function runnersUp(cands: Candidate[], subject: Candidate, n = 4): Candidate[] {
  const seen = new Set([subject.plane.typecode]);
  const out: Candidate[] = [];
  const sorted = cands
    .slice()
    .sort((a, b) => rarityRank(b.rarity) - rarityRank(a.rarity) || (b.plane.altFt ?? 0) - (a.plane.altFt ?? 0) || a.plane.hex.localeCompare(b.plane.hex));
  for (const c of sorted) {
    if (seen.has(c.plane.typecode)) continue;
    seen.add(c.plane.typecode);
    out.push(c);
    if (out.length >= n) break;
  }
  return out;
}

/** How many aircraft of this type are airborne in the snapshot (aggregate, any owner). */
export function airborneCountOfType(raw: RareNowRaw, typecode: string): number {
  return allPlanes(raw).filter((p) => p.typecode === typecode && isFreshAirborne(p)).length;
}

/** "B-52 Stratofortress" → #B52, "A380" → #A380, "747-8" → #Boeing747. */
export function typeHashtag(code: string): string {
  const first = shortName(code).split(" ")[0];
  if (/^\d/.test(first)) return `#${(typeInfo(code)?.make ?? "").replace(/[^A-Za-z]/g, "")}${first.split("-")[0]}`;
  return `#${first.replace(/[^A-Za-z0-9]/g, "")}`;
}

function utcStamp(d: Date): string {
  return `${d.toISOString().slice(0, 16).replace("T", " ")} UTC`;
}

export const rareNow: Template<RareNowRaw> = {
  id: "rare-now",
  label: "Rare right now",
  needsNetwork: true,
  params: () => ({}),

  async fetch() {
    const fetchedAt = new Date().toISOString();
    const sources: DataSource[] = [];
    let mil: ReadsbResponse | null = null;
    const errors: string[] = [];
    try {
      mil = await fetchMil();
      sources.push({ name: "adsb.lol /v2/mil", url: `${ADSB_LOL_BASE}/v2/mil`, fetchedAt, license: "ODbL-1.0" });
    } catch (e) {
      errors.push((e as Error).message);
    }
    const types: Record<string, ReadsbResponse | null> = {};
    for (const t of HEADLINE_TYPES) {
      // Two straight failures and nothing yet: the service is down or
      // blocking us. Stop hammering it; the CLI falls back to guess-plane.
      if (sources.length === 0 && errors.length >= 2) break;
      await sleep(PACE_MS);
      try {
        types[t] = await fetchType(t);
        sources.push({ name: `adsb.lol /v2/type/${t}`, url: `${ADSB_LOL_BASE}/v2/type/${t}`, fetchedAt, license: "ODbL-1.0" });
      } catch (e) {
        types[t] = null;
        errors.push((e as Error).message);
      }
    }
    if (sources.length === 0) throw new Error(`adsb.lol unreachable: ${errors.join("; ")}`);
    return { raw: { mil, types }, sources };
  },

  build(raw, ctx): Post {
    const cands = candidates(raw);
    const subject = chooseSubject(cands, ctx.seed);
    const p = subject.plane;
    const code = p.typecode!;
    const name = displayName(code);
    const region = regionFor(p.lat, p.lon);
    const sameType = airborneCountOfType(raw, code);
    const others = runnersUp(cands, subject);
    const pts = RARITY_POINTS[subject.rarity];
    const when = utcStamp(ctx.capturedAt);
    const src = `LIVE ADS-B · ADSB.LOL (ODbL) · ${when}`;
    const fact = TYPE_FACTS[code];
    const desig = designator(code);
    // B612 Mono glyphs are ~0.62em wide; fit the HUD's ~760 px inner width.
    const designatorSize = Math.min(230, Math.floor(760 / (desig.length * 0.62)));

    const hook = `There's ${article(name)} ${name} in the sky right now.`;
    const slides = [
      {
        name: "hook",
        html: `<div class="body">
  ${kicker("Rare right now", true)}
  <div class="hud"><span class="c1"></span><span class="c2"></span><div class="designator" style="font-size:${designatorSize}px">${esc(desig)}</div></div>
  ${tierBadge(subject.rarity)}
  <h1>There's ${esc(article(name))} <span class="accent">${escName(name)}</span> in the sky right now.</h1>
  <div class="lede">Could you catch it?</div>
</div>${foot(src)}`,
      },
      {
        name: "aircraft",
        html: `<div class="body">
  ${kicker("The aircraft")}
  <h2>${escName(name)}</h2>
  <div class="card">${rows([
    ["Callsign", p.callsign ?? "—"],
    ["Type code", code],
    ["Registration", p.registration ?? "—"],
    ["Registered in", p.regCountry ?? "—"],
    ...(p.operator ? ([["Operator", p.operator, "wide"]] as Array<[string, string, "wide"]>) : []),
  ])}</div>
  <div class="lede">Real flight, read straight off the public ADS-B feed. Not a render, not a guess.</div>
</div>${foot(src)}`,
      },
      {
        name: "where",
        html: `<div class="body">
  ${kicker("Where it is")}
  <h2>${esc(region.phrase.charAt(0).toUpperCase() + region.phrase.slice(1))}</h2>
  <div style="display:flex; gap:44px; align-items:center">
    ${compass(p.track)}
    <div class="rows" style="grid-template-columns:1fr; gap:30px">
      <div class="row"><div class="k">Altitude</div><div class="v">${esc(p.altFt !== null ? fmtAltitudeFt(p.altFt) : "—")}</div></div>
      <div class="row"><div class="k">Ground speed</div><div class="v">${esc(p.gsKt !== null ? fmtSpeedKt(p.gsKt) : "—")}</div></div>
      <div class="row"><div class="k">Heading</div><div class="v">${esc(p.track !== null ? `${Math.round(p.track)}° ${cardinal(p.track)}` : "—")}</div></div>
    </div>
  </div>
  <div class="lede">As of <b>${esc(when)}</b>. If it's overhead where you are, point your phone at it.</div>
</div>${foot(src)}`,
      },
      {
        name: "why-rare",
        html: `<div class="body">
  ${kicker(`Why it's ${subject.rarity}`)}
  <h2 style="font-size:64px; line-height:1.15; font-weight:700">${esc(fact ?? `${name}s are a rare sight: Tailspot rates the type ${subject.rarity.toUpperCase()}.`)}</h2>
  <div class="card" style="display:flex; flex-direction:column; gap:30px">
    <div class="row"><div class="k">In Tailspot</div><div class="v" style="color:${RARITY_COLORS[subject.rarity]}">${esc(subject.rarity.toUpperCase())} · ${pts} PTS</div></div>
    <div class="row"><div class="k">Same type in the air now</div><div class="v">${sameType} <span style="font-size:30px; font-weight:400; color:var(--dim)">tracked on adsb.lol</span></div></div>
  </div>
</div>${foot(src)}`,
      },
      {
        name: "also-up",
        html: `<div class="body">
  ${kicker("Also up there right now")}
  <h2>More rare ones, live</h2>
  <div class="list">${
    others.length
      ? others
          .map((o) => {
            const r = regionFor(o.plane.lat, o.plane.lon);
            return `<div class="item" style="--c:${RARITY_COLORS[o.rarity]}"><div class="name">${escName(displayName(o.plane.typecode!))}</div><div class="tier">${esc(o.rarity)}</div><div class="meta">${esc(o.plane.callsign ?? "")} · ${esc(o.plane.altFt !== null ? fmtAltitudeFt(o.plane.altFt) : "")} · ${esc(r.short)}</div></div>`;
          })
          .join("")
      : `<div class="lede">Nothing else this rare is airborne in the snapshot. That's how rare.</div>`
  }</div>
</div>${foot(src)}`,
      },
      { name: "cta", html: ctaSlide(ctx.stats ? roundedCatchCount(ctx.stats.catches) : null) },
    ];

    const caption = [
      hook,
      "",
      `As of ${when}: ${p.callsign} (${name}) at ${p.altFt !== null ? fmtAltitudeFt(p.altFt) : "unknown altitude"}, ${region.phrase}. In Tailspot that's ${/^[aeiou]/i.test(subject.rarity) ? "an" : "a"} ${subject.rarity.toUpperCase()} catch, worth ${pts} points.`,
      "",
      "Tailspot names the real plane over you from live ADS-B, then you add it to your collection. Free on iPhone, link in bio.",
      "",
      "Flight data: adsb.lol (ODbL).",
    ].join("\n");

    const hashtags = ["#avgeek", "#planespotting", "#aviation", typeHashtag(code), ...(p.military ? ["#militaryaviation"] : [])].slice(0, 5);

    return {
      template: "rare-now",
      hook,
      caption,
      hashtags,
      slides,
      subject: {
        typecode: code,
        name,
        rarity: subject.rarity,
        points: pts,
        callsign: p.callsign,
        registration: p.registration,
        icao24: p.hex,
        military: p.military,
        altitudeFt: p.altFt,
        region: region.phrase,
        airborneOfType: sameType,
        runnersUp: others.map((o) => ({ typecode: o.plane.typecode, callsign: o.plane.callsign, rarity: o.rarity })),
      },
      altText: [
        `${name} (${code}) badge, ${subject.rarity} tier: "${hook}"`,
        `Aircraft details: callsign ${p.callsign}, registration ${p.registration ?? "unknown"}.`,
        `Position: ${region.phrase}, ${p.altFt !== null ? fmtAltitudeFt(p.altFt) : ""}.`,
        `Why it's rare: ${fact ?? ""}`,
        `Other rare aircraft airborne now: ${others.map((o) => displayName(o.plane.typecode!)).join(", ")}.`,
        "Tailspot: catch the planes flying over you. Free on the App Store. tailspot.app",
      ],
    };
  },
};
