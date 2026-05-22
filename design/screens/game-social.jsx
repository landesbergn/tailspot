// Game-system screens — rarity (5 tiers), types (Pokédex-style),
// simplified XP receipt (rarity-only math), achievements/medals,
// sets browser, anonymous global leaderboard, share card, public hangar.

// ─────────────────────────────────────────────────────────────
// Rarity reference — 5 tiers
// ─────────────────────────────────────────────────────────────
function RarityReferenceScreen() {
  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      <SimpleNav title="Rarity"/>
      <div style={{
        position: "absolute", top: 110, left: 0, right: 0, bottom: 0,
        padding: "0 16px 40px", overflowY: "auto",
        display: "flex", flexDirection: "column", gap: 12,
      }}>
        <div style={{ marginBottom: 4 }}>
          <h2 className="t-display" style={{ fontSize: 22, margin: 0, lineHeight: 1.2 }}>Five tiers.</h2>
          <p className="t-caption" style={{ marginTop: 6, fontSize: 12, color: "var(--text-secondary)", lineHeight: 1.45 }}>
            Set per <span style={{ fontFamily: "var(--font-mono)" }}>(model × livery)</span>. The only thing that determines points.
          </p>
        </div>

        {RARITY_ORDER.map(rid => {
          const r = RARITY[rid];
          return (
            <div key={rid} style={{
              padding: 14, borderRadius: 10,
              background: r.bg,
              border: `1px solid ${r.color}`,
              display: "flex", gap: 14, alignItems: "center",
            }}>
              <div style={{
                width: 44, height: 44, borderRadius: 8,
                background: "rgba(0,0,0,0.25)",
                color: r.color,
                display: "flex", alignItems: "center", justifyContent: "center",
              }}>
                {rid === "legendary"
                  ? <span style={{ fontSize: 20 }}>★</span>
                  : <Icon.airplane size={22} color={r.color}/>}
              </div>
              <div style={{ flex: 1 }}>
                <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
                  <span style={{ fontFamily: "var(--font-mono)", fontSize: 14, fontWeight: 700, letterSpacing: 1.2, color: r.color }}>{r.label}</span>
                </div>
                <div className="t-caption" style={{ fontSize: 11, marginTop: 3 }}>{r.examples}</div>
              </div>
              <span style={{
                fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 18,
                color: r.color,
              }}>{r.base}<span style={{ fontSize: 10, color: r.color, opacity: 0.7, marginLeft: 2 }}>pt</span></span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Types reference — Pokédex style
// ─────────────────────────────────────────────────────────────
function TypesReferenceScreen() {
  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      <SimpleNav title="Types"/>
      <div style={{
        position: "absolute", top: 110, left: 0, right: 0, bottom: 0,
        padding: "0 16px 40px", overflowY: "auto",
      }}>
        <h2 className="t-display" style={{ fontSize: 22, margin: "0 0 4px", lineHeight: 1.2 }}>Seven types.</h2>
        <p className="t-caption" style={{ marginBottom: 16, fontSize: 12, color: "var(--text-secondary)", lineHeight: 1.45 }}>
          What kind of aircraft you caught. Drives set grouping and a few achievements.
        </p>

        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {Object.values(TYPES).map(t => (
            <div key={t.id} style={{
              padding: "12px 14px", borderRadius: 10,
              background: "var(--bg-elevated)",
              borderLeft: `4px solid ${t.color}`,
              display: "flex", gap: 12, alignItems: "center",
            }}>
              <div style={{
                width: 38, height: 38, borderRadius: 999,
                background: t.color, color: "rgba(0,0,0,0.7)",
                display: "flex", alignItems: "center", justifyContent: "center",
                fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 16,
              }}>{t.glyph}</div>
              <div style={{ flex: 1 }}>
                <span className="t-card-title" style={{ fontSize: 14 }}>{t.label}</span>
                <div className="t-caption" style={{ fontSize: 11, marginTop: 2 }}>{t.desc}</div>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// XP receipt — simplified. Points come ONLY from rarity, then
// uniqueness and multi-catch combo.
// ─────────────────────────────────────────────────────────────
function XPReceiptScreen() {
  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      <div style={{ position: "absolute", inset: 0, background: "radial-gradient(circle at 50% 22%, rgba(0,212,255,0.07) 0%, transparent 55%)" }}/>
      <SimpleNav title="Catch · UAL248"/>

      <div style={{
        position: "absolute", top: 110, left: 0, right: 0, bottom: 0,
        padding: "0 16px 40px", overflowY: "auto",
      }}>
        {/* Hero card */}
        <div style={{ display: "flex", justifyContent: "center", marginTop: 4, marginBottom: 18 }}>
          <PokeCard plane={PLANE_LIBRARY.ual248} owned/>
        </div>

        {/* Receipt — only 3 inputs */}
        <div className="hud-panel" style={{ padding: 0, overflow: "hidden" }}>
          <div style={{
            padding: "10px 14px",
            display: "flex", justifyContent: "space-between", alignItems: "center",
            background: "var(--bg-surface)",
            borderBottom: "1px solid rgba(255,255,255,0.05)",
          }}>
            <span className="t-label" style={{ fontSize: 10 }}>POINTS</span>
            <span className="t-hud-data" style={{ color: "var(--text-tertiary)" }}>Catch #048</span>
          </div>

          <ReceiptRow
            label={<span style={{ display: "flex", alignItems: "center", gap: 6 }}>
              <RarityBadge rarity="rare" size="sm"/> <span>Base</span>
            </span>}
            value="100"/>
          <ReceiptRow label="First 787 you've caught" detail="+50%" value="+50" accent/>
          <ReceiptRow label="Solo catch" detail="no combo" value="—" muted/>

          <div style={{
            padding: "14px 14px 16px",
            borderTop: "1px solid rgba(255,255,255,0.08)",
            display: "flex", justifyContent: "space-between", alignItems: "baseline",
            background: "var(--bg-surface)",
          }}>
            <span className="t-card-title" style={{ fontSize: 14 }}>Total</span>
            <span style={{ fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 26, color: "var(--alert-normal)" }}>+150 pts</span>
          </div>
        </div>

        <p className="t-caption" style={{ marginTop: 14, fontSize: 11, color: "var(--text-tertiary)", textAlign: "center", lineHeight: 1.5 }}>
          Points come from rarity only.<br/>
          Catch multiple planes in one frame for a combo bonus.
        </p>
      </div>
    </div>
  );
}

function ReceiptRow({ label, detail, value, accent = false, muted = false }) {
  return (
    <div style={{
      padding: "12px 14px",
      borderBottom: "0.5px solid rgba(255,255,255,0.04)",
      display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10,
    }}>
      <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 2 }}>
        <span className="t-body" style={{ fontSize: 13, color: muted ? "var(--text-tertiary)" : "var(--text-primary)" }}>{label}</span>
        {detail && <span className="t-caption" style={{ fontSize: 10, fontFamily: "var(--font-mono)" }}>{detail}</span>}
      </div>
      <span style={{
        fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 16,
        color: accent ? "var(--alert-advisory)" : muted ? "var(--text-tertiary)" : "var(--text-primary)",
      }}>{value}</span>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// PokeCard — the visual artifact for a caught plane.
// Treatment scales with rarity: holo overlay for rare+, gold foil for legendary.
// ─────────────────────────────────────────────────────────────
function PokeCard({ plane, owned = false, rotation = 0, size = "md", holo = true }) {
  const r = RARITY[plane.rarity];
  const dims = size === "lg"
    ? { w: 280, h: 400, photoH: 150, titleSz: 16, modelSz: 13, ptSz: 13 }
    : size === "sm"
    ? { w: 150, h: 210, photoH: 80,  titleSz: 11, modelSz: 10, ptSz: 11 }
    : { w: 220, h: 308, photoH: 116, titleSz: 13, modelSz: 11, ptSz: 12 };

  // global holo override (from Tweaks: off / subtle / vivid)
  const holoMode = (typeof window !== "undefined" && window.__tailspotHoloMode) || "vivid";
  const holoOpacity =
    holoMode === "off" ? 0 :
    holoMode === "subtle" ? 0.25 :
    0.5;
  const showHolo = holo && holoMode !== "off" && ["rare", "epic", "legendary"].includes(plane.rarity);
  const isLegendary = plane.rarity === "legendary";
  const legBoost = isLegendary ? 1.4 : 1;

  return (
    <div style={{
      width: dims.w, height: dims.h, borderRadius: 16,
      position: "relative", overflow: "hidden",
      transform: `rotate(${rotation}deg)`,
      boxShadow: `0 24px 60px rgba(0,0,0,0.55), 0 0 0 1.5px ${r.color}, 0 0 40px ${r.color}44`,
      background: "linear-gradient(180deg, #1a2030 0%, #050810 100%)",
    }}>
      {/* rarity rail top */}
      <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 5, background: r.color, zIndex: 5 }}/>

      {/* HOLO LAYER — conic gradient mesh, masked to subtle */}
      {showHolo && (
        <div style={{
          position: "absolute", inset: 0,
          background: `conic-gradient(from 45deg at 50% 50%,
            rgba(255,100,200,0.5),
            rgba(100,200,255,0.5),
            rgba(255,220,100,0.5),
            rgba(100,255,180,0.5),
            rgba(180,140,255,0.5),
            rgba(255,100,200,0.5))`,
          mixBlendMode: "overlay",
          opacity: holoOpacity * legBoost,
          pointerEvents: "none",
        }}/>
      )}
      {/* diagonal foil shine */}
      {showHolo && (
        <div style={{
          position: "absolute", inset: 0,
          background: "linear-gradient(115deg, transparent 30%, rgba(255,255,255,0.18) 50%, transparent 70%)",
          mixBlendMode: "screen",
          pointerEvents: "none",
        }}/>
      )}
      {/* legendary gold dust */}
      {isLegendary && (
        <>
          <div style={{
            position: "absolute", inset: 0,
            background: "radial-gradient(circle at 20% 30%, rgba(255,199,74,0.4) 0%, transparent 6%), radial-gradient(circle at 70% 70%, rgba(255,199,74,0.3) 0%, transparent 5%), radial-gradient(circle at 45% 15%, rgba(255,199,74,0.3) 0%, transparent 4%), radial-gradient(circle at 85% 35%, rgba(255,199,74,0.3) 0%, transparent 4%)",
            mixBlendMode: "screen",
            pointerEvents: "none",
          }}/>
        </>
      )}

      {/* CONTENT */}
      <div style={{
        position: "absolute", inset: 0,
        padding: dims.w * 0.06,
        display: "flex", flexDirection: "column", gap: 8,
        zIndex: 4,
      }}>
        {/* top row — callsign + rarity */}
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 6 }}>
          <span className="t-hud-callsign" style={{ fontSize: dims.titleSz - 1 }}>{plane.call}</span>
          <RarityBadge rarity={plane.rarity} size={size === "sm" ? "sm" : "md"}/>
        </div>

        {/* photo with inner shadow */}
        <div style={{ position: "relative", borderRadius: 8, overflow: "hidden", flex: "0 0 auto" }}>
          <PhotoPlaceholder height={dims.photoH} label={plane.model.split(" ").slice(0,2).join(" ").toUpperCase()} radius={8}/>
          {/* subtle inner top highlight */}
          <div style={{
            position: "absolute", inset: 0, borderRadius: 8,
            boxShadow: "inset 0 1px 0 rgba(255,255,255,0.06), inset 0 -20px 30px rgba(0,0,0,0.3)",
            pointerEvents: "none",
          }}/>
        </div>

        {/* title block */}
        <div style={{ display: "flex", flexDirection: "column", gap: 3 }}>
          <span className="t-card-title" style={{ fontSize: dims.titleSz, lineHeight: 1.15 }}>{plane.model}</span>
          <span className="t-caption" style={{ fontSize: dims.modelSz, color: "var(--text-secondary)" }}>{plane.carrier}</span>
        </div>

        {/* spacer */}
        <div style={{ flex: 1 }}/>

        {/* mini stats grid for medium+ */}
        {size !== "sm" && (
          <div style={{ display: "flex", gap: 6 }}>
            <StatChip label="ALT" value={plane.alt}/>
            <StatChip label="SPD" value={plane.spd}/>
            <StatChip label="DIST" value={plane.dist}/>
          </div>
        )}

        {/* footer row */}
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 6 }}>
          <TypeBadge type={plane.type} size={size === "sm" ? "sm" : "md"}/>
          <span style={{
            fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: dims.ptSz + 2,
            color: r.color,
          }}>
            {r.base}<span style={{ opacity: 0.7, fontSize: dims.ptSz - 2, marginLeft: 1 }}>pt</span>
          </span>
        </div>
      </div>

      {owned && size !== "sm" && (
        <div style={{
          position: "absolute", top: dims.w * 0.05, right: dims.w * 0.32,
          color: "var(--alert-normal)", fontFamily: "var(--font-mono)",
          fontSize: 9, fontWeight: 700, letterSpacing: 1, zIndex: 6,
        }}>● OWNED</div>
      )}
    </div>
  );
}

function StatChip({ label, value }) {
  return (
    <div style={{
      flex: 1, padding: "4px 6px",
      background: "rgba(0,0,0,0.4)",
      borderRadius: 4,
      border: "1px solid rgba(255,255,255,0.05)",
    }}>
      <div className="t-label" style={{ fontSize: 7, color: "var(--text-tertiary)", letterSpacing: 0.5 }}>{label}</div>
      <div style={{ fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 11, color: "var(--text-primary)", lineHeight: 1.1 }}>{value}</div>
    </div>
  );
}

// ── Card BACK — collector data ────────────────────────────────────────────
function PokeCardBack({ plane, num = 48, total = 142, rotation = 0 }) {
  const r = RARITY[plane.rarity];
  return (
    <div style={{
      width: 280, height: 400, borderRadius: 16,
      position: "relative", overflow: "hidden",
      transform: `rotate(${rotation}deg)`,
      background: "linear-gradient(165deg, #0e1424 0%, #050810 100%)",
      boxShadow: `0 24px 60px rgba(0,0,0,0.55), 0 0 0 1.5px ${r.color}, 0 0 40px ${r.color}33`,
      padding: 18,
      display: "flex", flexDirection: "column", gap: 12,
    }}>
      {/* corner watermark */}
      <div style={{ position: "absolute", top: 14, right: 14, opacity: 0.6 }}>
        <BrandMark size={28}/>
      </div>
      <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 5, background: r.color }}/>

      <div style={{ marginTop: 6 }}>
        <div className="t-label" style={{ fontSize: 9 }}>ENTRY #{String(num).padStart(3, "0")} / {total}</div>
        <h2 className="t-display" style={{ fontSize: 22, margin: "4px 0 2px", lineHeight: 1.1 }}>{plane.model}</h2>
        <span className="t-card-subtitle" style={{ fontSize: 13 }}>{plane.call} · {plane.carrier}</span>
      </div>

      <div style={{ display: "flex", gap: 6 }}>
        <RarityBadge rarity={plane.rarity}/>
        <TypeBadge type={plane.type}/>
      </div>

      {/* spec table */}
      <div style={{
        background: "rgba(0,0,0,0.4)",
        borderRadius: 8, padding: 12,
        display: "flex", flexDirection: "column", gap: 8,
      }}>
        <SpecLine label="REG / ICAO" value="N38950 / A9F2B1"/>
        <SpecLine label="ROUTE" value="SFO ▸ EWR"/>
        <SpecLine label="ALTITUDE" value="FL370 · 11,278 m"/>
        <SpecLine label="SPEED" value="478 kt · 885 km/h"/>
        <SpecLine label="DISTANCE" value="12.4 km slant"/>
      </div>

      <div style={{ flex: 1 }}/>

      {/* caught footer */}
      <div style={{
        display: "flex", flexDirection: "column", gap: 2,
        padding: "10px 0 0",
        borderTop: "1px solid rgba(255,255,255,0.06)",
      }}>
        <span className="t-label" style={{ fontSize: 9 }}>CAUGHT</span>
        <span className="t-card-subtitle" style={{ fontSize: 12, color: "var(--text-primary)" }}>May 20, 2026 · 5:24 PM</span>
        <span className="t-caption" style={{ fontSize: 11 }}>Berkeley, CA · 37.871° N</span>
      </div>

      <div style={{
        position: "absolute", bottom: 12, right: 14,
        fontFamily: "var(--font-mono)", fontSize: 9, color: "var(--text-tertiary)",
        letterSpacing: 0.8,
      }}>TAILSPOT</div>
    </div>
  );
}

