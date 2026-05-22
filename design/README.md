# Tailspot design canvas

HTML/JSX prototype handoff from Claude Design covering 33 artboards across 10 sections (splash, onboarding, AR home + states, catch flow, detail, hangar, sets, gamification, public surfaces, profile/settings/notifs). Source for the iOS visual direction — not production code.

## Open it

The prototype loads JSX via Babel-in-browser with relative `<script src>`, so it needs to be served over HTTP. From the repo root:

```sh
python3 -m http.server 4173 --directory design
open http://127.0.0.1:4173/
```

Babel-standalone will recompile the JSX on every load — first paint is slow (~1–2s), subsequent panning around the canvas is cheap.

## What's in the bundle

- `index.html` — entry point; pulls in React/ReactDOM/Babel from unpkg and loads the local JSX modules in order
- `brand.css` — design tokens mirroring `ios/Tailspot/Tailspot/Brand.swift`
- `app.jsx` — the canvas itself; one `<DCArtboard>` per screen, organized by `<DCSection>`
- `brand-atoms.jsx` / `ios-frame.jsx` / `design-canvas.jsx` / `tweaks-panel.jsx` — chrome
- `game-systems.jsx` / `game-trophies.jsx` — rarity, types, PokeCard, trophy components
- `screens/*.jsx` — one file per screen group (onboarding, AR + catch, AR states, detail/hangar/profile, game-social, final-moments)

## Tweaks panel

Top-right of the canvas. Drives accent color, density, card holo intensity, copy tone (pilot/casual/avgeek), and per-section variants (onboarding A/B, AR home clinical/instruments, detail photo-led/spec-sheet, hangar list/grid). Changes propagate live across every artboard.

## Porting to SwiftUI

Per the original handoff README: this is a prototype, not production code — recreate the visual output, don't port the JSX structure. Color tokens already match `Brand.swift`. Order of work is open; sequence per priority in `PLAN.md` §9.
