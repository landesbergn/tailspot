import { describe, expect, it } from "vitest";
import { countryForIcao24 } from "../src/providers/icaoCountry.js";

describe("countryForIcao24", () => {
  it("resolves a US address (A00000–AFFFFF block)", () => {
    expect(countryForIcao24("a808c5")).toBe("United States");
    expect(countryForIcao24("a00000")).toBe("United States");
    expect(countryForIcao24("affff f".replace(" ", ""))).toBe("United States");
  });

  it("resolves a German address (3C0000–3FFFFF block)", () => {
    expect(countryForIcao24("3c6444")).toBe("Germany");
    expect(countryForIcao24("3C0000")).toBe("Germany"); // case-insensitive
  });

  it("resolves a UK address (400000–43FFFF block)", () => {
    expect(countryForIcao24("400a1b")).toBe("United Kingdom");
  });

  it("resolves a Japanese address (840000–87FFFF block)", () => {
    expect(countryForIcao24("86e4b8")).toBe("Japan");
  });

  it("returns null for an unallocated address (gap between blocks)", () => {
    // 0x2b2e72 sits below the Italy block (0x300000) and above the
    // Mexico/Venezuela blocks — an unallocated gap.
    expect(countryForIcao24("2b2e72")).toBeNull();
  });

  it("returns null for non-hex input", () => {
    expect(countryForIcao24("zzzz")).toBeNull();
    expect(countryForIcao24("")).toBeNull();
  });

  it("returns null for a '~'-prefixed synthetic address", () => {
    // parseInt("~2b2e72", 16) is NaN, so this is null regardless of stripping.
    expect(countryForIcao24("~2b2e72")).toBeNull();
  });

  it("returns null for out-of-range values", () => {
    expect(countryForIcao24("1000000")).toBeNull(); // > 0xffffff
  });

  it("resolves block boundaries inclusively", () => {
    // Italy block is 0x300000–0x33ffff.
    expect(countryForIcao24("300000")).toBe("Italy");
    expect(countryForIcao24("33ffff")).toBe("Italy");
    // One past the end falls into the next block (Spain 0x340000).
    expect(countryForIcao24("340000")).toBe("Spain");
  });
});