function SpecLine({ label, value }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
      <span className="t-label" style={{ fontSize: 9 }}>{label}</span>
      <span style={{ fontFamily: "var(--font-mono)", fontSize: 11, fontWeight: 600, color: "var(--text-primary)" }}>{value}</span>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Achievements — medals you can unlock
// ─────────────────────────────────────────────────────────────
function AchievementsScreen() {
  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      <SimpleNav title="Trophies"/>

      {/* hero strip */}
      <div style={{
        position: "absolute", top: 110, left: 16, right: 16,
        padding: 16,
        background: "linear-gradient(135deg, rgba(255,199,74,0.1) 0%, rgba(155,93,229,0.1) 100%)",
        border: "1px solid rgba(255,199,74,0.25)",
        borderRadius: 14,
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
          <div style={{ display: "flex", gap: -6 }}>
            <div style={{ position: "relative", zIndex: 3 }}>
              <Trophy tier="gold" icon="diamond" size={48}/>
            </div>
            <div style={{ position: "relative", marginLeft: -10, zIndex: 2 }}>
              <Trophy tier="silver" icon="widebody" size={44}/>
            </div>
            <div style={{ position: "relative", marginLeft: -10, zIndex: 1 }}>
              <Trophy tier="bronze" icon="catcher" size={40}/>
            </div>
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontFamily: "var(--font-sans)", fontWeight: 700, fontSize: 22, color: "var(--text-primary)" }}>5 of 36</div>
            <div className="t-caption" style={{ fontSize: 11, marginTop: 2 }}>3 close to unlocking</div>
          </div>
        </div>
      </div>

      <div style={{
        position: "absolute", top: 234, left: 0, right: 0, bottom: 0,
        padding: "0 16px 40px", overflowY: "auto",
      }}>
        <SectionLabel>EARNED</SectionLabel>
        <div style={{ display: "flex", flexDirection: "column", gap: 8, marginBottom: 22 }}>
          {ACHIEVEMENTS.filter(a => highestEarnedTier(a)).slice(0, 4).map(a => (
            <AchievementRow key={a.id} achievement={a}/>
          ))}
        </div>

        <SectionLabel>IN PROGRESS</SectionLabel>
        <div style={{ display: "flex", flexDirection: "column", gap: 8, marginBottom: 22 }}>
          {ACHIEVEMENTS.filter(a => !highestEarnedTier(a) && a.progress > 0).map(a => (
            <AchievementRow key={a.id} achievement={a}/>
          ))}
        </div>

        <SectionLabel>LOCKED</SectionLabel>
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {ACHIEVEMENTS.filter(a => !highestEarnedTier(a) && a.progress === 0).map(a => (
            <AchievementRow key={a.id} achievement={a} hidden/>
          ))}
        </div>
      </div>
    </div>
  );
}

