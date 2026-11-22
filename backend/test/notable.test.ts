/**
 * Notable planes, unit level: the CSV parser, the row mapping and its
 * exclusion rules, the snapshot file, and the directory. No test here
 * touches the network.
 */
import { describe, expect, it } from "vitest";
import { parseCsv } from "../src/notable/csv.js";
import {
  NotableDirectory,
  loadNotableSnapshot,
  parseNotableSnapshot,
  serializeNotableSnapshot,
} from "../src/notable/directory.js";
import {
  CATEGORY_KINDS,
  NOTABLE_LABELS,
  NOTABLE_NAME_MAX_LENGTH,
  type Notable,
  type NotableKind,
  makeNotable,
  mapPlaneAlertRow,
  notableName,
  parsePlaneAlertCsv,
} from "../src/notable/mapping.js";

const HEADER =
  "$ICAO,$Registration,$Operator,$Type,$ICAO Type,#CMPG,$Tag 1,$#Tag 2,$#Tag 3,Category,$#Link";

/** One upstream CSV line. Fields are quoted only when the test passes quotes. */
function line(icao: string, operator: string, cmpg: string, category: string, reg = "N1"): string {
  return `${icao},${reg},${operator},Some Type,B738,${cmpg},Tag One,Tag Two,Tag Three,${category},https://example.invalid/x`;
}

describe("parseCsv", () => {
  it("splits plain rows and skips blank lines", () => {
    expect(parseCsv("a,b,c\n\n1,2,3\n")).toEqual([
      ["a", "b", "c"],
      ["1", "2", "3"],
    ]);
  });

  it("keeps commas, doubled quotes and line breaks inside quoted fields", () => {
    const text = 'id,name,note\n1,"Smith, John","said ""hi"""\n2,"two\nlines",x\n';
    expect(parseCsv(text)).toEqual([
      ["id", "name", "note"],
      ["1", "Smith, John", 'said "hi"'],
      ["2", "two\nlines", "x"],
    ]);
  });

  it("handles CRLF, a byte-order mark and a missing final newline", () => {
    expect(parseCsv("﻿a,b\r\n1,2")).toEqual([
      ["a", "b"],
      ["1", "2"],
    ]);
  });

  it("keeps empty fields, including a trailing one and a quoted empty one", () => {
    expect(parseCsv('a,,c\nx,y,\n"",z\n')).toEqual([
      ["a", "", "c"],
      ["x", "y", ""],
      ["", "z"],
    ]);
  });

  it("does not throw on an unterminated quote (a truncated download)", () => {
    expect(parseCsv('a,b\n1,"never closed\n2,3')).toEqual([
      ["a", "b"],
      ["1", "never closed\n2,3"],
    ]);
  });
});

