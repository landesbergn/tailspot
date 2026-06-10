# Test image sources

All images are from Wikimedia Commons, downloaded at a capped 800 px width via
`download.py` (which routes through the Commons `Special:FilePath?width=` thumbnail
endpoint). Total committed set is ~0.45 MB, so the JPEGs are committed directly.

To re-fetch: `python3 download.py` (no venv needed — stdlib `urllib` only).

Each entry: local filename, scenario it covers, the Commons file page, author,
and license. All licenses below permit reuse with attribution (CC0 requires
none); none are non-commercial-restricted.

| Local file | Scenario | Author | License |
|---|---|---|---|
| `01_airliner_overhead.jpg` | Airliner crossing overhead at altitude (small in frame) | Hermann Luyken | CC0 (public domain dedication) |
| `02_airliner_approach.jpg` | Airliner on final approach, gear down (medium/large) | Martin Cathrae | CC BY-SA 2.0 |
| `03_plane_in_clouds.jpg` | Jet against cloud/haze backdrop | SuperJet International | CC BY-SA 2.0 |
| `04_helicopter.jpg` | Helicopter in flight, daytime, airframe clearly visible (not a COCO "airplane" — false-positive probe) | CAPTAIN RAJU | CC BY-SA 4.0 |
| `05_empty_sky.jpg` | Empty sky, no aircraft (negative control) | Etim Blessing | CC BY 4.0 |
| `06_cessna_ga.jpg` | Small GA aircraft (Cessna 172) in flight | Eddie Maloney | CC BY-SA 2.0 |
| `07_airliner_distant.jpg` | Distant airliner small against sky over landscape | "The Bushranger" | CC BY-SA 4.0 |

## Full attribution + page links

1. **01_airliner_overhead.jpg** — "An airplane crossing our path" (Lufthansa flight LH6802),
   by Hermann Luyken. CC0.
   https://commons.wikimedia.org/wiki/File:2011.10.15.184427_LH6802_Airplane_crossing_Switzerland.jpg

2. **02_airliner_approach.jpg** — "Boeing 737-700 C-GYWJ WestJet 0886" (landing configuration),
   by Martin Cathrae. CC BY-SA 2.0.
   https://commons.wikimedia.org/wiki/File:Boeing_737-700_C-GYWJ_WestJet_0886.jpg

3. **03_plane_in_clouds.jpg** — "Sukhoi SuperJet 100", by SuperJet International. CC BY-SA 2.0.
   https://commons.wikimedia.org/wiki/File:Sukhoi_SuperJet_100_(5114478300).jpg

4. **04_helicopter.jpg** — "Helicopter on the sky in 2021.01", by CAPTAIN RAJU. CC BY-SA 4.0.
   https://commons.wikimedia.org/wiki/File:Helicopter_on_the_sky_in_2021.01.jpg

5. **05_empty_sky.jpg** — "Awesome beauty of the Sky", by Etim Blessing. CC BY 4.0.
   https://commons.wikimedia.org/wiki/File:Awesome_beauty_of_the_Sky.jpg

6. **06_cessna_ga.jpg** — "Cessna 172 N4811V", by Eddie Maloney. CC BY-SA 2.0.
   https://commons.wikimedia.org/wiki/File:Cessna_172_N4811V_(2700356170).jpg

7. **07_airliner_distant.jpg** — "American Eagle over Southeast Farm", by "The Bushranger".
   CC BY-SA 4.0.
   https://commons.wikimedia.org/wiki/File:American_Eagle_over_Southeast_Farm.jpg
