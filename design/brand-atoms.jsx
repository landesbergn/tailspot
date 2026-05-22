// Tailspot shared visual atoms — brand mark, reticle, sky placeholder, plane silhouettes.
// All bits that appear across multiple screens live here so the screen files stay focused.

// ─────────────────────────────────────────────────────────────
// Brand mark — corner-bracket reticle framing an airplane glyph.
// Renders at any size; pass `magenta`/`green` to recolor brackets.
// ─────────────────────────────────────────────────────────────
function BrandMark({ size = 56, variant = "cyan", filled = false }) {
  const color =
    variant === "magenta" ? "var(--alert-advisory)" :
    variant === "green"   ? "var(--alert-normal)"  :
    "var(--accent)";
  const arm = Math.max(6, size * 0.22);
  const stroke = Math.max(1.5, size / 28);

  return (
    <div style={{ width: size, height: size, position: "relative", flex: "0 0 auto" }}>
      {/* 4 L brackets */}
      {["tl","tr","bl","br"].map(p => (
        <div key={p} style={{
          position: "absolute",
          width: arm, height: arm,
          borderColor: color,
          borderStyle: "solid",
          borderWidth: 0,
          ...(p === "tl" && { top: 0, left: 0, borderTopWidth: stroke, borderLeftWidth: stroke }),
          ...(p === "tr" && { top: 0, right: 0, borderTopWidth: stroke, borderRightWidth: stroke }),
          ...(p === "bl" && { bottom: 0, left: 0, borderBottomWidth: stroke, borderLeftWidth: stroke }),
          ...(p === "br" && { bottom: 0, right: 0, borderBottomWidth: stroke, borderRightWidth: stroke }),
        }} />
      ))}
      {/* center airplane glyph */}
      <div style={{
        position: "absolute", inset: 0,
        display: "flex", alignItems: "center", justifyContent: "center",
      }}>
        <PlaneGlyph size={size * 0.5} color={filled ? color : color} />
      </div>
    </div>
  );
}

// SF-Symbol-ish airplane glyph (approximation — Apple's literal airplane is used in-app).
function PlaneGlyph({ size = 28, color = "currentColor", angle = -45 }) {
  return (
    <svg
      width={size} height={size} viewBox="0 0 24 24"
      style={{ transform: `rotate(${angle}deg)` }}
      aria-hidden="true"
    >
      <path
        d="M12 2.2c.8 0 1.4 1.1 1.6 2.1l.4 4.9 6.6 3.9c.7.4 1 1 1 1.7v.4c0 .3-.3.5-.6.4l-7-2-.4 4.5 1.6 1.1c.2.1.3.4.3.6v.3c0 .3-.3.5-.6.4l-2.9-.8-2.9.8c-.3.1-.6-.1-.6-.4v-.3c0-.2.1-.5.3-.6L9.4 18l-.4-4.5-7 2c-.3.1-.6-.1-.6-.4v-.4c0-.7.3-1.3 1-1.7l6.6-3.9.4-4.9c.2-1 .8-2 1.6-2z"
        fill={color}
      />
    </svg>
  );
}

// Horizontal wordmark lockup
function Lockup({ size = "md", color = "var(--text-primary)" }) {
  const iconSize = size === "lg" ? 96 : size === "sm" ? 22 : 36;
  const wmSize   = size === "lg" ? 30 : size === "sm" ? 13 : 18;
  const gap      = size === "lg" ? 18 : size === "sm" ? 8 : 12;
  const tracking = size === "lg" ? 6 : size === "sm" ? 2 : 3.5;
  return (
    <div style={{ display: "flex", alignItems: "center", gap }}>
      <BrandMark size={iconSize} />
      <span style={{
        fontFamily: "var(--font-mono)",
        fontWeight: 700,
        fontSize: wmSize,
        letterSpacing: tracking,
        textTransform: "uppercase",
        color,
      }}>TAILSPOT</span>
    </div>
  );
}

// Reticle / lock brackets for the AR view (positioned by parent).
function Reticle({ size = 110, state = "default", thickness = 2.5 }) {
  // state: 'default' (cyan thin), 'acquiring' (cyan, dashed), 'pinned' (magenta), 'locked' (green)
  const color =
    state === "pinned" ? "var(--alert-advisory)" :
    state === "locked" ? "var(--alert-normal)"   :
    "var(--accent)";
  const arm = size * 0.24;
  return (
    <div style={{ width: size, height: size, position: "relative", pointerEvents: "none" }}
         className={`bracket-set ${state}`}>
      {["tl","tr","bl","br"].map(p => (
        <div key={p} style={{
          position: "absolute",
          width: arm, height: arm,
          borderColor: color,
          borderStyle: state === "acquiring" ? "dashed" : "solid",
          borderWidth: 0,
          ...(p === "tl" && { top: 0, left: 0, borderTopWidth: thickness, borderLeftWidth: thickness }),
          ...(p === "tr" && { top: 0, right: 0, borderTopWidth: thickness, borderRightWidth: thickness }),
          ...(p === "bl" && { bottom: 0, left: 0, borderBottomWidth: thickness, borderLeftWidth: thickness }),
          ...(p === "br" && { bottom: 0, right: 0, borderBottomWidth: thickness, borderRightWidth: thickness }),
        }} />
      ))}
    </div>
  );
}