describe("mapPlaneAlertRow", () => {
  const row = (category: string, cmpg = "Civ", operator = "Acme Air", icao = "A1B2C3") =>
    mapPlaneAlertRow({ icao, operator, cmpg, category });

  it("maps every listed category to its kind and that kind's fixed label", () => {
    const expected: Record<NotableKind, string[]> = {
      government: ["Governments", "Dictator Alert", "Head of State", "Royal Aircraft"],
      celebrity: ["Don't you know who I am?"],
      business: ["As Seen on TV", "Bizjets", "Vanity Plate", "Climate Crisis", "Oligarch"],
      team: ["Football"],
      special: [
        "Historic",
        "Distinctive",
        "Aerobatic Teams",
        "Big Hello",
        "Gas Bags",
        "Nuclear",
        "Radiohead",
        "Jump Johnny Jump",
        "You came here in that thing?",
        "Zoomies",
      ],
      working: [
        "Coastguard",
        "Aerial Firefighter",
        "Hired Gun",
        "Ptolemy would be proud",
        "Dogs with Jobs",
        "Perfectly Serviceable Aircraft",
        "Oxcart",
        "Special Forces",
        "CAP",
        "Fire Fighting",
        "Quango",
      ],
    };
    for (const [kind, categories] of Object.entries(expected) as [NotableKind, string[]][]) {
      for (const category of categories) {
        expect(row(category), category).toEqual({
          icao24: "a1b2c3",
          notable: { kind, label: NOTABLE_LABELS[kind], name: "Acme Air" },
        });
      }
    }
    // The table above IS the whole allow-list: nothing is mapped that isn't pinned here.
    expect(Object.keys(CATEGORY_KINDS).sort()).toEqual(Object.values(expected).flat().sort());
  });

  it("uses the fixed user-facing labels", () => {
    expect(NOTABLE_LABELS).toEqual({
      government: "Head of state and government",
      celebrity: "Celebrity",
      business: "Business jet",
      team: "Team plane",
      special: "Historic and special",
      working: "Special mission",
    });
  });

  it("excludes the always-excluded categories and anything unmapped", () => {
    for (const category of [
      "Flying Doctors",
      "Police Forces",
      "UK National Police Air Service",
      "PIA",
      "USAF",
      "Other Air Forces",
      "Joe Cool",
      "Da Comrade",
      "A Category Upstream Adds Next Year",
      "",
      // A category that is a prototype key must not slip through the lookup.
      "constructor",
      "toString",
    ]) {
      expect(row(category), category).toBeNull();
    }
  });

  it("matches categories exactly (case and wording), after trimming", () => {
    expect(row("  Bizjets  ")?.notable.kind).toBe("business");
    expect(row("bizjets")).toBeNull();
    expect(row("Bizjet")).toBeNull();
  });

  it("drops military and police rows, except in the six kept categories", () => {
    for (const cmpg of ["Mil", "Pol", " mil ", "POL"]) {
      for (const dropped of ["Distinctive", "Oxcart", "Special Forces", "Coastguard", "Nuclear"]) {
        expect(row(dropped, cmpg), `${dropped}/${cmpg}`).toBeNull();
      }
      for (const kept of [
        "Governments",
        "Dictator Alert",
        "Head of State",
        "Royal Aircraft",
        "Historic",
        "Aerobatic Teams",
      ]) {
        expect(row(kept, cmpg), `${kept}/${cmpg}`).not.toBeNull();
      }
    }
    // Civ and Gov rows are kept everywhere a category is mapped.
    expect(row("Distinctive", "Gov")).not.toBeNull();
    expect(row("Oxcart", "Civ")).not.toBeNull();
    // The exception never rescues an excluded category.
    expect(row("Police Forces", "Civ")).toBeNull();
    expect(row("USAF", "Gov")).toBeNull();
  });

  it("lowercases the hex and skips malformed ones", () => {
    expect(row("Bizjets", "Civ", "Acme", " ADFDF8 ")?.icao24).toBe("adfdf8");
    for (const bad of ["10166", "", "zzzzzz", "abcdef0", "~abcde", "ab cd1"]) {
      expect(row("Bizjets", "Civ", "Acme", bad), bad).toBeNull();
    }
  });

  it("never exposes the tags or the raw category", () => {
    const [mapped] = [
      ...parsePlaneAlertCsv(
        `${HEADER}\n${line("a1b2c3", "Gov of Somewhere", "Gov", "Dictator Alert")}\n`,
      ).values(),
    ];
    expect(mapped).toEqual({
      kind: "government",
      label: "Head of state and government",
      name: "Gov of Somewhere",
    });
    expect(JSON.stringify(mapped)).not.toMatch(/Dictator|Tag /);
  });
});