function SectionLabel({ children }) {
  return <div className="t-label" style={{ padding: "6px 4px 10px" }}>{children}</div>;
}

function AchievementRow({ achievement: a, hidden = false }) {
  const earnedTier = highestEarnedTier(a);
  const next = nextTier(a);
  const nextProgress = next ? Math.min(1, a.progress / next.at) : 1;
  const tierToShow = earnedTier ?? (next?.tier ?? "bronze");
  const iconId = (typeof ACHIEVEMENT_ICONS !== "undefined" && ACHIEVEMENT_ICONS[a.id]) || "catcher";

  return (
    <div style={{
      padding: "12px 14px", borderRadius: 12,
      background: "var(--bg-elevated)",
      border: "1px solid rgba(255,255,255,0.04)",
      display: "flex", gap: 14, alignItems: "center",
    }}>
      <Trophy tier={tierToShow} icon={iconId} size={50} locked={hidden}/>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 6, marginBottom: 2 }}>
          <span className="t-card-title" style={{ fontSize: 14, color: hidden ? "var(--text-tertiary)" : "var(--text-primary)" }}>
            {hidden ? "???" : a.title}
          </span>
          {earnedTier && (
            <span style={{
              fontFamily: "var(--font-mono)", fontSize: 9, fontWeight: 700,
              color: MEDAL_TIERS[earnedTier].color, letterSpacing: 0.8,
            }}>{MEDAL_TIERS[earnedTier].label}</span>
          )}
        </div>
        <div className="t-caption" style={{ fontSize: 11 }}>
          {hidden ? "Hidden trophy — unlock by playing." : a.desc}
        </div>
        {!hidden && next && (
          <div style={{ marginTop: 8 }}>
            <div style={{ height: 4, borderRadius: 2, background: "rgba(255,255,255,0.06)", overflow: "hidden" }}>
              <div style={{ width: `${nextProgress * 100}%`, height: "100%", background: MEDAL_TIERS[next.tier].color }}/>
            </div>
            <div style={{ display: "flex", justifyContent: "space-between", marginTop: 4 }}>
              <span className="t-caption" style={{ fontSize: 10 }}>{a.progress}/{next.at}</span>
              <span className="t-caption" style={{ fontSize: 10, color: MEDAL_TIERS[next.tier].color }}>{MEDAL_TIERS[next.tier].label}</span>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Sets — by TYPE (Pokédex set per type, like generations)
// ─────────────────────────────────────────────────────────────
function SetsScreen() {
  const sets = [
    { name: "Narrow-body", type: "narrow", got: 12, of: 24 },
    { name: "Wide-body / Heavies", type: "wide", got: 6, of: 14 },
    { name: "Regional", type: "regional", got: 4, of: 18 },
    { name: "Business jets", type: "biz", got: 2, of: 12 },
    { name: "General aviation", type: "ga", got: 3, of: 22 },
    { name: "Military", type: "mil", got: 0, of: 16 },
    { name: "Heritage & special", type: "heritage", got: 1, of: 10 },
  ];
  const total = sets.reduce((a, s) => a + s.of, 0);
  const got = sets.reduce((a, s) => a + s.got, 0);

  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      <SimpleNav title="Sets"/>

      <div style={{
        position: "absolute", top: 110, left: 16, right: 16,
        padding: 16, borderRadius: 12,
        background: "linear-gradient(135deg, var(--bg-elevated) 0%, var(--bg-surface) 100%)",
        border: "1px solid rgba(255,255,255,0.06)",
      }}>
        <div className="t-label" style={{ fontSize: 10 }}>POKÉDEX-STYLE</div>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", marginTop: 4 }}>
          <h2 className="t-display" style={{ fontSize: 22, margin: 0 }}>Sets by type</h2>
          <span style={{ fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 18, color: "var(--accent)" }}>
            {got}<span style={{ color: "var(--text-tertiary)" }}>/{total}</span>
          </span>
        </div>
      </div>

      <div style={{
        position: "absolute", top: 224, left: 0, right: 0, bottom: 0,
        padding: "0 16px 40px", overflowY: "auto",
        display: "flex", flexDirection: "column", gap: 10,
      }}>
        {sets.map(s => <SetRow key={s.type} {...s}/>)}
      </div>
    </div>
  );
}

function SetRow({ name, type, got, of }) {
  const t = TYPES[type];
  const pct = got / of;
  return (
    <div style={{
      padding: 14, borderRadius: 12,
      background: "var(--bg-elevated)",
      borderLeft: `4px solid ${t.color}`,
      display: "flex", flexDirection: "column", gap: 10,
    }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, minWidth: 0 }}>
          <div style={{
            width: 30, height: 30, borderRadius: 999,
            background: t.color, color: "rgba(0,0,0,0.7)",
            fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 13,
            display: "flex", alignItems: "center", justifyContent: "center",
            flex: "0 0 auto",
          }}>{t.glyph}</div>
          <div style={{ minWidth: 0 }}>
            <div className="t-card-title" style={{ fontSize: 14 }}>{name}</div>
            <div className="t-caption" style={{ fontSize: 10 }}>{t.desc}</div>
          </div>
        </div>
        <span style={{ fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 14, color: t.color }}>
          {got}<span style={{ color: "var(--text-tertiary)" }}>/{of}</span>
        </span>
      </div>
      <div style={{ height: 4, borderRadius: 2, background: "rgba(255,255,255,0.05)", overflow: "hidden" }}>
        <div style={{ width: `${pct * 100}%`, height: "100%", background: t.color }}/>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Leaderboard — anonymous global only
// ─────────────────────────────────────────────────────────────
function LeaderboardScreen() {
  const rows = [
    { rank: 1, handle: "skytracker_jp",  pts: 18420 },
    { rank: 2, handle: "approach_lgw",   pts: 14210 },
    { rank: 3, handle: "callout_phx",    pts: 11982 },
    { rank: 4, handle: "tower_nrt",      pts: 10204 },
    { rank: 5, handle: "ramp_anc",       pts: 9800  },
    { rank: 6, handle: "hangar_yyz",     pts: 9012  },
    { rank: 12, handle: "you",           pts: 4275, you: true },
  ];

  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      <SimpleNav title="Leaderboard"/>

      {/* segmented */}
      <div style={{
        position: "absolute", top: 116, left: 16, right: 16, height: 36,
        background: "var(--bg-elevated)", borderRadius: 10, padding: 3,
        display: "flex", gap: 2,
      }}>
        {["Week", "Month", "All time"].map((l, i) => (
          <div key={l} style={{
            flex: 1, display: "flex", alignItems: "center", justifyContent: "center",
            borderRadius: 8,
            background: i === 0 ? "var(--bg-surface)" : "transparent",
            color: i === 0 ? "var(--text-primary)" : "var(--text-secondary)",
            fontFamily: "var(--font-sans)", fontWeight: i === 0 ? 600 : 500, fontSize: 13,
          }}>{l}</div>
        ))}
      </div>

      <div style={{
        position: "absolute", top: 168, left: 0, right: 0, bottom: 0,
        padding: "0 16px 40px", overflowY: "auto",
      }}>
        <p className="t-caption" style={{ fontSize: 11, color: "var(--text-tertiary)", padding: "10px 4px 8px", lineHeight: 1.5 }}>
          Public spotters worldwide. Handles only — no real names.
        </p>

        <div className="hud-panel" style={{ padding: 0, overflow: "hidden" }}>
          {rows.map((r, i) => (
            <LeaderRow key={r.handle} {...r} last={i === rows.length - 1}/>
          ))}
        </div>

        <div style={{
          marginTop: 14, padding: 14, borderRadius: 10,
          background: "rgba(0,212,255,0.06)",
          border: "1px solid rgba(0,212,255,0.2)",
          display: "flex", alignItems: "center", gap: 10,
        }}>
          <Icon.trophy size={16} color="var(--accent)"/>
          <div style={{ flex: 1 }}>
            <span className="t-card-title" style={{ fontSize: 13 }}>Climb 4 places to break top 10</span>
            <div className="t-caption" style={{ fontSize: 11, marginTop: 2 }}>Need ~1,200 more points this week.</div>
          </div>
        </div>
      </div>
    </div>
  );
}

function LeaderRow({ rank, handle, pts, you = false, last = false }) {
  return (
    <div style={{
      padding: "12px 14px",
      borderBottom: last ? 0 : "0.5px solid rgba(255,255,255,0.05)",
      display: "flex", alignItems: "center", gap: 12,
      background: you ? "rgba(0,212,255,0.08)" : "transparent",
    }}>
      <span style={{
        fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 13,
        width: 34, color: rank <= 3 ? "var(--accent)" : "var(--text-tertiary)",
      }}>#{rank}</span>
      <div style={{
        width: 30, height: 30, borderRadius: 6,
        background: `linear-gradient(135deg, hsl(${rank * 53 % 360},35%,42%), hsl(${rank * 53 % 360 + 60},30%,28%))`,
        display: "flex", alignItems: "center", justifyContent: "center",
        color: "rgba(255,255,255,0.8)", fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 11,
      }}>{handle.slice(0, 2).toUpperCase()}</div>
      <span style={{
        flex: 1,
        fontFamily: "var(--font-mono)", fontSize: 13, fontWeight: you ? 700 : 500,
        color: you ? "var(--accent)" : "var(--text-primary)",
      }}>{handle}{you && <span className="t-caption" style={{ marginLeft: 6, fontSize: 10 }}>· you</span>}</span>
      <span style={{
        fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 13,
        color: "var(--text-primary)",
      }}>{pts.toLocaleString()}</span>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Share card — caught plane → shareable graphic
// ─────────────────────────────────────────────────────────────
function ShareCardScreen() {
  const p = PLANE_LIBRARY.baw286;
  const r = RARITY[p.rarity];

  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-surface)", overflow: "hidden" }}>
      <SimpleNav title="Share"/>

      <div style={{
        position: "absolute", top: 116, left: 0, right: 0, bottom: 0,
        padding: "12px 16px 40px", overflowY: "auto",
        display: "flex", flexDirection: "column", gap: 16,
      }}>
        {/* The actual share artifact */}
        <div style={{
          background: "linear-gradient(160deg, #0A0E1A 0%, #1a2030 100%)",
          borderRadius: 18, padding: 18,
          position: "relative", overflow: "hidden",
          boxShadow: "0 20px 60px rgba(0,0,0,0.5)",
          border: `1.5px solid ${r.color}`,
        }}>
          {/* rarity stripe */}
          <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 4, background: r.color }}/>

          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 4 }}>
            <Lockup size="sm"/>
            <RarityBadge rarity={p.rarity} size="md"/>
          </div>

          <div style={{ marginTop: 16 }}>
            <PhotoPlaceholder height={150} label="A380 · BRITISH AIRWAYS" radius={10}/>
          </div>

          <div style={{ marginTop: 14 }}>
            <span className="t-hud-callsign" style={{ fontSize: 14 }}>{p.call}</span>
            <h3 className="t-display" style={{ fontSize: 22, margin: "4px 0 4px" }}>{p.model}</h3>
            <span className="t-card-subtitle" style={{ fontSize: 13 }}>{p.carrier} · LHR ▸ SFO</span>
          </div>

          <div style={{ display: "flex", gap: 8, marginTop: 14, alignItems: "center", flexWrap: "wrap" }}>
            <TypeBadge type={p.type} size="md"/>
            <span style={{ flex: 1 }}/>
            <span style={{
              fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 22, color: r.color,
            }}>+{r.base}<span style={{ fontSize: 12, opacity: 0.7, marginLeft: 2 }}>pts</span></span>
          </div>

          <div style={{
            marginTop: 14, paddingTop: 12,
            borderTop: "1px solid rgba(255,255,255,0.06)",
            display: "flex", justifyContent: "space-between", alignItems: "center",
          }}>
            <span className="t-caption" style={{ fontSize: 11 }}>caught by @you · Berkeley CA · #48</span>
            <span className="t-caption" style={{ fontSize: 10, fontFamily: "var(--font-mono)" }}>tailspot.app</span>
          </div>
        </div>

        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
          <ShareAction label="Copy link"/>
          <ShareAction label="Save image"/>
          <ShareAction label="Messages" accent/>
          <ShareAction label="Instagram"/>
        </div>
      </div>
    </div>
  );
}

