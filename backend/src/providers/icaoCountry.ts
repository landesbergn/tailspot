/**
 * ICAO 24-bit address → country derivation.
 *
 * OpenSky's /states/all supplies `origin_country` directly; readsb-based feeds
 * (adsb.lol) do NOT. To populate `originCountry` for the adsb.lol adapter we
 * map the numeric icao24 address into the ITU/ICAO national allocation blocks.
 *
 * Source: ICAO Annex 10, Volume III, Part I, Chapter 9 (Table 9-1) — the
 * 24-bit aircraft-address national allocations. The concrete range list below
 * is transcribed from the widely-used public implementation in the dump1090 /
 * readsb / pyModeS lineage (e.g.
 * https://github.com/wiedehopf/readsb -> aircraft_country tables, and
 * https://github.com/junzis/pyModeS -> icao_country), which itself encodes
 * the Annex 10 Table 9-1 allocations. Country names use common short forms.
 *
 * Each block is defined by a [start, end] inclusive numeric range (the first
 * 4/6/9/12/14 bits fix the state; remaining bits are the per-state serial).
 * The table is kept SORTED by `start` so lookup is a binary search. Addresses
 * with no matching block (genuinely unallocated, or the "~"-prefixed non-ICAO
 * TIS-B/ADS-R synthetic addresses that we strip before lookup) yield null.
 *
 * This is intentionally the full Annex 10 list rather than a few hand-picked
 * countries: it is static data, costs nothing at runtime, and "US plane shows
 * up as null country" would be a visible regression in the app.
 */

interface CountryBlock {
  start: number;
  end: number;
  country: string;
}

