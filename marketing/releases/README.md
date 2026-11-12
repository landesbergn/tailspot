# App Store marketing releases

One folder per App Store version: exactly what was (or will be) uploaded to
App Store Connect. Screenshots are the iPhone set: 1284 × 2778 through v1.2.2,
1206 × 2622 (6.3") plus 1320 × 2868 (6.9") from v1.2.5 (App Store Connect rejected 1284 × 2778 on 2026-11-10);
creative assets (header, search results) start with v1.2.2.

To add the next one, export the deck and the creative assets, then:

```bash
bin/marketing-release vX.Y.Z
```

That copies the current set here, writes the folder README stub, and adds a
row below. Flip the status once it's uploaded. Screenshots lock in App Store
Connect when a version is submitted, so a set packaged after submission
belongs to the next version.

| Version | Date | Status | What changed |
|---|---|---|---|
| [v1.0.0](v1.0.0/) | 2026-07-21 | shipped (live 2026-08-08, build 83) | First listing. Slides 1–3 on a stylized dusk sky. |
| [v1.1.0](v1.1.0/) | 2026-08-20 | shipped (live 2026-08-29, build 89) | Real catch photography throughout; real field capture on slide 1. |
| [v1.1.1](v1.1.1/) | 2026-09-13 | shipped (live 2026-09-14, build 94) | Slides 2–6 re-captured for the new card frames, units and sets. |
| [v1.2.0](v1.2.0/) | 2026-10-02 | packaged for 1.2.0 (live 2026-10-03); upload not recorded | Slide 7 (Challenges); slide 2 fill and slide 3 crop fixes. Still the live set for 1.2.1. |
| [v1.2.2](v1.2.2/) | 2026-10-12 | shipped (live 2026-10-12, build 107) | Fleet Week slides 1–2 (C-27J over the Golden Gate, Legendary E-6); first header and search results assets. |
| [v1.2.5](v1.2.5/) | 2026-11-11 | uploaded 2026-11-11 (1.2.5 not submitted yet) | New slides 1–2 for tracker searchers (E-6 "What's that plane?", L-39 "Every catch goes into your Hangar"); slides 3–7 redrawn as illustrations close to the app (guess round, Sets tab, trophy unlock, podium, challenge push); one look, no device frames. **1206 × 2622**: App Store Connect rejected 1284 × 2778 for this slot. New header and search results images: a hand of five real catch cards with the Legendary E-6 in front. Rendered from `source/deck.html` and `source/creative.html`, not the deck editor. |
