#!/usr/bin/env node
/**
 * Tailspot content engine — one ready-to-post carousel per run.
 *
 *   node --experimental-strip-types src/cli.ts [options]
 *   npm run generate -- [options]
 *
 * Options
 *   --template <id>     real-catches | rare-now | over-city | guess-plane (default: rotate by --date)
 *   --date YYYY-MM-DD   post date; drives rotation + seeded choices (default: today, UTC)
 *   --out <dir>         output directory (default: out/<date>-<template>)
 *   --dry-run           fetch/select and print the plan as JSON; no rendering
 *   --fixture           use fixtures/<template>.json instead of the network
 *   --fixture-path <f>  use a specific fixture file (implies --fixture)
 *   --save-fixture <f>  after a live fetch, save the raw inputs as a fixture
 *                       (the requested/rotated template's, even if it then falls back)
 *   --city <id>         over-city: force a city (sf-bay, london, nyc, tokyo, sydney, bali)
 *   --catch <id>        guess-plane: force a photo (b737, b767, a321, a220, bd700)
 *   --no-stats          don't call Tailspot's /v1/stats
 *   --keep-html         also write each slide's HTML (debugging)
 */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join, relative, resolve } from "node:path";
import { parseArgs } from "node:util";
import { DEFAULT_OUT_DIR, ENGINE_DIR, FIXTURES_DIR } from "./paths.ts";
import { fetchStats, type TailspotStats } from "./tailspot.ts";
import { fallbackChain, templateById, templateForDay } from "./templates/index.ts";
import { NoSubjectError, type BuildContext, type DataSource, type Fixture, type Post, type Template } from "./types.ts";
import { dayIndex, todayUtc } from "./util.ts";

const { values: args } = parseArgs({
  options: {
    template: { type: "string" },
    date: { type: "string" },
    out: { type: "string" },
    "dry-run": { type: "boolean", default: false },
    fixture: { type: "boolean", default: false },
    "fixture-path": { type: "string" },
    "save-fixture": { type: "string" },
    city: { type: "string" },
    catch: { type: "string" },
    "no-stats": { type: "boolean", default: false },
    "keep-html": { type: "boolean", default: false },
    help: { type: "boolean", short: "h", default: false },
  },
  strict: true,
});

const log = (...m: unknown[]) => console.error("[content-engine]", ...m);

interface Loaded {
  template: Template<any>;
  params: Record<string, unknown>;
  raw: unknown;
  sources: DataSource[];
  capturedAt: Date;
  stats: TailspotStats | null;
  sample: boolean;
  fixturePath: string | null;
}

async function loadLive(t: Template<any>, params: Record<string, unknown>): Promise<Loaded> {
  const { raw, sources } = await t.fetch(params);
  const stats = args["no-stats"] ? null : await fetchStats();
  if (stats) sources.push({ name: "Tailspot /v1/stats", url: "https://api.tailspot.app/v1/stats", fetchedAt: new Date().toISOString() });
  return { template: t, params, raw, sources, capturedAt: new Date(), stats, sample: false, fixturePath: null };
}

function loadFixture(t: Template<any>, path: string): Loaded {
  const fx = JSON.parse(readFileSync(path, "utf8")) as Fixture;
  if (fx.template !== t.id) throw new Error(`fixture ${path} is for "${fx.template}", not "${t.id}"`);
  return {
    template: t,
    params: fx.params ?? {},
    raw: fx.raw,
    sources: fx.sources ?? [],
    capturedAt: new Date(fx.capturedAt),
    stats: fx.tailspotStats ?? null,
    sample: fx.synthetic === true,
    fixturePath: path,
  };
}

function saveFixture(path: string, l: Loaded) {
  const fx: Fixture = {
    template: l.template.id,
    capturedAt: l.capturedAt.toISOString(),
    synthetic: false,
    params: l.params,
    raw: l.raw,
    sources: l.sources,
    tailspotStats: l.stats,
  };
  writeFileSync(path, JSON.stringify(fx, null, 1) + "\n");
  log(`saved fixture → ${path}`);
}