function ShareAction({ label, accent = false }) {
  return (
    <button style={{
      background: accent ? "var(--accent)" : "var(--bg-elevated)",
      color: accent ? "#02131a" : "var(--text-primary)",
      border: accent ? 0 : "1px solid rgba(255,255,255,0.06)",
      borderRadius: 12, padding: "14px 16px",
      fontFamily: "var(--font-sans)", fontWeight: 600, fontSize: 14,
      cursor: "pointer",
    }}>{label}</button>
  );
}

// ─────────────────────────────────────────────────────────────
// Public Hangar — anonymous handle, public by default
// ─────────────────────────────────────────────────────────────
function PublicHangarScreen() {
  return (
    <div style={{ position: "absolute", inset: 0, background: "var(--bg-primary)", overflow: "hidden" }}>
      <SimpleNav title="@skytracker_jp"/>

      <div style={{
        position: "absolute", top: 110, left: 0, right: 0, bottom: 0,
        padding: "16px 16px 40px", overflowY: "auto",
        display: "flex", flexDirection: "column", gap: 16,
      }}>
        <div style={{
          background: "linear-gradient(135deg, var(--bg-elevated) 0%, var(--bg-surface) 100%)",
          borderRadius: 14, padding: 16,
        }}>
          <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
            <div style={{
              width: 60, height: 60, borderRadius: 8,
              background: "linear-gradient(135deg, var(--alert-caution) 0%, #804400 100%)",
              display: "flex", alignItems: "center", justifyContent: "center",
              color: "rgba(0,0,0,0.6)", fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 22,
            }}>SJ</div>
            <div style={{ flex: 1 }}>
              <span className="t-display" style={{ fontSize: 18 }}>@skytracker_jp</span>
              <div className="t-caption" style={{ fontSize: 11, marginTop: 2 }}>NRT region · #1 this week</div>
              <div style={{ marginTop: 6, display: "flex", gap: 6 }}>
                <Trophy tier="gold" icon="crown" size={26}/>
                <Trophy tier="gold" icon="setmaster" size={26}/>
                <Trophy tier="silver" icon="widebody" size={26}/>
                <Trophy tier="silver" icon="world" size={26}/>
                <span className="t-caption" style={{ fontSize: 10, marginLeft: 4, alignSelf: "center" }}>+18</span>
              </div>
            </div>
          </div>
        </div>

        <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 8 }}>
          <MiniStat label="POINTS" value="18,420"/>
          <MiniStat label="CATCHES" value="312"/>
          <MiniStat label="LEGENDARY" value="3"/>
        </div>

        <div>
          <div className="t-label" style={{ padding: "0 4px 8px" }}>RECENT CATCHES</div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            <PokeCardMini plane={PLANE_LIBRARY.baw286}/>
            <PokeCardMini plane={PLANE_LIBRARY.nasa747}/>
            <PokeCardMini plane={PLANE_LIBRARY.af1}/>
            <PokeCardMini plane={PLANE_LIBRARY.ual248}/>
          </div>
        </div>

        <div>
          <div className="t-label" style={{ padding: "0 4px 8px" }}>COMPLETED SETS</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            <CompletedSet name="Wide-body / Heavies" t="wide" of={14}/>
            <CompletedSet name="Heritage & special" t="heritage" of={10}/>
          </div>
        </div>
      </div>
    </div>
  );
}

