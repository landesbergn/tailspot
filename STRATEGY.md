---
name: Tailspot
last_updated: 2026-06-18
---

# Tailspot Strategy

## Target problem

You see a plane crossing the sky and wonder what it is — the type, the airline, where it's coming from and where it's headed — but the moment passes in seconds. The hard part: the answer has to arrive *in that moment* and be about the specific plane you can actually see overhead, not dots on a map you hunt through — and it should only count when you genuinely saw it outdoors, not a plane that's merely overhead while you're indoors.

## Our approach

Make the catch real first, then make it a game. The foundation is identification you can trust — point your phone at the sky and it locks onto the actual plane in view, earned only by genuinely seeing it outdoors. On top of that real catch we build a collection game — catch, learn, share, unlock — so looking up stops being a one-off lookup and becomes a hobby worth returning to. If the catch isn't real the game is moot; the authenticity is what makes collecting feel earned, social, and defensible.

## Who it's for

**Primary:** Plane-curious enthusiasts / avgeeks — people who already look up when they hear a jet and find planes interesting. They're hiring Tailspot to turn the planes they already notice into a collection they can identify, learn about, and show their friends — without needing a spot at the airport fence or a long lens.

**Secondary:** Casual onlookers — someone who spots an unusual plane and just wants to know what it is. A gateway audience: accessible enough that mild curiosity can grow into the hobby through what they learn catching planes. The primary drives depth features; this audience keeps the funnel open.

## Key metrics

- **Catch confirmation rate** — share of capture attempts that produce an ID the user keeps and trusts (vs. abandoned, deleted, or reported wrong). The north-star for "is the catch real." *PostHog funnel + qualitative until a ground-truth confirm step exists.*
- **Catches per weekly-active spotter** — use intensity; leading. *PostHog.*
- **DAU/WAU stickiness ratio** — habit / returning behavior; leading. *PostHog.*
- **Week-4 retention of activated users** — of those who caught ≥1 plane, the share still spotting a month later; lagging. *PostHog cohort.*
- **Collection depth per active user** — unique aircraft types / sets advanced over time; can regress if catching stalls. *SwiftData today, backend later.*

## Tracks

### Real-catch engine

Identification you can trust: AR projection accuracy, visual confirmation (Vision/CV), data coverage & quality, and the in-frame + outdoor authenticity bar. It improves through a field-feedback loop — active session capture by testers (and willing TestFlight users) plus passive signals from everyone else — never by asking ordinary users to debug.

_Why it serves the approach:_ this is Bet A, the foundation the whole app rests on; it only earns trust if real-world sessions feed back into improving it without burdening the people just trying to catch planes.

### Collection & progression

The game that makes catching compulsive: catch flow, hangar, sets, rarity, trophies, and making the collectible cards exciting (medium TBD).

_Why it serves the approach:_ this is Bet B — it pulls people deeper than a one-off lookup and is the reason they come back.

### Social & sharing

What makes the hobby exciting and defensible: sharing catches with friends, leaderboards, public hangars.

_Why it serves the approach:_ turns a solo lookup into a social hobby and is where defensibility comes from.

### Backend & data platform

The server that makes the rest possible: ADS-B caching and coverage, sync, leaderboard infrastructure, push, curated rarity tables.

_Why it serves the approach:_ cross-cutting enabler for the real-catch engine's coverage and for social/progression at scale.

## Not working on

- **Monetization** — the app is free for now; revenue is deferred.
- **Android** — iOS-first and only for now.
- **A web app** — iOS-first and only; no companion web experience.

## Marketing

**One-liner:** Catch the planes flying over you.

**Key message:** Every catch is a plane you actually saw — overhead, outdoors — and yours to identify, collect, and share.
