// AR Home — states. Iteration 2:
// - Simpler empty/scanning screen (text-led, no radar dazzle)
// - Multi-catch replaces disambiguation: catching multiple planes in one frame is REWARDED
// - Compass-bad caution stays
// - Just-caught stays
// - Rare-alert + dusk removed per Noah

// ─────────────────────────────────────────────────────────────
// AR-S1 · Empty sky — minimal, status-line led
// ─────────────────────────────────────────────────────────────
function ARStateEmpty() {
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", background: "#000" }}>
      <SkyBackground time="day"/>
      <TopHUD heading="287°" headingAccuracy={3} mock={false}/>

      {/* Just a small reticle + status — no radar, no clutter */}
      <div style={{
        position: "absolute", top: "50%", left: "50%",
        transform: "translate(-50%,-50%)",
        display: "flex", flexDirection: "column", alignItems: "center", gap: 16,
      }}>
        <Reticle size={48} state="acquiring" thickness={1.5}/>
        <div className="hud-panel" style={{ padding: "10px 14px", textAlign: "center", minWidth: 160 }}>
          <div className="t-hud-data" style={{ color: "var(--text-primary)" }}>No aircraft in range</div>
          <div className="t-caption" style={{ fontSize: 10, marginTop: 4 }}>Searching · 50 km</div>
        </div>
      </div>

      <BottomControls catches={47}/>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// AR-S2 · Multi-catch — multiple planes framed at once
// Tap shutter once → catch ALL the planes inside the bracket frame.
// Combo bonus scales with how many.
// ─────────────────────────────────────────────────────────────
function ARStateMultiCatch() {
  const planes = [
    { ...PLANE_LIBRARY.ual248,  x: 40, y: 34 },
    { ...PLANE_LIBRARY.dal2104, x: 55, y: 42 },
    { ...PLANE_LIBRARY.swa2331, x: 48, y: 52 },
  ];
  const total = planes.reduce((a, p) => a + RARITY[p.rarity].base, 0);
  const combo = 1.5; // 3-in-frame
  const grand = Math.round(total * combo);

  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", background: "#000" }}>
      <SkyBackground time="day"/>
      {planes.map(p => <PlaneDot key={p.call} left={`${p.x}%`} top={`${p.y}%`} size={12}/>)}

      <TopHUD heading="287°" headingAccuracy={3} mock={false}/>

      {/* Big magenta capture frame around all planes */}
      <div style={{
        position: "absolute", top: "28%", left: "30%", right: "20%", bottom: "44%",
        pointerEvents: "none",
      }}>
        <div style={{ position: "relative", width: "100%", height: "100%" }}>
          <Reticle size={Math.max(160, 200)} state="pinned" thickness={2.5}/>
          {/* "expand" hint */}
          <div style={{
            position: "absolute", inset: 0,
            border: "1px dashed rgba(255,107,230,0.4)",
            borderRadius: 4,
          }}/>
        </div>
      </div>

      {/* Per-plane mini-tags inside the frame */}
      {planes.map(p => (
        <div key={p.call} style={{
          position: "absolute", left: `${p.x}%`, top: `${p.y}%`,
          transform: "translate(-50%,-50%)",
        }}>
          <div style={{ position: "relative", width: 22, height: 22 }}>
            <Reticle size={22} state="pinned" thickness={1.5}/>
          </div>
          <div className="hud-panel pinned" style={{
            marginTop: 4, padding: "2px 6px", whiteSpace: "nowrap",
            borderColor: "var(--alert-advisory)",
          }}>
            <span className="t-hud-callsign" style={{ fontSize: 9, color: "var(--alert-advisory)" }}>{p.call}</span>
          </div>
        </div>
      ))}

      {/* Banner: 3 planes locked + combo bonus */}
      <div style={{
        position: "absolute", left: 14, right: 14, bottom: 138,
        background: "linear-gradient(135deg, rgba(255,107,230,0.95) 0%, rgba(155,93,229,0.95) 100%)",
        borderRadius: 12,
        padding: "12px 14px",
        display: "flex", alignItems: "center", gap: 12,
        boxShadow: "0 12px 30px rgba(255,107,230,0.4)",
      }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 4 }}>
          <span style={{ fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 26, color: "#fff" }}>3</span>
          <span className="t-hud-data" style={{ color: "rgba(255,255,255,0.8)" }}>×</span>
        </div>
        <div style={{ flex: 1, color: "#fff" }}>
          <div style={{ fontFamily: "var(--font-sans)", fontWeight: 600, fontSize: 13 }}>Multi-catch frame</div>
          <div style={{ fontFamily: "var(--font-mono)", fontSize: 11, marginTop: 2, color: "rgba(255,255,255,0.85)" }}>
            base {total} × combo 1.5 = <b>+{grand} pts</b>
          </div>
        </div>
      </div>

      <BottomControlsMulti count={3}/>
    </div>
  );
}

