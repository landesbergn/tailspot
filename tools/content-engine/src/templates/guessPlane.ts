/**
 * Template (c) "Guess the plane": one of Noah's real catch photos, four
 * choices, clues from the recorded ADS-B, the answer on the last content
 * slide. Needs no network, so it's also the fallback when adsb.lol is down.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { displayName, RARITY_POINTS, typeInfo } from "../aircraftTypes.ts";
import { CATCHES, catchById, type CatchRecord } from "../catches.ts";
import { CATCH_PHOTOS_DIR } from "../paths.ts";
import { ctaSlide, foot, kicker, rows, tierBadge } from "../slides.ts";
import { roundedCatchCount } from "../tailspot.ts";
import type { BuildContext, Post, Template } from "../types.ts";
import { esc, escName, fmtAltitudeFt, fmtInt, seededRandom, shuffled } from "../util.ts";

export interface GuessRaw {
  catchId: string;
}

/** Plausible wrong answers per class; filtered against the answer's family. */
const POOLS: Record<string, string[]> = {
  narrow: ["A320", "A21N", "B738", "B38M", "A319", "BCS3", "B739", "B752", "A20N"],
  wide: ["B763", "B772", "A333", "B789", "A359", "B788", "A332", "B77W"],
  regional: ["E75L", "CRJ9", "E190", "CRJ7", "E145"],
  biz: ["GLEX", "CL35", "GLF5", "FA7X", "C68A", "GLF6", "CL60", "LJ45"],
};

/** Types too alike to be fair as separate options (same family/airframe). */
const FAMILY: Record<string, string> = {
  A319: "A32x", A320: "A32x", A20N: "A32x", A321: "A32x", A21N: "A32x",
  B738: "737", B38M: "737", B739: "737", B39M: "737",
  B788: "787", B789: "787", B772: "777", B77W: "777",
  A332: "A330", A333: "A330", A359: "A350",
  GLEX: "GLOBAL", GLF5: "GULF", GLF6: "GULF", CL35: "CL", CL60: "CL",
  E75L: "E-JET", E190: "E-JET", CRJ7: "CRJ", CRJ9: "CRJ",
};
const family = (t: string) => FAMILY[t] ?? t;

const CLASS_TEXT: Record<string, string> = {
  narrow: "Single-aisle twin jet",
  wide: "Twin-aisle widebody",
  regional: "Regional jet",
  biz: "Business jet",
  ga: "Light aircraft",
  mil: "Military",
};

/** Answer + 3 distractors, shuffled deterministically. */
export function buildChoices(answer: string, seed: string): { options: string[]; answerIndex: number } {
  const cls = typeInfo(answer)?.type ?? "narrow";
  const rand = seededRandom(`guess:${seed}`);
  const pool = (POOLS[cls] ?? POOLS.narrow).filter((t) => t !== answer && family(t) !== family(answer) && typeInfo(t));
  const picked: string[] = [];
  for (const t of shuffled(pool, rand)) {
    if (picked.some((p) => family(p) === family(t))) continue;
    picked.push(t);
    if (picked.length === 3) break;
  }
  if (picked.length < 3) throw new Error(`not enough distractors for ${answer}`);
  const options = shuffled([answer, ...picked], rand);
  return { options, answerIndex: options.indexOf(answer) };
}

export function cluesFor(c: CatchRecord): Array<[string, string]> {
  const info = typeInfo(c.typecode);
  const out: Array<[string, string]> = [];
  if (info) out.push(["Class", CLASS_TEXT[info.type] ?? info.type]);
  if (c.route) out.push(["Route", `${c.route[0]} → ${c.route[1]}`]);
  if (c.altitudeFt) out.push(["Altitude", fmtAltitudeFt(c.altitudeFt)]);
  if (c.speedKt) out.push(["Ground speed", `${fmtInt(c.speedKt)} kt`]);
  if (c.distanceKm) out.push(["Distance from camera", `${c.distanceKm} km`]);
  if (info) out.push(["Tailspot tier", info.rarity.toUpperCase()]);
  return out;
}

const LETTERS = ["A", "B", "C", "D"];

function photoUri(c: CatchRecord): string {
  return `data:image/jpeg;base64,${readFileSync(join(CATCH_PHOTOS_DIR, c.file)).toString("base64")}`;
}

/** Read focus.json (bracket centre) so the zoom stays on the plane. */
function focusOf(c: CatchRecord): [number, number] {
  try {
    const f = JSON.parse(readFileSync(join(CATCH_PHOTOS_DIR, "focus.json"), "utf8"));
    const key = c.file.replace(/\.jpg$/, "");
    return f[key]?.focus ?? [0.5, 0.5];
  } catch {
    return [0.5, 0.5];
  }
}

