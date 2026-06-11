import { describe, expect, it } from "vitest";
import { parseTypecodeMap } from "../src/ingest/typecodeMap.js";

/**
 * Unit tests for the committed-map loader (WP 1.4b). The on-disk load path is
 * exercised end-to-end by faa.test.ts via the injected map; here we cover the
 * pure parse function (string in -> Map out) in isolation.
 */
describe("parseTypecodeMap", () => {
  it("parses a code -> designator object into a Map", () => {
    const map = parseTypecodeMap('{"1380530":"B738","2072725":"SR22"}');
    expect(map.size).toBe(2);
    expect(map.get("1380530")).toBe("B738");
    expect(map.get("2072725")).toBe("SR22");
  });

  it("trims keys and uppercases designators", () => {
    const map = parseTypecodeMap('{" 0560200 ":"c172"}');
    expect(map.get("0560200")).toBe("C172");
  });

  it("skips empty/non-string entries defensively", () => {
    const map = parseTypecodeMap('{"good":"B738","empty":"","missing":null,"num":42}');
    expect(map.size).toBe(1);
    expect(map.get("good")).toBe("B738");
  });

  it("returns an empty map for an empty object", () => {
    expect(parseTypecodeMap("{}").size).toBe(0);
  });
});
