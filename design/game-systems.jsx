// Tailspot game systems — Pokédex-style typing + 5-tier rarity + medals.
// Shared by every screen that displays a plane card or counts XP.

// ─────────────────────────────────────────────────────────────
// 5 RARITY tiers — drives all point math
// ─────────────────────────────────────────────────────────────
const RARITY = {
  common:    { id: "common",    label: "COMMON",    color: "#8595A5", bg: "rgba(133,149,165,0.16)", base: 10,   examples: "737 NG · A320 · CRJ" },
  uncommon:  { id: "uncommon",  label: "UNCOMMON",  color: "#4ECCA3", bg: "rgba(78,204,163,0.16)",  base: 25,   examples: "737 MAX · A220 · E190" },
  rare:      { id: "rare",      label: "RARE",      color: "#00D4FF", bg: "rgba(0,212,255,0.16)",   base: 100,  examples: "787 · A350 · 777" },
  epic:      { id: "epic",      label: "EPIC",      color: "#9B5DE5", bg: "rgba(155,93,229,0.16)",  base: 500,  examples: "A380 · 747-8 · Concorde-era heavies" },
  legendary: { id: "legendary", label: "LEGENDARY", color: "#FFC74A", bg: "rgba(255,199,74,0.16)",  base: 2000, examples: "Air Force One · NASA SOFIA · prototypes" }, // collector gold — NOT FAA caution amber #FFB800 (2026-07-21)
};

const RARITY_ORDER = ["common", "uncommon", "rare", "epic", "legendary"];

// ─────────────────────────────────────────────────────────────
// 7 TYPES — Pokédex-style. Drives badges + set grouping.
// ─────────────────────────────────────────────────────────────
const TYPES = {
  narrow:   { id: "narrow",   label: "NARROW",   color: "#5B9DDB", glyph: "N", desc: "Single-aisle airliners" },
  wide:     { id: "wide",     label: "WIDE",     color: "#7E5FE6", glyph: "W", desc: "Twin-aisle / heavies" },
  regional: { id: "regional", label: "REGIONAL", color: "#3DD68C", glyph: "R", desc: "Short-haul jets & turboprops" },
  biz:      { id: "biz",      label: "BIZ",      color: "#E6B847", glyph: "B", desc: "Business jets" },
  mil:      { id: "mil",      label: "MIL",      color: "#88936A", glyph: "M", desc: "Military aircraft" },
  ga:       { id: "ga",       label: "GA",       color: "#E66B7A", glyph: "G", desc: "General aviation" },
  heritage: { id: "heritage", label: "HERITAGE", color: "#E68847", glyph: "H", desc: "Vintage & special-mission" },
};

// ─────────────────────────────────────────────────────────────
// Badge components — uniform sizes across the app
// ─────────────────────────────────────────────────────────────
function RarityBadge({ rarity, size = "md" }) {
  const r = RARITY[rarity] ?? RARITY.common;
  const sz = size === "sm"
    ? { padX: 6, padY: 1, font: 8 }
    : size === "lg"
    ? { padX: 10, padY: 3, font: 11 }
    : { padX: 8, padY: 2, font: 9 };
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", gap: 4,
      padding: `${sz.padY}px ${sz.padX}px`,
      borderRadius: 4,
      background: r.bg,
      color: r.color,
      fontFamily: "var(--font-mono)",
      fontWeight: 700, fontSize: sz.font,
      letterSpacing: 0.8,
      border: `1px solid ${r.color}`,
      lineHeight: 1,
    }}>
      {rarity === "legendary" && <span style={{ fontSize: sz.font - 1 }}>★</span>}
      {r.label}
    </span>
  );
}

function TypeBadge({ type, size = "md" }) {
  const t = TYPES[type] ?? TYPES.narrow;
  const sz = size === "sm"
    ? { padX: 5, padY: 1, font: 8, glyph: 12 }
    : size === "lg"
    ? { padX: 8, padY: 2, font: 11, glyph: 16 }
    : { padX: 6, padY: 1.5, font: 9, glyph: 14 };
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", gap: 4,
      padding: `${sz.padY}px ${sz.padX}px`,
      borderRadius: 999,
      background: t.color,
      color: "rgba(0,0,0,0.75)",
      fontFamily: "var(--font-sans)",
      fontWeight: 700, fontSize: sz.font,
      letterSpacing: 0.4,
      lineHeight: 1,
    }}>
      <span style={{
        width: sz.glyph, height: sz.glyph, borderRadius: 999,
        background: "rgba(0,0,0,0.2)",
        display: "inline-flex", alignItems: "center", justifyContent: "center",
        fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: sz.font - 1,
        color: "rgba(255,255,255,0.95)",
      }}>{t.glyph}</span>
      {t.label}
    </span>
  );
}