function MiniStat({ label, value }) {
  return (
    <div className="hud-panel" style={{ padding: "10px 12px", textAlign: "center" }}>
      <div className="t-label" style={{ fontSize: 9 }}>{label}</div>
      <div className="t-hud-callsign" style={{ fontSize: 16, marginTop: 2 }}>{value}</div>
    </div>
  );
}

function PokeCardMini({ plane }) {
  const r = RARITY[plane.rarity];
  return (
    <div style={{
      borderRadius: 10,
      background: "linear-gradient(180deg, var(--bg-elevated) 0%, var(--bg-surface) 100%)",
      border: `1px solid ${r.color}`,
      padding: 10, display: "flex", flexDirection: "column", gap: 6,
      position: "relative", overflow: "hidden",
    }}>
      <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 2, background: r.color }}/>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <span className="t-hud-callsign" style={{ fontSize: 11 }}>{plane.call}</span>
        <RarityBadge rarity={plane.rarity} size="sm"/>
      </div>
      <PhotoPlaceholder height={66} label={plane.model.split(" ")[0].toUpperCase()} radius={5}/>
      <div className="t-card-title" style={{ fontSize: 11, lineHeight: 1.2 }}>{plane.model}</div>
      <TypeBadge type={plane.type} size="sm"/>
    </div>
  );
}

