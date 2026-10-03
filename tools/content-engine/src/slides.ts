/**
 * Slide design system: one 1080×1920 HTML page per slide, screenshotted by
 * render.ts. Brand tokens mirror web/public/style.css and Brand.swift
 * (carbon-dark base, signature cyan, B612 Mono for data, a clean sans for
 * prose, the app's rarity tints).
 *
 * SAFE ZONE. TikTok / Reels / Shorts overlay their UI on the bottom ~20%
 * (caption, music, progress) and the right ~12% (like/comment/share rail),
 * plus a strip at the top. Text lives inside `.safe` (left 72, right 140,
 * top 150, bottom 400). Only background decoration crosses those lines.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { RARITY_COLORS, RARITY_POINTS, type Rarity } from "./aircraftTypes.ts";
import { APP_ICON_PATH, B612_DIR, INTER_FONT_PATH, REPO_ROOT } from "./paths.ts";
import { esc, seededRandom } from "./util.ts";

export const W = 1080;
export const H = 1920;
export const SAFE = { left: 72, right: 140, top: 150, bottom: 400 } as const;

const dataUri = (path: string, mime: string) => `data:${mime};base64,${readFileSync(path).toString("base64")}`;

let fontCss: string | null = null;
function fonts(): string {
  if (fontCss) return fontCss;
  fontCss = `
@font-face { font-family: "Inter"; font-weight: 400 900; src: url(${dataUri(INTER_FONT_PATH, "font/woff2")}) format("woff2"); }
@font-face { font-family: "B612 Mono"; font-weight: 400; src: url(${dataUri(join(B612_DIR, "B612Mono-Regular.ttf"), "font/ttf")}) format("truetype"); }
@font-face { font-family: "B612 Mono"; font-weight: 700; src: url(${dataUri(join(B612_DIR, "B612Mono-Bold.ttf"), "font/ttf")}) format("truetype"); }`;
  return fontCss;
}

const CSS = `
:root {
  --bg: #0A0E1A; --bg-elev: #1A2030; --bg-surface: #0F1425; --border: #1C2340;
  --text: #E8F4FF; --dim: #A0B0C0; --dim2: #7A8B9C;
  --cyan: #00D4FF; --magenta: #FF6BE6; --gold: #FFC74A; --green: #3DD68C;
  --mono: "B612 Mono", ui-monospace, monospace;
  --sans: "Inter", system-ui, sans-serif;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { width: ${W}px; height: ${H}px; overflow: hidden; background: #03060D; }
body { font-family: var(--sans); color: var(--text); -webkit-font-smoothing: antialiased; }
.slide { position: relative; width: ${W}px; height: ${H}px; overflow: hidden;
  background:
    radial-gradient(900px 700px at 78% 6%, rgba(0,212,255,0.16), transparent 62%),
    radial-gradient(800px 700px at 0% 22%, rgba(255,107,230,0.07), transparent 60%),
    radial-gradient(1400px 500px at 50% 112%, rgba(0,150,220,0.30), transparent 70%),
    linear-gradient(180deg, #02040A 0%, #050B18 38%, #0A1830 74%, #10294A 100%);
}
.stars { position: absolute; inset: 0; pointer-events: none; }
.stars i { position: absolute; border-radius: 50%; background: #fff; }
.grid { position: absolute; inset: 0; pointer-events: none; opacity: .5;
  background-image: linear-gradient(rgba(0,212,255,.045) 2px, transparent 2px), linear-gradient(90deg, rgba(0,212,255,.045) 2px, transparent 2px);
  background-size: 120px 120px; mask-image: linear-gradient(180deg, transparent 0%, #000 55%, transparent 100%); }
.safe { position: absolute; left: ${SAFE.left}px; right: ${SAFE.right}px; top: ${SAFE.top}px; bottom: ${SAFE.bottom}px;
  display: flex; flex-direction: column; }
.topbar { display: flex; align-items: center; justify-content: space-between; height: 56px; flex: none; }
.wordmark { font-family: var(--mono); font-weight: 700; font-size: 34px; letter-spacing: .22em; color: var(--cyan); display: flex; align-items: center; gap: 16px; }
.wordmark img { width: 52px; height: 52px; border-radius: 12px; }
.count { font-family: var(--mono); font-size: 28px; color: var(--dim2); letter-spacing: .1em; }
.sample { margin-top: 18px; align-self: flex-start; font-family: var(--mono); font-weight: 700; font-size: 22px; letter-spacing: .14em;
  color: #0A0E1A; background: var(--gold); padding: 8px 16px; border-radius: 8px; }
.body { flex: 1; display: flex; flex-direction: column; justify-content: center; gap: 44px; padding-top: 24px; }
.body.top { justify-content: flex-start; padding-top: 72px; }
.foot { flex: none; font-family: var(--mono); font-size: 22px; color: var(--dim2); letter-spacing: .06em; line-height: 1.4; }
.kicker { font-family: var(--mono); font-weight: 700; font-size: 30px; letter-spacing: .2em; color: var(--cyan); text-transform: uppercase; display: flex; align-items: center; gap: 16px; }
.kicker .dot { width: 18px; height: 18px; border-radius: 50%; background: #FF5555; box-shadow: 0 0 18px #FF5555; }
h1 { font-weight: 800; font-size: 100px; line-height: 1.02; letter-spacing: -0.025em; }
h2 { font-weight: 800; font-size: 76px; line-height: 1.05; letter-spacing: -0.02em; }
.lede { font-weight: 500; font-size: 44px; line-height: 1.32; color: var(--dim); }
.lede b { color: var(--text); font-weight: 700; }
.accent { color: var(--cyan); }
.mono { font-family: var(--mono); }
.badge { display: inline-flex; align-items: center; gap: 14px; align-self: flex-start; font-family: var(--mono); font-weight: 700; font-size: 34px; letter-spacing: .16em;
  text-transform: uppercase; padding: 14px 26px; border-radius: 14px; border: 3px solid var(--c); color: var(--c);
  background: color-mix(in srgb, var(--c) 14%, transparent); box-shadow: 0 0 40px color-mix(in srgb, var(--c) 35%, transparent); }
.badge small { font-size: 26px; letter-spacing: .08em; opacity: .85; }
.card { background: rgba(15,20,37,.78); border: 2px solid var(--border); border-radius: 32px; padding: 44px 48px; backdrop-filter: blur(6px); }
.rows { display: grid; grid-template-columns: 1fr 1fr; gap: 40px 36px; }
.row .k { font-family: var(--mono); font-size: 24px; letter-spacing: .16em; color: var(--dim2); text-transform: uppercase; margin-bottom: 10px; }
.row .v { font-family: var(--mono); font-weight: 700; font-size: 50px; color: var(--text); line-height: 1.1; overflow-wrap: anywhere; }
.row.wide { grid-column: 1 / -1; }
.hud { position: relative; padding: 56px 40px; display: flex; align-items: center; justify-content: center; }
.hud::before, .hud::after, .hud > .c1, .hud > .c2 { content: ""; position: absolute; width: 90px; height: 90px; border: 0 solid var(--cyan); filter: drop-shadow(0 0 10px rgba(0,212,255,.55)); }
.hud::before { left: 0; top: 0; border-left-width: 10px; border-top-width: 10px; border-top-left-radius: 14px; }
.hud::after { right: 0; top: 0; border-right-width: 10px; border-top-width: 10px; border-top-right-radius: 14px; }
.hud > .c1 { left: 0; bottom: 0; border-left-width: 10px; border-bottom-width: 10px; border-bottom-left-radius: 14px; }
.hud > .c2 { right: 0; bottom: 0; border-right-width: 10px; border-bottom-width: 10px; border-bottom-right-radius: 14px; }
.designator { font-family: var(--mono); font-weight: 700; color: var(--text); letter-spacing: .02em; line-height: 1; text-shadow: 0 0 60px rgba(0,212,255,.45); white-space: nowrap; }
.photo { position: relative; border-radius: 28px; overflow: hidden; border: 2px solid var(--border); box-shadow: 0 30px 80px rgba(0,0,0,.55); }
.photo img { display: block; width: 100%; height: 100%; object-fit: cover; }
.photo .tag { position: absolute; left: 20px; bottom: 20px; font-family: var(--mono); font-weight: 700; font-size: 22px; letter-spacing: .14em; color: var(--text);
  background: rgba(5,8,16,.72); padding: 8px 14px; border-radius: 8px; }
.list { display: flex; flex-direction: column; gap: 22px; }
.item { display: grid; grid-template-columns: 1fr auto; align-items: center; gap: 12px 24px; padding: 30px 36px; border-radius: 26px;
  background: rgba(15,20,37,.78); border: 2px solid var(--border); border-left: 8px solid var(--c, var(--cyan)); }
.item .name { font-weight: 800; font-size: 46px; letter-spacing: -0.01em; line-height: 1.1; }
.item .meta { grid-column: 1 / -1; font-family: var(--mono); font-size: 26px; color: var(--dim); letter-spacing: .04em; }
.item .tier { font-family: var(--mono); font-weight: 700; font-size: 24px; letter-spacing: .14em; color: var(--c); text-transform: uppercase; }
.bars { display: flex; flex-direction: column; gap: 26px; }
.bar { display: grid; grid-template-columns: 250px 1fr 110px; align-items: center; gap: 20px; }
.bar .l { font-family: var(--mono); font-weight: 700; font-size: 28px; letter-spacing: .12em; text-transform: uppercase; color: var(--c, var(--text)); }
.bar .t { height: 40px; border-radius: 12px; background: rgba(255,255,255,.06); overflow: hidden; }
.bar .f { height: 100%; border-radius: 12px; background: var(--c, var(--cyan)); box-shadow: 0 0 24px color-mix(in srgb, var(--c, var(--cyan)) 50%, transparent); min-width: 12px; }
.bar .n { font-family: var(--mono); font-weight: 700; font-size: 38px; text-align: right; }
.big { font-family: var(--mono); font-weight: 700; color: var(--cyan); line-height: .9; letter-spacing: -0.02em; text-shadow: 0 0 80px rgba(0,212,255,.5); }
.chips { display: flex; flex-wrap: wrap; gap: 18px; }
.chip { font-family: var(--mono); font-size: 30px; padding: 16px 24px; border-radius: 16px; background: rgba(15,20,37,.8); border: 2px solid var(--border); color: var(--dim); }
.chip b { color: var(--text); font-weight: 700; margin-right: 10px; }
.choices { display: grid; grid-template-columns: 1fr 1fr; gap: 22px; }
.choice { display: flex; align-items: center; gap: 22px; padding: 30px 30px; border-radius: 24px; background: rgba(15,20,37,.82); border: 2px solid var(--border); }
.choice .letter { flex: none; width: 66px; height: 66px; border-radius: 16px; display: grid; place-items: center; font-family: var(--mono); font-weight: 700; font-size: 36px; color: #05101C; background: var(--cyan); }
.choice .opt { font-weight: 700; font-size: 38px; line-height: 1.12; }
.steps { display: flex; flex-direction: column; gap: 30px; }
.step { display: grid; grid-template-columns: 96px 1fr; gap: 28px; align-items: start; }
.step .n { width: 96px; height: 96px; border-radius: 24px; border: 3px solid var(--cyan); display: grid; place-items: center; font-family: var(--mono); font-weight: 700; font-size: 44px; color: var(--cyan); }
.step .t { font-weight: 800; font-size: 46px; line-height: 1.1; }
.step .d { font-weight: 500; font-size: 34px; color: var(--dim); line-height: 1.3; margin-top: 8px; }
.compass { position: relative; width: 300px; height: 300px; flex: none; border-radius: 50%; border: 3px solid rgba(0,212,255,.45);
  background: radial-gradient(circle, rgba(0,212,255,.10), transparent 70%); }
.compass span { position: absolute; font-family: var(--mono); font-weight: 700; font-size: 28px; color: var(--dim2); }
.compass .N { top: 12px; left: 50%; transform: translateX(-50%); color: var(--cyan); }
.compass .S { bottom: 12px; left: 50%; transform: translateX(-50%); }
.compass .E { right: 16px; top: 50%; transform: translateY(-50%); }
.compass .W { left: 16px; top: 50%; transform: translateY(-50%); }
.compass svg { position: absolute; inset: 0; }
.cta-icon { width: 260px; height: 260px; border-radius: 58px; box-shadow: 0 0 120px rgba(0,212,255,.35), 0 30px 80px rgba(0,0,0,.6); border: 2px solid rgba(0,212,255,.35); }
.store { height: 120px; }
`;

function stars(seed: string): string {
  const rand = seededRandom(`stars:${seed}`);
  let out = "";
  for (let i = 0; i < 90; i++) {
    const x = rand() * W;
    const y = rand() * H * 0.75;
    const s = rand() < 0.12 ? 4 : rand() < 0.5 ? 3 : 2;
    const o = (0.15 + rand() * 0.55) * (1 - y / (H * 0.9));
    out += `<i style="left:${x.toFixed(0)}px;top:${y.toFixed(0)}px;width:${s}px;height:${s}px;opacity:${o.toFixed(2)}"></i>`;
  }
  return `<div class="stars">${out}</div>`;
}

let iconUri: string | null = null;
export function appIconUri(): string {
  iconUri ??= dataUri(APP_ICON_PATH, "image/png");
  return iconUri;
}

let badgeUri: string | null = null;
function appStoreBadgeUri(): string {
  badgeUri ??= dataUri(join(REPO_ROOT, "web/public/app-store-badge.svg"), "image/svg+xml");
  return badgeUri;
}

export interface FrameOptions {
  index: number;
  total: number;
  sample: boolean;
  seed: string;
}

/** Wrap a slide's inner HTML into a full document. */
export function page(inner: string, o: FrameOptions): string {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${fonts()}${CSS}</style></head><body>
<div class="slide">${stars(o.seed)}<div class="grid"></div>
<div class="safe">
  <div class="topbar"><div class="wordmark"><img src="${appIconUri()}" alt="">TAILSPOT</div><div class="count">${o.index}/${o.total}</div></div>
  ${o.sample ? `<div class="sample">SAMPLE DATA · NOT A REAL SIGHTING</div>` : ""}
  ${inner}
</div></div></body></html>`;
}

// ── Components (return HTML strings; every data value goes through esc) ──

export const kicker = (text: string, live = false) => `<div class="kicker">${live ? '<span class="dot"></span>' : ""}${esc(text)}</div>`;

export function tierBadge(r: Rarity, withPoints = true): string {
  const pts = withPoints ? ` <small>${RARITY_POINTS[r]} PTS</small>` : "";
  return `<div class="badge" style="--c:${RARITY_COLORS[r]}">${esc(r)}${pts}</div>`;
}

export function rows(items: Array<[string, string] | [string, string, "wide"]>): string {
  return `<div class="rows">${items
    .map(([k, v, w]) => `<div class="row${w ? " wide" : ""}"><div class="k">${esc(k)}</div><div class="v">${esc(v)}</div></div>`)
    .join("")}</div>`;
}

export const foot = (text: string) => `<div class="foot">${esc(text)}</div>`;

/** Heading-in-a-compass graphic: an aircraft glyph rotated to its track. */
export function compass(trackDeg: number | null): string {
  const rot = trackDeg ?? 0;
  const plane = `<g transform="rotate(${rot.toFixed(0)} 150 150)"><path fill="#00D4FF" d="M150 70 c6 0 9 8 9 18 v40 l56 30 v14 l-56-14 v34 l16 12 v10 l-25-7 l-25 7 v-10 l16-12 v-34 l-56 14 v-14 l56-30 v-40 c0-10 3-18 9-18z" style="filter: drop-shadow(0 0 10px rgba(0,212,255,.7))"/></g>`;
  return `<div class="compass"><span class="N">N</span><span class="E">E</span><span class="S">S</span><span class="W">W</span><svg viewBox="0 0 300 300">${trackDeg === null ? "" : plane}</svg></div>`;
}

export function ctaSlide(statsLine: string | null): string {
  return `<div class="body" style="align-items:flex-start; gap: 48px">
  <img class="cta-icon" src="${appIconUri()}" alt="Tailspot app icon">
  <h1>Catch the planes flying <span class="accent">over you.</span></h1>
  <div class="lede">Point your phone at the sky. Tailspot names the <b>real</b> aircraft from live ADS-B, then you collect it.</div>
  ${statsLine ? `<div class="chips"><div class="chip"><b>${esc(statsLine)}</b>planes caught so far</div></div>` : ""}
  <div style="display:flex; align-items:center; gap: 36px">
    <img class="store" src="${appStoreBadgeUri()}" alt="Download on the App Store">
    <div><div class="mono" style="font-size:44px; font-weight:700; color:var(--cyan)">tailspot.app</div><div class="mono" style="font-size:26px; color:var(--dim2); letter-spacing:.1em; margin-top:6px">FREE · iPHONE</div></div>
  </div>
</div>`;
}
