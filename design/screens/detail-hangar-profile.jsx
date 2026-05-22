// Aircraft / Catch detail, Hangar (2 variants), Profile, Settings.

// ─────────────────────────────────────────────────────────────
// Catch / Aircraft Detail — Variation A · Photo-led collector card
// ─────────────────────────────────────────────────────────────
function DetailA() {
  const p = PLANE_LIBRARY.ual248;
  const r = RARITY[p.rarity];
  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      {/* Photo hero — fades into bg */}
      <div style={{ position: "absolute", inset: 0, height: 320 }}>
        <PhotoPlaceholder height={320} label="UA 787-9 · N38950" radius={0}/>
        <div style={{
          position: "absolute", inset: 0,
          background: "linear-gradient(180deg, rgba(10,14,26,0) 40%, rgba(10,14,26,0.85) 80%, var(--bg-primary) 100%)",
        }}/>
      </div>

      <div style={{
        position: "absolute", top: 60, left: 0, right: 0,
        padding: "0 16px",
        display: "flex", justifyContent: "space-between",
      }}>
        <ChromePill><Icon.chevron size={14} color="var(--text-primary)" dir="left"/></ChromePill>
        <ChromePill><Icon.bolt size={14} color="var(--text-primary)"/></ChromePill>
      </div>

      <div style={{ position: "absolute", top: 230, left: 18, display: "flex", gap: 6 }}>
        <RarityBadge rarity={p.rarity}/>
        <TypeBadge type={p.type}/>
        <span className="pill normal" style={{ fontSize: 10 }}>● 2m ago</span>
      </div>

      <div style={{
        position: "absolute", top: 280, left: 0, right: 0, bottom: 0,
        padding: "0 20px",
        display: "flex", flexDirection: "column", gap: 14,
        overflowY: "auto",
      }}>
        <div>
          <div className="t-hud-callsign" style={{ fontSize: 14 }}>{p.call} · UA248</div>
          <h1 className="t-display" style={{ fontSize: 30, margin: "4px 0 4px" }}>{p.model}</h1>
          <div className="t-card-subtitle">{p.carrier}</div>
        </div>

        {/* Earned + rarity */}
        <div style={{
          padding: 14, borderRadius: 10,
          background: r.bg,
          border: `1px solid ${r.color}`,
          display: "flex", justifyContent: "space-between", alignItems: "center",
        }}>
          <div>
            <div className="t-label" style={{ fontSize: 10, color: r.color }}>EARNED</div>
            <div style={{ fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 22, color: r.color }}>+150 pts</div>
          </div>
          <div style={{ textAlign: "right", display: "flex", flexDirection: "column", gap: 2 }}>
            <span className="t-caption" style={{ fontSize: 10 }}>Catch #048</span>
            <span className="t-caption" style={{ fontSize: 10 }}>Entry 048 / 142</span>
          </div>
        </div>

        {/* Route */}
        <div className="hud-panel" style={{ padding: 14 }}>
          <div className="t-label" style={{ fontSize: 9, marginBottom: 8 }}>ROUTE</div>
          <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
            <RouteEndpoint code="SFO" name="San Francisco"/>
            <RouteLine progress={0.45}/>
            <RouteEndpoint code="EWR" name="Newark" align="right"/>
          </div>
        </div>

        {/* Stats grid */}
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
          <Stat label="ALTITUDE" value="FL370" hint="11.3 km"/>
          <Stat label="SPEED" value="478kt" hint="885 km/h"/>
          <Stat label="DISTANCE" value="12.4 km" hint="slant"/>
          <Stat label="BEARING" value="287°" hint="WNW"/>
          <Stat label="ICAO24" value="A9F2B1" hint="hex"/>
          <Stat label="REGISTRATION" value="N38950" hint="tail"/>
        </div>

        <div className="hud-panel" style={{ padding: 14 }}>
          <div className="t-label" style={{ fontSize: 9, marginBottom: 6 }}>CAUGHT AT</div>
          <div className="t-body" style={{ fontSize: 14 }}>May 20, 2026 · 5:24 PM</div>
          <div className="t-caption" style={{ marginTop: 2 }}>Berkeley, CA · 37.871° N, −122.272° W</div>
        </div>

        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 4, marginTop: 4, paddingBottom: 24 }}>
          <span className="t-caption" style={{ fontSize: 10 }}>© Maarten Visser · planespotters.net</span>
        </div>
      </div>
    </div>
  );
}

