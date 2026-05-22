// Tailspot trophies — custom illustrated icons + tier-colored hex badges.
// Each achievement has its OWN icon. No more generic-trophy spam.

// ─────────────────────────────────────────────────────────────
// Custom icons — each is its own SVG with character
// All draw at 28×28 unless noted; passed `color` and `size` override.
// ─────────────────────────────────────────────────────────────
const TROPHY_ICONS = {
  // Bracket reticle — the catch act itself
  catcher: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <path d="M5 9V5h4M27 9V5h-4M5 23v4h4M27 23v4h-4" stroke={color} strokeWidth="2.2" strokeLinecap="round"/>
      <circle cx="16" cy="16" r="3" fill={color}/>
      <circle cx="16" cy="16" r="7" stroke={color} strokeWidth="1.4" strokeDasharray="2 2"/>
    </svg>
  ),
  // Wide-body silhouette (top-down)
  widebody: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <path d="M16 3c1.2 0 1.8 1.5 2 3l.4 6 8 4.2c.8.4 1.2 1 1.2 1.8v.6c0 .3-.3.5-.6.4l-8.6-2-.3 5 2.4 1.6c.2.2.3.4.3.7v.2c0 .3-.3.5-.6.4l-4.2-1-4.2 1c-.3.1-.6-.1-.6-.4v-.2c0-.3.1-.5.3-.7L13.5 22l-.3-5-8.6 2c-.3.1-.6-.1-.6-.4V18c0-.8.4-1.4 1.2-1.8l8-4.2.4-6c.2-1.5.8-3 2-3z" fill={color}/>
    </svg>
  ),
  // Regional jet — smaller plane with speed lines
  regional: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <path d="M21 16l-7-5v3l-4 1v1l4 1v3l7-4z" fill={color}/>
      <path d="M3 12h6M3 16h8M3 20h6" stroke={color} strokeWidth="1.6" strokeLinecap="round" opacity="0.6"/>
    </svg>
  ),
  // Telescope — long lens
  longlens: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <path d="M5 22l16-9 4 7-16 9-4-7z" stroke={color} strokeWidth="2" strokeLinejoin="round"/>
      <path d="M20 13l-3-5 4-2 3 5-4 2z" stroke={color} strokeWidth="2" strokeLinejoin="round"/>
      <circle cx="8" cy="25" r="2" fill={color}/>
    </svg>
  ),
  // Globe + orbiting plane
  world: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <circle cx="16" cy="16" r="9" stroke={color} strokeWidth="2"/>
      <path d="M7 16h18M16 7c3 3 3 15 0 18M16 7c-3 3-3 15 0 18" stroke={color} strokeWidth="1.6" opacity="0.7"/>
      <path d="M28 8l-2 2 1 1 2-2-1-1z" fill={color}/>
      <ellipse cx="16" cy="16" rx="12" ry="4" stroke={color} strokeWidth="1" strokeDasharray="2 2" opacity="0.5"/>
    </svg>
  ),
  // Constellation — 3 planes in formation
  constellation: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <g fill={color}>
        <circle cx="16" cy="7" r="2"/>
        <circle cx="8" cy="20" r="2"/>
        <circle cx="24" cy="20" r="2"/>
      </g>
      <path d="M16 9l-6 9M16 9l6 9M10 20h12" stroke={color} strokeWidth="1.2" opacity="0.6"/>
      <path d="M16 5l1 2-1 1-1-1 1-2zM8 18l1 2-1 1-1-1 1-2zM24 18l1 2-1 1-1-1 1-2z" fill={color}/>
    </svg>
  ),
  // Five-point spread — 5 dots in V
  quintet: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <g fill={color}>
        <circle cx="6" cy="9" r="2"/>
        <circle cx="11" cy="15" r="2"/>
        <circle cx="16" cy="22" r="2.4"/>
        <circle cx="21" cy="15" r="2"/>
        <circle cx="26" cy="9" r="2"/>
      </g>
      <path d="M6 9l5 6 5 7 5-7 5-6" stroke={color} strokeWidth="1" opacity="0.4"/>
    </svg>
  ),
  // Cut diamond — rare
  diamond: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <path d="M16 4L6 13l10 15 10-15-10-9z" stroke={color} strokeWidth="1.8" strokeLinejoin="round" fill={color} fillOpacity="0.18"/>
      <path d="M6 13h20M11 13l5 15M21 13l-5 15M16 4l-5 9M16 4l5 9" stroke={color} strokeWidth="1.2"/>
    </svg>
  ),
  // 4-point sparkle — epic
  sparkle: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <path d="M16 2l3 13 13 1-13 3-3 13-3-13-13-1 13-3 3-13z" fill={color}/>
      <circle cx="6" cy="6" r="1.5" fill={color}/>
      <circle cx="26" cy="26" r="1.5" fill={color}/>
    </svg>
  ),
  // Crown — legendary
  crown: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <path d="M4 12l3 12h18l3-12-6 5-6-9-6 9-6-5z" fill={color}/>
      <circle cx="4" cy="11" r="2" fill={color}/>
      <circle cx="16" cy="6" r="2" fill={color}/>
      <circle cx="28" cy="11" r="2" fill={color}/>
      <path d="M7 26h18" stroke={color} strokeWidth="2" strokeLinecap="round"/>
    </svg>
  ),
  // Laurel + 100 — centurion
  centurion: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <path d="M4 16c0-6 4-10 8-10M28 16c0-6-4-10-8-10M4 18c0 6 4 10 8 10M28 18c0 6-4 10-8 10" stroke={color} strokeWidth="1.6" strokeLinecap="round" opacity="0.7"/>
      <path d="M8 12c1 2 3 3 4 3M22 12c-1 2-3 3-4 3M8 20c1-2 3-3 4-3M22 20c-1-2-3-3-4-3" stroke={color} strokeWidth="1.6" strokeLinecap="round" opacity="0.5"/>
      <text x="16" y="20" textAnchor="middle" fill={color} fontFamily="ui-monospace, monospace" fontSize="9" fontWeight="700">100</text>
    </svg>
  ),
  // Checklist — set master
  setmaster: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <rect x="6" y="5" width="20" height="22" rx="2.5" stroke={color} strokeWidth="1.8"/>
      <path d="M11 11l2 2 4-4M11 18l2 2 4-4M11 25h6" stroke={color} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  ),
  // Moon — night owl
  night: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <path d="M14 4a12 12 0 100 24 10 10 0 01-3-19c1-1 2-3 3-5z" fill={color}/>
      <circle cx="24" cy="9" r="1" fill={color}/>
      <circle cx="26" cy="14" r="1.2" fill={color}/>
      <circle cx="22" cy="16" r="0.8" fill={color}/>
    </svg>
  ),
  // Heritage — biplane silhouette
  heritage: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <path d="M4 12h24M4 20h24" stroke={color} strokeWidth="2.4" strokeLinecap="round"/>
      <path d="M14 8l4 16M18 8l-4 16" stroke={color} strokeWidth="1.4"/>
      <circle cx="16" cy="16" r="2.5" fill={color}/>
      <path d="M9 16l1 1 1-1M21 16l1 1 1-1" stroke={color} strokeWidth="1" strokeLinecap="round" opacity="0.6"/>
    </svg>
  ),
  // Flag / continent — coast to coast
  coast: ({ size = 28, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <path d="M4 10c2-2 4 0 6 0s2-2 4-2 2 2 4 2 4-2 6 0v8c-2 2-4 0-6 0s-2 2-4 2-2-2-4-2-4 2-6 0v-8z" fill={color}/>
      <path d="M4 22c2 1 6 1 12 1s10 0 12-1" stroke={color} strokeWidth="1.6" opacity="0.7"/>
    </svg>
  ),
};

