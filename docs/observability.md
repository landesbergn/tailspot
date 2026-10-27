# Observability: the read-only cloud environment

How the claude.ai/code **debugging and analytics** environment is set up, how to
query PostHog, Sentry, and Fly from it with `bin/obs`, and the traps that make
Tailspot numbers wrong. The rules for what a cloud session may do are in
CLAUDE.md "Cloud sessions"; this file is the how-to.

## Environment setup (claude.ai/code → environment selector → New environment)

| Setting | Value |
|---|---|
| Name | `tailspot-observe` |
| Network access | **None**. Hosts that carry a network secret are still reachable; nothing else is, so data read from prod can't be sent anywhere except back to those hosts and GitHub. |
| Setup script | none (`jq` and `curl` are in the base image) |
| Environment variables | `TAILSPOT_NOAH_PERSON_ID=<Noah's PostHog person_id>` and `TAILSPOT_NOAH_DISTINCT_ID=<his iPhone's distinct_id>`. Not secrets, but kept out of this public repo. |
| Network secrets | the three below |

Each network secret: **Name**, **Allowed websites**, and one **Custom header**
row (Name `Authorization`, a Prefix, and the key as Value). The proxy adds the
header after the request leaves the VM; the key can't be viewed again after
saving, and it never appears in the session's environment or files.

### PostHog: personal API key, read scopes only

PostHog → Settings → Account → Personal API keys → Create. Scope it to the
**Tailspot project only** and pick only `:read` scopes: `query:read` (needed for
`posthog-sql`), plus `person:read`, `session_recording:read`, `insight:read`,
`dashboard:read`, `feature_flag:read`, `event_definition:read`,
`property_definition:read` as wanted.

- Allowed websites: `us.posthog.com`
- Header: `Authorization`, Prefix `Bearer`

### Sentry: user auth token, read scopes only

sentry.io → User settings → Personal Tokens → Create. Scopes: `org:read`,
`project:read`, `team:read`, `event:read`. Nothing with `write` or `admin`.

- Allowed websites: `sentry.io`, `*.sentry.io`
- Header: `Authorization`, Prefix `Bearer`

### Fly: org read-only token

```
fly tokens create readonly personal --name claude-cloud-readonly --expiry 2160h
```

The output already starts with `FlyV1 `, which is the scheme the logs endpoint
requires (it 401s on `Bearer`; the Machines API accepts either).

- Allowed websites: `api.fly.io`, `api.machines.dev`
- Header: `Authorization`, **Prefix cleared**, Value = the whole output
  including `FlyV1 `
- Expiry is 90 days: note the date and rotate it. Revoke with
  `fly tokens revoke <id>` (`fly tokens list` shows ids).

### First-session check

The SessionStart hook runs `bin/obs check` and reports `ok`/`FAILED` per source.
On a new or re-keyed environment, also confirm `env | grep -iE 'posthog|sentry|fly'`
shows no key. Untested assumptions to confirm on the first run: that the
read-only Fly token can read logs (`fly-logs`), and that PostHog accepts the
query endpoint with only `query:read`.

## `bin/obs` recipes

```
bin/obs check
bin/obs posthog-sql "select event, count() from events where timestamp > now() - interval 1 day group by event order by 2 desc limit 20"
bin/obs posthog "session_recordings/?limit=5"
bin/obs sentry "organizations/noah-lc/issues/?query=is:unresolved&statsPeriod=24h"
bin/obs sentry "organizations/noah-lc/issues/<id>/events/latest/"
bin/obs fly-machines tailspot-api
bin/obs fly-logs tailspot-api            # then: bin/obs fly-logs tailspot-api <next_token>
```

- Fly apps: `tailspot-api` (backend), `tailspot-www`, `tailspot-www-preview`,
  `tailspot-db`. Backend log lines are pino JSON; `fly-logs` returns a recent
  window, paged forward with `next_token`.
- Sentry: org `noah-lc`, one project, `broken-darkness-5055` = the backend.
  The feed alerters use the fingerprints `position-feed-fallback` (degraded)
  and `position-feed-outage` (users get 503). The uptime monitor watches
  `https://api.tailspot.app/readyz`.
- PostHog: project 466448, US cloud. The query endpoint can be slow; `bin/obs`
  allows 60 s.

## Traps that make Tailspot numbers wrong

- **Exclude Noah before any per-user number.** Filter
  `person_id != '$TAILSPOT_NOAH_PERSON_ID'` (the full UUID, never a short
  prefix) and/or `properties.$app_build not in ('1', '1.0')`: only his phone
  runs `bin/deploy` dev builds, so build 1 / 1.0 is him.
- **HogQL datetime literals are Pacific**, the project timezone. A UTC window
  silently returns nothing and looks like missing data. Write times in Pacific
  or wrap with `toTimeZone`.
- **Missing events don't prove nothing happened.** Whole field sessions can be
  absent (connectivity). Run a coarse per-`distinct_id` count over the whole
  day before concluding anything from absence.
- **TestFlight events are mixed into prod, on purpose.** Leave them in by
  default, but split on `properties.$is_testflight` before quoting a per-user
  rate (testers are a much bigger share of persons than of events), and say
  which basis a number uses.
- **Apple review and compatibility devices inflate the new-user cohort.**
  Before any activation or first-session number, drop sessions located in
  Cupertino/Sunnyvale or US with no city, fresh installs of superseded builds,
  and single-session zero-catch devices with the compass stuck at exactly 89°
  or 180°.
- **Dev builds are slower.** Debug builds (`$app_build = '1.0'`) snap several
  times slower than Release; filter them out of `catch_pipeline_timing` before
  comparing versions.
- **`catch_performed` with null rarity is a duplicate re-catch,** not an Unknown
  aircraft. Filter `properties.rarity IS NOT NULL`, and pair each catch with its
  `catch_uploaded`; a real catch with no upload means the upload failed.
- **Built-in event definitions aren't ingested events.** Confirm with a count
  (and `$app_version`) before claiming an event is duplicated or dead.