function CompletedSet({ name, t, of }) {
  const ty = TYPES[t];
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 12,
      padding: "10px 14px",
      background: "var(--bg-elevated)", borderRadius: 8,
      borderLeft: `3px solid ${ty.color}`,
    }}>
      <div style={{
        width: 24, height: 24, borderRadius: 999,
        background: ty.color, color: "rgba(0,0,0,0.7)",
        fontFamily: "var(--font-mono)", fontWeight: 700, fontSize: 11,
        display: "flex", alignItems: "center", justifyContent: "center",
      }}>{ty.glyph}</div>
      <span className="t-card-title" style={{ fontSize: 13, flex: 1 }}>{name}</span>
      <span className="t-hud-data" style={{ color: ty.color, fontWeight: 700 }}>{of}/{of}</span>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Reusable nav header
// ─────────────────────────────────────────────────────────────
function SimpleNav({ title }) {
  return (
    <div style={{
      position: "absolute", top: 56, left: 0, right: 0,
      padding: "0 16px", height: 44,
      display: "flex", alignItems: "center", justifyContent: "space-between",
    }}>
      <span className="t-body" style={{ color: "var(--accent)", fontWeight: 500, fontSize: 16 }}>‹ Back</span>
      <span className="t-card-title" style={{ fontSize: 17 }}>{title}</span>
      <span style={{ width: 50 }}/>
    </div>
  );
}

Object.assign(window, {
  RarityReferenceScreen, TypesReferenceScreen,
  XPReceiptScreen, AchievementsScreen,
  SetsScreen, LeaderboardScreen,
  ShareCardScreen, PublicHangarScreen,
  PokeCard, PokeCardBack, PokeCardMini,
  SimpleNav,
});
