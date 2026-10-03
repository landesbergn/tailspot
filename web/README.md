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
  nginx.conf       # port 8080, gzip, cache headers, /c/CODE routing
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

## The catch counter

The hero's "N planes caught so far" line is the site's one live number. It is
fetched from `GET https://api.tailspot.app/v1/stats` (see `backend/README.md`),
which answers only when the browser's `Origin` is this site and caches the
count for five minutes. The line reserves its height from first paint and
fades in when the number arrives; if the fetch fails it stays invisible —
never a zero. The count-up starts at 92% of the total rather than 0 so it
doesn't read as a slot machine.

Because the API decides by `Origin`, a local `python3 -m http.server` preview
gets a 404 and an invisible line. The Fly preview site
(`tailspot-www-preview.fly.dev`) is allowlisted, so staging there shows the
real number. For a local preview, mock the request (Playwright `page.route`)
or add your local origin to the backend's `STATS_ALLOWED_ORIGINS`.

## Challenge invite links (universal links)

Two routes serve `https://tailspot.app/c/CODE`, the challenge invite link the
app shares:

- **`/.well-known/apple-app-site-association`** — the file iOS reads to learn
  that `/c/*` belongs to the Tailspot app (team `G9FJX2A5TA`, bundle
  `com.landesberg.Tailspot`). It lives at `public/.well-known/` with no file
  extension, so `nginx.conf` serves it with `default_type application/json`
  and `no-cache`. It must be reachable over **https with no redirect** —
  not even `www` → apex — or iOS quietly ignores the association.
- **`/c/CODE`** — a 302 to the App Store listing (attributed to the
  `Challenge Invite` campaign). This is the fallback: on an iPhone with
  Tailspot installed, iOS opens the app and nginx never sees the request.
  The pattern is the invite alphabet exactly — 6 characters (or 8, for
  codes issued before 2026-09-26) from A–Z
  minus `I`, `L`, `O` plus `2`–`9`, case-insensitive, optional trailing
  slash — so a code that could never exist (`/c/K7M4QD2O`, `/c/short`)
  falls through to the 404 page instead of a pointless App Store trip.
  The regex is **quoted** because nginx reads a bare `{6}` as the start of
  a config block and refuses to start. There is no landing page by design.
- **`/c/CODE` for link-preview crawlers** — WhatsApp, Slack, Discord,
  Telegram, X, Facebook, LinkedIn, Skype, Pinterest and Reddit fetch a
  pasted link themselves; following the 302 they used to show the generic
  App Store page. A `map` on `$http_user_agent` (`$is_preview_bot`) sends
  just those requests, via `rewrite … last` into the internal
  `/_invite-card/` location, to `https://api.tailspot.app/v1/invites/CODE/card`
  — an HTML page of Open Graph tags (challenge name, creator, window,
  spotter count, `img/og-image.jpg`) with a meta refresh to the same App
  Store URL. People never see it; iMessage doesn't need it (the app hands
  it `LPLinkMetadata`). Googlebot is deliberately not in the list. If the
  API errors, 404s (www deployed before the API) or times out, nginx falls
  back to the same 302. `proxy_pass` names the host literally, so nginx
  resolves `api.tailspot.app` once at startup (no `resolver` needed) and
  **won't start if that lookup fails**. To check after a deploy:
  `curl -s -A WhatsApp/2 https://tailspot.app/c/CODE | grep og:` (tags),
  and without `-A` (still the 302).

`.well-known` is a dot-directory, which `COPY public/ /usr/share/nginx/html/`
in the Dockerfile does include (a directory source copies its contents,
dotfiles and all — there is no `.dockerignore` here). If you ever add one,
don't let it swallow `.well-known`.

**Apple's CDN caches the association file.** After a deploy, iOS devices may
keep using the old copy for hours. What Apple currently serves is visible at
`https://app-site-association.cdn-apple.com/a/v1/tailspot.app`; the origin is
`curl -sI https://tailspot.app/.well-known/apple-app-site-association`
(expect `200` and `content-type: application/json`, never a `301`). A device
re-fetches on install and on app update, so the reliable test after a change
is delete-and-reinstall rather than waiting.

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
