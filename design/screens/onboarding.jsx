// Splash + Onboarding screens — 2 variations (Pilot HUD vs. Card Collector)
// Both arrive at the same destination (the AR view) but with different first impressions.

// ─────────────────────────────────────────────────────────────
// Splash — wordmark lockup, brief, then crossfade
// ─────────────────────────────────────────────────────────────
function ScreenSplash({ copy }) {
  return (
    <div style={{
      position: "absolute", inset: 0,
      background: "var(--bg-primary)",
      display: "flex", alignItems: "center", justifyContent: "center",
      flexDirection: "column", gap: 24,
    }}>
      {/* radial glow */}
      <div style={{
        position: "absolute", inset: 0,
        background: "radial-gradient(circle at center, rgba(0,212,255,0.08) 0%, transparent 50%)",
      }} />
      <Lockup size="lg" />
      <div style={{ height: 1, width: 80, background: "var(--accent)", opacity: 0.5 }} />
      <span className="t-caption" style={{ letterSpacing: 2, textTransform: "uppercase" }}>
        {copy?.splashTagline ?? "Look up. Catch them all."}
      </span>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Onboarding Variation A — Pilot HUD
// Three steps: welcome, permissions, calibration. Clinical, instrument-toned.
// ─────────────────────────────────────────────────────────────
function OnboardingA_Welcome({ copy }) {
  return (
    <div style={{
      position: "absolute", inset: 0,
      background: "var(--bg-primary)",
      padding: "100px 28px 40px",
      display: "flex", flexDirection: "column",
    }}>
      <div style={{ display: "flex", flexDirection: "column", alignItems: "flex-start", gap: 14 }}>
        <Lockup size="md" />
        <div style={{ height: 1, width: 40, background: "var(--accent)", opacity: 0.6, marginTop: 6 }} />
      </div>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", gap: 18 }}>
        <span className="t-label" style={{ color: "var(--accent)" }}>STEP 1 / 3</span>
        <h1 className="t-display" style={{ margin: 0, lineHeight: 1.15, fontSize: 30 }}>
          {copy?.welcomeTitle ?? "Spot every plane overhead."}
        </h1>
        <p className="t-body" style={{ color: "var(--text-secondary)", lineHeight: 1.45, margin: 0 }}>
          {copy?.welcomeBody ??
            "Point your phone at the sky. Tailspot uses live ADS-B data to identify the aircraft you're looking at, then lets you catch it to your Hangar."}
        </p>
      </div>
      <OnboardingFooter step={1} primary={copy?.welcomeCTA ?? "Get started"} />
    </div>
  );
}

function OnboardingA_Permissions({ copy }) {
  const rows = [
    { glyph: "L", title: "Location, while in use",
      body: "Match your viewing angle against live flight positions. Not retained as history." },
    { glyph: "C", title: "Camera",
      body: "Used for AR overlay only. Tailspot never records or transmits the camera feed." },
    { glyph: "M", title: "Motion & orientation",
      body: "Read your pitch and heading so reticles land on the right plane." },
  ];
  return (
    <div style={{
      position: "absolute", inset: 0, background: "var(--bg-primary)",
      padding: "70px 24px 40px", display: "flex", flexDirection: "column",
    }}>
      <span className="t-label" style={{ color: "var(--accent)" }}>STEP 2 / 3 · PERMISSIONS</span>
      <h2 className="t-display" style={{ margin: "10px 0 22px", fontSize: 24, lineHeight: 1.2 }}>
        Three permissions to read the sky.
      </h2>
      <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        {rows.map(r => (
          <div key={r.glyph} className="hud-panel" style={{ padding: "12px 14px", display: "flex", gap: 12, alignItems: "flex-start" }}>
            <div style={{
              width: 30, height: 30, borderRadius: 6,
              background: "rgba(0,212,255,0.12)", color: "var(--accent)",
              display: "flex", alignItems: "center", justifyContent: "center",
              fontFamily: "var(--font-mono)", fontWeight: 700,
              flex: "0 0 auto",
            }}>{r.glyph}</div>
            <div style={{ display: "flex", flexDirection: "column", gap: 3 }}>
              <span className="t-card-title" style={{ fontSize: 14 }}>{r.title}</span>
              <span className="t-caption" style={{ lineHeight: 1.35 }}>{r.body}</span>
            </div>
          </div>
        ))}
      </div>
      <div style={{ flex: 1 }} />
      <OnboardingFooter step={2} primary="Allow permissions" />
    </div>
  );
}

function OnboardingA_Calibration({ copy }) {
  return (
    <div style={{
      position: "absolute", inset: 0, background: "var(--bg-primary)",
      padding: "60px 24px 40px", display: "flex", flexDirection: "column",
    }}>
      <span className="t-label" style={{ color: "var(--accent)" }}>STEP 3 / 3 · COMPASS</span>
      <h2 className="t-display" style={{ margin: "10px 0 8px", fontSize: 24, lineHeight: 1.2 }}>
        Trace a figure-8 in the air.
      </h2>
      <p className="t-caption" style={{ color: "var(--text-secondary)", lineHeight: 1.45, margin: 0, fontSize: 13 }}>
        iPhone compasses drift near cars and buildings. A quick calibration brings accuracy to ±2°.
      </p>

      {/* figure-8 animation surface */}
      <div style={{
        flex: 1, marginTop: 22, marginBottom: 22,
        display: "flex", alignItems: "center", justifyContent: "center",
        position: "relative",
      }}>
        <svg viewBox="0 0 200 200" width="220" height="220">
          <path d="M40 100 C 40 60, 100 60, 100 100 C 100 140, 160 140, 160 100 C 160 60, 100 60, 100 100 C 100 140, 40 140, 40 100 Z"
            fill="none" stroke="var(--accent)" strokeWidth="1.5" strokeOpacity="0.35" strokeDasharray="3 5"/>
          <circle r="6" fill="var(--accent)">
            <animateMotion dur="3.2s" repeatCount="indefinite"
              path="M40 100 C 40 60, 100 60, 100 100 C 100 140, 160 140, 160 100 C 160 60, 100 60, 100 100 C 100 140, 40 140, 40 100 Z"/>
          </circle>
        </svg>
        {/* center compass readout */}
        <div className="hud-panel" style={{
          position: "absolute", bottom: 8, left: "50%", transform: "translateX(-50%)",
          padding: "6px 12px", display: "flex", gap: 14,
        }}>
          <span className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>HDG</span>
          <span className="t-hud-callsign" style={{ fontSize: 12 }}>287°</span>
          <span className="t-hud-data" style={{ color: "var(--alert-caution)" }}>±8°</span>
        </div>
      </div>

      <OnboardingFooter step={3} primary="Skip · I'll do it later" subtle/>
    </div>
  );
}

function OnboardingFooter({ step, primary, subtle = false }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14, alignItems: "stretch" }}>
      {/* progress */}
      <div style={{ display: "flex", gap: 6 }}>
        {[1,2,3].map(i => (
          <div key={i} style={{
            flex: 1, height: 3, borderRadius: 2,
            background: i <= step ? "var(--accent)" : "rgba(255,255,255,0.12)",
          }} />
        ))}
      </div>
      <button style={{
        height: 50, borderRadius: 12, border: 0, cursor: "pointer",
        background: subtle ? "transparent" : "var(--accent)",
        color: subtle ? "var(--text-secondary)" : "#02131a",
        fontFamily: "var(--font-sans)",
        fontWeight: 600, fontSize: 16,
        boxShadow: subtle ? "none" : "0 6px 24px rgba(0,212,255,0.25)",
      }}>{primary}</button>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Onboarding Variation B — Card Collector
// Trading-card forward, warmer tone, sample card hero
// ─────────────────────────────────────────────────────────────
function OnboardingB_Welcome({ copy }) {
  return (
    <div style={{
      position: "absolute", inset: 0, background: "var(--bg-primary)",
      padding: "80px 24px 40px", display: "flex", flexDirection: "column",
    }}>
      {/* night sky backdrop */}
      <div style={{
        position: "absolute", inset: 0,
        background: "radial-gradient(ellipse at 50% 30%, rgba(255,107,230,0.16) 0%, transparent 55%), radial-gradient(ellipse at 50% 70%, rgba(0,212,255,0.10) 0%, transparent 60%)",
        pointerEvents: "none",
      }}/>
      {/* floating sample card */}
      <div style={{ position: "relative", margin: "0 auto", marginBottom: 28 }}>
        <PokeCard plane={PLANE_LIBRARY.ual248} rotation={-6} size="md"/>
      </div>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "flex-end", gap: 12 }}>
        <Lockup size="sm" />
        <h1 className="t-display" style={{ margin: 0, fontSize: 30, lineHeight: 1.1 }}>
          Build a hangar of every plane you see.
        </h1>
        <p className="t-body" style={{ color: "var(--text-secondary)", margin: 0, lineHeight: 1.45 }}>
          That contrail at 33,000 ft? It's a Boeing 787 inbound to SFO. Catch it.
        </p>
      </div>
      <div style={{ marginTop: 22 }}>
        <OnboardingFooter step={1} primary="Sign in with Apple" />
      </div>
    </div>
  );
}