function BottomControlsMulti({ count }) {
  return (
    <div style={{
      position: "absolute", left: 0, right: 0, bottom: 50,
      display: "flex", alignItems: "center", justifyContent: "space-between",
      padding: "0 30px",
    }}>
      <button style={{
        width: 56, height: 56, borderRadius: 14, border: 0, cursor: "pointer",
        background: "rgba(10,14,26,0.7)",
        backdropFilter: "blur(8px)",
        border: "1px solid rgba(255,255,255,0.08)",
        display: "flex", alignItems: "center", justifyContent: "center",
      }}>
        <Icon.hangar size={26} color="var(--text-primary)"/>
      </button>

      {/* Big magenta multi-catch button */}
      <button style={{
        width: 84, height: 84, borderRadius: 999, border: 0, cursor: "pointer",
        background: "var(--alert-advisory)",
        boxShadow: "0 14px 40px rgba(255,107,230,0.5), inset 0 0 0 4px #02131a, inset 0 0 0 5px var(--alert-advisory)",
        display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center",
        color: "#02131a",
        position: "relative",
      }}>
        <span style={{ fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 22 }}>{count}×</span>
        <span style={{ fontFamily: "var(--font-mono)", fontSize: 9, fontWeight: 700, letterSpacing: 1 }}>CATCH</span>
      </button>

      <button style={{
        width: 56, height: 56, borderRadius: 14, border: 0, cursor: "pointer",
        background: "rgba(10,14,26,0.7)",
        backdropFilter: "blur(8px)",
        border: "1px solid rgba(255,255,255,0.08)",
        display: "flex", alignItems: "center", justifyContent: "center",
      }}>
        <Icon.person size={26} color="var(--text-primary)"/>
      </button>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// AR-S3 · Compass caution — unchanged from v1
// ─────────────────────────────────────────────────────────────
function ARStateCompassBad() {
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", background: "#000" }}>
      <SkyBackground time="day"/>
      <PlaneDot left="44%" top="36%" size={14} color="rgba(20,30,40,0.55)"/>
      <PlaneDot left="52%" top="42%" size={11} color="rgba(20,30,40,0.45)"/>

      <div style={{
        position: "absolute", left: 0, right: 0, top: 56,
        padding: "0 18px",
        display: "flex", justifyContent: "space-between", alignItems: "center",
      }}>
        <div className="hud-panel" style={{ padding: "6px 10px", display: "flex", gap: 10, alignItems: "center", borderColor: "var(--alert-caution)" }}>
          <span className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>HDG</span>
          <span className="t-hud-callsign" style={{ fontSize: 12 }}>287°</span>
          <span className="t-hud-data" style={{ color: "var(--alert-caution)", fontWeight: 700 }}>±22°</span>
        </div>
        <div className="hud-panel" style={{ padding: "6px 10px", display: "flex", gap: 8, alignItems: "center" }}>
          <span className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>ADS-B</span>
          <span className="t-hud-callsign" style={{ fontSize: 12, color: "var(--alert-normal)" }}>LIVE</span>
        </div>
      </div>

      <div style={{
        position: "absolute", top: 120, left: 12, right: 12,
        background: "rgba(10,14,26,0.95)",
        border: "1px solid var(--alert-caution)",
        borderRadius: 8, padding: "12px 14px",
        display: "flex", alignItems: "center", gap: 12,
      }}>
        <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
          <path d="M12 3l10 17H2L12 3z" stroke="var(--alert-caution)" strokeWidth="2" strokeLinejoin="round"/>
          <path d="M12 10v5" stroke="var(--alert-caution)" strokeWidth="2" strokeLinecap="round"/>
          <circle cx="12" cy="17.5" r="1" fill="var(--alert-caution)"/>
        </svg>
        <div style={{ flex: 1 }}>
          <span className="t-card-title" style={{ fontSize: 13, color: "var(--alert-caution)" }}>Compass needs calibration</span>
          <div className="t-caption" style={{ fontSize: 11, marginTop: 2 }}>Step away from cars, then trace a figure-8.</div>
        </div>
        <button style={{
          background: "var(--alert-caution)", color: "#1a1100",
          border: 0, borderRadius: 6, padding: "6px 10px",
          fontFamily: "var(--font-sans)", fontWeight: 600, fontSize: 11,
        }}>FIX</button>
      </div>

      <div style={{
        position: "absolute", left: "44%", top: "36%", transform: "translate(-50%,-50%)", opacity: 0.4,
      }}>
        <Reticle size={28} state="default" thickness={1.5}/>
        <div className="hud-panel" style={{ marginTop: 4, padding: "2px 6px" }}>
          <span className="t-hud-callsign" style={{ fontSize: 10 }}>?</span>
        </div>
      </div>

      <BottomControls catches={47}/>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// AR-S4 · Just-caught — green flash + points popup
// ─────────────────────────────────────────────────────────────
function ARStateJustCaught() {
  const p = { ...PLANE_LIBRARY.ual248, x: 48, y: 38 };
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", background: "#000" }}>
      <SkyBackground time="day"/>
      <PlaneDot left={`${p.x}%`} top={`${p.y}%`} size={14}/>

      <div style={{
        position: "absolute", inset: 0,
        background: "radial-gradient(circle at 48% 38%, rgba(61,214,140,0.5) 0%, transparent 35%)",
        animation: "caughtFlash 1.4s ease-out",
      }}/>
      <style>{`@keyframes caughtFlash{0%{opacity:0}30%{opacity:1}100%{opacity:0.4}}`}</style>

      <TopHUD heading="287°" headingAccuracy={3} mock={false}/>

      <div style={{ position: "absolute", left: `${p.x}%`, top: `${p.y}%`, transform: "translate(-50%,-50%)" }}>
        <Reticle size={90} state="locked" thickness={3}/>
      </div>

      <div style={{
        position: "absolute", left: "50%", top: "44%",
        transform: "translateX(-50%)",
        display: "flex", flexDirection: "column", alignItems: "center", gap: 4,
      }}>
        <span style={{
          fontFamily: "var(--font-mono)", fontSize: 38, fontWeight: 700,
          color: "var(--alert-normal)",
          textShadow: "0 0 24px rgba(61,214,140,0.6)",
        }}>+150</span>
        <span className="t-label" style={{ color: "var(--alert-normal)", fontSize: 10 }}>RARE · 787 CAUGHT</span>
      </div>

      <div style={{
        position: "absolute", left: 14, right: 14, bottom: 140,
        background: "rgba(10,14,26,0.92)",
        border: "1px solid var(--alert-normal)",
        borderRadius: 12, padding: "12px 14px",
        display: "flex", alignItems: "center", gap: 12,
      }}>
        <div style={{
          width: 40, height: 40, borderRadius: 8,
          background: "rgba(61,214,140,0.15)",
          display: "flex", alignItems: "center", justifyContent: "center",
        }}>
          <Icon.airplane size={20} color="var(--alert-normal)"/>
        </div>
        <div style={{ flex: 1 }}>
          <div className="t-hud-callsign" style={{ fontSize: 13, color: "var(--alert-normal)" }}>UAL248 caught</div>
          <div className="t-caption" style={{ fontSize: 11 }}>Boeing 787-9 · added to your hangar</div>
        </div>
        <span className="pill normal" style={{ fontSize: 11 }}>VIEW</span>
      </div>

      <BottomControls catches={48}/>
    </div>
  );
}

Object.assign(window, {
  ARStateEmpty, ARStateMultiCatch, ARStateCompassBad, ARStateJustCaught,
});
