// Final-pass screens — multi-catch reveal, trophy unlock, set detail, map view.

// ─────────────────────────────────────────────────────────────
// Multi-catch reveal — 3 cards fan out from a single capture
// ─────────────────────────────────────────────────────────────
function MultiCatchReveal() {
  const catches = [
    PLANE_LIBRARY.ual248,
    PLANE_LIBRARY.dal2104,
    PLANE_LIBRARY.swa2331,
  ];
  const base = catches.reduce((s, p) => s + RARITY[p.rarity].base, 0);
  const combo = 1.5;
  const total = Math.round(base * combo);

  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", background: "var(--bg-primary)" }}>
      {/* magenta backdrop (multi-catch is magenta-coded throughout the app) */}
      <div style={{
        position: "absolute", inset: 0,
        background: `
          radial-gradient(ellipse at 50% 48%, rgba(255,107,230,0.22) 0%, transparent 55%),
          radial-gradient(ellipse at 50% 48%, rgba(155,93,229,0.18) 0%, transparent 65%)
        `,
      }}/>

      {/* status banner */}
      <div style={{
        position: "absolute", top: 76, left: 0, right: 0,
        display: "flex", justifyContent: "center",
      }}>
        <div style={{
          padding: "8px 16px", borderRadius: 999,
          background: "linear-gradient(135deg, rgba(255,107,230,0.95) 0%, rgba(155,93,229,0.95) 100%)",
          boxShadow: "0 8px 24px rgba(255,107,230,0.4)",
          display: "flex", alignItems: "center", gap: 10,
        }}>
          <span style={{
            fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 14,
            color: "#fff", letterSpacing: 1.5,
          }}>3×</span>
          <span style={{
            fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 11,
            color: "rgba(255,255,255,0.9)", letterSpacing: 2,
          }}>MULTI-CATCH</span>
        </div>
      </div>

      {/* Card fan */}
      <div style={{
        position: "absolute", top: 142, left: 0, right: 0,
        display: "flex", justifyContent: "center",
        height: 380,
      }}>
        <div style={{ position: "relative", width: 320, height: 380 }}>
          <div style={{ position: "absolute", left: 8, top: 28, transform: "rotate(-10deg)", transformOrigin: "bottom center" }}>
            <PokeCard plane={catches[0]} owned size="md"/>
          </div>
          <div style={{ position: "absolute", left: 110, top: 60, transform: "rotate(10deg)", transformOrigin: "bottom center" }}>
            <PokeCard plane={catches[2]} owned size="md"/>
          </div>
          <div style={{ position: "absolute", left: 50, top: 12, zIndex: 3 }}>
            <PokeCard plane={catches[1]} owned size="md"/>
          </div>
        </div>
      </div>

      {/* combo math card */}
      <div style={{
        position: "absolute", bottom: 130, left: 20, right: 20,
        background: "rgba(10,14,26,0.7)",
        backdropFilter: "blur(12px)",
        border: "1px solid var(--alert-advisory)",
        borderRadius: 12,
        padding: "14px 16px",
        display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12,
      }}>
        <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          <span className="t-label" style={{ fontSize: 9, color: "var(--alert-advisory)" }}>COMBO REWARD</span>
          <span style={{ fontFamily: "var(--font-mono)", fontSize: 12, color: "var(--text-secondary)" }}>
            {base} base × {combo} combo
          </span>
        </div>
        <span style={{
          fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 30,
          color: "var(--alert-advisory)",
          textShadow: "0 0 20px rgba(255,107,230,0.4)",
        }}>+{total}<span style={{ fontSize: 13, opacity: 0.7, marginLeft: 2 }}>pt</span></span>
      </div>

      {/* actions */}
      <div style={{
        position: "absolute", bottom: 56, left: 20, right: 20,
        display: "flex", gap: 10,
      }}>
        <button style={{
          flex: 1, height: 50, border: "1px solid rgba(255,255,255,0.1)", cursor: "pointer",
          background: "transparent", color: "var(--text-secondary)",
          fontFamily: "var(--font-sans)", fontWeight: 500, fontSize: 15,
          borderRadius: 12,
        }}>View cards</button>
        <button style={{
          flex: 2, height: 50, border: 0, cursor: "pointer",
          background: "var(--accent)", color: "#02131a",
          fontFamily: "var(--font-sans)", fontWeight: 700, fontSize: 15,
          borderRadius: 12,
        }}>Keep spotting</button>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Trophy unlock — earned a new trophy or moved up a tier
// ─────────────────────────────────────────────────────────────
function TrophyUnlock() {
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", background: "var(--bg-primary)" }}>
      {/* gold rays radiating */}
      <div style={{
        position: "absolute", inset: 0,
        background: `
          radial-gradient(circle at 50% 38%, rgba(255,199,74,0.25) 0%, transparent 50%),
          conic-gradient(from 0deg at 50% 38%,
            transparent 0deg, rgba(255,199,74,0.12) 6deg, transparent 12deg,
            transparent 30deg, rgba(255,199,74,0.10) 36deg, transparent 42deg,
            transparent 60deg, rgba(255,199,74,0.12) 66deg, transparent 72deg,
            transparent 120deg, rgba(255,199,74,0.10) 126deg, transparent 132deg,
            transparent 180deg, rgba(255,199,74,0.12) 186deg, transparent 192deg,
            transparent 240deg, rgba(255,199,74,0.10) 246deg, transparent 252deg,
            transparent 300deg, rgba(255,199,74,0.12) 306deg, transparent 312deg)
        `,
      }}/>

      <div style={{
        position: "absolute", top: 76, left: 0, right: 0,
        display: "flex", justifyContent: "center",
      }}>
        <div style={{
          padding: "6px 14px", borderRadius: 999,
          background: "rgba(10,14,26,0.7)",
          backdropFilter: "blur(10px)",
          border: "1px solid var(--alert-caution)",
          fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 11,
          letterSpacing: 2, color: "var(--alert-caution)",
        }}>TIER UP · GOLD</div>
      </div>

      {/* trophy hero */}
      <div style={{
        position: "absolute", top: 200, left: 0, right: 0,
        display: "flex", justifyContent: "center",
      }}>
        <div style={{ position: "relative" }}>
          {/* aura */}
          <div style={{
            position: "absolute", inset: -30,
            background: "radial-gradient(circle, rgba(255,199,74,0.4) 0%, transparent 60%)",
            filter: "blur(20px)",
          }}/>
          <Trophy tier="gold" icon="widebody" size={160}/>
        </div>
      </div>

      {/* trophy name + description */}
      <div style={{
        position: "absolute", top: 410, left: 0, right: 0,
        textAlign: "center", padding: "0 24px",
      }}>
        <h2 className="t-display" style={{ fontSize: 28, margin: 0 }}>Wide Awake</h2>
        <p className="t-caption" style={{ fontSize: 13, color: "var(--text-secondary)", marginTop: 6, lineHeight: 1.45 }}>
          Caught your 20th wide-body aircraft.
        </p>
      </div>

      {/* tier progress chain */}
      <div style={{
        position: "absolute", top: 510, left: 24, right: 24,
        padding: "14px 16px",
        background: "var(--bg-elevated)",
        border: "1px solid rgba(255,255,255,0.05)",
        borderRadius: 12,
      }}>
        <div className="t-label" style={{ fontSize: 9, textAlign: "center", marginBottom: 10 }}>YOUR PROGRESS</div>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 0 }}>
          <TierStep tier="bronze" icon="widebody" reached label="5"/>
          <TierLine reached/>
          <TierStep tier="silver" icon="widebody" reached label="20" current/>
          <TierLine/>
          <TierStep tier="gold" icon="widebody" label="50"/>
        </div>
        <div style={{ display: "flex", justifyContent: "space-between", marginTop: 8 }}>
          <span className="t-caption" style={{ fontSize: 10 }}>Bronze</span>
          <span className="t-caption" style={{ fontSize: 10, color: "var(--alert-caution)", fontWeight: 700 }}>Silver · now</span>
          <span className="t-caption" style={{ fontSize: 10 }}>Gold · 30 to go</span>
        </div>
      </div>

      <div style={{
        position: "absolute", bottom: 56, left: 20, right: 20,
        display: "flex", gap: 10,
      }}>
        <button style={{
          flex: 1, height: 50, border: "1px solid rgba(255,255,255,0.1)", cursor: "pointer",
          background: "transparent", color: "var(--text-secondary)",
          fontFamily: "var(--font-sans)", fontWeight: 500, fontSize: 15,
          borderRadius: 12,
        }}>Share</button>
        <button style={{
          flex: 2, height: 50, border: 0, cursor: "pointer",
          background: "var(--accent)", color: "#02131a",
          fontFamily: "var(--font-sans)", fontWeight: 700, fontSize: 15,
          borderRadius: 12,
        }}>Nice</button>
      </div>
    </div>
  );
}