describe("notableName", () => {
  it("trims, collapses whitespace and caps the length", () => {
    expect(notableName("  Acme   Air  ")).toBe("Acme Air");
    const long = `${"x".repeat(NOTABLE_NAME_MAX_LENGTH - 1)} yz`;
    const capped = notableName(long);
    expect(capped).toBe("x".repeat(NOTABLE_NAME_MAX_LENGTH - 1));
    expect(capped?.length).toBeLessThanOrEqual(NOTABLE_NAME_MAX_LENGTH);
  });

  it("omits empty values and placeholders", () => {
    for (const v of ["", "   ", "Private", "private", "PRIVATE OWNER", "Unknown", "Corporate"]) {
      expect(notableName(v), v).toBeUndefined();
    }
    for (const v of ["Unknown Owner", "Operator Unknown", "TBC", "N/A"]) {
      expect(notableName(v), v).toBeUndefined();
    }
    // A real name that merely contains a placeholder word is kept.
    expect(notableName("Wheels Up Private Jets")).toBe("Wheels Up Private Jets");
  });

  it("caps by code point and never splits a surrogate pair", () => {
    const plane = "\u{1F6E9}"; // one code point, two UTF-16 units
    // 59 letters then two planes: the cap of 60 lands between the pair's halves
    // if you count UTF-16 units.
    const capped = notableName(`${"x".repeat(NOTABLE_NAME_MAX_LENGTH - 1)}${plane}${plane}`);
    expect(capped).toBe(`${"x".repeat(NOTABLE_NAME_MAX_LENGTH - 1)}${plane}`);
    expect(Array.from(capped ?? "")).toHaveLength(NOTABLE_NAME_MAX_LENGTH);
    // No lone surrogate anywhere: it survives a UTF-8 round trip unchanged.
    expect(Buffer.from(capped ?? "", "utf8").toString("utf8")).toBe(capped);
    // 60 astral characters are 120 UTF-16 units and still fit whole.
    expect(notableName(plane.repeat(NOTABLE_NAME_MAX_LENGTH + 5))).toBe(
      plane.repeat(NOTABLE_NAME_MAX_LENGTH),
    );
    // Exactly at the cap: untouched.
    expect(notableName("y".repeat(NOTABLE_NAME_MAX_LENGTH))).toBe(
      "y".repeat(NOTABLE_NAME_MAX_LENGTH),
    );
  });

  it("strips control, bidi and zero-width characters before trimming", () => {
    // Bidi overrides and isolates (the "Trojan Source" set).
    for (const cp of [0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069]) {
      const ch = String.fromCodePoint(cp);
      expect(notableName(`Acme${ch} Air${ch}`), cp.toString(16)).toBe("Acme Air");
    }
    // Zero-width characters, directional marks, BOM, soft hyphen.
    for (const cp of [0x200b, 0x200c, 0x200d, 0x2060, 0xfeff, 0x200e, 0x200f, 0x00ad, 0x061c]) {
      const ch = String.fromCodePoint(cp);
      expect(notableName(`${ch}Ac${ch}me Air${ch}`), cp.toString(16)).toBe("Acme Air");
    }
    // C0 and C1 controls and DEL are removed; tabs and line breaks are
    // whitespace, so they become a space rather than gluing words together.
    expect(notableName("Ac\u0000me\u0007 A\u001bir\u007f\u0085\u009f")).toBe("Acme Air");
    expect(notableName("Acme\tAir\r\nLtd")).toBe("Acme Air Ltd");
    // Stripping happens BEFORE the trim and the placeholder check.
    expect(notableName("\u200b \u202e ")).toBeUndefined();
    expect(notableName(" \u202ePrivate\u202c ")).toBeUndefined();
    expect(notableName("\u200bN101YK", "N101YK")).toBeUndefined();
    // A removed character between two spaces does not leave a double space.
    expect(notableName("Acme \u200b Air")).toBe("Acme Air");
    // Ordinary non-ASCII names are left alone.
    expect(notableName("Société Aérienne Ōsaka")).toBe("Société Aérienne Ōsaka");
  });

  it("omits an operator that just repeats the registration", () => {
    expect(notableName("N101YK", "N101YK")).toBeUndefined();
    expect(notableName("Acme", "N101YK")).toBe("Acme");
  });

  it("a row with no usable name has no `name` key at all", () => {
    const mapped = mapPlaneAlertRow({
      icao: "a1b2c3",
      operator: "Private",
      cmpg: "Civ",
      category: "Historic",
    });
    expect(mapped?.notable).toEqual({ kind: "special", label: "Historic and special" });
    expect(Object.keys(mapped?.notable ?? {})).toEqual(["kind", "label"]);
  });
});

describe("parsePlaneAlertCsv", () => {
  it("parses rows, including a quoted operator with a comma, and applies the rules", () => {
    const csv = [
      HEADER,
      line("A00001", '"Smith, Jones & Co"', "Civ", "Bizjets"),
      line("a00002", "Some Air Force", "Mil", "Distinctive"), // dropped: Mil
      line("a00003", "Some Air Force", "Mil", "Governments"), // kept: exception
      line("a00004", "Metro Police", "Pol", "Police Forces"), // dropped
      line("10166", "Short Hex", "Civ", "Bizjets"), // dropped: malformed
      line("a00006", "Private", "Civ", "Football"),
      line("a00001", "Duplicate", "Civ", "Football"), // first row wins
    ].join("\r\n");
    expect([...parsePlaneAlertCsv(csv).entries()]).toEqual([
      ["a00001", { kind: "business", label: "Business jet", name: "Smith, Jones & Co" }],
      [
        "a00003",
        { kind: "government", label: "Head of state and government", name: "Some Air Force" },
      ],
      ["a00006", { kind: "team", label: "Team plane" }],
    ]);
  });

  it("finds columns by header name, so a reordered file still parses", () => {
    const csv = "Category,#CMPG,$Operator,$ICAO\nFootball,Civ,Some Club,abc123\n";
    expect([...parsePlaneAlertCsv(csv).entries()]).toEqual([
      ["abc123", { kind: "team", label: "Team plane", name: "Some Club" }],
    ]);
  });

  it("returns nothing when a needed column is missing, or the text is not the CSV", () => {
    expect(parsePlaneAlertCsv("$ICAO,$Operator,Category\nabc123,X,Football\n").size).toBe(0);
    expect(parsePlaneAlertCsv("<html><body>404: Not Found</body></html>").size).toBe(0);
    expect(parsePlaneAlertCsv("").size).toBe(0);
  });
});

