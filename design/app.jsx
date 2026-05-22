// Tailspot — design canvas of every screen, organized by section.
// Iterates iOS frames with each screen variation, exposes a Tweaks panel
// for color theme, type, density, copy, layout variants.

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "accent": "#00D4FF",
  "tone": "pilot",
  "density": "regular",
  "holo": "vivid",
  "showSplash": true,
  "homeVariant": "A",
  "detailVariant": "A",
  "hangarVariant": "B",
  "onboardingVariant": "A"
}/*EDITMODE-END*/;

const COPY_PRESETS = {
  pilot: {
    splashTagline: "Look up. Catch them all.",
    welcomeTitle: "Spot every plane overhead.",
    welcomeBody: "Point your phone at the sky. Tailspot uses live ADS-B data to identify the aircraft you're looking at, then lets you catch it to your Hangar.",
    welcomeCTA: "Get started",
  },
  casual: {
    splashTagline: "Wonder what that plane is?",
    welcomeTitle: "That plane? We'll tell you what it is.",
    welcomeBody: "Hold your phone up at any plane in the sky. We'll tell you the airline, the model, where it's flying. Build a collection of every one you spot.",
    welcomeCTA: "Let's go",
  },
  avgeek: {
    splashTagline: "ADS-B in your pocket.",
    welcomeTitle: "Every aircraft. Every overflight.",
    welcomeBody: "Real-time ADS-B overlay with sub-degree compass-corrected lock-on. Forward-extrapolated to compensate for OpenSky's 5-15s lag. Catch, log, export.",
    welcomeCTA: "Begin spotting",
  },
};

const ACCENT_OPTIONS = [
  "#00D4FF", // cyan (spec default)
  "#FFB800", // amber (caution-tier, repurposed as primary)
  "#3DD68C", // green
  "#FF6BE6", // magenta (advisory-tier)
];