function SampleCard({ rotation = 0, locked = false }) {
  return (
    <div style={{
      width: 200, height: 260, borderRadius: 14,
      background: "linear-gradient(180deg, #1a2030 0%, #050810 100%)",
      border: `1px solid ${locked ? "var(--alert-normal)" : "rgba(255,255,255,0.1)"}`,
      boxShadow: "0 20px 50px rgba(0,0,0,0.55), 0 0 0 1px rgba(0,212,255,0.08)",
      transform: `rotate(${rotation}deg)`,
      padding: 14, display: "flex", flexDirection: "column", gap: 10,
      position: "relative", overflow: "hidden",
    }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <span className="t-hud-callsign" style={{ fontSize: 12 }}>UAL248</span>
        <span className="pill advisory" style={{ fontSize: 9, padding: "2px 7px" }}>RARE</span>
      </div>
      <PhotoPlaceholder height={110} label="787-9 LIVERY" radius={6}/>
      <div>
        <div className="t-card-title" style={{ fontSize: 13, marginBottom: 2 }}>Boeing 787-9</div>
        <div className="t-caption" style={{ fontSize: 11 }}>United Airlines · SFO ▸ EWR</div>
      </div>
      <div style={{ display: "flex", gap: 6, marginTop: "auto" }}>
        <span className="pill" style={{ fontSize: 9, padding: "2px 7px" }}>FL370</span>
        <span className="pill" style={{ fontSize: 9, padding: "2px 7px" }}>478kt</span>
      </div>
    </div>
  );
}

function OnboardingB_Permissions({ copy }) {
  return (
    <div style={{
      position: "absolute", inset: 0, background: "var(--bg-primary)",
      padding: "80px 24px 40px", display: "flex", flexDirection: "column", gap: 24,
    }}>
      <Lockup size="sm" />
      <div>
        <h2 className="t-display" style={{ margin: 0, fontSize: 26, lineHeight: 1.15 }}>How Tailspot works</h2>
        <p className="t-caption" style={{ color: "var(--text-secondary)", marginTop: 6 }}>Three things, then you're spotting.</p>
      </div>

      {[
        { n: "01", title: "We use your location, motion and camera", body: "Strictly for the AR overlay. The camera feed never leaves your phone." },
        { n: "02", title: "We never share or sell your data", body: "Only a catch event hits our server — for cheat validation." },
        { n: "03", title: "Sign in with Apple, that's it", body: "Email hidden via relay, no passwords." },
      ].map(r => (
        <div key={r.n} style={{ display: "flex", gap: 14, alignItems: "flex-start" }}>
          <span className="t-hud-callsign" style={{ fontSize: 24, color: "var(--accent)", lineHeight: 1, marginTop: 2 }}>{r.n}</span>
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            <span className="t-card-title" style={{ fontSize: 15 }}>{r.title}</span>
            <span className="t-caption" style={{ lineHeight: 1.4 }}>{r.body}</span>
          </div>
        </div>
      ))}
      <div style={{ flex: 1 }} />
      <OnboardingFooter step={2} primary="Allow & continue" />
    </div>
  );
}

Object.assign(window, {
  ScreenSplash,
  OnboardingA_Welcome, OnboardingA_Permissions, OnboardingA_Calibration,
  OnboardingB_Welcome, OnboardingB_Permissions,
  SampleCard, OnboardingFooter,
});
