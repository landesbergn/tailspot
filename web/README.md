# tailspot-www

Static site for tailspot.app — landing page, privacy policy, terms of service, and attributions.

## Structure

```
web/
  public/          # hand-written HTML + CSS (no build step)
    index.html
    privacy.html
    terms.html
    attributions.html
    support.html
    style.css
    img/           # real catch photos + the social preview card
  Dockerfile       # nginx:alpine serving public/ on :8080
  nginx.conf       # port 8080, gzip, cache headers
  fly.toml         # Fly.io config — app: tailspot-www, region: sjc
```

## Images

`public/img/` holds Noah's own catch photographs, exported from
`marketing/catch-photos/` at 900px wide (~175 KB for all five) plus a
1200x630 `og-image.jpg` for social previews.

The hero cycles them with the ADS-B the app actually recorded for each shot.
It used to be a pure-CSS HUD mockup rotating **invented** flights — Emirates,
BA, Lufthansa — none of which were ever caught. Don't reintroduce fabricated
flights here: the site's only claim is that the identification is real, and
the photos are the evidence.

To refresh them, re-run the resize from `marketing/catch-photos/` and keep the
`.catch-frame` aspect ratio (900/567) in sync with `style.css` — the
single-screen height budget is computed from it.

## Deploy

```sh
cd web
flyctl deploy --remote-only
```

No CI deploy wiring — run the above command from `web/` to push an update.
The app scales to zero when idle (`auto_stop_machines = true`).

## DNS (Namecheap)

After first deploy, add A/AAAA records from `flyctl ips list -a tailspot-www`.
See PR description for the exact host/value pairs.
