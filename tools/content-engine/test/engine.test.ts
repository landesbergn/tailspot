/**
 * Data selection + formatting tests, all offline against fixtures/.
 * Run: npm test  (node:test via --experimental-strip-types)
 */

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, test } from "node:test";
import { normalize, type Plane } from "../src/adsb.ts";
import { designator, displayName, typeInfo } from "../src/aircraftTypes.ts";
import { CATCHES } from "../src/catches.ts";
import { regionFor } from "../src/geo.ts";
import { CATCH_PHOTOS_DIR, FIXTURES_DIR } from "../src/paths.ts";
import { isSpotlightable } from "../src/privacy.ts";
import { roundedCatchCount } from "../src/tailspot.ts";
import { buildChoices, guessPlane } from "../src/templates/guessPlane.ts";
import { TEMPLATES, templateById, templateForDay } from "../src/templates/index.ts";
import { CITIES, cityStats, overCity } from "../src/templates/overCity.ts";
import { airborneCountOfType, candidates, chooseSubject, rareNow, runnersUp, typeHashtag } from "../src/templates/rareNow.ts";
import type { BuildContext, Fixture } from "../src/types.ts";
import { article, dayIndex } from "../src/util.ts";

const fixture = <T>(id: string) => JSON.parse(readFileSync(join(FIXTURES_DIR, `${id}.json`), "utf8")) as Fixture<T>;

function ctxFor(fx: Fixture, date = "2026-10-03"): BuildContext {
  return {
    date,
    dayIndex: dayIndex(date),
    seed: `${date}:${fx.template}`,
    capturedAt: new Date(fx.capturedAt),
    stats: fx.tailspotStats ?? null,
    sample: fx.synthetic === true,
    params: fx.params ?? {},
  };
}

const plane = (over: Partial<Plane>): Plane => ({
  hex: "abc123",
  callsign: "UAL1",
  registration: "N1",
  typecode: "B738",
  desc: null,
  operator: null,
  regCountry: "United States",
  lat: 37.7,
  lon: -122.2,
  altFt: 30000,
  onGround: false,
  gsKt: 450,
  track: 90,
  seenPosS: 1,
  category: "A3",
  military: false,
  privacyListed: false,
  ...over,
});

describe("rotation", () => {
  test("three templates cycle by day", () => {
    const d = dayIndex("2026-10-03");
    const ids = [0, 1, 2, 3].map((i) => templateForDay(d + i).id);
    assert.equal(new Set(ids.slice(0, 3)).size, 3);
    assert.equal(ids[0], ids[3]);
    assert.deepEqual(TEMPLATES.map((t) => t.id).sort(), ["guess-plane", "over-city", "rare-now"]);
  });

  test("over-city visits every city before repeating", () => {
    const d0 = dayIndex("2026-10-03");
    const seen = new Set<string>();
    for (let k = 0; k < CITIES.length; k++) seen.add(String(overCity.params(d0 + 3 * k).city));
    assert.equal(seen.size, CITIES.length);
  });

  test("bad --date and --template are rejected", () => {
    assert.throws(() => dayIndex("10/03/2026"));
    assert.throws(() => templateById("nope"));
  });
});

describe("adsb normalisation + privacy", () => {
  test("drops TIS-B (~) addresses and rows without a position", () => {
    assert.equal(normalize({ hex: "~2b2e72", lat: 1, lon: 1 }), null);
    assert.equal(normalize({ hex: "a1b2c3" }), null);
  });

  test("reads ground, altitude fallback, flags", () => {
    const g = normalize({ hex: "A1B2C3", lat: 1, lon: 2, alt_baro: "ground", flight: "ABC1   " })!;
    assert.equal(g.onGround, true);
    assert.equal(g.hex, "a1b2c3");
    assert.equal(g.callsign, "ABC1");
    const a = normalize({ hex: "a1b2c3", lat: 1, lon: 2, alt_geom: 12000, dbFlags: 9 })!;
    assert.equal(a.altFt, 12000);
    assert.equal(a.military, true);
    assert.equal(a.privacyListed, true);
  });

  test("LADD/PIA, private tail numbers and stale positions are never spotlighted", () => {
    assert.equal(isSpotlightable(plane({})), true);
    assert.equal(isSpotlightable(plane({ privacyListed: true })), false);
    assert.equal(isSpotlightable(plane({ typecode: "GLF6", callsign: "N650XX", registration: "N650XX" })), false);
    assert.equal(isSpotlightable(plane({ typecode: "C172", callsign: "GBXYZ", registration: "G-BXYZ" })), false);
    assert.equal(isSpotlightable(plane({ typecode: "CL35", callsign: "LXJ506", registration: "N506FX" })), true);
    assert.equal(isSpotlightable(plane({ seenPosS: 300 })), false);
    assert.equal(isSpotlightable(plane({ onGround: true, altFt: 0 })), false);
    assert.equal(isSpotlightable(plane({ callsign: null })), false);
  });
});