function TierStep({ tier, icon, reached = false, current = false, label }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 4 }}>
      <Trophy tier={tier} icon={icon} size={current ? 44 : 36} locked={!reached}/>
      <span className="t-hud-data" style={{ fontSize: 10, color: reached ? MEDAL_TIERS[tier].color : "var(--text-tertiary)" }}>{label}</span>
    </div>
  );
}
function TierLine({ reached = false }) {
  return (
    <div style={{
      flex: 1, height: 2,
      background: reached ? "var(--alert-caution)" : "rgba(255,255,255,0.08)",
      margin: "0 -2px",
    }}/>
  );
}

// ─────────────────────────────────────────────────────────────
// Set detail — opening a single set (Wide-body) showing all entries
// Caught ones are colored, uncaught are silhouettes
// ─────────────────────────────────────────────────────────────
function SetDetail() {
  // 14 wide-body slots, 6 caught
  const SET = [
    { call: "BAW286",  model: "Airbus A380",      rarity: "epic",      caught: true },
    { call: "UAL248",  model: "Boeing 787-9",     rarity: "rare",      caught: true },
    { call: "AAL173",  model: "Boeing 777-300ER", rarity: "rare",      caught: true },
    { call: "DLH409",  model: "Boeing 747-8",     rarity: "epic",      caught: true },
    { call: "QFA12",   model: "Airbus A350-1000", rarity: "rare",      caught: true },
    { call: "ANA204",  model: "Boeing 777-200",   rarity: "rare",      caught: true },
    { call: "—",       model: "Airbus A330-300",  rarity: "uncommon",  caught: false },
    { call: "—",       model: "Boeing 767-300",   rarity: "uncommon",  caught: false },
    { call: "—",       model: "Airbus A340-600",  rarity: "rare",      caught: false },
    { call: "—",       model: "Boeing 747-400",   rarity: "rare",      caught: false },
    { call: "—",       model: "Airbus A330-900",  rarity: "uncommon",  caught: false },
    { call: "—",       model: "Boeing 787-10",    rarity: "rare",      caught: false },
    { call: "—",       model: "Airbus A350-900",  rarity: "rare",      caught: false },
    { call: "—",       model: "Boeing 777X",      rarity: "legendary", caught: false },
  ];
  const got = SET.filter(s => s.caught).length;
  const t = TYPES.wide;

  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      <SimpleNav title="Wide-body"/>

      {/* hero */}
      <div style={{
        position: "absolute", top: 110, left: 16, right: 16,
        padding: 16, borderRadius: 14,
        background: `linear-gradient(135deg, ${t.color}33 0%, var(--bg-elevated) 100%)`,
        border: `1px solid ${t.color}`,
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
          <div style={{
            width: 56, height: 56, borderRadius: 999,
            background: t.color, color: "rgba(0,0,0,0.7)",
            fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 24,
            display: "flex", alignItems: "center", justifyContent: "center",
            flex: "0 0 auto",
          }}>{t.glyph}</div>
          <div style={{ flex: 1 }}>
            <span className="t-display" style={{ fontSize: 22 }}>Wide-body / Heavies</span>
            <div className="t-caption" style={{ fontSize: 11, marginTop: 2 }}>{t.desc}</div>
          </div>
        </div>
        <div style={{ marginTop: 14 }}>
          <div style={{
            height: 6, borderRadius: 3,
            background: "rgba(0,0,0,0.4)",
            overflow: "hidden",
          }}>
            <div style={{ width: `${(got / SET.length) * 100}%`, height: "100%", background: t.color }}/>
          </div>
          <div style={{ display: "flex", justifyContent: "space-between", marginTop: 6 }}>
            <span style={{ fontFamily: "var(--font-mono)", fontSize: 12, fontWeight: 700, color: t.color }}>{got}/{SET.length}</span>
            <span className="t-caption" style={{ fontSize: 10 }}>8 to go</span>
          </div>
        </div>
      </div>

      <div style={{
        position: "absolute", top: 264, left: 0, right: 0, bottom: 0,
        padding: "0 16px 40px", overflowY: "auto",
      }}>
        <div className="t-label" style={{ padding: "4px 4px 10px" }}>POKÉDEX · 14 ENTRIES</div>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
          {SET.map((s, i) => (
            <SetEntry key={i} num={i + 1} entry={s}/>
          ))}
        </div>
      </div>
    </div>
  );
}

function SetEntry({ num, entry }) {
  const r = RARITY[entry.rarity];
  if (!entry.caught) {
    return (
      <div style={{
        borderRadius: 10,
        background: "var(--bg-surface)",
        border: "1px dashed rgba(255,255,255,0.08)",
        padding: 10, display: "flex", flexDirection: "column", gap: 8,
        position: "relative", overflow: "hidden",
        opacity: 0.85,
      }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <span style={{ fontFamily: "var(--font-mono)", fontSize: 10, color: "var(--text-tertiary)" }}>#{String(num).padStart(2, "0")}</span>
          <span style={{ fontFamily: "var(--font-mono)", fontSize: 9, fontWeight: 700, color: r.color, opacity: 0.7 }}>{r.label}</span>
        </div>
        <div style={{
          height: 66, borderRadius: 6,
          background: "repeating-linear-gradient(135deg, #0e1424 0px, #0e1424 4px, #131b2e 4px, #131b2e 8px)",
          display: "flex", alignItems: "center", justifyContent: "center",
        }}>
          {/* dark plane silhouette */}
          <PlaneGlyph size={28} color="rgba(127,139,152,0.35)"/>
        </div>
        <div>
          <div className="t-card-title" style={{ fontSize: 11, lineHeight: 1.2, color: "var(--text-tertiary)" }}>{entry.model}</div>
          <div className="t-caption" style={{ fontSize: 10, marginTop: 2, color: "var(--text-tertiary)" }}>Not yet caught</div>
        </div>
      </div>
    );
  }
  return (
    <div style={{
      borderRadius: 10,
      background: "linear-gradient(180deg, var(--bg-elevated) 0%, var(--bg-surface) 100%)",
      border: `1px solid ${r.color}`,
      padding: 10, display: "flex", flexDirection: "column", gap: 8,
      position: "relative", overflow: "hidden",
    }}>
      <div style={{ position: "absolute", left: 0, right: 0, top: 0, height: 2, background: r.color }}/>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 2 }}>
        <span style={{ fontFamily: "var(--font-mono)", fontSize: 10, color: "var(--text-tertiary)" }}>#{String(num).padStart(2, "0")}</span>
        <RarityBadge rarity={entry.rarity} size="sm"/>
      </div>
      <PhotoPlaceholder height={66} label={entry.model.split(" ")[0].toUpperCase()} radius={5}/>
      <div>
        <div className="t-card-title" style={{ fontSize: 11, lineHeight: 1.2 }}>{entry.model}</div>
        <div className="t-caption" style={{ fontSize: 10, marginTop: 2 }}>{entry.call}</div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Map view — where in the world you've caught planes
// ─────────────────────────────────────────────────────────────
function MapView() {
  const pins = [
    { left: 42, top: 32, rarity: "rare" },
    { left: 38, top: 36, rarity: "common" },
    { left: 46, top: 30, rarity: "common" },
    { left: 50, top: 38, rarity: "uncommon" },
    { left: 36, top: 42, rarity: "common" },
    { left: 44, top: 46, rarity: "rare" },
    { left: 52, top: 48, rarity: "uncommon" },
    { left: 56, top: 36, rarity: "common" },
    { left: 30, top: 48, rarity: "common" },
    { left: 60, top: 52, rarity: "common" },
    { left: 48, top: 56, rarity: "common" },
    { left: 42, top: 60, rarity: "epic" },
    { left: 34, top: 28, rarity: "common" },
    { left: 64, top: 44, rarity: "common" },
  ];

  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      {/* Nav */}
      <div style={{
        position: "absolute", top: 56, left: 0, right: 0,
        padding: "0 16px", height: 56,
        display: "flex", alignItems: "center", justifyContent: "space-between",
        background: "rgba(10,14,26,0.95)", zIndex: 4,
        borderBottom: "1px solid rgba(255,255,255,0.04)",
      }}>
        <Lockup size="sm"/>
        <div style={{ display: "flex", gap: 6 }}>
          <span className="pill accent" style={{ fontSize: 11 }}>MAP</span>
        </div>
      </div>

      {/* Map "canvas" — stylized topographic */}
      <div style={{
        position: "absolute", top: 112, left: 0, right: 0, bottom: 0,
        background: `
          radial-gradient(ellipse at 30% 60%, #15212e 0%, transparent 50%),
          radial-gradient(ellipse at 70% 30%, #1a2638 0%, transparent 55%),
          linear-gradient(180deg, #050810 0%, #0a141c 100%)
        `,
      }}>
        {/* faux coastline / lat-long grid */}
        <svg style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }}>
          {/* graticule */}
          {[...Array(8)].map((_, i) => (
            <line key={`v${i}`} x1={`${(i + 1) * 12.5}%`} y1="0%" x2={`${(i + 1) * 12.5}%`} y2="100%" stroke="rgba(0,212,255,0.05)" strokeDasharray="2 4"/>
          ))}
          {[...Array(8)].map((_, i) => (
            <line key={`h${i}`} x1="0%" y1={`${(i + 1) * 12.5}%`} x2="100%" y2={`${(i + 1) * 12.5}%`} stroke="rgba(0,212,255,0.05)" strokeDasharray="2 4"/>
          ))}

          {/* stylized coastline */}
          <path d="M 0 250 Q 60 240 120 260 T 240 270 Q 290 285 330 270 T 400 280"
            stroke="rgba(0,212,255,0.25)" strokeWidth="1.5" fill="none"/>
          <path d="M 60 380 Q 140 370 200 390 T 320 400"
            stroke="rgba(0,212,255,0.15)" strokeWidth="1" fill="none"/>

          {/* bay shape */}
          <path d="M 130 180 Q 160 220 140 280 Q 130 320 170 360 L 220 380 Q 250 360 240 320 Q 230 280 250 240 Q 230 200 200 180 Z"
            fill="rgba(0,212,255,0.05)" stroke="rgba(0,212,255,0.2)" strokeWidth="1"/>
        </svg>

        {/* Pins */}
        {pins.map((p, i) => {
          const r = RARITY[p.rarity];
          return (
            <div key={i} style={{
              position: "absolute", left: `${p.left}%`, top: `${p.top}%`,
              transform: "translate(-50%, -100%)",
            }}>
              <Pin color={r.color} legend={p.rarity}/>
            </div>
          );
        })}

        {/* User location dot */}
        <div style={{
          position: "absolute", left: "44%", top: "50%",
          transform: "translate(-50%,-50%)",
        }}>
          <div style={{
            width: 14, height: 14, borderRadius: 999,
            background: "var(--accent)",
            border: "2px solid var(--bg-primary)",
            boxShadow: "0 0 12px var(--accent), 0 0 0 8px rgba(0,212,255,0.15)",
          }}/>
        </div>

        {/* Scale + legend bottom */}
        <div style={{
          position: "absolute", bottom: 88, left: 14, right: 14,
          padding: "12px 14px",
          background: "rgba(10,14,26,0.85)",
          backdropFilter: "blur(10px)",
          border: "1px solid rgba(255,255,255,0.06)",
          borderRadius: 12,
          display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12,
        }}>
          <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
            <span className="t-label" style={{ fontSize: 9 }}>BERKELEY REGION</span>
            <span className="t-hud-callsign" style={{ fontSize: 13 }}>47 sightings</span>
            <span className="t-caption" style={{ fontSize: 10 }}>12 days · 31 unique</span>
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            <span className="t-label" style={{ fontSize: 9, textAlign: "right" }}>LEGEND</span>
            <div style={{ display: "flex", gap: 6 }}>
              {RARITY_ORDER.map(rid => (
                <div key={rid} style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 2 }}>
                  <div style={{ width: 8, height: 8, borderRadius: 999, background: RARITY[rid].color }}/>
                  <span style={{ fontFamily: "var(--font-mono)", fontSize: 8, color: "var(--text-tertiary)" }}>
                    {RARITY[rid].label[0]}
                  </span>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Filter chips at top */}
        <div style={{
          position: "absolute", top: 14, left: 14, right: 14,
          display: "flex", gap: 6, overflowX: "auto",
        }}>
          <Chip2 active>All · 47</Chip2>
          <Chip2>This week</Chip2>
          <Chip2>Rare+</Chip2>
          <Chip2>Heavies</Chip2>
        </div>
      </div>
    </div>
  );
}

