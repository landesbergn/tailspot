# Remote incident response: a Claude Code cloud environment for Tailspot

Scope (Noah, 2026-10-19, item 2 after the unalerted feed outage): a cloud
environment on claude.ai/code that can diagnose and fix a production incident
from a phone or any browser when the laptop is closed. This is the researched
plan, not yet executed. Sources are the Claude Code docs
(https://code.claude.com/docs); items marked *unverified* are inferences.

## What the cloud can and cannot do today

- **Where it is configured:** claude.ai/code → environment → *Edit cloud
  environment*: network access, env vars (`.env` format), setup script.
  Sessions start from the Code tab in the Claude app or claude.ai/code and
  persist; idle sessions are reclaimed (history restored, background
  processes lost).
- **Secrets:** env vars are readable by anyone using the environment. The docs
  recommend *network secrets* (a proxy attaches the key to requests for listed
  hosts, so the key never enters the VM). *Unverified:* whether `flyctl`
  accepts a proxy-injected token, since it reads `FLY_API_TOKEN` itself.
- **Setup script:** runs as root on Ubuntu 24.04, cached if it finishes in
  about five minutes. `gh` is preinstalled; `flyctl` is not, so the script
  installs it. Mid-session installs do not persist.
- **Network:** levels None / Trusted / Custom / Full. Trusted does NOT include
  fly.io, sentry.io or PostHog hosts. Use Custom with those hosts (watch for
  `403 host_not_allowed` to find exact hostnames) or Full.
- **MCP:** a committed `.mcp.json` loads in single-repo cloud sessions; claude.ai
  connectors are available by default and need no allowlist entry. *Unverified:*
  whether this account's Sentry and PostHog MCP servers reach cloud sessions as
  connectors; reconnect at claude.ai/customize/connectors if not.
- **Permissions:** cloud sessions run in Accept edits, Plan or Auto (no
  Bypass). A committed `.claude/settings.json` applies; `~/.claude/settings.json`
  and `settings.local.json` do not. The repo's `.claude/settings.json` is
  currently gitignored, so it must be un-ignored and committed to take effect.
- **Triggers:** *scheduled tasks* (claude.ai/code/routines) have an **API
  trigger** — a POST to a per-task `/fire` endpoint with a bearer token and an
  optional `text` body. That is the alert-driven pattern. Fired text is wrapped
  as untrusted, so alert-driven runs should stay diagnosis-only (read logs,
  open a draft PR, never deploy). *Unverified:* whether a Sentry alert webhook
  can send the required `Authorization` header. Remote Control only works while
  the laptop is on.
- **Limits:** foreground commands time out at 2 min by default (raise with
  `BASH_DEFAULT_TIMEOUT_MS`, up to 10); `gh pr`/`gh issue` fail behind the
  GitHub proxy (GraphQL) — use `gh api`; scheduled fires are capped hourly.

## Recommended setup (in order)

1. **Environment:** Custom network access listing the Fly API hosts, Sentry and
   PostHog (keep the default list). Setup script installs `flyctl`; confirm it
   caches.
2. **Fly token:** try it as a network secret first; if `flyctl` rejects that,
   use a dedicated, scoped, rotatable `FLY_API_TOKEN` env var and accept that
   environment users can read it (Noah is the only user). Prefer the Sentry
   connector over a Sentry token.
3. **Connectors:** confirm Sentry and PostHog appear inside a cloud session.
4. **Permissions:** un-ignore and commit `.claude/settings.json`. Allow the
   read-only commands (`fly logs`, `fly status`, `fly machine status`,
   `gh api`); set `ask` for `fly deploy` so a deploy is a phone prompt, not a
   block. Keep the CLAUDE.md rule: prod deploys only on an explicit go-ahead.
5. **Alert-driven task:** create one API-trigger scheduled task whose prompt
   investigates the fired payload, pulls Fly logs and Sentry, and opens a draft
   `claude/` PR without deploying. Point the Sentry uptime issue rule (or a
   small relay) at its `/fire` URL if the header question resolves.
6. **Dry run from the phone:** *Run now*, then a real session that runs
   `fly logs -a tailspot-api` and `curl https://api.tailspot.app/readyz`. Watch
   for host 403s and GraphQL rejections.

## Why this is the right scope

The outage was diagnosable in minutes from the Fly log (`adsblol returned HTTP
429`, `airplaneslive returned HTTP 403`) and fixable with one CLI command (a
static egress IP). A cloud session with `flyctl`, Sentry and PostHog reach, and
a readiness URL that tells the truth (`/readyz`, this round) is enough to do
that from anywhere.