describe("rare-now", () => {
  const fx = fixture<any>("rare-now");

  test("picks the top tier, skipping LADD, stale and grounded aircraft", () => {
    const cands = candidates(fx.raw);
    const types = new Set(cands.map((c) => c.plane.typecode));
    assert.ok(!types.has("F35"), "LADD-listed F-35 must be excluded");
    assert.ok(!types.has("B1"), "stale B-1 must be excluded");
    assert.ok(!types.has("E6"), "grounded E-6 must be excluded");
    assert.ok(!types.has("MD11"), "grounded MD-11 must be excluded");
    const s = chooseSubject(cands, "2026-10-03:rare-now");
    assert.equal(s.plane.typecode, "B52");
    assert.equal(s.rarity, "legendary");
  });

  test("runners-up are distinct types, best tier first, excluding the subject", () => {
    const cands = candidates(fx.raw);
    const s = chooseSubject(cands, "x");
    const r = runnersUp(cands, s);
    assert.equal(r.length, 4);
    assert.equal(new Set(r.map((c) => c.plane.typecode)).size, 4);
    assert.ok(r.every((c) => c.plane.typecode !== s.plane.typecode));
  });

  test("same-type count is aggregate over airborne aircraft", () => {
    assert.equal(airborneCountOfType(fx.raw, "A388"), 2);
    assert.equal(airborneCountOfType(fx.raw, "MD11"), 0);
  });

  test("selection is deterministic for a date", () => {
    const a = rareNow.build(fx.raw, ctxFor(fx));
    const b = rareNow.build(fx.raw, ctxFor(fx));
    assert.deepEqual(a.subject, b.subject);
  });

  test("hashtags and designators read like an avgeek wrote them", () => {
    assert.equal(typeHashtag("B52"), "#B52");
    assert.equal(typeHashtag("A388"), "#A380");
    assert.equal(typeHashtag("B748"), "#Boeing747");
    assert.equal(designator("K35R"), "KC-135");
    assert.equal(designator("B748"), "747-8");
    assert.equal(article(displayName("A388")), "an");
    assert.equal(article(displayName("B52")), "a");
  });
});

describe("over-city", () => {
  const fx = fixture<any>("over-city");

  test("aggregates counts, tiers and sky points", () => {
    const s = cityStats(fx.raw);
    assert.equal(s.airborne.length, 41);
    assert.equal(s.onGround, 5);
    assert.equal(s.unrated, 1);
    const tierTotal = Object.values(s.tiers).reduce((a, b) => a + b, 0);
    assert.equal(tierTotal + s.unrated, s.airborne.length);
    assert.equal(s.kinds.helicopter, 1);
    assert.equal(s.kinds.military, 1);
    assert.equal(s.topTypes[0].typecode, "A320");
  });

  test("rarest is the A380, never the private G650 at the same tier", () => {
    const s = cityStats(fx.raw);
    assert.equal(s.rarest?.plane.typecode, "A388");
    assert.equal(s.rarest?.rarity, "rare");
  });
});

describe("guess-plane", () => {
  test("every catch has a photo on disk and a known type", () => {
    for (const c of CATCHES) {
      assert.ok(existsSync(join(CATCH_PHOTOS_DIR, c.file)), c.file);
      assert.ok(typeInfo(c.typecode), c.typecode);
    }
  });

  test("choices: 4 distinct, include the answer, no same-family lookalikes", () => {
    for (const c of CATCHES) {
      for (const seed of ["a", "b", "c", "2026-10-03:guess-plane"]) {
        const { options, answerIndex } = buildChoices(c.typecode, seed);
        assert.equal(options.length, 4);
        assert.equal(new Set(options).size, 4);
        assert.equal(options[answerIndex], c.typecode);
        if (c.typecode === "B738") assert.ok(!options.includes("B38M") && !options.includes("B739"));
        if (c.typecode === "A21N") assert.ok(!options.some((o) => ["A320", "A20N", "A319", "A321"].includes(o)));
      }
    }
    assert.deepEqual(buildChoices("B738", "s"), buildChoices("B738", "s"));
  });
});

describe("every fixture builds a postable-shaped carousel", () => {
  for (const t of TEMPLATES) {
    test(t.id, () => {
      const fx = fixture<any>(t.id);
      const post = t.build(fx.raw, ctxFor(fx));
      assert.ok(post.slides.length >= 5 && post.slides.length <= 6);
      assert.equal(post.slides.at(-1)!.name, "cta");
      assert.ok(post.hashtags.length >= 3 && post.hashtags.length <= 5);
      assert.ok(post.hashtags.every((h) => /^#[A-Za-z0-9]+$/.test(h)), post.hashtags.join(" "));
      assert.ok(post.caption.startsWith(post.hook));
      assert.equal(post.altText.length, post.slides.length);
      // Privacy: no slide may carry raw coordinates.
      for (const s of post.slides) assert.ok(!/\d+\.\d{3,}/.test(s.html.replace(/data:[^"')]+/g, "").replace(/style="[^"]*"/g, "")), `coords leaked in ${s.name}`);
    });
  }

  test("synthetic fixtures are flagged, the real one is not", () => {
    assert.equal(fixture("rare-now").synthetic, true);
    assert.equal(fixture("over-city").synthetic, true);
    assert.equal(fixture("guess-plane").synthetic, false);
  });

  test("guess-plane needs no network", () => {
    assert.equal(guessPlane.needsNetwork, false);
  });
});

describe("formatting", () => {
  test("regions are coarse", () => {
    assert.match(regionFor(37.8, -122.4).phrase, /^near San Francisco/);
    assert.match(regionFor(63.12, -146.05).phrase, /km SE of Fairbanks, Alaska$/);
    assert.equal(regionFor(40.5, -45).phrase, "over the North Atlantic");
  });

  test("catch count rounds down so the slide never overstates", () => {
    assert.equal(roundedCatchCount(5812), "5,800+");
    assert.equal(roundedCatchCount(987), "980+");
    assert.equal(roundedCatchCount(12_345), "12,000+");
  });
});