function Chip2({ children, active = false }) {
  return (
    <span style={{
      flexShrink: 0,
      padding: "6px 12px",
      borderRadius: 999,
      background: active ? "var(--accent)" : "rgba(10,14,26,0.85)",
      color: active ? "#02131a" : "var(--text-secondary)",
      fontFamily: "var(--font-sans)",
      fontWeight: 600, fontSize: 12,
      border: active ? 0 : "1px solid rgba(255,255,255,0.08)",
      backdropFilter: active ? undefined : "blur(8px)",
    }}>{children}</span>
  );
}

function Pin({ color, legend }) {
  return (
    <div style={{
      width: 22, height: 28, position: "relative",
      filter: `drop-shadow(0 4px 8px rgba(0,0,0,0.6)) drop-shadow(0 0 4px ${color})`,
    }}>
      <svg viewBox="0 0 22 28">
        <path d="M11 1 C 17 1 21 5 21 11 C 21 17 11 27 11 27 C 11 27 1 17 1 11 C 1 5 5 1 11 1 Z"
          fill={color} stroke="rgba(0,0,0,0.4)" strokeWidth="1"/>
        <circle cx="11" cy="10" r="3.5" fill="rgba(0,0,0,0.4)"/>
      </svg>
    </div>
  );
}

Object.assign(window, { MultiCatchReveal, TrophyUnlock, SetDetail, MapView, HandleSetup, NotificationsScreen, RarePushTap, HangarEmpty });