export const guessPlane: Template<GuessRaw> = {
  id: "guess-plane",
  label: "Guess the plane",
  needsNetwork: false,
  // Day-by-day, because guess-plane also runs on any day as the fallback.
  params: (dayIndex) => ({ catchId: CATCHES[((dayIndex % CATCHES.length) + CATCHES.length) % CATCHES.length].id }),

  async fetch(params) {
    const c = catchById(params.catchId);
    return {
      raw: { catchId: c.id },
      sources: [
        {
          name: "Noah's catch photo + recorded ADS-B",
          url: `marketing/catch-photos/${c.file}`,
          fetchedAt: new Date().toISOString(),
        },
      ],
    };
  },

  build(raw, ctx): Post {
    const c = catchById(raw.catchId);
    const info = typeInfo(c.typecode);
    if (!info) throw new Error(`catch ${c.id}: type ${c.typecode} not in AircraftTypes.json`);
    const { options, answerIndex } = buildChoices(c.typecode, ctx.seed);
    const answerLetter = LETTERS[answerIndex];
    const name = displayName(c.typecode);
    const photo = photoUri(c);
    const [fx, fy] = focusOf(c);
    const contrail = c.visible === "contrail";
    const hook = contrail ? "Guess the plane making this contrail." : "Guess the plane.";
    const src = "REAL CATCH · PHOTO + ADS-B RECORDED IN TAILSPOT";
    const clues = cluesFor(c);

    // Zoomed crop: scale the 831x524 photo up around its bracket centre.
    const scale = contrail ? 1.6 : 3.2;
    const zoomPhoto = (h: number, extraStyle = "") => {
      const w = 868;
      const imgW = 831 * scale;
      const imgH = 524 * scale;
      const left = Math.min(0, Math.max(w - imgW, w / 2 - fx * imgW));
      const top = Math.min(0, Math.max(h - imgH, h / 2 - fy * imgH));
      return `<div class="photo" style="height:${h}px; flex:none; ${extraStyle}"><img src="${photo}" style="position:absolute; width:${imgW}px; height:${imgH}px; max-width:none; left:${left.toFixed(0)}px; top:${top.toFixed(0)}px; object-fit:fill" alt=""><div class="tag">${scale.toFixed(1)}× ZOOM</div></div>`;
    };

    const choicesHtml = (highlight: number | null) =>
      `<div class="choices">${options
        .map(
          (t, i) =>
            `<div class="choice" style="${highlight === null ? "" : i === highlight ? "border-color:var(--green); background:rgba(61,214,140,.14)" : "opacity:.38"}"><div class="letter" style="${highlight === i ? "background:var(--green)" : ""}">${LETTERS[i]}</div><div class="opt">${escName(displayName(t))}</div></div>`,
        )
        .join("")}</div>`;

    const slides = [
      {
        name: "hook",
        html: `<div class="body">
  ${kicker("Guess the plane")}
  <h1>${contrail ? `What's making <span class="accent">this contrail?</span>` : `Can you name <span class="accent">this plane?</span>`}</h1>
  <div class="photo" style="height:547px"><img src="${photo}" style="transform:scale(1.045)" alt=""><div class="tag">REAL PHOTO · SHOT IN TAILSPOT</div></div>
  <div class="lede">A real catch, shot through the Tailspot app. Four options next. Answer on slide 5.</div>
</div>${foot(src)}`,
      },
      {
        name: "choices",
        html: `<div class="body">
  ${kicker("Enhance")}
  ${zoomPhoto(560)}
  ${choicesHtml(null)}
</div>${foot(src)}`,
      },
      {
        name: "clues",
        html: `<div class="body">
  ${kicker("Clues from the recorded ADS-B")}
  <h2>Need a hint?</h2>
  <div class="card">${rows(clues.map(([k, v]) => [k, v, "wide"] as [string, string, "wide"]))}</div>
</div>${foot(src)}`,
      },
      {
        name: "lock-in",
        html: `<div class="body">
  ${kicker("Lock it in")}
  <h1>A, B, C or D?</h1>
  ${zoomPhoto(340)}
  ${choicesHtml(null)}
  <div class="lede">Comment your answer, <b>then</b> swipe.</div>
</div>${foot(src)}`,
      },
      {
        name: "answer",
        html: `<div class="body" style="gap:30px">
  ${kicker("Answer")}
  <h1><span class="accent">${answerLetter}.</span> ${escName(name)}</h1>
  ${zoomPhoto(240, "border-color: var(--green)")}
  ${tierBadge(info.rarity)}
  <div class="card">${rows([
    ["Callsign", c.callsign],
    ["Operator", c.operator],
    ...(c.route ? ([["Route", `${c.route[0]} → ${c.route[1]}`]] as Array<[string, string]>) : []),
    ...(c.distanceKm && !c.route ? ([["Distance", `${c.distanceKm} km`]] as Array<[string, string]>) : []),
  ])}</div>
  <div class="lede">Tailspot didn't guess: it matched the plane in the brackets to <b>live ADS-B</b>.</div>
</div>${foot(src)}`,
      },
      { name: "cta", html: ctaSlide(ctx.stats ? roundedCatchCount(ctx.stats.catches) : null) },
    ];

    const caption = [
      hook,
      "",
      `A real ${contrail ? "contrail" : "plane"}, photographed and identified in Tailspot. A, B, C or D? Comment before you swipe; the answer is on slide 5.`,
      "",
      "Tailspot names the real plane over you from live ADS-B, then you add it to your collection. Free on iPhone, link in bio.",
    ].join("\n");

    return {
      template: "guess-plane",
      hook,
      caption,
      hashtags: ["#avgeek", "#planespotting", "#guesstheplane", "#aviation"],
      slides,
      subject: {
        catchId: c.id,
        photo: `marketing/catch-photos/${c.file}`,
        answer: c.typecode,
        answerName: name,
        answerLetter,
        options,
        rarity: info.rarity,
        points: RARITY_POINTS[info.rarity],
      },
      altText: [
        `A real sky photo from the Tailspot app with cyan lock-on brackets around ${contrail ? "a contrail" : "a distant plane"}. ${hook}`,
        `Zoomed crop and four options: ${options.map((t, i) => `${LETTERS[i]}) ${displayName(t)}`).join(", ")}.`,
        `Clues: ${clues.map(([k, v]) => `${k}: ${v}`).join("; ")}.`,
        "A, B, C or D? Comment your answer.",
        `Answer: ${answerLetter}, ${name}, callsign ${c.callsign}, ${c.operator}.`,
        "Tailspot: catch the planes flying over you. Free on the App Store. tailspot.app",
      ],
    };
  },
};
