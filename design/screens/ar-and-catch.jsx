// AR Home (camera + lock-on) and Catch flow screens.
// 2 home variations: A = clinical HUD (per spec), B = full pilot instruments.

// Sample aircraft data the AR overlays draw against.
// `kind` = TYPES key, `rarity` = RARITY key.
const SAMPLE_PLANES = [
  { id: "a", callsign: "UAL248",  carrier: "United Airlines",     type: "Boeing 787-9",    alt: "FL370", speed: "478kt", dist: "12km", x: 48, y: 38, size: 14, kind: "wide",   rarity: "rare" },
  { id: "b", callsign: "DAL2104", carrier: "Delta Air Lines",     type: "Airbus A320",     alt: "FL280", speed: "412kt", dist: "8km",  x: 22, y: 52, size: 11, kind: "narrow", rarity: "common" },
  { id: "c", callsign: "SWA2331", carrier: "Southwest",           type: "Boeing 737-800",  alt: "FL340", speed: "455kt", dist: "18km", x: 76, y: 60, size: 9,  kind: "narrow", rarity: "common" },
];

// ─────────────────────────────────────────────────────────────
// AR Home — Variation A · Clinical HUD (matches §5 lock label spec)
// ─────────────────────────────────────────────────────────────
function ARHomeA({ pinned = "a", copy }) {
  const main = SAMPLE_PLANES.find(p => p.id === pinned) ?? SAMPLE_PLANES[0];
  const others = SAMPLE_PLANES.filter(p => p.id !== pinned);

  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", background: "#000" }}>
      {/* live camera */}
      <SkyBackground time="day" />
      {/* distant silhouettes */}
      {SAMPLE_PLANES.map(p => (
        <PlaneDot key={p.id} left={`${p.x}%`} top={`${p.y}%`}
          size={p.size} color={p.id === pinned ? "rgba(20,30,40,0.8)" : "rgba(20,30,40,0.55)"}/>
      ))}

      {/* Top HUD strip — compass + dyn island gap */}
      <TopHUD heading="287°" headingAccuracy={3} mock={false}/>

      {/* Side HUD readouts */}
      <SideHUD/>

      {/* Pinned (main) lock label */}
      <LockOverlay plane={main} state="pinned"/>

      {/* Other planes — passive labels */}
      {others.map(p => (
        <PassiveLabel key={p.id} plane={p}/>
      ))}

      {/* Hangar + center capture controls */}
      <BottomControls catches={47} rare={3} primary="catch"/>

      {/* Pinned status caption */}
      <div style={{
        position: "absolute", left: 0, right: 0, bottom: 156,
        display: "flex", justifyContent: "center",
      }}>
        <span className="pill advisory" style={{ fontSize: 10 }}>
          ◉ TAPPED · PINNED TO {main.callsign}
        </span>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// AR Home — Variation B · Full Pilot Instruments
// More aviation-y: horizon line, pitch ladder, compass tape on top
// ─────────────────────────────────────────────────────────────
function ARHomeB() {
  const main = SAMPLE_PLANES[0];
  const others = SAMPLE_PLANES.slice(1);
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", background: "#000" }}>
      <SkyBackground time="day" />
      {SAMPLE_PLANES.map(p => (
        <PlaneDot key={p.id} left={`${p.x}%`} top={`${p.y}%`}
          size={p.size} color="rgba(20,30,40,0.6)"/>
      ))}

      {/* Compass tape across the top */}
      <CompassTape heading={287}/>

      {/* Pitch ladder */}
      <PitchLadder pitch={12}/>

      {/* Center reticle (no lock yet — acquiring) */}
      <div style={{
        position: "absolute", top: "50%", left: "50%",
        transform: "translate(-50%, -50%)",
      }}>
        <Reticle size={64} state="acquiring" thickness={2}/>
      </div>

      {/* Locked plane label, offset */}
      <div style={{ position: "absolute", left: `${main.x}%`, top: `${main.y}%`, transform: "translate(-50%,-50%)" }}>
        <div style={{ position: "relative", width: 36, height: 36 }}>
          <Reticle size={36} state="locked" thickness={2}/>
        </div>
        <div className="hud-panel locked" style={{ marginTop: 8, padding: "8px 10px", minWidth: 130 }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 4 }}>
            <span className="t-hud-callsign" style={{ color: "var(--alert-normal)" }}>{main.callsign}</span>
            <span className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>LOCK</span>
          </div>
          <div className="t-hud-data">{main.carrier}</div>
          <div className="t-hud-data">{main.type}</div>
          <div className="t-hud-data" style={{ color: "var(--text-secondary)", marginTop: 4 }}>
            {main.alt} · {main.speed} · {main.dist}
          </div>
        </div>
      </div>

      {others.map(p => <PassiveLabel key={p.id} plane={p}/>)}

      {/* Bottom: airspeed-style tape + altitude tape framing the catch button */}
      <BottomTapeControls/>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Sub-components
// ─────────────────────────────────────────────────────────────
function TopHUD({ heading, headingAccuracy, mock }) {
  return (
    <div style={{
      position: "absolute", left: 0, right: 0, top: 56,
      padding: "0 18px",
      display: "flex", justifyContent: "space-between", alignItems: "center",
      pointerEvents: "none",
    }}>
      <div className="hud-panel" style={{ padding: "6px 10px", display: "flex", gap: 10, alignItems: "center" }}>
        <span className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>HDG</span>
        <span className="t-hud-callsign" style={{ fontSize: 12 }}>{heading}</span>
        <span className="t-hud-data" style={{ color: headingAccuracy > 15 ? "var(--alert-caution)" : "var(--alert-normal)" }}>±{headingAccuracy}°</span>
      </div>
      <div className="hud-panel" style={{ padding: "6px 10px", display: "flex", gap: 8, alignItems: "center" }}>
        <span className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>ADS-B</span>
        <span className="t-hud-callsign" style={{ fontSize: 12, color: mock ? "var(--alert-caution)" : "var(--alert-normal)" }}>
          {mock ? "[MOCK]" : "LIVE"}
        </span>
      </div>
    </div>
  );
}

function SideHUD() {
  return (
    <div style={{
      position: "absolute", right: 14, top: 110,
      display: "flex", flexDirection: "column", gap: 8,
    }}>
      <div className="hud-panel" style={{ padding: "8px 10px", display: "flex", flexDirection: "column", gap: 2 }}>
        <span className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>ELEV</span>
        <span className="t-hud-callsign" style={{ fontSize: 12 }}>+22°</span>
      </div>
      <div className="hud-panel" style={{ padding: "8px 10px", display: "flex", flexDirection: "column", gap: 2 }}>
        <span className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>FOV</span>
        <span className="t-hud-callsign" style={{ fontSize: 12 }}>1.0×</span>
      </div>
      <div className="hud-panel" style={{ padding: "8px 10px", display: "flex", flexDirection: "column", gap: 2 }}>
        <span className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>VISIBLE</span>
        <span className="t-hud-callsign" style={{ fontSize: 12 }}>3</span>
      </div>
    </div>
  );
}

function LockOverlay({ plane, state = "pinned" }) {
  // plane is from SAMPLE_PLANES (legacy). Map rarity if available.
  const rarityId = plane.rarity ?? (plane.rare ? "rare" : "uncommon");
  const typeId = plane.kind ?? "wide";
  return (
    <div style={{
      position: "absolute", left: `${plane.x}%`, top: `${plane.y}%`,
      transform: "translate(-50%,-50%)",
    }}>
      <div style={{ position: "relative", width: 70, height: 70 }}>
        <Reticle size={70} state={state}/>
      </div>
      <div className={`hud-panel ${state}`} style={{
        marginTop: 10, padding: "8px 10px",
        minWidth: 180, position: "relative",
      }}>
        <div style={{
          position: "absolute", left: "50%", top: -6, transform: "translateX(-50%) rotate(45deg)",
          width: 8, height: 8, background: "rgba(10,14,26,0.88)",
          borderLeft: "1px solid",
          borderTop: "1px solid",
          borderColor: state === "pinned" ? "var(--alert-advisory)" : state === "locked" ? "var(--alert-normal)" : "rgba(255,255,255,0.08)",
        }}/>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", marginBottom: 5 }}>
          <span className="t-hud-callsign" style={{ color: state === "pinned" ? "var(--alert-advisory)" : "var(--accent)" }}>
            {plane.callsign}
          </span>
          <RarityBadge rarity={rarityId} size="sm"/>
        </div>
        <div className="t-hud-data">{plane.carrier}</div>
        <div className="t-hud-data">{plane.type}</div>
        <div className="t-hud-data" style={{ color: "var(--text-secondary)", marginTop: 4 }}>
          {plane.alt} · {plane.speed} · {plane.dist}
        </div>
        <div style={{ marginTop: 6 }}>
          <TypeBadge type={typeId} size="sm"/>
        </div>
      </div>
    </div>
  );
}

function PassiveLabel({ plane }) {
  return (
    <div style={{
      position: "absolute", left: `${plane.x}%`, top: `${plane.y}%`,
      transform: "translate(-50%,-50%)",
    }}>
      <div style={{ position: "relative", width: 30, height: 30 }}>
        <Reticle size={30} state="default" thickness={1.5}/>
      </div>
      <div className="hud-panel" style={{
        marginTop: 6, padding: "3px 7px", whiteSpace: "nowrap",
        opacity: 0.85,
      }}>
        <span className="t-hud-callsign" style={{ fontSize: 10 }}>{plane.callsign}</span>
      </div>
    </div>
  );
}

function BottomControls({ catches = 47, rare = 3, primary = "catch" }) {
  return (
    <div style={{
      position: "absolute", left: 0, right: 0, bottom: 50,
      display: "flex", alignItems: "center", justifyContent: "space-between",
      padding: "0 30px",
    }}>
      {/* Hangar tray */}
      <button style={{
        width: 56, height: 56, borderRadius: 14, border: 0, cursor: "pointer",
        background: "rgba(10,14,26,0.7)",
        backdropFilter: "blur(8px)",
        border: "1px solid rgba(255,255,255,0.08)",
        position: "relative",
        display: "flex", alignItems: "center", justifyContent: "center",
        color: "var(--text-primary)",
      }}>
        <Icon.hangar size={26} color="var(--text-primary)"/>
        <span style={{
          position: "absolute", top: -4, right: -4,
          background: "var(--alert-normal)",
          color: "#02131a",
          fontSize: 10, fontWeight: 700,
          padding: "2px 6px", borderRadius: 999,
          fontFamily: "var(--font-mono)",
        }}>{catches}</span>
      </button>

      {/* Catch button — big, central, primary */}
      <button style={{
        width: 76, height: 76, borderRadius: 999, border: 0, cursor: "pointer",
        background: "var(--accent)",
        boxShadow: "0 12px 40px rgba(0,212,255,0.4), inset 0 0 0 4px #02131a, inset 0 0 0 5px var(--accent)",
        display: "flex", alignItems: "center", justifyContent: "center",
      }}>
        <Icon.bracketReticle size={32} color="#02131a"/>
      </button>

      {/* Profile / record */}
      <button style={{
        width: 56, height: 56, borderRadius: 14, border: 0, cursor: "pointer",
        background: "rgba(10,14,26,0.7)",
        backdropFilter: "blur(8px)",
        border: "1px solid rgba(255,255,255,0.08)",
        display: "flex", alignItems: "center", justifyContent: "center",
        color: "var(--text-primary)",
      }}>
        <Icon.person size={26} color="var(--text-primary)"/>
      </button>
    </div>
  );
}

function CompassTape({ heading = 287 }) {
  // Render a strip of cardinal/sub-cardinal degrees centered on `heading`
  const marks = [];
  for (let i = -50; i <= 50; i += 10) {
    const v = (heading + i + 360) % 360;
    marks.push({ v, offset: i });
  }
  const cardinal = (v) => {
    const m = { 0: "N", 90: "E", 180: "S", 270: "W", 45: "NE", 135: "SE", 225: "SW", 315: "NW" };
    return m[v] || null;
  };
  return (
    <div style={{
      position: "absolute", top: 56, left: 0, right: 0, height: 36,
      overflow: "hidden",
      background: "linear-gradient(180deg, rgba(10,14,26,0.7) 0%, rgba(10,14,26,0) 100%)",
    }}>
      <div style={{ position: "relative", width: "100%", height: "100%" }}>
        {marks.map(m => {
          const card = cardinal(Math.round(m.v / 10) * 10);
          return (
            <div key={m.offset} style={{
              position: "absolute", left: `${50 + m.offset * 1.6}%`,
              top: 0, transform: "translateX(-50%)",
              display: "flex", flexDirection: "column", alignItems: "center", gap: 2,
            }}>
              <div style={{ width: 1, height: card ? 12 : 8, background: "var(--accent)", opacity: 0.7 }} />
              <span className="t-hud-data" style={{ fontSize: card ? 11 : 9, color: card ? "var(--accent)" : "var(--text-tertiary)" }}>
                {card ?? m.v}
              </span>
            </div>
          );
        })}
        {/* center indicator */}
        <div style={{
          position: "absolute", left: "50%", top: -2, transform: "translateX(-50%)",
          width: 0, height: 0,
          borderLeft: "6px solid transparent", borderRight: "6px solid transparent",
          borderTop: "8px solid var(--accent)",
        }} />
      </div>
    </div>
  );
}

function PitchLadder({ pitch = 0 }) {
  return (
    <div style={{
      position: "absolute", left: 18, top: "30%", bottom: "30%",
      display: "flex", flexDirection: "column", justifyContent: "space-between",
      pointerEvents: "none",
    }}>
      {[20, 10, 0, -10, -20].map(v => (
        <div key={v} style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <span className="t-hud-data" style={{ color: "var(--accent)" }}>{v > 0 ? `+${v}` : v}°</span>
          <div style={{
            height: 1, width: v === 0 ? 30 : 16,
            background: "var(--accent)", opacity: v === 0 ? 0.9 : 0.4,
          }} />
        </div>
      ))}
    </div>
  );
}

function BottomTapeControls() {
  return (
    <div style={{
      position: "absolute", left: 0, right: 0, bottom: 50,
      display: "flex", alignItems: "center", justifyContent: "space-between",
      padding: "0 18px",
    }}>
      <div className="hud-panel" style={{ padding: "10px 8px", width: 64, textAlign: "center" }}>
        <div className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>SPD</div>
        <div className="t-hud-callsign" style={{ fontSize: 14 }}>478</div>
        <div className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>kt</div>
      </div>
      <button style={{
        width: 76, height: 76, borderRadius: 999, border: "3px solid var(--accent)", cursor: "pointer",
        background: "rgba(0,212,255,0.18)",
        backdropFilter: "blur(6px)",
        display: "flex", alignItems: "center", justifyContent: "center",
        color: "var(--accent)",
        fontFamily: "var(--font-mono)",
        fontWeight: 700, fontSize: 11, letterSpacing: 1.2,
        textTransform: "uppercase",
      }}>CATCH</button>
      <div className="hud-panel" style={{ padding: "10px 8px", width: 64, textAlign: "center" }}>
        <div className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>ALT</div>
        <div className="t-hud-callsign" style={{ fontSize: 14 }}>370</div>
        <div className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>FL</div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Catch Flow — simplified
// 1. Confirm sheet (review the plane you're about to catch)
// 2. Caught — Pokémon "Gotcha!" moment
// ─────────────────────────────────────────────────────────────
function CatchReview() {
  const main = SAMPLE_PLANES[0];
  const r = RARITY[main.rarity];
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", background: "#000" }}>
      <SkyBackground time="day" />
      <div style={{ position: "absolute", inset: 0, background: "rgba(5,8,16,0.7)" }} />

      <div style={{
        position: "absolute", left: 0, right: 0, bottom: 0,
        background: "var(--bg-primary)",
        borderTopLeftRadius: 22, borderTopRightRadius: 22,
        padding: "12px 20px 36px",
        boxShadow: "0 -20px 60px rgba(0,0,0,0.6)",
        border: "1px solid rgba(255,255,255,0.06)",
      }}>
        <div style={{ width: 36, height: 4, borderRadius: 2, background: "rgba(255,255,255,0.2)", margin: "0 auto 18px" }}/>

        {/* tags first */}
        <div style={{ display: "flex", gap: 6, marginBottom: 10 }}>
          <RarityBadge rarity={main.rarity}/>
          <TypeBadge type={main.kind}/>
        </div>

        <span className="t-hud-callsign" style={{ fontSize: 14 }}>{main.callsign}</span>
        <h2 className="t-display" style={{ fontSize: 24, margin: "4px 0 4px" }}>{main.type}</h2>
        <div className="t-card-subtitle" style={{ marginBottom: 14 }}>{main.carrier} · SFO ▸ EWR</div>

        <PhotoPlaceholder height={130} label="LIVERY · UNITED 787" radius={10}/>

        {/* Single big point reward, no stats grid clutter */}
        <div style={{
          marginTop: 16, padding: "14px 16px",
          background: r.bg,
          border: `1px solid ${r.color}`,
          borderRadius: 10,
          display: "flex", justifyContent: "space-between", alignItems: "center",
        }}>
          <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
            <span className="t-label" style={{ fontSize: 10, color: r.color }}>YOU'LL EARN</span>
            <span style={{ fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 22, color: r.color }}>+150 pts</span>
          </div>
          <span className="t-caption" style={{ fontSize: 10, textAlign: "right", color: "var(--text-secondary)" }}>
            base {r.base}<br/>+50% first 787
          </span>
        </div>

        <button style={{
          marginTop: 16, width: "100%", height: 52, border: 0, cursor: "pointer",
          background: "var(--accent)", color: "#02131a",
          fontFamily: "var(--font-sans)", fontWeight: 700, fontSize: 16,
          borderRadius: 12, letterSpacing: 0.2,
          boxShadow: "0 12px 30px rgba(0,212,255,0.35)",
        }}>
          Catch this plane
        </button>
        <button style={{
          marginTop: 6, width: "100%", height: 40, border: 0, cursor: "pointer",
          background: "transparent", color: "var(--text-secondary)",
          fontFamily: "var(--font-sans)", fontWeight: 500, fontSize: 14,
        }}>Cancel</button>
      </div>
    </div>
  );
}

function Stat({ label, value, hint }) {
  return (
    <div className="hud-panel" style={{ padding: "10px 12px" }}>
      <div className="t-label" style={{ fontSize: 9 }}>{label}</div>
      <div className="t-hud-callsign" style={{ fontSize: 15, marginTop: 2 }}>{value}</div>
      {hint && <div className="t-caption" style={{ fontSize: 10 }}>{hint}</div>}
    </div>
  );
}

// Card-reveal moment. The card IS the message. No "Gotcha!" theatrics.
function CatchConfirmed() {
  const p = PLANE_LIBRARY.ual248;
  const r = RARITY[p.rarity];
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", background: "var(--bg-primary)" }}>
      {/* light rays radiating from card center, tinted by rarity */}
      <div style={{
        position: "absolute", inset: 0,
        background: `
          radial-gradient(ellipse at 50% 48%, ${r.color}33 0%, transparent 50%),
          conic-gradient(from 0deg at 50% 48%,
            transparent 0deg, ${r.color}11 8deg, transparent 16deg,
            transparent 22deg, ${r.color}11 30deg, transparent 38deg,
            transparent 60deg, ${r.color}11 68deg, transparent 76deg,
            transparent 100deg, ${r.color}11 108deg, transparent 116deg,
            transparent 140deg, ${r.color}11 148deg, transparent 156deg,
            transparent 200deg, ${r.color}11 208deg, transparent 216deg,
            transparent 240deg, ${r.color}11 248deg, transparent 256deg,
            transparent 280deg, ${r.color}11 288deg, transparent 296deg,
            transparent 320deg, ${r.color}11 328deg, transparent 336deg)
        `,
      }}/>

      {/* top status pill */}
      <div style={{
        position: "absolute", top: 76, left: 0, right: 0,
        display: "flex", justifyContent: "center",
      }}>
        <div style={{
          padding: "6px 14px", borderRadius: 999,
          background: "rgba(10,14,26,0.7)",
          backdropFilter: "blur(10px)",
          border: `1px solid ${r.color}`,
          display: "flex", alignItems: "center", gap: 8,
        }}>
          <span style={{
            width: 8, height: 8, borderRadius: 999,
            background: "var(--alert-normal)",
            boxShadow: "0 0 8px var(--alert-normal)",
          }}/>
          <span style={{
            fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 11,
            letterSpacing: 2, color: "var(--text-primary)",
          }}>NEW CARD · ENTRY #048</span>
        </div>
      </div>

      {/* The card */}
      <div style={{
        position: "absolute", top: "50%", left: "50%",
        transform: "translate(-50%,-50%)",
      }}>
        <PokeCard plane={p} owned size="lg"/>
      </div>

      {/* Flip indicator (the card can be tapped) */}
      <div style={{
        position: "absolute", bottom: 158, left: 0, right: 0,
        display: "flex", justifyContent: "center",
      }}>
        <span style={{
          fontFamily: "var(--font-mono)", fontSize: 10, color: "var(--text-tertiary)",
          letterSpacing: 1, opacity: 0.7,
        }}>tap card to flip</span>
      </div>

      {/* Actions — minimal */}
      <div style={{
        position: "absolute", bottom: 56, left: 20, right: 20,
        display: "flex", gap: 10,
      }}>
        <button style={{
          flex: 1, height: 50, border: "1px solid rgba(255,255,255,0.1)", cursor: "pointer",
          background: "transparent", color: "var(--text-secondary)",
          fontFamily: "var(--font-sans)", fontWeight: 500, fontSize: 15,
          borderRadius: 12,
        }}>Hangar</button>
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

// Card-back / Pokédex-entry moment (what you see after the flip)
function CatchCardBack() {
  const p = PLANE_LIBRARY.baw286; // show an Epic for the back view
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", background: "var(--bg-primary)" }}>
      <div style={{
        position: "absolute", inset: 0,
        background: "radial-gradient(ellipse at 50% 48%, rgba(155,93,229,0.18) 0%, transparent 55%)",
      }}/>

      <div style={{
        position: "absolute", top: 76, left: 0, right: 0,
        display: "flex", justifyContent: "center",
      }}>
        <div style={{
          padding: "6px 14px", borderRadius: 999,
          background: "rgba(10,14,26,0.7)",
          backdropFilter: "blur(10px)",
          border: "1px solid rgba(155,93,229,0.6)",
          fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 11,
          letterSpacing: 2, color: "var(--text-primary)",
        }}>POKÉDEX · ENTRY #048</div>
      </div>

      <div style={{
        position: "absolute", top: "50%", left: "50%",
        transform: "translate(-50%,-50%)",
      }}>
        <PokeCardBack plane={p} num={48} total={142}/>
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
        }}>Hangar</button>
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

Object.assign(window, { ARHomeA, ARHomeB, CatchReview, CatchConfirmed, CatchCardBack, Stat, SAMPLE_PLANES });