// Faux camera sky — gradient + soft clouds + faint plane silhouettes positioned by parent.
function SkyBackground({ time = "day" }) {
  const gradient = time === "dusk"
    ? "linear-gradient(180deg, #1a1428 0%, #3b2a4a 38%, #c46f55 78%, #f0b78e 100%)"
    : time === "night"
    ? "linear-gradient(180deg, #050810 0%, #0a0e1a 60%, #1a2030 100%)"
    : "linear-gradient(180deg, #4a7da8 0%, #79a8c9 50%, #b3d2e6 100%)";
  return (
    <div style={{ position: "absolute", inset: 0, background: gradient, overflow: "hidden" }}>
      {/* clouds */}
      <div style={{
        position: "absolute", left: "-10%", top: "60%", width: "70%", height: 100,
        background: "radial-gradient(ellipse, rgba(255,255,255,0.35) 0%, transparent 60%)",
        filter: "blur(20px)",
      }} />
      <div style={{
        position: "absolute", right: "-15%", top: "40%", width: "80%", height: 120,
        background: "radial-gradient(ellipse, rgba(255,255,255,0.22) 0%, transparent 65%)",
        filter: "blur(24px)",
      }} />
      <div style={{
        position: "absolute", left: "20%", top: "75%", width: "50%", height: 60,
        background: "radial-gradient(ellipse, rgba(255,255,255,0.18) 0%, transparent 70%)",
        filter: "blur(16px)",
      }} />
      {/* contrails */}
      <div style={{
        position: "absolute", left: "10%", top: "28%", width: "60%", height: 2,
        background: "linear-gradient(90deg, transparent 0%, rgba(255,255,255,0.4) 50%, transparent 100%)",
        transform: "rotate(-8deg)",
        filter: "blur(1px)",
      }} />
    </div>
  );
}

// Tiny dot/silhouette for distant planes drawn over the sky.
function PlaneDot({ left, top, size = 10, angle = 0, color = "rgba(20,30,40,0.6)" }) {
  return (
    <div style={{
      position: "absolute", left, top,
      transform: `translate(-50%,-50%) rotate(${angle}deg)`,
    }}>
      <PlaneGlyph size={size} color={color} />
    </div>
  );
}

// Striped placeholder for an aircraft photo card (used until Planespotters image lands).
function PhotoPlaceholder({ width = "100%", height = 140, label = "AIRCRAFT PHOTO", radius = 8 }) {
  return (
    <div style={{
      width, height, borderRadius: radius, overflow: "hidden",
      position: "relative",
      background: "repeating-linear-gradient(135deg, #0e1424 0px, #0e1424 6px, #131b2e 6px, #131b2e 12px)",
      border: "1px solid rgba(255,255,255,0.06)",
      display: "flex", alignItems: "center", justifyContent: "center",
    }}>
      <span style={{
        fontFamily: "var(--font-mono)",
        fontSize: 10, letterSpacing: 1.2,
        color: "rgba(160,176,192,0.5)",
        textTransform: "uppercase",
      }}>{label}</span>
    </div>
  );
}

// Tiny SF Symbol replacements drawn inline (we don't have SF Symbols on web).
const Icon = {
  airplane: ({ size = 16, color = "currentColor", rotate = -45 }) =>
    <PlaneGlyph size={size} color={color} angle={rotate} />,
  bracketReticle: ({ size = 16, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M3 7V3h4M21 7V3h-4M3 17v4h4M21 17v4h-4" stroke={color} strokeWidth="2"/>
      <circle cx="12" cy="12" r="2" fill={color}/>
    </svg>
  ),
  hangar: ({ size = 16, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M3 11l9-6 9 6v9H3v-9z" stroke={color} strokeWidth="2" strokeLinejoin="round"/>
      <path d="M3 11h18" stroke={color} strokeWidth="2"/>
    </svg>
  ),
  person: ({ size = 16, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <circle cx="12" cy="8" r="4" stroke={color} strokeWidth="2"/>
      <path d="M4 21c0-4 4-7 8-7s8 3 8 7" stroke={color} strokeWidth="2" strokeLinecap="round"/>
    </svg>
  ),
  gear: ({ size = 16, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <circle cx="12" cy="12" r="3" stroke={color} strokeWidth="2"/>
      <path d="M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2" stroke={color} strokeWidth="2" strokeLinecap="round"/>
    </svg>
  ),
  chevron: ({ size = 12, color = "currentColor", dir = "right" }) => {
    const r = { right: 0, down: 90, left: 180, up: 270 }[dir];
    return (
      <svg width={size} height={size} viewBox="0 0 12 12" style={{ transform: `rotate(${r}deg)` }}>
        <path d="M3 1l5 5-5 5" stroke={color} strokeWidth="2" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
    );
  },
  close: ({ size = 16, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M6 6l12 12M18 6l-12 12" stroke={color} strokeWidth="2.4" strokeLinecap="round"/>
    </svg>
  ),
  bolt: ({ size = 16, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M13 2L4 14h7l-2 8 9-12h-7l2-8z" stroke={color} strokeWidth="2" strokeLinejoin="round"/>
    </svg>
  ),
  compass: ({ size = 16, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <circle cx="12" cy="12" r="9" stroke={color} strokeWidth="2"/>
      <path d="M14 10l-2 6-2-6 2-2 2 2z" fill={color}/>
    </svg>
  ),
  trophy: ({ size = 16, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M6 4h12v5a6 6 0 01-12 0V4z" stroke={color} strokeWidth="2" strokeLinejoin="round"/>
      <path d="M6 6H3v2a3 3 0 003 3M18 6h3v2a3 3 0 01-3 3M9 21h6M12 15v6" stroke={color} strokeWidth="2" strokeLinecap="round"/>
    </svg>
  ),
};

Object.assign(window, {
  BrandMark, Lockup, Reticle, SkyBackground, PlaneDot, PhotoPlaceholder, PlaneGlyph, Icon,
});