async function main() {
  if (args.help) {
    console.log(readFileSync(new URL(import.meta.url), "utf8").split("*/")[0]);
    return;
  }
  const date = args.date ?? todayUtc();
  const day = dayIndex(date);
  const explicit = args.template ? templateById(args.template) : null;
  let template = explicit ?? templateForDay(day);
  const useFixture = args.fixture || !!args["fixture-path"];

  const paramsFor = (t: Template<any>) => {
    const p = { ...t.params(day) };
    if (args.city && t.id === "over-city") p.city = args.city;
    if (args.catch && t.id === "guess-plane") p.catchId = args.catch;
    return p;
  };

  const ctxFor = (l: Loaded): BuildContext => ({
    date,
    dayIndex: day,
    seed: `${date}:${l.template.id}`,
    capturedAt: l.capturedAt,
    stats: l.stats,
    sample: l.sample,
    params: l.params,
  });

  let loaded!: Loaded;
  let post!: Post;
  let fallbackFrom: string | null = null;
  if (useFixture) {
    loaded = loadFixture(template, args["fixture-path"] ?? join(FIXTURES_DIR, `${template.id}.json`));
    // guess-plane's "data" is just which of Noah's photos to use, so it can be
    // swapped; a city fixture holds that city's aircraft and cannot.
    if (args.catch && template.id === "guess-plane") {
      loaded.raw = { catchId: args.catch };
      loaded.params = { ...loaded.params, catchId: args.catch };
    }
    if (args.city && template.id === "over-city" && args.city !== loaded.params.city) {
      throw new Error(`fixture holds data for "${loaded.params.city}", not "${args.city}"`);
    }
    post = template.build(loaded.raw, ctxFor(loaded));
  } else {
    // Rotated runs walk the fallback chain (real-catches → rare-now →
    // guess-plane) when a template can't fetch or finds nothing worth posting.
    // An explicit --template never falls back.
    const chain = [template, ...(explicit ? [] : fallbackChain(template.id))];
    for (let i = 0; i < chain.length; i++) {
      const t = chain[i];
      const last = i === chain.length - 1;
      let l: Loaded;
      try {
        l = await loadLive(t, paramsFor(t));
      } catch (e) {
        if (last) throw e;
        log(`live fetch for ${t.id} failed (${(e as Error).message}); falling back to ${chain[i + 1].id}`);
        fallbackFrom ??= t.id;
        continue;
      }
      if (args["save-fixture"] && i === 0) saveFixture(args["save-fixture"], l);
      try {
        post = t.build(l.raw, ctxFor(l));
      } catch (e) {
        // Only "nothing worth posting" falls back; a real bug should fail loudly.
        if (!(e instanceof NoSubjectError) || last) throw e;
        log(`${t.id}: ${e.message}; falling back to ${chain[i + 1].id}`);
        fallbackFrom ??= t.id;
        continue;
      }
      loaded = l;
      template = t;
      break;
    }
  }

  const summary = {
    template: template.id,
    label: template.label,
    date,
    fallbackFrom,
    params: loaded.params,
    dataCapturedAt: loaded.capturedAt.toISOString(),
    sample: loaded.sample,
    hook: post.hook,
    hashtags: post.hashtags,
    subject: post.subject,
    sources: loaded.sources,
    tailspotStats: loaded.stats,
  };

  if (args["dry-run"]) {
    console.log(JSON.stringify({ ...summary, caption: post.caption, slides: post.slides.map((s) => s.name) }, null, 2));
    return;
  }

  const outDir = resolve(args.out ?? join(DEFAULT_OUT_DIR, `${date}-${template.id}`));
  mkdirSync(outDir, { recursive: true });
  const { renderSlides } = await import("./render.ts"); // Playwright only when rendering
  const files = await renderSlides(post.slides, { outDir, sample: loaded.sample, seed: `${date}:${template.id}`, keepHtml: args["keep-html"] });

  writeFileSync(join(outDir, "caption.txt"), `${post.caption}\n\n${post.hashtags.join(" ")}\n`);
  const postJson = {
    version: 1,
    ...summary,
    generatedAt: new Date().toISOString(),
    // A synthetic fixture must never be posted. A replay of a real LIVE
    // capture is stale ("right now" was then), so only guess-plane — whose
    // data is a fixed, real catch — stays postable from a fixture.
    postable: !loaded.sample && (!loaded.fixturePath || !template.needsNetwork),
    fixture: loaded.fixturePath ? relative(ENGINE_DIR, loaded.fixturePath) : null,
    caption: post.caption,
    slides: files.map((f, i) => ({ file: basename(f), alt: post.altText[i] ?? "" })),
    platforms: {
      tiktok: { mode: "draft", note: "API posts land as drafts until TikTok's app audit; add a sound and publish by hand." },
      instagram: { mode: "auto", format: "carousel" },
      youtube: { mode: "auto", format: "shorts", note: "Shorts needs video: slideshow the PNGs (Postiz or ffmpeg) before upload." },
    },
    privacy:
      post.privacyNote ??
      "Public ADS-B (adsb.lol, ODbL) + Tailspot public aggregate count + Noah's own catch photos only. No user photos, user catch GPS, or user handles. LADD/PIA and privately operated aircraft never spotlighted; positions named at region level.",
  };
  writeFileSync(join(outDir, "post.json"), JSON.stringify(postJson, null, 2) + "\n");
  log(`${template.id}${fallbackFrom ? ` (fallback from ${fallbackFrom})` : ""}: ${files.length} slides → ${outDir}`);
  console.log(outDir);
}

main().catch((e) => {
  log(`FAILED: ${(e as Error).stack ?? e}`);
  process.exitCode = 1;
});
