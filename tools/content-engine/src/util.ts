/**
 * Small pure helpers: date rotation, a seeded RNG (so a given --date + data
 * always picks the same subject), and number formatting.
 */

/** Days since 1970-01-01 for a YYYY-MM-DD date (UTC). Drives the rotation. */
export function dayIndex(date: string): number {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  if (!m) throw new Error(`bad --date "${date}" (want YYYY-MM-DD)`);
  return Math.floor(Date.UTC(+m[1], +m[2] - 1, +m[3]) / 86_400_000);
}

export function todayUtc(now = new Date()): string {
  return now.toISOString().slice(0, 10);
}

/** FNV-1a 32-bit hash: turns a seed string into a number. */
export function hash32(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

/** mulberry32: tiny deterministic PRNG returning floats in [0, 1). */
export function seededRandom(seed: string): () => number {
  let a = hash32(seed);
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function pick<T>(items: readonly T[], rand: () => number): T {
  if (items.length === 0) throw new Error("pick() from empty list");
  return items[Math.floor(rand() * items.length)];
}

/** Deterministic shuffle (Fisher-Yates) that does not mutate the input. */
export function shuffled<T>(items: readonly T[], rand: () => number): T[] {
  const out = items.slice();
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

export function fmtInt(n: number): string {
  return Math.round(n).toLocaleString("en-US");
}

/** 36,975 ft → "37,000 ft" style rounding to the nearest 25 ft is too fussy for a slide; round to 100. */
export function fmtAltitudeFt(ft: number): string {
  return `${fmtInt(Math.round(ft / 100) * 100)} ft`;
}

export function fmtSpeedKt(kt: number): string {
  return `${fmtInt(kt)} kt`;
}

const CARDINALS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"] as const;
const CARDINAL_WORDS: Record<string, string> = {
  N: "north",
  NE: "northeast",
  E: "east",
  SE: "southeast",
  S: "south",
  SW: "southwest",
  W: "west",
  NW: "northwest",
};

export function cardinal(deg: number): string {
  const i = Math.round((((deg % 360) + 360) % 360) / 45) % 8;
  return CARDINALS[i];
}

export function cardinalWord(deg: number): string {
  return CARDINAL_WORDS[cardinal(deg)];
}

/** HTML-escape for anything that came from data (callsigns, registrations…). */
export function esc(s: unknown): string {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * esc() plus non-breaking hyphens inside names ("737‑800", "B‑52") so a
 * headline never wraps as "737-" / "800". Sans (Inter) text only.
 */
export function escName(s: unknown): string {
  return esc(s).replace(/(\w)-(\w)/g, "$1\u2011$2");
}

/** "a" / "an" for an aircraft name ("an A380", "a 747-8", "an MD-11"). */
export function article(word: string): string {
  const w = word.trim();
  // Letters pronounced with a leading vowel sound: A, E, F, H, I, L, M, N, O, R, S, X.
  if (/^[AEFHILMNORSX][-\d]/.test(w)) return "an";
  if (/^(8|11|18)/.test(w)) return "an";
  if (/^[aeiou]/i.test(w) && !/^(U-|Eu)/.test(w)) return "an";
  return "a";
}