// ─────────────────────────────────────────────────────────────
// Onboarding extras — spotter handle setup
// ─────────────────────────────────────────────────────────────
function HandleSetup() {
  return (
    <div style={{
      position: "absolute", inset: 0, background: "var(--bg-primary)",
      padding: "70px 24px 40px", display: "flex", flexDirection: "column",
    }}>
      <span className="t-label" style={{ color: "var(--accent)" }}>FINAL STEP · PUBLIC HANDLE</span>
      <h2 className="t-display" style={{ margin: "10px 0 6px", fontSize: 24, lineHeight: 1.2 }}>
        Pick a handle.
      </h2>
      <p className="t-caption" style={{ color: "var(--text-secondary)", lineHeight: 1.45, margin: 0, fontSize: 13 }}>
        Shown on the global leaderboard and your public hangar. Real name stays private.
      </p>

      {/* input */}
      <div style={{ marginTop: 26 }}>
        <div className="t-label" style={{ fontSize: 10, marginBottom: 6 }}>HANDLE</div>
        <div style={{
          padding: "14px 16px", borderRadius: 10,
          background: "var(--bg-elevated)",
          border: "1.5px solid var(--accent)",
          display: "flex", alignItems: "center", gap: 8,
        }}>
          <span style={{ fontFamily: "var(--font-mono)", fontSize: 18, color: "var(--text-tertiary)" }}>@</span>
          <span style={{ fontFamily: "var(--font-mono)", fontSize: 18, fontWeight: 600, color: "var(--text-primary)", flex: 1 }}>
            tailspotter_sf
          </span>
          <span style={{
            fontFamily: "var(--font-mono)", fontSize: 10, fontWeight: 700,
            color: "var(--alert-normal)", letterSpacing: 0.8,
          }}>● AVAILABLE</span>
        </div>
        <div className="t-caption" style={{ fontSize: 11, marginTop: 8 }}>
          Letters, numbers, underscores. 3–20 characters.
        </div>
      </div>

      {/* suggestions */}
      <div style={{ marginTop: 24 }}>
        <div className="t-label" style={{ fontSize: 10, marginBottom: 8 }}>SUGGESTIONS</div>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          {["berkeley_skywatch", "contrail_47", "approach_sfo", "hangar_bay_12"].map(s => (
            <span key={s} style={{
              padding: "7px 12px", borderRadius: 999,
              background: "var(--bg-elevated)",
              border: "1px solid rgba(255,255,255,0.06)",
              fontFamily: "var(--font-mono)", fontSize: 11,
              color: "var(--text-secondary)",
            }}>@{s}</span>
          ))}
        </div>
      </div>

      {/* privacy */}
      <div style={{ marginTop: 24, padding: 14, borderRadius: 10, background: "var(--bg-elevated)", border: "1px solid rgba(255,255,255,0.04)" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <div>
            <div className="t-card-title" style={{ fontSize: 13 }}>Public profile</div>
            <div className="t-caption" style={{ fontSize: 11, marginTop: 2 }}>Anyone can view your hangar</div>
          </div>
          <Toggle on/>
        </div>
      </div>

      <div style={{ flex: 1 }}/>
      <OnboardingFooter step={3} primary="Start spotting"/>
    </div>
  );
}

function Toggle({ on }) {
  return (
    <div style={{
      width: 50, height: 30, borderRadius: 999,
      background: on ? "var(--alert-normal)" : "rgba(255,255,255,0.12)",
      position: "relative",
    }}>
      <div style={{
        position: "absolute", top: 2,
        left: on ? 22 : 2,
        width: 26, height: 26, borderRadius: 999,
        background: "#fff",
      }}/>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Notifications — system settings page
// ─────────────────────────────────────────────────────────────
function NotificationsScreen() {
  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      <SimpleNav title="Notifications"/>

      <div style={{
        position: "absolute", top: 110, left: 0, right: 0, bottom: 0,
        padding: "4px 0 40px", overflowY: "auto",
        display: "flex", flexDirection: "column", gap: 22,
      }}>
        {/* Master */}
        <NotifGroup header="PUSH">
          <NotifRow title="Allow Tailspot notifications" caption="You'll never get more than 1–2 a day." toggle on/>
        </NotifGroup>

        <NotifGroup header="NEARBY AIRCRAFT">
          <NotifRow title="Rare or Epic aircraft"
            caption="When a Rare+ plane is within 15 km of you and approaching."
            toggle on/>
          <NotifRow title="Legendary aircraft"
            caption="Air Force One, NASA SOFIA, etc. Within 50 km."
            toggle on/>
          <NotifRow title="First-of-type for you"
            caption="Aircraft type you've never caught is in range."
            toggle/>
          <NotifRow title="Multi-catch opportunity"
            caption="Three or more visible aircraft overhead."
            toggle/>
        </NotifGroup>

        <NotifGroup header="PROGRESS">
          <NotifRow title="Trophy unlocks"  toggle on/>
          <NotifRow title="Set completion (one to go)" caption="Heads-up when you're at N−1/N on a set." toggle/>
          <NotifRow title="Weekly summary" caption="Sunday 8pm · your week in numbers." toggle on last/>
        </NotifGroup>

        <NotifGroup header="QUIET HOURS">
          <NotifRow title="Mute 10pm → 7am" toggle on/>
          <NotifRow title="Mute on weekends" toggle last/>
        </NotifGroup>
      </div>
    </div>
  );
}

function NotifGroup({ header, children }) {
  return (
    <div>
      <div className="t-label" style={{ padding: "0 20px 6px", fontSize: 10 }}>{header}</div>
      <div style={{ margin: "0 16px", background: "var(--bg-elevated)", borderRadius: 14, overflow: "hidden" }}>{children}</div>
    </div>
  );
}

function NotifRow({ title, caption, toggle, on = false, last = false }) {
  return (
    <div style={{
      padding: "12px 16px",
      borderBottom: last ? 0 : "0.5px solid rgba(255,255,255,0.05)",
      display: "flex", alignItems: "center", gap: 10,
    }}>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 3 }}>
        <span className="t-body" style={{ fontSize: 15 }}>{title}</span>
        {caption && <span className="t-caption" style={{ fontSize: 11, lineHeight: 1.4 }}>{caption}</span>}
      </div>
      {toggle && <Toggle on={on}/>}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Rare-push tap-in — lock-screen style notification
// ─────────────────────────────────────────────────────────────
function RarePushTap() {
  return (
    <div style={{ position: "absolute", inset: 0, background: "#000", overflow: "hidden" }}>
      {/* faux lock screen wallpaper */}
      <div style={{
        position: "absolute", inset: 0,
        background: "linear-gradient(160deg, #0a1d3a 0%, #1a2855 50%, #2a3868 100%)",
      }}/>
      <div style={{
        position: "absolute", inset: 0,
        background: "radial-gradient(circle at 30% 18%, rgba(255,255,255,0.08) 0%, transparent 35%), radial-gradient(circle at 80% 80%, rgba(255,107,230,0.08) 0%, transparent 40%)",
      }}/>

      {/* time */}
      <div style={{
        position: "absolute", top: 90, left: 0, right: 0,
        textAlign: "center",
      }}>
        <div style={{ fontFamily: "var(--font-sans)", fontWeight: 200, fontSize: 92, color: "#fff", letterSpacing: -2, lineHeight: 1 }}>5:24</div>
        <div style={{ fontFamily: "var(--font-sans)", fontWeight: 500, fontSize: 22, color: "rgba(255,255,255,0.85)", marginTop: 2 }}>Wednesday, May 20</div>
      </div>

      {/* notification */}
      <div style={{
        position: "absolute", top: 320, left: 14, right: 14,
      }}>
        <div style={{
          background: "rgba(255,255,255,0.18)",
          backdropFilter: "blur(40px) saturate(180%)",
          WebkitBackdropFilter: "blur(40px) saturate(180%)",
          borderRadius: 18,
          padding: "12px 14px",
          display: "flex", gap: 12,
          border: "1px solid rgba(255,255,255,0.1)",
          boxShadow: "0 20px 50px rgba(0,0,0,0.4)",
        }}>
          {/* App icon */}
          <div style={{
            width: 44, height: 44, borderRadius: 10,
            background: "var(--bg-primary)",
            display: "flex", alignItems: "center", justifyContent: "center",
            border: "1px solid rgba(255,107,230,0.6)",
            flex: "0 0 auto",
          }}>
            <BrandMark size={32}/>
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
              <span style={{ fontFamily: "var(--font-sans)", fontWeight: 600, fontSize: 14, color: "#fff" }}>TAILSPOT</span>
              <span style={{ fontFamily: "var(--font-sans)", fontSize: 11, color: "rgba(255,255,255,0.65)" }}>now</span>
            </div>
            <div style={{ marginTop: 3, fontFamily: "var(--font-sans)", fontWeight: 600, fontSize: 15, color: "#fff" }}>
              <span style={{ color: "#FF6BE6" }}>RARE</span> aircraft inbound — Airbus A380
            </div>
            <div style={{ marginTop: 2, fontFamily: "var(--font-sans)", fontSize: 14, color: "rgba(255,255,255,0.85)" }}>
              BAW286 · LHR ▸ SFO · 9 km west · visible in 2 min
            </div>
          </div>
        </div>
      </div>

      {/* call to action footer */}
      <div style={{
        position: "absolute", bottom: 80, left: 0, right: 0,
        textAlign: "center",
      }}>
        <span style={{
          fontFamily: "var(--font-mono)", fontSize: 13, fontWeight: 600,
          color: "rgba(255,255,255,0.7)",
        }}>☝ swipe up to open</span>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Hangar empty state — first-launch (1 catch, mostly empty slots)
// ─────────────────────────────────────────────────────────────
function HangarEmpty() {
  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      {/* Nav */}
      <div style={{
        position: "absolute", top: 56, left: 0, right: 0,
        padding: "0 16px", height: 56,
        display: "flex", alignItems: "center", justifyContent: "space-between",
        background: "rgba(10,14,26,0.95)", zIndex: 2,
        borderBottom: "1px solid rgba(255,255,255,0.04)",
      }}>
        <Lockup size="sm"/>
        <span className="pill accent" style={{ fontSize: 11 }}>1 catch</span>
      </div>

      <div style={{
        position: "absolute", top: 124, left: 0, right: 0, bottom: 0,
        padding: "16px 16px 40px", overflowY: "auto",
        display: "flex", flexDirection: "column", gap: 18,
      }}>
        {/* The one card */}
        <div>
          <div className="t-label" style={{ marginBottom: 10 }}>YOUR FIRST CATCH</div>
          <div style={{ display: "flex", justifyContent: "center" }}>
            <PokeCard plane={PLANE_LIBRARY.swa2331} owned size="md"/>
          </div>
        </div>

        {/* CTA — go outside */}
        <div style={{
          padding: 16, borderRadius: 14,
          background: "linear-gradient(135deg, rgba(0,212,255,0.12) 0%, rgba(255,107,230,0.08) 100%)",
          border: "1px solid rgba(0,212,255,0.3)",
          textAlign: "center",
        }}>
          <div style={{ fontSize: 32, marginBottom: 6 }}>🔍</div>
          <h3 className="t-display" style={{ fontSize: 18, margin: 0 }}>Go outside.</h3>
          <p className="t-caption" style={{ fontSize: 12, marginTop: 6, lineHeight: 1.45, color: "var(--text-secondary)" }}>
            Tailspot needs a clear view of the sky. There are <b style={{ color: "var(--text-primary)" }}>3 planes</b> overhead right now.
          </p>
          <button style={{
            marginTop: 12, width: "100%", height: 46, border: 0, cursor: "pointer",
            background: "var(--accent)", color: "#02131a",
            fontFamily: "var(--font-sans)", fontWeight: 700, fontSize: 15,
            borderRadius: 10,
          }}>Open AR view</button>
        </div>

        {/* Type set previews */}
        <div>
          <div className="t-label" style={{ marginBottom: 10 }}>SETS TO COLLECT</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            <EmptySetRow type="narrow" of={24} sub="Most common at major airports"/>
            <EmptySetRow type="wide" of={14} sub="Long-haul heavies" got={1}/>
            <EmptySetRow type="regional" of={18} sub="Short-haul jets"/>
            <EmptySetRow type="heritage" of={10} sub="Vintage & special-mission"/>
          </div>
        </div>
      </div>
    </div>
  );
}

function EmptySetRow({ type, of, sub, got = 0 }) {
  const t = TYPES[type];
  return (
    <div style={{
      padding: "12px 14px",
      background: "var(--bg-elevated)",
      borderRadius: 10,
      borderLeft: `3px solid ${t.color}`,
      display: "flex", alignItems: "center", gap: 12,
    }}>
      <div style={{
        width: 30, height: 30, borderRadius: 999,
        background: t.color, color: "rgba(0,0,0,0.7)",
        fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 13,
        display: "flex", alignItems: "center", justifyContent: "center",
      }}>{t.glyph}</div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <span className="t-card-title" style={{ fontSize: 13 }}>{t.label}</span>
        <div className="t-caption" style={{ fontSize: 11, marginTop: 2 }}>{sub}</div>
      </div>
      <span style={{ fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 13, color: t.color }}>
        {got}<span style={{ color: "var(--text-tertiary)" }}>/{of}</span>
      </span>
    </div>
  );
}