function RouteEndpoint({ code, name, align = "left" }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 2, textAlign: align, flex: "0 0 auto" }}>
      <span className="t-hud-callsign" style={{ fontSize: 17 }}>{code}</span>
      <span className="t-caption" style={{ fontSize: 10 }}>{name}</span>
    </div>
  );
}
function RouteLine({ progress = 0.5 }) {
  return (
    <div style={{ flex: 1, height: 22, position: "relative" }}>
      <div style={{ position: "absolute", top: 10, left: 0, right: 0, height: 2,
        background: "repeating-linear-gradient(90deg, var(--text-tertiary) 0 4px, transparent 4px 8px)" }}/>
      <div style={{
        position: "absolute", top: 4, left: `${progress * 100}%`, transform: "translateX(-50%)",
        color: "var(--accent)",
      }}>
        <PlaneGlyph size={14} color="var(--accent)" angle={-45}/>
      </div>
    </div>
  );
}

function ChromePill({ children }) {
  return (
    <div style={{
      width: 36, height: 36, borderRadius: 999,
      background: "rgba(10,14,26,0.7)",
      backdropFilter: "blur(10px)",
      border: "1px solid rgba(255,255,255,0.1)",
      display: "flex", alignItems: "center", justifyContent: "center",
    }}>{children}</div>
  );
}

// ─────────────────────────────────────────────────────────────
// Detail — Variation B · Spec sheet / departure board
// Reads like FlightAware. Less photo, more data.
// ─────────────────────────────────────────────────────────────
function DetailB() {
  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      {/* header */}
      <div style={{ position: "absolute", top: 60, left: 16, right: 16, display: "flex", justifyContent: "space-between" }}>
        <ChromePill><Icon.chevron size={14} color="var(--text-primary)" dir="left"/></ChromePill>
        <span className="t-label">CATCH #048</span>
        <ChromePill><Icon.bolt size={14} color="var(--text-primary)"/></ChromePill>
      </div>

      <div style={{ position: "absolute", top: 110, left: 0, right: 0, bottom: 0, padding: "0 18px", display: "flex", flexDirection: "column", gap: 12, overflowY: "auto" }}>
        {/* split-flap callsign */}
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 4, marginTop: 8 }}>
          <span className="t-label">CALLSIGN</span>
          <div style={{ display: "flex", gap: 4 }}>
            {"UAL248".split("").map((c, i) => (
              <div key={i} style={{
                width: 28, height: 36, borderRadius: 4,
                background: "var(--bg-surface)",
                border: "1px solid rgba(255,255,255,0.08)",
                color: "var(--accent)",
                fontFamily: "var(--font-mono)",
                fontWeight: 700, fontSize: 22,
                display: "flex", alignItems: "center", justifyContent: "center",
              }}>{c}</div>
            ))}
          </div>
          <span className="t-card-title" style={{ marginTop: 8 }}>Boeing 787-9</span>
          <span className="t-card-subtitle">United Airlines</span>
        </div>

        {/* route timeline */}
        <div className="hud-panel" style={{ padding: 16 }}>
          <div style={{ display: "flex", justifyContent: "space-between" }}>
            <div>
              <div className="t-hud-callsign" style={{ fontSize: 22 }}>SFO</div>
              <div className="t-caption">San Francisco · 14:18</div>
            </div>
            <div style={{ flex: 1, padding: "0 14px", display: "flex", flexDirection: "column", justifyContent: "center", gap: 4 }}>
              <div style={{ height: 1.5, background: "var(--accent)", opacity: 0.4 }}/>
              <span className="t-label" style={{ fontSize: 9, textAlign: "center" }}>5h 02m · 4,134 km</span>
            </div>
            <div style={{ textAlign: "right" }}>
              <div className="t-hud-callsign" style={{ fontSize: 22 }}>EWR</div>
              <div className="t-caption">Newark · 22:20</div>
            </div>
          </div>
        </div>

        {/* data rows */}
        <div className="hud-panel">
          <SpecRow label="ALTITUDE" value="FL370 · 11,278 m"/>
          <SpecRow label="GROUND SPEED" value="478 kt · 885 km/h"/>
          <SpecRow label="HEADING" value="082° E"/>
          <SpecRow label="BEARING FROM YOU" value="287° WNW · +22° elev"/>
          <SpecRow label="DISTANCE" value="12.4 km slant"/>
          <SpecRow label="REGISTRATION" value="N38950 · A9F2B1"/>
          <SpecRow label="OPERATOR" value="United Airlines" last/>
        </div>

        {/* caught */}
        <div className="hud-panel" style={{ padding: 14 }}>
          <div className="t-label" style={{ fontSize: 9 }}>CAUGHT</div>
          <div className="t-body" style={{ fontSize: 14, marginTop: 4 }}>May 20, 2026 · 5:24 PM · Berkeley CA</div>
        </div>

        <div style={{ height: 32 }}/>
      </div>
    </div>
  );
}

