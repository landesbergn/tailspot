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
import { CATCH_COLUMNS, isCatchSpotlightable, isSpotlightable } from "../src/privacy.ts";
import { roundedCatchCount } from "../src/tailspot.ts";
import { buildChoices, guessPlane } from "../src/templates/guessPlane.ts";
import { fallbackChain, ROTATION, TEMPLATES, templateById, templateForDay } from "../src/templates/index.ts";
import { CITIES, cityStats, overCity } from "../src/templates/overCity.ts";
import {
  alsoCaught,
  chooseSubject as chooseCatch,
  eligibleCatches,
  parseCatchRows,
  placeFor,
  projectCatchRows,
  realCatches,
  type RealCatchesRaw,
} from "../src/templates/realCatches.ts";
import { airborneCountOfType, candidates, chooseSubject, rareNow, runnersUp, typeHashtag } from "../src/templates/rareNow.ts";
import { NoSubjectError, type BuildContext, type Fixture } from "../src/types.ts";
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
  test("7-day rotation: real-catches 4 days, every other template once", () => {
    const d = dayIndex("2026-10-03");
    const ids = Array.from({ length: 7 }, (_, i) => templateForDay(d + i).id);
    const count = (id: string) => ids.filter((x) => x === id).length;
    assert.equal(count("real-catches"), 4);
    for (const id of ["rare-now", "over-city", "guess-plane"]) assert.equal(count(id), 1, id);
    assert.equal(templateForDay(d).id, templateForDay(d + 7).id);
    assert.equal(ROTATION.length, 7);
    assert.deepEqual(TEMPLATES.map((t) => t.id).sort(), ["guess-plane", "over-city", "rare-now", "real-catches"]);
  });

  test("fallback chain: real-catches → rare-now → guess-plane", () => {
    assert.deepEqual(fallbackChain("real-catches").map((t) => t.id), ["rare-now", "guess-plane"]);
    assert.deepEqual(fallbackChain("rare-now").map((t) => t.id), ["guess-plane"]);
    assert.deepEqual(fallbackChain("guess-plane"), []);
  });

  test("over-city visits every city before repeating (one slot a week)", () => {
    const d0 = dayIndex("2026-10-03");
    const seen = new Set<string>();
    for (let k = 0; k < CITIES.length; k++) seen.add(String(overCity.params(d0 + 7 * k).city));
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

describe("real-catches", () => {
  const fx = fixture<RealCatchesRaw>("real-catches");
  const COLS = ["rarity", "manufacturer", "model", "operator_name", "typecode", "city", "country", "day", "within_48h"];
  // [rarity, manufacturer, model, operator_name, typecode, city, country, day, within_48h], newest first
  const raw = (...results: unknown[][]): RealCatchesRaw => ({ columns: COLS, results });
  const row = (over: Partial<Record<string, unknown>> = {}): unknown[] => {
    const base: Record<string, unknown> = {
      rarity: "rare", manufacturer: "Boeing", model: "747-400", operator_name: "Atlas Air", typecode: "B744",
      city: "Oakland", country: "United States", day: "2026-10-03", within_48h: 1, ...over,
    };
    return COLS.map((c) => base[c]);
  };
  const ctx = (): BuildContext => ({ date: "2026-10-04", dayIndex: dayIndex("2026-10-04"), seed: "s", capturedAt: new Date("2026-10-04T16:00:00Z"), stats: null, sample: false, params: {} });

  test("the live fixture holds only the allowlisted columns", () => {
    assert.deepEqual(fx.raw.columns, [...CATCH_COLUMNS]);
    assert.equal(fx.synthetic, false);
  });

  test("subject: highest tier first, then most recent, within 48 h", () => {
    const rows = parseCatchRows(
      raw(
        row({ rarity: "rare", typecode: "B744" }),
        row({ rarity: "epic", typecode: "B748", model: "747-8", operator_name: "Lufthansa", city: "San Francisco" }),
        row({ rarity: "epic", typecode: "MD11", model: "MD-11", operator_name: "FedEx Express" }),
        row({ rarity: "legendary", typecode: "B52", model: "B-52", operator_name: null, city: "Tucson", day: "2026-09-29", within_48h: 0 }),
      ),
    );
    const { subject, recent } = chooseCatch(eligibleCatches(rows));
    assert.equal(recent, true);
    assert.equal(subject.row.typecode, "B748", "the older legendary loses to the newest 48 h epic");
    const post = realCatches.build(raw(...[row({ rarity: "epic", typecode: "B748", model: "747-8", operator_name: "Lufthansa", city: "San Francisco" })]), ctx());
    assert.equal(post.hook, "A Lufthansa 747-8 was just caught in the San Francisco area.");
  });

  test("falls back to the whole week when nothing is from the last 48 h", () => {
    const rows = parseCatchRows(raw(row({ within_48h: 0, typecode: "B744" }), row({ within_48h: 0, rarity: "epic", typecode: "C17", model: "C-17", operator_name: null })));
    const { subject, recent } = chooseCatch(eligibleCatches(rows));
    assert.equal(recent, false);
    assert.equal(subject.row.typecode, "C17");
    assert.match(realCatches.build(raw(row({ within_48h: 0 })), ctx()).hook, /was caught this week/);
  });

  test("no eligible catch is a NoSubjectError (so the CLI falls back to rare-now)", () => {
    assert.throws(() => realCatches.build(raw(), ctx()), NoSubjectError);
    assert.throws(() => realCatches.build(raw(row({ city: null })), ctx()), NoSubjectError);
  });

  test("private GA / business jets are never spotlighted; airline, cargo and military are", () => {
    assert.equal(isCatchSpotlightable({ typecode: "EPIC", operator: null }), false);
    assert.equal(isCatchSpotlightable({ typecode: "GLEX", operator: "Solairus Aviation" }), false);
    assert.equal(isCatchSpotlightable({ typecode: "GL7T", operator: "NetJets" }), false);
    assert.equal(isCatchSpotlightable({ typecode: "GLF6", operator: "Flexjet" }), false);
    assert.equal(isCatchSpotlightable({ typecode: "GLF6", operator: "N650XX" }), false);
    assert.equal(isCatchSpotlightable({ typecode: "ZZZZ", operator: null }), false, "unknown type is treated as private");
    assert.equal(isCatchSpotlightable({ typecode: "B748", operator: "Lufthansa" }), true);
    assert.equal(isCatchSpotlightable({ typecode: "C17", operator: null }), true);
    assert.equal(isCatchSpotlightable({ typecode: "T38", operator: null }), true, "T-38 is military despite its GA class");
    assert.equal(isCatchSpotlightable({ typecode: "CL35", operator: "Air Force Reserve" }), true);
    // The live fixture has private bizjets (GLEX, GL7T, GLF6, EPIC, ...): none may surface.
    const post = realCatches.build(fx.raw, ctxFor(fx));
    const names = [post.subject.typecode, ...(post.subject.alsoCaught as Array<{ typecode: string }>).map((o) => o.typecode)];
    for (const code of ["GLEX", "GL7T", "GL5T", "GLF6", "GA6C", "EPIC"]) assert.ok(!names.includes(code), code);
    const text = post.caption + post.slides.map((s) => s.html).join("") + post.altText.join("");
    for (const word of ["Global", "Gulfstream", "Epic Aircraft", "E1000", "Solairus", "NetJets", "Flexjet"]) assert.ok(!text.includes(word), word);
  });

  test("a malicious fixture can't leak handle, registration, callsign or icao24", () => {
    const evil: RealCatchesRaw = {
      columns: [...COLS, "handle", "registration", "callsign", "icao24", "origin_icao"],
      results: [
        [...row({ rarity: "epic", typecode: "B748", model: "747-8", operator_name: "Lufthansa", city: "San Francisco" }), "@skyhawk_noah", "D-ABYA", "DLH454", "3c4b21", "EDDF"],
        [...row({ typecode: "MD11", model: "MD-11", operator_name: "N123AB", city: "Oakland" }), "@other", "N571FE", "FDX12", "a1b2c3", "KMEM"],
        [...row({ typecode: "B744", operator_name: "Atlas Air", city: "@sneaky_handle" }), "@third", "N498MC", "GTI8", "abcdef", "KCVG"],
      ],
    };
    assert.deepEqual(projectCatchRows(evil).columns, COLS, "non-allowlisted columns are dropped");
    const post = realCatches.build(evil, ctx());
    const text = [post.hook, post.caption, ...post.hashtags, ...post.altText, ...post.slides.map((s) => s.html), JSON.stringify(post.subject)].join("\n");
    for (const leak of ["skyhawk", "@other", "@third", "sneaky", "D-ABYA", "DLH454", "3c4b21", "N571FE", "FDX12", "a1b2c3", "N123AB", "N498MC", "GTI8", "EDDF", "KMEM"]) {
      assert.ok(!text.includes(leak), `leaked ${leak}`);
    }
  });

  test("also caught: deduped by model + place, distinct models first, subject excluded", () => {
    const rows = parseCatchRows(
      raw(
        row({ rarity: "epic", typecode: "B748", model: "747-8", operator_name: "Lufthansa", city: "San Francisco" }),
        row({ rarity: "epic", typecode: "B748", model: "747-8", operator_name: "UPS Airlines", city: "Concord" }), // same model + metro as subject
        row({ rarity: "epic", typecode: "MD11", model: "MD-11", operator_name: "FedEx Express", city: "Oakland" }),
        row({ rarity: "epic", typecode: "MD11", model: "MD-11", operator_name: "FedEx Express", city: "Berkeley" }), // dup MD-11 / SF area
        row({ rarity: "epic", typecode: "MD11", model: "MD-11", operator_name: "FedEx Express", city: "New York" }),
        row({ rarity: "rare", typecode: "B744", city: "Sacramento" }),
        row({ rarity: "rare", typecode: "A388", model: "A380-800", operator_name: "Emirates", city: "Stockport", country: "United Kingdom" }),
      ),
    );
    const cands = eligibleCatches(rows);
    const { subject } = chooseCatch(cands);
    const others = alsoCaught(cands, subject);
    const keys = others.map((o) => `${o.row.typecode}|${o.place.key}`);
    assert.equal(new Set(keys).size, keys.length);
    assert.ok(!keys.includes(`B748|metro:San Francisco`));
    // Shown best tier first, then most recent.
    assert.deepEqual(keys, ["MD11|metro:San Francisco", "MD11|metro:New York", "B744|city:sacramento", "A388|metro:Manchester"]);
    // With room for only three, a second MD-11 loses to models not yet shown.
    assert.deepEqual(
      alsoCaught(cands, subject, 3).map((o) => o.row.typecode),
      ["MD11", "B744", "A388"],
    );
  });

  test("city phrasing is approximate: metro areas, 'near' elsewhere, junk dropped", () => {
    assert.equal(placeFor("San Francisco", "United States")?.phrase, "in the San Francisco area");
    assert.equal(placeFor("Concord", "United States")?.phrase, "in the San Francisco area");
    assert.equal(placeFor("Tucson", "United States")?.phrase, "near Tucson");
    assert.equal(placeFor("Denpasar", "Indonesia")?.phrase, "near Denpasar, Indonesia");
    assert.equal(placeFor("Stockport", "United Kingdom")?.phrase, "in the Manchester area");
    assert.equal(placeFor("Leeds", "United Kingdom")?.phrase, "near Leeds, UK");
    assert.equal(placeFor(null, "United States"), null);
    assert.equal(placeFor("", null), null);
    assert.equal(placeFor("@handle", null), null);
    assert.equal(placeFor("37.7749", null), null);
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
    assert.equal(fixture("real-catches").synthetic, false);
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
