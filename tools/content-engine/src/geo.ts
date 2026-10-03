/**
 * Coarse, offline "where is it" naming. Slides say a REGION ("about 200 km
 * NE of Denver, USA", "over the North Atlantic"), never coordinates precise
 * enough to pin an aircraft to a field or a house. Region-level only.
 */

import { cardinal } from "./util.ts";

const R_KM = 6371;
const toRad = (d: number) => (d * Math.PI) / 180;
const toDeg = (r: number) => (r * 180) / Math.PI;

export function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R_KM * Math.asin(Math.min(1, Math.sqrt(a)));
}

/** Initial bearing from point 1 to point 2, degrees true. */
export function bearingDeg(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const y = Math.sin(toRad(lon2 - lon1)) * Math.cos(toRad(lat2));
  const x =
    Math.cos(toRad(lat1)) * Math.sin(toRad(lat2)) -
    Math.sin(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.cos(toRad(lon2 - lon1));
  return (toDeg(Math.atan2(y, x)) + 360) % 360;
}

/** [name, country-or-state, lat, lon] — well-known reference cities, approx. centres. */
type City = [string, string, number, number];
export const CITIES: readonly City[] = [
  // North America
  ["San Francisco", "California", 37.77, -122.42], ["Los Angeles", "California", 34.05, -118.24],
  ["San Diego", "California", 32.72, -117.16], ["Sacramento", "California", 38.58, -121.49],
  ["Las Vegas", "Nevada", 36.17, -115.14], ["Reno", "Nevada", 39.53, -119.81],
  ["Phoenix", "Arizona", 33.45, -112.07], ["Salt Lake City", "Utah", 40.76, -111.89],
  ["Denver", "Colorado", 39.74, -104.99], ["Seattle", "Washington", 47.61, -122.33],
  ["Portland", "Oregon", 45.52, -122.68], ["Boise", "Idaho", 43.62, -116.2],
  ["Albuquerque", "New Mexico", 35.08, -106.65], ["El Paso", "Texas", 31.76, -106.49],
  ["Dallas", "Texas", 32.78, -96.8], ["Houston", "Texas", 29.76, -95.37],
  ["San Antonio", "Texas", 29.42, -98.49], ["Oklahoma City", "Oklahoma", 35.47, -97.52],
  ["Kansas City", "Missouri", 39.1, -94.58], ["Omaha", "Nebraska", 41.26, -95.94],
  ["Minneapolis", "Minnesota", 44.98, -93.27], ["Chicago", "Illinois", 41.88, -87.63],
  ["Detroit", "Michigan", 42.33, -83.05], ["St. Louis", "Missouri", 38.63, -90.2],
  ["Memphis", "Tennessee", 35.15, -90.05], ["Nashville", "Tennessee", 36.16, -86.78],
  ["Atlanta", "Georgia", 33.75, -84.39], ["New Orleans", "Louisiana", 29.95, -90.07],
  ["Miami", "Florida", 25.76, -80.19], ["Orlando", "Florida", 28.54, -81.38],
  ["Jacksonville", "Florida", 30.33, -81.66], ["Charlotte", "North Carolina", 35.23, -80.84],
  ["Washington, D.C.", "USA", 38.91, -77.04], ["Philadelphia", "Pennsylvania", 39.95, -75.17],
  ["New York", "USA", 40.71, -74.01], ["Boston", "Massachusetts", 42.36, -71.06],
  ["Pittsburgh", "Pennsylvania", 40.44, -80.0], ["Indianapolis", "Indiana", 39.77, -86.16],
  ["Billings", "Montana", 45.78, -108.5], ["Fargo", "North Dakota", 46.88, -96.79],
  ["Anchorage", "Alaska", 61.22, -149.9], ["Fairbanks", "Alaska", 64.84, -147.72],
  ["Honolulu", "Hawaii", 21.31, -157.86], ["Vancouver", "Canada", 49.28, -123.12],
  ["Calgary", "Canada", 51.05, -114.07], ["Edmonton", "Canada", 53.55, -113.49],
  ["Winnipeg", "Canada", 49.9, -97.14], ["Toronto", "Canada", 43.65, -79.38],
  ["Montreal", "Canada", 45.5, -73.57], ["Halifax", "Canada", 44.65, -63.57],
  ["St. John's", "Newfoundland", 47.56, -52.71], ["Mexico City", "Mexico", 19.43, -99.13],
  ["Monterrey", "Mexico", 25.69, -100.32], ["Guadalajara", "Mexico", 20.66, -103.35],
  ["Cancún", "Mexico", 21.16, -86.85], ["Havana", "Cuba", 23.11, -82.37],
  ["San Juan", "Puerto Rico", 18.47, -66.11], ["Panama City", "Panama", 8.98, -79.52],
  // South America
  ["Bogotá", "Colombia", 4.71, -74.07], ["Caracas", "Venezuela", 10.48, -66.9],
  ["Quito", "Ecuador", -0.18, -78.47], ["Lima", "Peru", -12.05, -77.04],
  ["Santiago", "Chile", -33.45, -70.67], ["Buenos Aires", "Argentina", -34.6, -58.38],
  ["São Paulo", "Brazil", -23.55, -46.63], ["Rio de Janeiro", "Brazil", -22.91, -43.17],
  ["Brasília", "Brazil", -15.79, -47.88], ["Manaus", "Brazil", -3.12, -60.02],
  // Europe
  ["London", "UK", 51.51, -0.13], ["Manchester", "UK", 53.48, -2.24],
  ["Glasgow", "UK", 55.86, -4.25], ["Dublin", "Ireland", 53.35, -6.26],
  ["Paris", "France", 48.86, 2.35], ["Lyon", "France", 45.76, 4.84],
  ["Marseille", "France", 43.3, 5.37], ["Brussels", "Belgium", 50.85, 4.35],
  ["Amsterdam", "Netherlands", 52.37, 4.9], ["Frankfurt", "Germany", 50.11, 8.68],
  ["Berlin", "Germany", 52.52, 13.4], ["Hamburg", "Germany", 53.55, 9.99],
  ["Munich", "Germany", 48.14, 11.58], ["Zurich", "Switzerland", 47.38, 8.54],
  ["Vienna", "Austria", 48.21, 16.37], ["Prague", "Czechia", 50.08, 14.44],
  ["Warsaw", "Poland", 52.23, 21.01], ["Copenhagen", "Denmark", 55.68, 12.57],
  ["Oslo", "Norway", 59.91, 10.75], ["Stockholm", "Sweden", 59.33, 18.07],
  ["Helsinki", "Finland", 60.17, 24.94], ["Reykjavík", "Iceland", 64.15, -21.94],
  ["Madrid", "Spain", 40.42, -3.7], ["Barcelona", "Spain", 41.39, 2.17],
  ["Lisbon", "Portugal", 38.72, -9.14], ["Rome", "Italy", 41.9, 12.5],
  ["Milan", "Italy", 45.46, 9.19], ["Naples", "Italy", 40.85, 14.27],
  ["Athens", "Greece", 37.98, 23.73], ["Istanbul", "Türkiye", 41.01, 28.98],
  ["Ankara", "Türkiye", 39.93, 32.86], ["Bucharest", "Romania", 44.43, 26.1],
  ["Budapest", "Hungary", 47.5, 19.04], ["Belgrade", "Serbia", 44.79, 20.45],
  ["Kyiv", "Ukraine", 50.45, 30.52], ["Riga", "Latvia", 56.95, 24.11],
  ["Moscow", "Russia", 55.76, 37.62], ["St. Petersburg", "Russia", 59.93, 30.36],
  // Middle East & Africa
  ["Dubai", "UAE", 25.2, 55.27], ["Doha", "Qatar", 25.29, 51.53],
  ["Riyadh", "Saudi Arabia", 24.71, 46.68], ["Jeddah", "Saudi Arabia", 21.49, 39.19],
  ["Tel Aviv", "Israel", 32.09, 34.78], ["Amman", "Jordan", 31.95, 35.93],
  ["Baghdad", "Iraq", 33.31, 44.36], ["Tehran", "Iran", 35.69, 51.39],
  ["Kuwait City", "Kuwait", 29.38, 47.99], ["Muscat", "Oman", 23.59, 58.41],
  ["Cairo", "Egypt", 30.04, 31.24], ["Casablanca", "Morocco", 33.57, -7.59],
  ["Algiers", "Algeria", 36.75, 3.06], ["Tunis", "Tunisia", 36.81, 10.18],
  ["Lagos", "Nigeria", 6.52, 3.38], ["Accra", "Ghana", 5.6, -0.19],
  ["Dakar", "Senegal", 14.72, -17.47], ["Nairobi", "Kenya", -1.29, 36.82],
  ["Addis Ababa", "Ethiopia", 9.03, 38.74], ["Johannesburg", "South Africa", -26.2, 28.05],
  ["Cape Town", "South Africa", -33.92, 18.42], ["Kinshasa", "DR Congo", -4.44, 15.27],
  ["Khartoum", "Sudan", 15.5, 32.56], ["Luanda", "Angola", -8.84, 13.23],
  // Asia
  ["Karachi", "Pakistan", 24.86, 67.01], ["Delhi", "India", 28.61, 77.21],
  ["Mumbai", "India", 19.08, 72.88], ["Bengaluru", "India", 12.97, 77.59],
  ["Chennai", "India", 13.08, 80.27], ["Kolkata", "India", 22.57, 88.36],
  ["Kathmandu", "Nepal", 27.72, 85.32], ["Dhaka", "Bangladesh", 23.81, 90.41],
  ["Colombo", "Sri Lanka", 6.93, 79.86], ["Bangkok", "Thailand", 13.76, 100.5],
  ["Yangon", "Myanmar", 16.87, 96.2], ["Hanoi", "Vietnam", 21.03, 105.85],
  ["Ho Chi Minh City", "Vietnam", 10.82, 106.63], ["Kuala Lumpur", "Malaysia", 3.14, 101.69],
  ["Singapore", "Singapore", 1.35, 103.82], ["Jakarta", "Indonesia", -6.21, 106.85],
  ["Surabaya", "Indonesia", -7.25, 112.75], ["Denpasar", "Bali", -8.65, 115.22],
  ["Manila", "Philippines", 14.6, 120.98], ["Hong Kong", "China", 22.32, 114.17],
  ["Taipei", "Taiwan", 25.03, 121.57], ["Shanghai", "China", 31.23, 121.47],
  ["Beijing", "China", 39.9, 116.41], ["Guangzhou", "China", 23.13, 113.26],
  ["Chengdu", "China", 30.57, 104.07], ["Seoul", "South Korea", 37.57, 126.98],
  ["Tokyo", "Japan", 35.68, 139.69], ["Osaka", "Japan", 34.69, 135.5],
  ["Sapporo", "Japan", 43.06, 141.35], ["Fukuoka", "Japan", 33.59, 130.4],
  ["Naha", "Okinawa", 26.21, 127.68], ["Ulaanbaatar", "Mongolia", 47.89, 106.91],
  ["Almaty", "Kazakhstan", 43.24, 76.89], ["Tashkent", "Uzbekistan", 41.3, 69.24],
  ["Novosibirsk", "Russia", 55.01, 82.93], ["Yekaterinburg", "Russia", 56.84, 60.61],
  ["Vladivostok", "Russia", 43.12, 131.89], ["Hagåtña", "Guam", 13.47, 144.75],
  // Oceania
  ["Sydney", "Australia", -33.87, 151.21], ["Melbourne", "Australia", -37.81, 144.96],
  ["Brisbane", "Australia", -27.47, 153.03], ["Perth", "Australia", -31.95, 115.86],
  ["Adelaide", "Australia", -34.93, 138.6], ["Darwin", "Australia", -12.46, 130.84],
  ["Cairns", "Australia", -16.92, 145.77], ["Alice Springs", "Australia", -23.7, 133.88],
  ["Auckland", "New Zealand", -36.85, 174.76], ["Christchurch", "New Zealand", -43.53, 172.64],
  ["Nadi", "Fiji", -17.8, 177.42], ["Port Moresby", "Papua New Guinea", -9.44, 147.18],
  ["Nouméa", "New Caledonia", -22.28, 166.46], ["Papeete", "Tahiti", -17.53, -149.57],
  ["Hobart", "Australia", -42.88, 147.33], ["Townsville", "Australia", -19.26, 146.82],
  ["Broome", "Australia", -17.96, 122.24], ["Wellington", "New Zealand", -41.29, 174.78],
  // Fill-ins so sparse regions still get a city reference
  ["Thunder Bay", "Canada", 48.38, -89.25], ["Sault Ste. Marie", "Michigan", 46.5, -84.35],
  ["Duluth", "Minnesota", 46.79, -92.1], ["Milwaukee", "Wisconsin", 43.04, -87.91],
  ["Cleveland", "Ohio", 41.5, -81.69], ["Louisville", "Kentucky", 38.25, -85.76],
  ["Raleigh", "North Carolina", 35.78, -78.64], ["Norfolk", "Virginia", 36.85, -76.29],
  ["Ottawa", "Canada", 45.42, -75.7], ["Quebec City", "Canada", 46.81, -71.21],
  ["Regina", "Canada", 50.45, -104.62], ["Saskatoon", "Canada", 52.13, -106.67],
  ["Whitehorse", "Canada", 60.72, -135.06], ["Yellowknife", "Canada", 62.45, -114.37],
  ["Iqaluit", "Canada", 63.75, -68.52], ["Juneau", "Alaska", 58.3, -134.42],
  ["Nome", "Alaska", 64.5, -165.41], ["Utqiaġvik", "Alaska", 71.29, -156.79],
  ["Bismarck", "North Dakota", 46.81, -100.78], ["Rapid City", "South Dakota", 44.08, -103.23],
  ["Spokane", "Washington", 47.66, -117.43], ["Cheyenne", "Wyoming", 41.14, -104.82],
  ["Hilo", "Hawaii", 19.71, -155.09], ["Bermuda", "Bermuda", 32.3, -64.78],
  ["Ponta Delgada", "Azores", 37.74, -25.67], ["Las Palmas", "Canary Islands", 28.12, -15.44],
  ["Shannon", "Ireland", 52.7, -8.86], ["Bergen", "Norway", 60.39, 5.32],
  ["Tromsø", "Norway", 69.65, 18.96], ["Nuuk", "Greenland", 64.18, -51.72],
  ["Tripoli", "Libya", 32.89, 13.19], ["Niamey", "Niger", 13.51, 2.11],
  ["Bamako", "Mali", 12.64, -8.0], ["Abidjan", "Côte d'Ivoire", 5.36, -4.01],
  ["Douala", "Cameroon", 4.05, 9.77], ["Dar es Salaam", "Tanzania", -6.79, 39.21],
  ["Lusaka", "Zambia", -15.39, 28.32], ["Harare", "Zimbabwe", -17.83, 31.05],
  ["Windhoek", "Namibia", -22.56, 17.08], ["Antananarivo", "Madagascar", -18.88, 47.51],
  ["Islamabad", "Pakistan", 33.68, 73.05], ["Kabul", "Afghanistan", 34.56, 69.21],
  ["Lhasa", "China", 29.65, 91.17], ["Ürümqi", "China", 43.83, 87.62],
  ["Harbin", "China", 45.8, 126.53], ["Irkutsk", "Russia", 52.29, 104.3],
  ["Yakutsk", "Russia", 62.03, 129.73], ["Magadan", "Russia", 59.57, 150.8],
  ["Petropavlovsk-Kamchatsky", "Russia", 53.02, 158.65], ["Wake Island", "Pacific", 19.28, 166.65],
  ["La Paz", "Bolivia", -16.5, -68.15], ["Asunción", "Paraguay", -25.26, -57.58],
  ["Montevideo", "Uruguay", -34.9, -56.16], ["Recife", "Brazil", -8.05, -34.88],
  ["Belém", "Brazil", -1.46, -48.5], ["Punta Arenas", "Chile", -53.16, -70.91],
];

/** Coarse boxes for when no reference city is within range. First match wins. */
const AREAS: ReadonlyArray<[string, number, number, number, number]> = [
  // [label, latMin, latMax, lonMin, lonMax]
  ["the Arctic", 72, 90, -180, 180],
  ["Antarctica and the Southern Ocean", -90, -60, -180, 180],
  ["Greenland", 60, 84, -75, -10],
  ["northern Canada", 55, 72, -141, -60],
  ["Siberia", 50, 75, 60, 180],
  ["Central Asia", 35, 55, 50, 100],
  ["the Sahara", 15, 33, -15, 35],
  ["central Africa", -15, 15, 10, 40],
  ["the Arabian Peninsula", 12, 30, 35, 60],
  ["the Australian Outback", -35, -15, 115, 150],
  ["the Amazon", -15, 5, -75, -45],
  ["the Gulf of Mexico", 18, 30, -98, -82],
  ["the Mediterranean", 30, 45, -5, 36],
  ["the Caribbean", 10, 25, -85, -60],
  ["the North Atlantic", 0, 72, -80, -5],
  ["the South Atlantic", -60, 0, -60, 15],
  ["the Indian Ocean", -60, 25, 20, 120],
  ["the North Pacific", 0, 72, 120, 180],
  ["the North Pacific", 0, 72, -180, -100],
  ["the South Pacific", -60, 0, 120, 180],
  ["the South Pacific", -60, 0, -180, -70],
];

export interface Region {
  /** e.g. "near Denver, Colorado" / "about 300 km NE of Anchorage, Alaska" / "over the North Atlantic" */
  phrase: string;
  /** Short label for a data row ("Denver area", "North Atlantic"). */
  short: string;
}

const NEAR_KM = 80;
const RELATIVE_KM = 450;

export function nearestCity(lat: number, lon: number): { city: City; km: number } {
  let best = CITIES[0];
  let bestKm = Infinity;
  for (const c of CITIES) {
    const d = haversineKm(lat, lon, c[2], c[3]);
    if (d < bestKm) {
      best = c;
      bestKm = d;
    }
  }
  return { city: best, km: bestKm };
}

export function regionFor(lat: number, lon: number): Region {
  const { city, km } = nearestCity(lat, lon);
  const [name, where] = city;
  const label = name === where || where === "USA" ? name : `${name}, ${where}`;
  if (km <= NEAR_KM) return { phrase: `near ${label}`, short: `${name} area` };
  if (km <= RELATIVE_KM) {
    const dir = cardinal(bearingDeg(city[2], city[3], lat, lon));
    const rounded = Math.round(km / 10) * 10;
    return { phrase: `about ${rounded} km ${dir} of ${label}`, short: `${rounded} km ${dir} of ${name}` };
  }
  for (const [area, latMin, latMax, lonMin, lonMax] of AREAS) {
    if (lat >= latMin && lat <= latMax && lon >= lonMin && lon <= lonMax) {
      return { phrase: `over ${area}`, short: area.replace(/^the /, "").replace(/^./, (c) => c.toUpperCase()) };
    }
  }
  const ns = `${Math.abs(Math.round(lat))}°${lat >= 0 ? "N" : "S"}`;
  const ew = `${Math.abs(Math.round(lon))}°${lon >= 0 ? "E" : "W"}`;
  return { phrase: `around ${ns} ${ew}`, short: `${ns} ${ew}` };
}