describe("the committed snapshot", () => {
  const snapshot = loadNotableSnapshot();

  it("loads, and every entry is well formed", () => {
    expect(snapshot.size).toBeGreaterThan(4000);
    for (const [icao24, n] of snapshot) {
      expect(icao24).toMatch(/^[0-9a-f]{6}$/);
      expect(n.label).toBe(NOTABLE_LABELS[n.kind]);
      if (n.name !== undefined) {
        expect(n.name.length).toBeGreaterThan(0);
        expect(n.name.length).toBeLessThanOrEqual(NOTABLE_NAME_MAX_LENGTH);
      }
    }
  });

  it("covers all six kinds", () => {
    expect(new Set([...snapshot.values()].map((n) => n.kind))).toEqual(
      new Set(Object.keys(NOTABLE_LABELS)),
    );
  });

  it("round-trips through serialize and parse", () => {
    const entries = new Map<string, Notable>([
      ["bbbbbb", makeNotable("team")],
      ["aaaaaa", makeNotable("celebrity", 'A "Quoted", Name')],
    ]);
    const text = serializeNotableSnapshot(entries, "2026-11-21");
    expect(JSON.parse(text)).toMatchObject({ count: 2, generatedAt: "2026-11-21" });
    // Sorted by hex, one airframe per line.
    expect(text.split("\n")[1]).toContain('"aaaaaa"');
    expect([...parseNotableSnapshot(text).entries()]).toEqual([
      ["aaaaaa", { kind: "celebrity", label: "Celebrity", name: 'A "Quoted", Name' }],
      ["bbbbbb", { kind: "team", label: "Team plane" }],
    ]);
  });

  it("parse skips malformed rows and rejects a file with no airframes", () => {
    const text = JSON.stringify({
      airframes: [["aaaaaa", "team"], ["XYZ", "team"], ["bbbbbb", "not-a-kind"], "junk", []],
    });
    expect([...parseNotableSnapshot(text).keys()]).toEqual(["aaaaaa"]);
    expect(() => parseNotableSnapshot("{}")).toThrow();
  });
});

describe("NotableDirectory", () => {
  const seed = () =>
    new NotableDirectory(
      new Map(
        Array.from({ length: 10 }, (_, i) => [
          (0xa00000 + i).toString(16),
          makeNotable("business", `Seed ${i}`),
        ]),
      ),
    );

  it("looks up by lowercase hex, tolerating case and whitespace", () => {
    const dir = seed();
    expect(dir.lookup("a00003")).toEqual({
      kind: "business",
      label: "Business jet",
      name: "Seed 3",
    });
    expect(dir.lookup(" A00003 ")).toEqual(dir.lookup("a00003"));
    expect(dir.lookup("ffffff")).toBeUndefined();
    expect(dir.size).toBe(10);
  });

  it("fromSnapshot never throws: a missing file reports the error and starts empty", () => {
    const errors: unknown[] = [];
    const dir = NotableDirectory.fromSnapshot({
      path: "/nonexistent/notable-airframes.json",
      onError: (err) => errors.push(err),
    });
    expect(dir.size).toBe(0);
    expect(errors).toHaveLength(1);
  });

  it("fromSnapshot with no arguments loads the committed file", () => {
    expect(NotableDirectory.fromSnapshot().size).toBe(loadNotableSnapshot().size);
  });
});

describe("the real upstream shape", () => {
  it("the mapped snapshot is what the mapping makes of a real-looking excerpt", () => {
    // Verbatim rows from plane-alert-db (2026-11-21), one per rule.
    const csv = [
      HEADER,
      "000004,FAC1282,Colombian Aerospace Force,CASA C-295 M,C295,Mil,Cargo,Tactical Transport,Marching Powder,Other Air Forces,https://w.wiki/8pa2",
      "ADFDF8,82-8000,US Government,Boeing VC25A,B742,Gov,Air Force One,Government,POTUS,Radiohead,https://en.wikipedia.org/wiki/Boeing_VC-25",
    ].join("\n");
    expect([...parsePlaneAlertCsv(csv).entries()]).toEqual([
      [
        "adfdf8",
        { kind: "government", label: "Head of state and government", name: "US Government" },
      ],
    ]);
    // The committed snapshot is real data that changes when regenerated, so
    // only its shape is checked here, never a particular airframe.
    expect(loadNotableSnapshot().size).toBeGreaterThan(1000);
  });
});