// ─────────────────────────────────────────────────────────────
// Trophy badge — hex-shaped via clip-path, tier-colored, custom icon inside
// ─────────────────────────────────────────────────────────────
const HEX_CLIP = "polygon(50% 0%, 95% 25%, 95% 75%, 50% 100%, 5% 75%, 5% 25%)";

function Trophy({ tier = "bronze", icon = "catcher", size = 56, locked = false }) {
  const t = MEDAL_TIERS[tier] ?? MEDAL_TIERS.bronze;
  const Glyph = TROPHY_ICONS[icon] ?? TROPHY_ICONS.catcher;

  if (locked) {
    return (
      <div style={{ width: size, height: size, position: "relative" }}>
        <div style={{
          position: "absolute", inset: 0,
          clipPath: HEX_CLIP,
          background: "var(--bg-surface)",
        }}/>
        <div style={{
          position: "absolute", inset: 2,
          clipPath: HEX_CLIP,
          background: "transparent",
          border: "1px dashed rgba(255,255,255,0.12)",
        }}/>
        <div style={{
          position: "absolute", inset: 0,
          display: "flex", alignItems: "center", justifyContent: "center",
          color: "var(--text-tertiary)",
        }}>
          <svg width={size * 0.34} height={size * 0.34} viewBox="0 0 24 24" fill="none">
            <rect x="5" y="11" width="14" height="10" rx="2" stroke="currentColor" strokeWidth="1.6"/>
            <path d="M8 11V8a4 4 0 018 0v3" stroke="currentColor" strokeWidth="1.6"/>
          </svg>
        </div>
      </div>
    );
  }

  return (
    <div style={{
      width: size, height: size,
      position: "relative",
      filter: `drop-shadow(0 4px 14px ${t.glow})`,
    }}>
      {/* outer ring — tier color */}
      <div style={{
        position: "absolute", inset: 0,
        clipPath: HEX_CLIP,
        background: `linear-gradient(135deg, ${t.color} 0%, ${t.inner} 100%)`,
      }}/>
      {/* inner well — dark with subtle inner glow */}
      <div style={{
        position: "absolute", inset: size * 0.1,
        clipPath: HEX_CLIP,
        background: `radial-gradient(circle at 35% 30%, ${t.inner} 0%, rgba(0,0,0,0.85) 100%)`,
      }}/>
      {/* icon */}
      <div style={{
        position: "absolute", inset: 0,
        display: "flex", alignItems: "center", justifyContent: "center",
      }}>
        <Glyph size={size * 0.52} color={t.color}/>
      </div>
      {/* tier pip — small dot bottom-right */}
      <div style={{
        position: "absolute", bottom: size * 0.04, right: size * 0.18,
        width: size * 0.14, height: size * 0.14, borderRadius: 999,
        background: t.color,
        boxShadow: `0 0 0 1.5px rgba(0,0,0,0.55), 0 0 8px ${t.glow}`,
      }}/>
    </div>
  );
}

// Updated achievement metadata — each one gets an icon
const ACHIEVEMENT_ICONS = {
  catcher:   "catcher",
  heavy:     "widebody",
  regional:  "regional",
  longshot:  "longlens",
  world:     "world",
  multi:     "constellation",
  quintet:   "quintet",
  firstrare: "diamond",
  epic:      "sparkle",
  legendary: "crown",
  setmaster: "setmaster",
  centurion: "centurion",
  night:     "night",
  heritage:  "heritage",
  coast:     "coast",
};

Object.assign(window, {
  TROPHY_ICONS, Trophy, ACHIEVEMENT_ICONS,
});