function SpecRow({ label, value, last = false }) {
  return (
    <div style={{
      padding: "12px 14px",
      borderBottom: last ? 0 : "1px solid rgba(255,255,255,0.06)",
      display: "flex", alignItems: "center", justifyContent: "space-between",
    }}>
      <span className="t-label" style={{ fontSize: 10 }}>{label}</span>
      <span className="t-hud-data" style={{ fontSize: 12, color: "var(--text-primary)" }}>{value}</span>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Hangar — Variation A · List (matches current §5 spec rows)
// ─────────────────────────────────────────────────────────────
function HangarA() {
  const sections = [
    { title: "WIDE-BODY", count: 6, items: [
      { call: "UAL248", op: "United Airlines", model: "Boeing 787-9", dist: "12.4km", time: "2m", n: 3, type: "wide", rarity: "rare" },
      { call: "AAL173", op: "American Airlines", model: "Boeing 777-300ER", dist: "28.0km", time: "Yesterday", n: 1, type: "wide", rarity: "rare" },
      { call: "BAW286", op: "British Airways", model: "Airbus A380", dist: "9.4km", time: "3d", n: 1, type: "wide", rarity: "epic" },
    ]},
    { title: "NARROW-BODY", count: 38, items: [
      { call: "DAL2104", op: "Delta", model: "Airbus A320", dist: "8.0km", time: "9m", n: 5, type: "narrow", rarity: "common" },
      { call: "SWA2331", op: "Southwest", model: "Boeing 737-800", dist: "18.0km", time: "1h", n: 12, type: "narrow", rarity: "common" },
      { call: "ASA1276", op: "Alaska Airlines", model: "Boeing 737 MAX 9", dist: "5.2km", time: "Yesterday", n: 2, type: "narrow", rarity: "uncommon" },
    ]},
    { title: "GENERAL AVIATION", count: 3, items: [
      { call: "N773LF", op: "Private", model: "Cessna 172", dist: "2.1km", time: "2d", n: 1, type: "ga", rarity: "common" },
    ]},
  ];

  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      {/* Nav */}
      <div style={{
        position: "absolute", top: 56, left: 0, right: 0,
        padding: "0 16px",
        display: "flex", alignItems: "center", justifyContent: "space-between",
        height: 56,
        borderBottom: "1px solid rgba(255,255,255,0.04)",
        background: "rgba(10,14,26,0.95)",
        zIndex: 2,
      }}>
        <Lockup size="sm"/>
        <div style={{ display: "flex", gap: 8 }}>
          <span className="pill accent" style={{ fontSize: 11 }}>47 catches</span>
        </div>
      </div>

      {/* Segmented control */}
      <div style={{
        position: "absolute", top: 124, left: 16, right: 16, height: 36,
        background: "var(--bg-elevated)", borderRadius: 10,
        padding: 3, display: "flex", gap: 2,
      }}>
        {["By type", "By airline", "Recent"].map((l, i) => (
          <div key={l} style={{
            flex: 1, display: "flex", alignItems: "center", justifyContent: "center",
            borderRadius: 8,
            background: i === 0 ? "var(--bg-surface)" : "transparent",
            color: i === 0 ? "var(--text-primary)" : "var(--text-secondary)",
            fontFamily: "var(--font-sans)", fontWeight: i === 0 ? 600 : 500, fontSize: 13,
          }}>{l}</div>
        ))}
      </div>

      {/* List */}
      <div style={{
        position: "absolute", top: 174, left: 0, right: 0, bottom: 0,
        padding: "10px 16px 40px", overflowY: "auto",
      }}>
        {sections.map(s => (
          <div key={s.title} style={{ marginBottom: 20 }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", marginBottom: 8, padding: "0 4px" }}>
              <span className="t-label">{s.title}</span>
              <span className="t-caption" style={{ fontSize: 10 }}>{s.count} CAUGHT</span>
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              {s.items.map(it => <HangarRow key={it.call} {...it}/>)}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function HangarRow({ call, op, model, dist, time, n, type, rarity }) {
  const t = TYPES[type] ?? TYPES.narrow;
  const r = RARITY[rarity] ?? RARITY.common;
  return (
    <div style={{
      background: "var(--bg-elevated)", borderRadius: 8,
      padding: "12px 14px",
      display: "flex", alignItems: "center", gap: 12,
      borderLeft: `3px solid ${r.color}`,
    }}>
      <div style={{
        width: 36, height: 36, borderRadius: 7,
        background: t.color,
        display: "flex", alignItems: "center", justifyContent: "center",
        color: "rgba(0,0,0,0.7)",
        fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 14,
      }}>{t.glyph}</div>
      <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 3 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 6 }}>
          <span className="t-hud-callsign" style={{ fontSize: 13 }}>{call}</span>
          <RarityBadge rarity={rarity} size="sm"/>
        </div>
        <span className="t-card-subtitle" style={{ fontSize: 12, color: "var(--text-tertiary)" }}>
          {model} · {dist}
        </span>
      </div>
      <div style={{ display: "flex", flexDirection: "column", alignItems: "flex-end", gap: 4 }}>
        {n > 1 && (
          <span style={{
            background: "rgba(232,244,255,0.1)", color: "var(--text-primary)",
            fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 10,
            padding: "2px 7px", borderRadius: 999,
          }}>×{n}</span>
        )}
        <span className="t-caption" style={{ fontSize: 10 }}>{time}</span>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Hangar — Variation B · Card grid
// Treats each catch as a trading card. Big visual hangar.
// ─────────────────────────────────────────────────────────────
function HangarB() {
  const cards = [
    { call: "UAL248",  op: "United", model: "Boeing 787-9", type: "wide", rarity: "rare", n: 3 },
    { call: "DAL2104", op: "Delta", model: "Airbus A320", type: "narrow", rarity: "common", n: 5 },
    { call: "BAW286",  op: "British Airways", model: "Airbus A380", type: "wide", rarity: "epic", n: 1 },
    { call: "SWA2331", op: "Southwest", model: "Boeing 737-800", type: "narrow", rarity: "common", n: 12 },
    { call: "AAL173",  op: "American", model: "Boeing 777-300ER", type: "wide", rarity: "rare", n: 1 },
    { call: "ASA1276", op: "Alaska", model: "Boeing 737 MAX 9", type: "narrow", rarity: "uncommon", n: 2 },
  ];

  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      <div style={{
        position: "absolute", top: 56, left: 0, right: 0,
        padding: "0 16px",
        height: 56,
        display: "flex", alignItems: "center", justifyContent: "space-between",
        background: "rgba(10,14,26,0.95)",
        zIndex: 2,
        borderBottom: "1px solid rgba(255,255,255,0.04)",
      }}>
        <Lockup size="sm"/>
        <div style={{ display: "flex", gap: 8 }}>
          <span className="pill accent" style={{ fontSize: 11 }}>47</span>
        </div>
      </div>

      {/* Filter chips */}
      <div style={{ position: "absolute", top: 124, left: 0, right: 0, padding: "0 16px",
        display: "flex", gap: 6, overflowX: "auto", paddingBottom: 8 }}>
        <Chip active>All · 47</Chip>
        <Chip>Rare · 5</Chip>
        <Chip>Wide-body · 6</Chip>
        <Chip>Narrow-body · 38</Chip>
        <Chip>GA · 3</Chip>
      </div>

      {/* Card grid */}
      <div style={{
        position: "absolute", top: 176, left: 0, right: 0, bottom: 0,
        padding: "8px 16px 40px",
        overflowY: "auto",
        display: "grid", gridTemplateColumns: "1fr 1fr",
        gap: 12,
      }}>
        {cards.map(c => <MiniCard key={c.call} {...c}/>)}
      </div>
    </div>
  );
}

function Chip({ children, active = false }) {
  return (
    <span style={{
      flexShrink: 0,
      padding: "7px 13px",
      borderRadius: 999,
      background: active ? "var(--accent)" : "var(--bg-elevated)",
      color: active ? "#02131a" : "var(--text-secondary)",
      fontFamily: "var(--font-sans)",
      fontWeight: 600, fontSize: 12,
      letterSpacing: 0.2,
    }}>{children}</span>
  );
}

function MiniCard({ call, op, model, type, rarity, n = 1 }) {
  const r = RARITY[rarity] ?? RARITY.common;
  return (
    <div style={{
      borderRadius: 12,
      background: "linear-gradient(180deg, var(--bg-elevated) 0%, var(--bg-surface) 100%)",
      border: `1px solid ${r.color}`,
      padding: 10, display: "flex", flexDirection: "column", gap: 8,
      position: "relative", overflow: "hidden",
    }}>
      <div style={{ position: "absolute", left: 0, right: 0, top: 0, height: 2, background: r.color }}/>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 2 }}>
        <span className="t-hud-callsign" style={{ fontSize: 11 }}>{call}</span>
        <RarityBadge rarity={rarity} size="sm"/>
      </div>
      <PhotoPlaceholder height={66} label={model.split(" ")[0].toUpperCase()} radius={6}/>
      <div>
        <div className="t-card-title" style={{ fontSize: 12, lineHeight: 1.2 }}>{model}</div>
        <div className="t-caption" style={{ fontSize: 10, marginTop: 2 }}>{op}</div>
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <TypeBadge type={type} size="sm"/>
        {n > 1 && (
          <span style={{
            background: "rgba(0,0,0,0.5)", color: "var(--text-primary)",
            fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 10,
            padding: "2px 6px", borderRadius: 999,
          }}>×{n}</span>
        )}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Profile
// ─────────────────────────────────────────────────────────────
function ProfileScreen() {
  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      <div style={{
        position: "absolute", top: 56, left: 0, right: 0,
        padding: "0 16px", height: 56,
        display: "flex", alignItems: "center", justifyContent: "space-between",
        background: "rgba(10,14,26,0.95)", zIndex: 2,
        borderBottom: "1px solid rgba(255,255,255,0.04)",
      }}>
        <Lockup size="sm"/>
        <ChromePill><Icon.gear size={14} color="var(--text-primary)"/></ChromePill>
      </div>

      <div style={{
        position: "absolute", top: 124, left: 0, right: 0, bottom: 0,
        padding: "16px 16px 40px", overflowY: "auto",
        display: "flex", flexDirection: "column", gap: 18,
      }}>
        {/* Identity */}
        <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
          <div style={{
            width: 72, height: 72, borderRadius: 12,
            background: "linear-gradient(135deg, #00d4ff 0%, #9B5DE5 100%)",
            display: "flex", alignItems: "center", justifyContent: "center",
            color: "rgba(0,0,0,0.7)", fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 24,
          }}>NL</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            <span className="t-display" style={{ fontSize: 22 }}>@you</span>
            <span className="t-caption">Berkeley, CA · joined May 2026</span>
            <div style={{ marginTop: 4, display: "flex", gap: 6 }}>
              <span className="pill" style={{ fontSize: 10, background: "rgba(0,212,255,0.12)", color: "var(--accent)" }}>PUBLIC</span>
            </div>
          </div>
        </div>

        {/* Headline points */}
        <div style={{
          padding: 16, borderRadius: 12,
          background: "linear-gradient(135deg, var(--bg-elevated) 0%, var(--bg-surface) 100%)",
          border: "1px solid rgba(255,255,255,0.06)",
          display: "flex", justifyContent: "space-between", alignItems: "center",
        }}>
          <div>
            <div className="t-label" style={{ fontSize: 10 }}>TOTAL POINTS</div>
            <div style={{ fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 32, color: "var(--accent)", marginTop: 4 }}>4,275</div>
          </div>
          <div style={{ textAlign: "right" }}>
            <div className="t-label" style={{ fontSize: 10 }}>GLOBAL RANK</div>
            <div style={{ fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 22, color: "var(--text-primary)", marginTop: 4 }}>#12</div>
            <div className="t-caption" style={{ fontSize: 10, color: "var(--alert-normal)" }}>+3 this week</div>
          </div>
        </div>

        {/* Stats grid */}
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr 1fr", gap: 8 }}>
          <ProfileStat label="CATCHES" value="47"/>
          <ProfileStat label="UNIQUE" value="31"/>
          <ProfileStat label="RARE+" value="5"/>
          <ProfileStat label="MEDALS" value="5"/>
        </div>

        {/* Rarity breakdown bar */}
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <div className="t-label" style={{ fontSize: 10, padding: "0 4px" }}>BY RARITY</div>
          <RarityStrip counts={{ common: 31, uncommon: 9, rare: 5, epic: 2, legendary: 0 }}/>
        </div>

        {/* Medals strip */}
        <div>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", padding: "0 4px 10px" }}>
            <span className="t-label">RECENT MEDALS</span>
            <span className="t-caption" style={{ fontSize: 10, color: "var(--accent)" }}>VIEW ALL ›</span>
          </div>
          <div style={{ display: "flex", gap: 12, overflowX: "auto", padding: "4px 4px 8px" }}>
            <TrophyCard tier="silver" icon="widebody" title="Wide Awake" sub="5 wide-bodies"/>
            <TrophyCard tier="bronze" icon="catcher"  title="Catcher"    sub="10 catches"/>
            <TrophyCard tier="bronze" icon="world"    title="World Tour" sub="3 countries"/>
            <TrophyCard tier="silver" icon="diamond"  title="First Rare" sub="caught one"/>
            <TrophyCard tier="bronze" icon="constellation" title="Constellation" sub="2-catch"/>
          </div>
        </div>

        {/* Recent catches strip */}
        <div>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", padding: "0 4px 10px" }}>
            <span className="t-label">RECENT CATCHES</span>
            <span className="t-caption" style={{ fontSize: 10, color: "var(--accent)" }}>HANGAR ›</span>
          </div>
          <div style={{ display: "flex", gap: 8, overflowX: "auto", padding: "0 4px" }}>
            {[PLANE_LIBRARY.ual248, PLANE_LIBRARY.dal2104, PLANE_LIBRARY.swa2331, PLANE_LIBRARY.asa1276, PLANE_LIBRARY.skw5102].map((p, i) => (
              <div key={i} style={{ flex: "0 0 110px" }}>
                <PokeCardMini plane={p}/>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function ProfileStat({ label, value }) {
  return (
    <div className="hud-panel" style={{ padding: "10px 8px", textAlign: "center" }}>
      <div className="t-label" style={{ fontSize: 9 }}>{label}</div>
      <div className="t-hud-callsign" style={{ fontSize: 17, marginTop: 3 }}>{value}</div>
    </div>
  );
}

function RarityStrip({ counts }) {
  const total = Object.values(counts).reduce((a, b) => a + b, 0) || 1;
  return (
    <div>
      <div style={{ display: "flex", height: 12, borderRadius: 6, overflow: "hidden" }}>
        {RARITY_ORDER.map(rid => {
          const r = RARITY[rid];
          const c = counts[rid] ?? 0;
          if (c === 0) return null;
          return <div key={rid} style={{ flex: c, background: r.color }} title={`${r.label}: ${c}`}/>;
        })}
        {/* placeholder for empty tiers */}
        {RARITY_ORDER.every(rid => counts[rid] === 0) && (
          <div style={{ flex: 1, background: "var(--bg-elevated)" }}/>
        )}
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", marginTop: 8, gap: 4, fontFamily: "var(--font-mono)", fontSize: 10 }}>
        {RARITY_ORDER.map(rid => {
          const r = RARITY[rid];
          return (
            <div key={rid} style={{ flex: 1, textAlign: "center" }}>
              <div style={{ color: r.color, fontWeight: 700 }}>{counts[rid] ?? 0}</div>
              <div style={{ color: "var(--text-tertiary)", fontSize: 8, marginTop: 1, letterSpacing: 0.5 }}>{r.label.slice(0, 4)}</div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function TrophyCard({ tier, icon, title, sub }) {
  return (
    <div style={{
      flex: "0 0 auto", width: 110,
      padding: "14px 8px", borderRadius: 12,
      background: "var(--bg-elevated)",
      border: "1px solid rgba(255,255,255,0.04)",
      display: "flex", flexDirection: "column", alignItems: "center", gap: 8,
    }}>
      <Trophy tier={tier} icon={icon} size={50}/>
      <span className="t-card-title" style={{ fontSize: 12, textAlign: "center", lineHeight: 1.2 }}>{title}</span>
      <span className="t-caption" style={{ fontSize: 9, textAlign: "center" }}>{sub}</span>
    </div>
  );
}

function MedalCard({ tier, title, sub }) {
  // legacy fallback — redirect to TrophyCard for any caller still passing tier/title/sub.
  return <TrophyCard tier={tier} icon="catcher" title={title} sub={sub}/>;
}

function Badge() { return null; } // legacy stub

// ─────────────────────────────────────────────────────────────
// Settings — iOS-native grouped list, brand tokens
// ─────────────────────────────────────────────────────────────
function SettingsScreen() {
  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      {/* nav */}
      <div style={{
        position: "absolute", top: 56, left: 0, right: 0,
        padding: "0 16px",
        display: "flex", alignItems: "center", justifyContent: "space-between",
        height: 44,
      }}>
        <span className="t-body" style={{ color: "var(--accent)", fontWeight: 500 }}>‹ Profile</span>
        <span className="t-card-title" style={{ fontSize: 17 }}>Settings</span>
        <span style={{ width: 60 }}/>
      </div>

      <div style={{
        position: "absolute", top: 112, left: 0, right: 0, bottom: 0,
        padding: "0 0 40px", overflowY: "auto",
        display: "flex", flexDirection: "column", gap: 22,
      }}>
        <SettingsGroup header="ACCOUNT">
          <SRow title="Signed in as" value="Noah L." />
          <SRow title="Apple ID" value="hidden·relay" />
          <SRow title="Manage subscription" chevron />
        </SettingsGroup>

        <SettingsGroup header="SPOTTING">
          <SRow title="Live ADS-B source" value="OpenSky" chevron/>
          <SRow title="Search radius" value="50 km" chevron/>
          <SRow title="Visibility cap" value="100 km" chevron/>
          <SRow title="Mock data" toggle/>
          <SRow title="Debug overlay" toggle off/>
        </SettingsGroup>

        <SettingsGroup header="NOTIFICATIONS">
          <SRow title="Rare aircraft nearby" toggle />
          <SRow title="Streak reminders" toggle off />
          <SRow title="Weekly summary" toggle />
        </SettingsGroup>

        <SettingsGroup header="DATA & PRIVACY">
          <SRow title="Location precision" value="High" chevron/>
          <SRow title="Export my data" chevron/>
          <SRow title="Delete my account" destructive chevron/>
        </SettingsGroup>

        <SettingsGroup header="ABOUT">
          <SRow title="Version" value="0.4.0 (build 217)"/>
          <SRow title="Acknowledgments" chevron/>
          <SRow title="Privacy policy" chevron/>
          <SRow title="Terms" chevron last/>
        </SettingsGroup>

        <div style={{ padding: "20px 16px 0", display: "flex", flexDirection: "column", alignItems: "center", gap: 4 }}>
          <Lockup size="sm" color="var(--text-tertiary)"/>
          <span className="t-caption" style={{ fontSize: 10 }}>Made with ❘ in Berkeley</span>
        </div>
      </div>
    </div>
  );
}

function SettingsGroup({ header, children }) {
  return (
    <div>
      <div className="t-label" style={{ padding: "0 20px 6px", fontSize: 10 }}>{header}</div>
      <div style={{
        margin: "0 16px",
        background: "var(--bg-elevated)",
        borderRadius: 14,
        overflow: "hidden",
      }}>{children}</div>
    </div>
  );
}

function SRow({ title, value, chevron, toggle, off, destructive, last }) {
  return (
    <div style={{
      padding: "12px 16px",
      borderBottom: last ? 0 : "0.5px solid rgba(255,255,255,0.06)",
      display: "flex", alignItems: "center", gap: 10, minHeight: 44,
    }}>
      <span className="t-body" style={{ flex: 1, fontSize: 15, color: destructive ? "var(--alert-warning)" : "var(--text-primary)" }}>{title}</span>
      {value && <span className="t-caption" style={{ fontSize: 13, color: "var(--text-secondary)" }}>{value}</span>}
      {toggle && (
        <div style={{
          width: 50, height: 30, borderRadius: 999,
          background: off ? "rgba(255,255,255,0.12)" : "var(--alert-normal)",
          position: "relative",
        }}>
          <div style={{
            position: "absolute", top: 2,
            left: off ? 2 : 22,
            width: 26, height: 26, borderRadius: 999,
            background: "#fff",
          }}/>
        </div>
      )}
      {chevron && <Icon.chevron size={12} color="var(--text-tertiary)"/>}
    </div>
  );
}

Object.assign(window, {
  DetailA, DetailB, HangarA, HangarB, ProfileScreen, SettingsScreen,
});