// Transcribed from ICAO Annex 10 Vol III Table 9-1 (dump1090/readsb/pyModeS
// lineage). Hex endpoints shown in comments for auditability.
const BLOCKS: CountryBlock[] = [
  { start: 0x004000, end: 0x0043ff, country: "Zimbabwe" },
  { start: 0x006000, end: 0x006fff, country: "Mozambique" },
  { start: 0x008000, end: 0x00ffff, country: "South Africa" },
  { start: 0x010000, end: 0x017fff, country: "Egypt" },
  { start: 0x018000, end: 0x01ffff, country: "Libya" },
  { start: 0x020000, end: 0x027fff, country: "Morocco" },
  { start: 0x028000, end: 0x02ffff, country: "Tunisia" },
  { start: 0x030000, end: 0x0303ff, country: "Botswana" },
  { start: 0x032000, end: 0x032fff, country: "Burundi" },
  { start: 0x034000, end: 0x034fff, country: "Cameroon" },
  { start: 0x035000, end: 0x0353ff, country: "Comoros" },
  { start: 0x036000, end: 0x036fff, country: "Congo" },
  { start: 0x038000, end: 0x038fff, country: "Cote d'Ivoire" },
  { start: 0x03e000, end: 0x03efff, country: "Gabon" },
  { start: 0x040000, end: 0x040fff, country: "Ethiopia" },
  { start: 0x042000, end: 0x042fff, country: "Equatorial Guinea" },
  { start: 0x044000, end: 0x044fff, country: "Ghana" },
  { start: 0x046000, end: 0x046fff, country: "Guinea" },
  { start: 0x048000, end: 0x0483ff, country: "Guinea-Bissau" },
  { start: 0x04a000, end: 0x04a3ff, country: "Lesotho" },
  { start: 0x04c000, end: 0x04cfff, country: "Kenya" },
  { start: 0x050000, end: 0x050fff, country: "Liberia" },
  { start: 0x054000, end: 0x054fff, country: "Madagascar" },
  { start: 0x058000, end: 0x058fff, country: "Malawi" },
  { start: 0x05a000, end: 0x05a3ff, country: "Maldives" },
  { start: 0x05c000, end: 0x05cfff, country: "Mali" },
  { start: 0x05e000, end: 0x05e3ff, country: "Mauritania" },
  { start: 0x060000, end: 0x0603ff, country: "Mauritius" },
  { start: 0x062000, end: 0x062fff, country: "Niger" },
  { start: 0x064000, end: 0x064fff, country: "Nigeria" },
  { start: 0x068000, end: 0x068fff, country: "Uganda" },
  { start: 0x06a000, end: 0x06a3ff, country: "Qatar" },
  { start: 0x06c000, end: 0x06cfff, country: "Central African Republic" },
  { start: 0x06e000, end: 0x06efff, country: "Rwanda" },
  { start: 0x070000, end: 0x070fff, country: "Senegal" },
  { start: 0x074000, end: 0x0743ff, country: "Seychelles" },
  { start: 0x076000, end: 0x0763ff, country: "Sierra Leone" },
  { start: 0x078000, end: 0x078fff, country: "Somalia" },
  { start: 0x07a000, end: 0x07a3ff, country: "Eswatini" },
  { start: 0x07c000, end: 0x07cfff, country: "Sudan" },
  { start: 0x080000, end: 0x080fff, country: "Tanzania" },
  { start: 0x084000, end: 0x084fff, country: "Chad" },
  { start: 0x088000, end: 0x088fff, country: "Togo" },
  { start: 0x08a000, end: 0x08afff, country: "Zambia" },
  { start: 0x08c000, end: 0x08cfff, country: "DR Congo" },
  { start: 0x090000, end: 0x090fff, country: "Angola" },
  { start: 0x094000, end: 0x0943ff, country: "Benin" },
  { start: 0x096000, end: 0x0963ff, country: "Cape Verde" },
  { start: 0x098000, end: 0x0983ff, country: "Djibouti" },
  { start: 0x09a000, end: 0x09afff, country: "Gambia" },
  { start: 0x09c000, end: 0x09c3ff, country: "Burkina Faso" },
  { start: 0x09e000, end: 0x09e3ff, country: "Sao Tome and Principe" },
  { start: 0x0a0000, end: 0x0a7fff, country: "Algeria" },
  { start: 0x0a8000, end: 0x0a8fff, country: "Bahamas" },
  { start: 0x0aa000, end: 0x0aa3ff, country: "Barbados" },
  { start: 0x0ab000, end: 0x0ab3ff, country: "Belize" },
  { start: 0x0ac000, end: 0x0acfff, country: "Colombia" },
  { start: 0x0ae000, end: 0x0ae3ff, country: "Costa Rica" },
  { start: 0x0b0000, end: 0x0b03ff, country: "Cuba" },
  { start: 0x0b2000, end: 0x0b2fff, country: "El Salvador" },
  { start: 0x0b4000, end: 0x0b43ff, country: "Guatemala" },
  { start: 0x0b6000, end: 0x0b63ff, country: "Guyana" },
  { start: 0x0b8000, end: 0x0b83ff, country: "Haiti" },
  { start: 0x0ba000, end: 0x0ba3ff, country: "Honduras" },
  { start: 0x0bc000, end: 0x0bc3ff, country: "Saint Vincent and the Grenadines" },
  { start: 0x0be000, end: 0x0be3ff, country: "Jamaica" },
  { start: 0x0c0000, end: 0x0c0fff, country: "Nicaragua" },
  { start: 0x0c2000, end: 0x0c23ff, country: "Panama" },
  { start: 0x0c4000, end: 0x0c4fff, country: "Dominican Republic" },
  { start: 0x0c6000, end: 0x0c63ff, country: "Trinidad and Tobago" },
  { start: 0x0c8000, end: 0x0c8fff, country: "Suriname" },
  { start: 0x0ca000, end: 0x0ca3ff, country: "Antigua and Barbuda" },
  { start: 0x0cc000, end: 0x0cc3ff, country: "Grenada" },
  { start: 0x0d0000, end: 0x0d7fff, country: "Mexico" },
  { start: 0x0d8000, end: 0x0dffff, country: "Venezuela" },
  { start: 0x100000, end: 0x1fffff, country: "Russia" },
  { start: 0x201000, end: 0x2013ff, country: "Namibia" },
  { start: 0x202000, end: 0x2023ff, country: "Eritrea" },
  { start: 0x300000, end: 0x33ffff, country: "Italy" },
  { start: 0x340000, end: 0x37ffff, country: "Spain" },
  { start: 0x380000, end: 0x3bffff, country: "France" },
  { start: 0x3c0000, end: 0x3fffff, country: "Germany" },
  { start: 0x400000, end: 0x43ffff, country: "United Kingdom" },
  { start: 0x440000, end: 0x447fff, country: "Austria" },
  { start: 0x448000, end: 0x44ffff, country: "Belgium" },
  { start: 0x450000, end: 0x457fff, country: "Bulgaria" },
  { start: 0x458000, end: 0x45ffff, country: "Denmark" },
  { start: 0x460000, end: 0x467fff, country: "Finland" },
  { start: 0x468000, end: 0x46ffff, country: "Greece" },
  { start: 0x470000, end: 0x477fff, country: "Hungary" },
  { start: 0x478000, end: 0x47ffff, country: "Norway" },
  { start: 0x480000, end: 0x487fff, country: "Netherlands" },
  { start: 0x488000, end: 0x48ffff, country: "Poland" },
  { start: 0x490000, end: 0x497fff, country: "Portugal" },
  { start: 0x498000, end: 0x49ffff, country: "Czechia" },
  { start: 0x4a0000, end: 0x4a7fff, country: "Romania" },
  { start: 0x4a8000, end: 0x4affff, country: "Sweden" },
  { start: 0x4b0000, end: 0x4b7fff, country: "Switzerland" },
  { start: 0x4b8000, end: 0x4bffff, country: "Turkey" },
  { start: 0x4c0000, end: 0x4c7fff, country: "Serbia" },
  { start: 0x4c8000, end: 0x4c83ff, country: "Cyprus" },
  { start: 0x4ca000, end: 0x4cafff, country: "Ireland" },
  { start: 0x4cc000, end: 0x4ccfff, country: "Iceland" },
  { start: 0x4d0000, end: 0x4d03ff, country: "Luxembourg" },
  { start: 0x4d2000, end: 0x4d2fff, country: "Malta" },
  { start: 0x4d4000, end: 0x4d43ff, country: "Monaco" },
  { start: 0x500000, end: 0x5003ff, country: "San Marino" },
  { start: 0x501000, end: 0x5013ff, country: "Albania" },
  { start: 0x501c00, end: 0x501fff, country: "Croatia" },
  { start: 0x502c00, end: 0x502fff, country: "Latvia" },
  { start: 0x503c00, end: 0x503fff, country: "Lithuania" },
  { start: 0x504c00, end: 0x504fff, country: "Moldova" },
  { start: 0x505c00, end: 0x505fff, country: "Slovakia" },
  { start: 0x506c00, end: 0x506fff, country: "Slovenia" },
  { start: 0x507c00, end: 0x507fff, country: "Uzbekistan" },
  { start: 0x508000, end: 0x50ffff, country: "Ukraine" },
  { start: 0x510000, end: 0x5103ff, country: "Belarus" },
  { start: 0x511000, end: 0x5113ff, country: "Estonia" },
  { start: 0x512000, end: 0x5123ff, country: "North Macedonia" },
  { start: 0x513000, end: 0x5133ff, country: "Bosnia and Herzegovina" },
  { start: 0x514000, end: 0x5143ff, country: "Georgia" },
  { start: 0x515000, end: 0x5153ff, country: "Tajikistan" },
  { start: 0x516000, end: 0x5163ff, country: "Montenegro" },
  { start: 0x600000, end: 0x6003ff, country: "Armenia" },
  { start: 0x600800, end: 0x600bff, country: "Azerbaijan" },
  { start: 0x601000, end: 0x6013ff, country: "Kyrgyzstan" },
  { start: 0x601800, end: 0x601bff, country: "Turkmenistan" },
  { start: 0x680000, end: 0x6803ff, country: "Bhutan" },
  { start: 0x681000, end: 0x6813ff, country: "Micronesia" },
  { start: 0x682000, end: 0x6823ff, country: "Mongolia" },
  { start: 0x683000, end: 0x6833ff, country: "Kazakhstan" },
  { start: 0x684000, end: 0x6843ff, country: "Palau" },
  { start: 0x700000, end: 0x700fff, country: "Afghanistan" },
  { start: 0x702000, end: 0x702fff, country: "Bangladesh" },
  { start: 0x704000, end: 0x704fff, country: "Myanmar" },
  { start: 0x706000, end: 0x706fff, country: "Kuwait" },
  { start: 0x708000, end: 0x708fff, country: "Laos" },
  { start: 0x70a000, end: 0x70afff, country: "Nepal" },
  { start: 0x70c000, end: 0x70c3ff, country: "Oman" },
  { start: 0x70e000, end: 0x70efff, country: "Cambodia" },
  { start: 0x710000, end: 0x717fff, country: "Saudi Arabia" },
  { start: 0x718000, end: 0x71ffff, country: "South Korea" },
  { start: 0x720000, end: 0x727fff, country: "North Korea" },
  { start: 0x728000, end: 0x72ffff, country: "Iraq" },
  { start: 0x730000, end: 0x737fff, country: "Iran" },
  { start: 0x738000, end: 0x73ffff, country: "Israel" },
  { start: 0x740000, end: 0x747fff, country: "Jordan" },
  { start: 0x748000, end: 0x74ffff, country: "Lebanon" },
  { start: 0x750000, end: 0x757fff, country: "Malaysia" },
  { start: 0x758000, end: 0x75ffff, country: "Philippines" },
  { start: 0x760000, end: 0x767fff, country: "Pakistan" },
  { start: 0x768000, end: 0x76ffff, country: "Singapore" },
  { start: 0x770000, end: 0x777fff, country: "Sri Lanka" },
  { start: 0x778000, end: 0x77ffff, country: "Syria" },
  { start: 0x780000, end: 0x7bffff, country: "China" },
  { start: 0x7c0000, end: 0x7fffff, country: "Australia" },
  { start: 0x800000, end: 0x83ffff, country: "India" },
  { start: 0x840000, end: 0x87ffff, country: "Japan" },
  { start: 0x880000, end: 0x887fff, country: "Thailand" },
  { start: 0x888000, end: 0x88ffff, country: "Viet Nam" },
  { start: 0x890000, end: 0x890fff, country: "Yemen" },
  { start: 0x894000, end: 0x894fff, country: "Bahrain" },
  { start: 0x895000, end: 0x8953ff, country: "Brunei" },
  { start: 0x896000, end: 0x896fff, country: "United Arab Emirates" },
  { start: 0x897000, end: 0x8973ff, country: "Solomon Islands" },
  { start: 0x898000, end: 0x898fff, country: "Papua New Guinea" },
  { start: 0x899000, end: 0x8993ff, country: "Taiwan" },
  { start: 0x8a0000, end: 0x8a7fff, country: "Indonesia" },
  { start: 0x900000, end: 0x9003ff, country: "Marshall Islands" },
  { start: 0x901000, end: 0x9013ff, country: "Cook Islands" },
  { start: 0x902000, end: 0x9023ff, country: "Samoa" },
  { start: 0xa00000, end: 0xafffff, country: "United States" },
  { start: 0xc00000, end: 0xc3ffff, country: "Canada" },
  { start: 0xc80000, end: 0xc87fff, country: "New Zealand" },
  { start: 0xc88000, end: 0xc88fff, country: "Fiji" },
  { start: 0xc8a000, end: 0xc8a3ff, country: "Nauru" },
  { start: 0xc8c000, end: 0xc8c3ff, country: "Saint Lucia" },
  { start: 0xc8d000, end: 0xc8d3ff, country: "Tonga" },
  { start: 0xc8e000, end: 0xc8e3ff, country: "Kiribati" },
  { start: 0xc90000, end: 0xc903ff, country: "Vanuatu" },
  { start: 0xe00000, end: 0xe3ffff, country: "Argentina" },
  { start: 0xe40000, end: 0xe7ffff, country: "Brazil" },
  { start: 0xe80000, end: 0xe80fff, country: "Chile" },
  { start: 0xe84000, end: 0xe84fff, country: "Ecuador" },
  { start: 0xe88000, end: 0xe88fff, country: "Paraguay" },
  { start: 0xe8c000, end: 0xe8cfff, country: "Peru" },
  { start: 0xe90000, end: 0xe90fff, country: "Uruguay" },
  { start: 0xe94000, end: 0xe94fff, country: "Bolivia" },
];

/**
 * Resolve an icao24 hex string to a country name, or null if unallocated.
 *
 * Accepts any-case hex; non-hex / out-of-range / "~"-prefixed inputs return
 * null (callers should already have stripped "~" addresses, but we guard
 * anyway). Binary search over the sorted BLOCKS.
 */
export function countryForIcao24(icao24: string): string | null {
  const n = Number.parseInt(icao24, 16);
  if (!Number.isInteger(n) || n < 0 || n > 0xffffff) return null;
  let lo = 0;
  let hi = BLOCKS.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const b = BLOCKS[mid];
    if (n < b.start) {
      hi = mid - 1;
    } else if (n > b.end) {
      lo = mid + 1;
    } else {
      return b.country;
    }
  }
  return null;
}
