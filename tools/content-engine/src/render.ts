/**
 * HTML → PNG via Playwright Chromium. One browser, one page, one screenshot
 * per slide. In the cloud agent env Chromium is preinstalled under
 * PLAYWRIGHT_BROWSERS_PATH (/opt/pw-browsers); never `playwright install`.
 */

import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright";
import { H, page as wrap, W } from "./slides.ts";
import type { Slide } from "./types.ts";

export interface RenderOptions {
  outDir: string;
  sample: boolean;
  seed: string;
  /** Also write each slide's HTML next to the PNG (debugging). */
  keepHtml?: boolean;
}

export async function renderSlides(slides: Slide[], o: RenderOptions): Promise<string[]> {
  const browser = await chromium.launch();
  try {
    const ctx = await browser.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
    const pg = await ctx.newPage();
    const files: string[] = [];
    for (let i = 0; i < slides.length; i++) {
      const html = wrap(slides[i].html, { index: i + 1, total: slides.length, sample: o.sample, seed: `${o.seed}:${i}` });
      const base = `slide-${String(i + 1).padStart(2, "0")}-${slides[i].name}`;
      if (o.keepHtml) writeFileSync(join(o.outDir, `${base}.html`), html);
      await pg.setContent(html, { waitUntil: "load" });
      await pg.evaluate(() => document.fonts.ready);
      const file = join(o.outDir, `${base}.png`);
      await pg.screenshot({ path: file, type: "png", fullPage: false });
      files.push(file);
    }
    return files;
  } finally {
    await browser.close();
  }
}