function applyTweaks(t) {
  const root = document.documentElement;
  root.style.setProperty("--accent", t.accent);
  if (t.density === "dense") root.style.setProperty("--pad", "0.85");
  else if (t.density === "airy") root.style.setProperty("--pad", "1.2");
  else root.style.setProperty("--pad", "1");
  // Holo intensity — surfaces a global var consumed by PokeCard
  root.style.setProperty("--holo-strength",
    t.holo === "off" ? "0" :
    t.holo === "subtle" ? "0.45" : "0.85");
  window.__tailspotHoloMode = t.holo;
}

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const copy = COPY_PRESETS[t.tone] ?? COPY_PRESETS.pilot;

  React.useEffect(() => { applyTweaks(t); }, [t.accent, t.density, t.holo]);

  const frame = (children, dark = true) => (
    <IOSDevice dark={dark}>{children}</IOSDevice>
  );

  return (
    <>
      <DesignCanvas>
        {/* ─────────── 00 · Splash + Brand ─────────── */}
        {t.showSplash && (
          <DCSection id="brand" title="Splash & brand mark" subtitle="The wordmark lockup that anchors the app">
            <DCArtboard id="splash" label="Splash · launch animation" width={402} height={874}>
              {frame(<ScreenSplash copy={copy} />)}
            </DCArtboard>
            <DCArtboard id="lockups" label="Brand lockups" width={402} height={874}>
              <div style={{ width: "100%", height: "100%", background: "var(--bg-primary)", padding: "100px 28px", display: "flex", flexDirection: "column", gap: 40 }}>
                <div>
                  <div className="t-label" style={{ marginBottom: 14 }}>HORIZONTAL · LARGE (SPLASH)</div>
                  <Lockup size="lg"/>
                </div>
                <div>
                  <div className="t-label" style={{ marginBottom: 14 }}>HORIZONTAL · MEDIUM (NAV)</div>
                  <Lockup size="md"/>
                </div>
                <div>
                  <div className="t-label" style={{ marginBottom: 14 }}>HORIZONTAL · SMALL (TOOLBAR)</div>
                  <Lockup size="sm"/>
                </div>
                <div>
                  <div className="t-label" style={{ marginBottom: 14 }}>MARK · STATES</div>
                  <div style={{ display: "flex", gap: 24, alignItems: "center" }}>
                    <BrandMark size={64} variant="cyan"/>
                    <BrandMark size={64} variant="magenta"/>
                    <BrandMark size={64} variant="green"/>
                  </div>
                  <div style={{ display: "flex", gap: 24, marginTop: 8 }}>
                    <span className="t-caption" style={{ width: 64, textAlign: "center" }}>default</span>
                    <span className="t-caption" style={{ width: 64, textAlign: "center" }}>pinned</span>
                    <span className="t-caption" style={{ width: 64, textAlign: "center" }}>caught</span>
                  </div>
                </div>
              </div>
            </DCArtboard>
          </DCSection>
        )}

        {/* ─────────── 01 · Onboarding ─────────── */}
        <DCSection id="onboarding" title="01 · Onboarding"
          subtitle={t.onboardingVariant === "A" ? "Variation A — Pilot HUD (clinical)" : "Variation B — Card collector (warm)"}>
          {t.onboardingVariant === "A" ? (
            <>
              <DCArtboard id="welcome-a" label="A1 · Welcome" width={402} height={874}>
                {frame(<OnboardingA_Welcome copy={copy}/>)}
              </DCArtboard>
              <DCArtboard id="perms-a" label="A2 · Permissions" width={402} height={874}>
                {frame(<OnboardingA_Permissions/>)}
              </DCArtboard>
              <DCArtboard id="cal-a" label="A3 · Compass calibration" width={402} height={874}>
                {frame(<OnboardingA_Calibration/>)}
              </DCArtboard>
              <DCArtboard id="handle-a" label="A4 · Pick a handle" width={402} height={874}>
                {frame(<HandleSetup/>)}
              </DCArtboard>
            </>
          ) : (
            <>
              <DCArtboard id="welcome-b" label="B1 · Welcome" width={402} height={874}>
                {frame(<OnboardingB_Welcome/>)}
              </DCArtboard>
              <DCArtboard id="perms-b" label="B2 · How it works" width={402} height={874}>
                {frame(<OnboardingB_Permissions/>)}
              </DCArtboard>
              <DCArtboard id="cal-b" label="B3 · Compass calibration" width={402} height={874}>
                {frame(<OnboardingA_Calibration/>)}
              </DCArtboard>
              <DCArtboard id="handle-b" label="B4 · Pick a handle" width={402} height={874}>
                {frame(<HandleSetup/>)}
              </DCArtboard>
            </>
          )}
        </DCSection>

        {/* ─────────── 02 · AR Home ─────────── */}
        <DCSection id="home" title="02 · AR Home"
          subtitle={t.homeVariant === "A" ? "Variation A — Clinical HUD (spec-faithful)" : "Variation B — Full pilot instruments (compass tape, pitch ladder)"}>
          <DCArtboard id="home-main" label={t.homeVariant === "A" ? "A · Tapped + pinned" : "B · Acquiring lock"} width={402} height={874}>
            {frame(t.homeVariant === "A" ? <ARHomeA copy={copy}/> : <ARHomeB/>)}
          </DCArtboard>
          {/* show the *other* variant alongside so they can be compared without toggling */}
          <DCArtboard id="home-alt" label={t.homeVariant === "A" ? "B · For comparison" : "A · For comparison"} width={402} height={874}>
            {frame(t.homeVariant === "A" ? <ARHomeB/> : <ARHomeA copy={copy}/>)}
          </DCArtboard>
        </DCSection>

        {/* ─────────── 02b · AR States ─────────── */}
        <DCSection id="ar-states" title="02b · AR Home — states"
          subtitle="Empty sky · multi-catch reward · compass caution · just-caught flash">
          <DCArtboard id="ar-empty" label="Empty sky · searching" width={402} height={874}>
            {frame(<ARStateEmpty/>)}
          </DCArtboard>
          <DCArtboard id="ar-multi" label="Multi-catch · combo reward" width={402} height={874}>
            {frame(<ARStateMultiCatch/>)}
          </DCArtboard>
          <DCArtboard id="ar-caution" label="Compass bad · calibrate" width={402} height={874}>
            {frame(<ARStateCompassBad/>)}
          </DCArtboard>
          <DCArtboard id="ar-caught" label="Just caught · +pts flash" width={402} height={874}>
            {frame(<ARStateJustCaught/>)}
          </DCArtboard>
        </DCSection>

        {/* ─────────── 03 · Catch flow ─────────── */}
        <DCSection id="catch" title="03 · Catch flow" subtitle="Review → card reveal → flip to dex → receipt. Multi-catch fans 3 cards.">
          <DCArtboard id="review" label="Catch · review sheet" width={402} height={874}>
            {frame(<CatchReview/>)}
          </DCArtboard>
          <DCArtboard id="confirmed" label="Card reveal · front" width={402} height={874}>
            {frame(<CatchConfirmed/>)}
          </DCArtboard>
          <DCArtboard id="cardback" label="Card flip · back" width={402} height={874}>
            {frame(<CatchCardBack/>)}
          </DCArtboard>
          <DCArtboard id="multi-reveal" label="Multi-catch · 3-card fan" width={402} height={874}>
            {frame(<MultiCatchReveal/>)}
          </DCArtboard>
          <DCArtboard id="receipt" label="Points receipt" width={402} height={874}>
            {frame(<XPReceiptScreen/>)}
          </DCArtboard>
        </DCSection>

        {/* ─────────── 04 · Detail ─────────── */}
        <DCSection id="detail" title="04 · Aircraft / Catch detail"
          subtitle={t.detailVariant === "A" ? "Variation A — Photo-led collector card" : "Variation B — Spec sheet / split-flap board"}>
          <DCArtboard id="detail-main" label={t.detailVariant === "A" ? "A · Photo-led" : "B · Spec sheet"} width={402} height={874}>
            {frame(t.detailVariant === "A" ? <DetailA/> : <DetailB/>)}
          </DCArtboard>
          <DCArtboard id="detail-alt" label={t.detailVariant === "A" ? "B · For comparison" : "A · For comparison"} width={402} height={874}>
            {frame(t.detailVariant === "A" ? <DetailB/> : <DetailA/>)}
          </DCArtboard>
        </DCSection>

        {/* ─────────── 05 · Hangar ─────────── */}
        <DCSection id="hangar" title="05 · Hangar (collection)"
          subtitle={t.hangarVariant === "A" ? "Variation A — Grouped list (spec recipe)" : "Variation B — Card grid (trading-card vibe)"}>
          <DCArtboard id="hangar-empty" label="Empty · first launch" width={402} height={874}>
            {frame(<HangarEmpty/>)}
          </DCArtboard>
          <DCArtboard id="hangar-main" label={t.hangarVariant === "A" ? "A · List" : "B · Grid"} width={402} height={874}>
            {frame(t.hangarVariant === "A" ? <HangarA/> : <HangarB/>)}
          </DCArtboard>
          <DCArtboard id="hangar-alt" label={t.hangarVariant === "A" ? "B · For comparison" : "A · For comparison"} width={402} height={874}>
            {frame(t.hangarVariant === "A" ? <HangarB/> : <HangarA/>)}
          </DCArtboard>
        </DCSection>

        {/* ─────────── 05b · Sets ─────────── */}
        <DCSection id="sets" title="05b · Sets · Pokédex-style"
          subtitle="Seven type sets to complete. Each set is a quest.">
          <DCArtboard id="sets-browser" label="Sets · by type" width={402} height={874}>
            {frame(<SetsScreen/>)}
          </DCArtboard>
          <DCArtboard id="set-detail" label="Set · Wide-body opened" width={402} height={874}>
            {frame(<SetDetail/>)}
          </DCArtboard>
        </DCSection>

        {/* ─────────── 06 · Game systems ─────────── */}
        <DCSection id="game" title="06 · Gamification — the spine"
          subtitle="5 rarity tiers · 7 types · trophies. Each visible to the player, no hidden math.">
          <DCArtboard id="rarity" label="Rarity · 5 tiers" width={402} height={874}>
            {frame(<RarityReferenceScreen/>)}
          </DCArtboard>
          <DCArtboard id="types" label="Types · 7 categories" width={402} height={874}>
            {frame(<TypesReferenceScreen/>)}
          </DCArtboard>
          <DCArtboard id="medals" label="Trophies · achievements" width={402} height={874}>
            {frame(<AchievementsScreen/>)}
          </DCArtboard>
          <DCArtboard id="trophy-unlock" label="Trophy unlock · tier up" width={402} height={874}>
            {frame(<TrophyUnlock/>)}
          </DCArtboard>
        </DCSection>

        {/* ─────────── 07 · Public / Leaderboard ─────────── */}
        <DCSection id="public" title="07 · Public surfaces"
          subtitle="Anonymous global leaderboard, shareable catch card, public hangar, world map.">
          <DCArtboard id="leaderboard" label="Leaderboard · global" width={402} height={874}>
            {frame(<LeaderboardScreen/>)}
          </DCArtboard>
          <DCArtboard id="map" label="Map · your sightings" width={402} height={874}>
            {frame(<MapView/>)}
          </DCArtboard>
          <DCArtboard id="share-card" label="Share · catch card" width={402} height={874}>
            {frame(<ShareCardScreen/>)}
          </DCArtboard>
          <DCArtboard id="public-hangar" label="Public hangar · visit" width={402} height={874}>
            {frame(<PublicHangarScreen/>)}
          </DCArtboard>
        </DCSection>

        {/* ─────────── 08 · Profile + Settings + Notifications ─────────── */}
        <DCSection id="profile" title="08 · Profile, Settings & Notifications" subtitle="Identity, stats, trophies, controls">
          <DCArtboard id="profile" label="Profile" width={402} height={874}>
            {frame(<ProfileScreen/>)}
          </DCArtboard>
          <DCArtboard id="settings" label="Settings" width={402} height={874}>
            {frame(<SettingsScreen/>)}
          </DCArtboard>
          <DCArtboard id="notifs" label="Notifications" width={402} height={874}>
            {frame(<NotificationsScreen/>)}
          </DCArtboard>
          <DCArtboard id="push" label="Rare push · lock screen" width={402} height={874}>
            {frame(<RarePushTap/>, true)}
          </DCArtboard>
        </DCSection>
      </DesignCanvas>

      {/* Tweaks panel */}
      <TweaksPanel title="Tweaks">
        <TweakSection label="Variant">
          <TweakRadio label="Onboarding"
            value={t.onboardingVariant}
            options={[{label: "Pilot HUD", value: "A"}, {label: "Collector", value: "B"}]}
            onChange={(v) => setTweak("onboardingVariant", v)}/>
          <TweakRadio label="AR Home"
            value={t.homeVariant}
            options={[{label: "Clinical", value: "A"}, {label: "Instruments", value: "B"}]}
            onChange={(v) => setTweak("homeVariant", v)}/>
          <TweakRadio label="Detail"
            value={t.detailVariant}
            options={[{label: "Photo-led", value: "A"}, {label: "Spec sheet", value: "B"}]}
            onChange={(v) => setTweak("detailVariant", v)}/>
          <TweakRadio label="Hangar"
            value={t.hangarVariant}
            options={[{label: "List", value: "A"}, {label: "Grid", value: "B"}]}
            onChange={(v) => setTweak("hangarVariant", v)}/>
        </TweakSection>

        <TweakSection label="Theme">
          <TweakColor label="Accent" value={t.accent}
            options={ACCENT_OPTIONS}
            onChange={(v) => setTweak("accent", v)}/>
          <TweakRadio label="Density"
            value={t.density}
            options={[{label:"Dense", value:"dense"}, {label:"Regular", value:"regular"}, {label:"Airy", value:"airy"}]}
            onChange={(v) => setTweak("density", v)}/>
          <TweakRadio label="Card holo"
            value={t.holo}
            options={[{label:"Off", value:"off"}, {label:"Subtle", value:"subtle"}, {label:"Vivid", value:"vivid"}]}
            onChange={(v) => setTweak("holo", v)}/>
        </TweakSection>

        <TweakSection label="Voice & copy">
          <TweakRadio label="Tone"
            value={t.tone}
            options={[{label:"Pilot", value:"pilot"}, {label:"Casual", value:"casual"}, {label:"Avgeek", value:"avgeek"}]}
            onChange={(v) => setTweak("tone", v)}/>
        </TweakSection>

        <TweakSection label="Show">
          <TweakToggle label="Splash & brand section" value={t.showSplash} onChange={(v) => setTweak("showSplash", v)}/>
        </TweakSection>
      </TweaksPanel>
    </>
  );
}

const root = ReactDOM.createRoot(document.getElementById("root"));
root.render(<App/>);