// Compact dual-badge — rarity rail + type pill, used on cards
function TagRow({ type, rarity, size = "md" }) {
  return (
    <div style={{ display: "flex", gap: 5, alignItems: "center", flexWrap: "wrap" }}>
      <RarityBadge rarity={rarity} size={size}/>
      <TypeBadge type={type} size={size}/>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Medal — bronze / silver / gold / platinum tier for an achievement
// ─────────────────────────────────────────────────────────────
const MEDAL_TIERS = {
  bronze:   { color: "#C26B3F", inner: "#7d3f1f", glow: "rgba(194,107,63,0.4)",  label: "BRONZE" },
  silver:   { color: "#C5D0DA", inner: "#6c7986", glow: "rgba(197,208,218,0.4)", label: "SILVER" },
  gold:     { color: "#FFC74A", inner: "#9c6e00", glow: "rgba(255,199,74,0.5)",  label: "GOLD" },
  platinum: { color: "#A9F4FF", inner: "#005a73", glow: "rgba(169,244,255,0.5)", label: "PLATINUM" },
};

function Medal({ tier = "bronze", size = 56, locked = false, glyph }) {
  const m = MEDAL_TIERS[tier] ?? MEDAL_TIERS.bronze;
  if (locked) {
    return (
      <div style={{
        width: size, height: size, borderRadius: 999,
        background: "var(--bg-surface)",
        border: "1px dashed rgba(255,255,255,0.12)",
        display: "flex", alignItems: "center", justifyContent: "center",
        color: "var(--text-tertiary)",
      }}>
        <svg width={size * 0.4} height={size * 0.4} viewBox="0 0 24 24" fill="none">
          <rect x="5" y="11" width="14" height="10" rx="2" stroke="currentColor" strokeWidth="1.6"/>
          <path d="M8 11V8a4 4 0 018 0v3" stroke="currentColor" strokeWidth="1.6"/>
        </svg>
      </div>
    );
  }
  return (
    <div style={{
      width: size, height: size, position: "relative",
      filter: `drop-shadow(0 6px 14px ${m.glow})`,
    }}>
      {/* outer ring */}
      <div style={{
        position: "absolute", inset: 0, borderRadius: 999,
        background: `radial-gradient(circle at 30% 30%, ${m.color} 0%, ${m.inner} 90%)`,
        boxShadow: `inset 0 -2px 4px rgba(0,0,0,0.4), inset 0 2px 2px rgba(255,255,255,0.5)`,
      }}/>
      {/* inner disk */}
      <div style={{
        position: "absolute", inset: size * 0.12, borderRadius: 999,
        background: `radial-gradient(circle at 40% 40%, ${m.inner} 0%, rgba(0,0,0,0.4) 100%)`,
        display: "flex", alignItems: "center", justifyContent: "center",
        color: m.color,
      }}>
        {glyph ?? <Icon.trophy size={size * 0.45} color={m.color}/>}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Sample data — used for designs across the app
// ─────────────────────────────────────────────────────────────
const PLANE_LIBRARY = {
  ual248:  { call: "UAL248",  carrier: "United Airlines", type: "wide",    rarity: "rare",      model: "Boeing 787-9",      alt: "FL370", spd: "478kt", dist: "12km" },
  baw286:  { call: "BAW286",  carrier: "British Airways", type: "wide",    rarity: "epic",      model: "Airbus A380",       alt: "FL360", spd: "488kt", dist: "9km"  },
  dal2104: { call: "DAL2104", carrier: "Delta",           type: "narrow",  rarity: "common",    model: "Airbus A320",       alt: "FL280", spd: "412kt", dist: "8km"  },
  swa2331: { call: "SWA2331", carrier: "Southwest",       type: "narrow",  rarity: "common",    model: "Boeing 737-800",    alt: "FL340", spd: "455kt", dist: "18km" },
  asa1276: { call: "ASA1276", carrier: "Alaska",          type: "narrow",  rarity: "uncommon",  model: "Boeing 737 MAX 9",  alt: "FL320", spd: "446kt", dist: "14km" },
  skw5102: { call: "SKW5102", carrier: "SkyWest",         type: "regional",rarity: "common",    model: "Embraer E175",      alt: "FL220", spd: "388kt", dist: "5km"  },
  af1:     { call: "AF1",     carrier: "USAF",            type: "mil",     rarity: "legendary", model: "Boeing VC-25",      alt: "FL400", spd: "480kt", dist: "31km" },
  nasa747: { call: "NASA747", carrier: "NASA SOFIA",      type: "heritage",rarity: "legendary", model: "Boeing 747SP",      alt: "FL410", spd: "390kt", dist: "22km" },
  vist22:  { call: "VTI22",   carrier: "VistaJet",        type: "biz",     rarity: "uncommon",  model: "Global 7500",       alt: "FL410", spd: "452kt", dist: "17km" },
  cessna:  { call: "N773LF",  carrier: "Private",         type: "ga",      rarity: "common",    model: "Cessna 172",        alt: "3,200", spd: "118kt", dist: "2km"  },
};

// ─────────────────────────────────────────────────────────────
// Achievements — definition list. Multi-tier (b/s/g/p) or one-shot.
// ─────────────────────────────────────────────────────────────
const ACHIEVEMENTS = [
  { id: "catcher",   title: "Catcher",       desc: "Catches",                       progress: 47,  tiers: [{ tier: "bronze", at: 10 }, { tier: "silver", at: 50 }, { tier: "gold", at: 250 }, { tier: "platinum", at: 1000 }] },
  { id: "heavy",     title: "Wide Awake",    desc: "Wide-bodies caught",            progress: 6,   tiers: [{ tier: "bronze", at: 5 }, { tier: "silver", at: 20 }, { tier: "gold", at: 50 }] },
  { id: "regional",  title: "Regional Pilot",desc: "Regional jets caught",          progress: 0,   tiers: [{ tier: "bronze", at: 10 }, { tier: "silver", at: 30 }, { tier: "gold", at: 75 }] },
  { id: "longshot",  title: "Long Lens",     desc: "Catches > 30 km away",          progress: 1,   tiers: [{ tier: "bronze", at: 1 }, { tier: "silver", at: 5 }, { tier: "gold", at: 15 }] },
  { id: "world",     title: "World Tour",    desc: "Aircraft registered in N countries", progress: 4, tiers: [{ tier: "bronze", at: 3 }, { tier: "silver", at: 10 }, { tier: "gold", at: 25 }] },
  { id: "multi",     title: "Constellation", desc: "Multi-catches (2+ in frame)",   progress: 1,   tiers: [{ tier: "bronze", at: 1 }, { tier: "silver", at: 5 }, { tier: "gold", at: 20 }] },
  { id: "quintet",   title: "Quintet",       desc: "Caught 5+ planes in one frame", progress: 0,   tiers: [{ tier: "gold", at: 1 }] },
  { id: "firstrare", title: "First Rare",    desc: "Caught a Rare-tier plane",      progress: 1,   tiers: [{ tier: "silver", at: 1 }] },
  { id: "epic",      title: "Epic Encounter",desc: "Caught an Epic-tier plane",     progress: 0,   tiers: [{ tier: "gold", at: 1 }] },
  { id: "legendary", title: "Legendary",     desc: "Caught a Legendary-tier plane", progress: 0,   tiers: [{ tier: "platinum", at: 1 }] },
  { id: "setmaster", title: "Set Master",    desc: "First set completed",           progress: 0,   tiers: [{ tier: "silver", at: 1 }] },
  { id: "centurion", title: "Centurion",     desc: "100 catches",                   progress: 47,  tiers: [{ tier: "gold", at: 100 }] },
];

// Helpers
function highestEarnedTier(a) {
  let last = null;
  for (const t of a.tiers) {
    if (a.progress >= t.at) last = t.tier;
    else break;
  }
  return last;
}
function nextTier(a) {
  for (const t of a.tiers) if (a.progress < t.at) return t;
  return null;
}

Object.assign(window, {
  RARITY, RARITY_ORDER, TYPES, MEDAL_TIERS,
  RarityBadge, TypeBadge, TagRow, Medal,
  PLANE_LIBRARY, ACHIEVEMENTS,
  highestEarnedTier, nextTier,
});
