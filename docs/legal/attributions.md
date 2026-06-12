# Attributions

Tailspot is built on the work of several open data projects, public-domain government databases, and open-source contributors. This page is the canonical credits list; it is suitable for use in an in-app "About" or "Attributions" screen.

---

## Live aircraft position data — adsb.lol

Live aircraft positions are provided by **adsb.lol**, a community ADS-B aggregation network.

**License:** Open Database License (ODbL) 1.0
**License text:** https://opendatacommons.org/licenses/odbl/1-0/
**Source:** https://www.adsb.lol

**Required ODbL attribution statement:**

> This product uses data from adsb.lol, which is made available under the Open Database License (ODbL) v1.0. You are free to copy, distribute, transmit, and adapt this data, provided you attribute adsb.lol and its contributors. If you alter, transform, or build upon this data, you may distribute the resulting data only under the same license. Full license text: https://opendatacommons.org/licenses/odbl/1-0/

> REVIEW: ODbL's "share-alike" condition applies to *produced works* derived from the database. The in-app display of individual position fixes is a "Produced Work" (not a database redistribution) and does not trigger share-alike. However, if Tailspot's leaderboard or hangar ever publicly redistributes a *collection* of flight records derived from adsb.lol, that collection may constitute a "Derivative Database" subject to ODbL share-alike. Have a lawyer confirm the share-alike boundary before launching any feature that publishes aggregated position data.

---

## Aircraft registry data — FAA Releasable Aircraft Database

Aircraft registration and identity data for US-registered aircraft (N-numbers) is sourced from the **FAA Releasable Aircraft Database**.

**License:** Public domain
**Source:** https://www.faa.gov/licenses_certificates/aircraft_certification/aircraft_registry/releasable_aircraft_download
**Credit note:** Per the FAA: "All digital products published by the FAA are in the public domain… a written release or credit is not required." This credit is provided as a courtesy.

---

## Aircraft type designators — ICAO DOC 8643

Aircraft type identification uses type designators from **ICAO Document 8643 — Aircraft Type Designators**, published by the International Civil Aviation Organization.

**Source:** https://www.icao.int/publications/DOC8643/Pages/default.aspx
**Note:** DOC 8643 is a publicly accessible aeronautical reference. Type designators are factual identifiers (e.g., "B738" for the Boeing 737-800) and are not subject to creative copyright protection. This reference is used for aircraft identification, not for redistribution of the publication.

> REVIEW: ICAO publishes DOC 8643 as a public reference, but ICAO's broader publications carry copyright notices ("© ICAO"). The specific type-designator strings (short codes + manufacturer/model names) are widely treated as factual data and unlikely to attract copyright, but confirm with a lawyer if you plan to reproduce large extracts of the document's textual descriptions rather than just the designator codes and model names.

---

## Aircraft position data (fallback) — OpenSky Network

During the current development phase, aircraft position data may also be sourced from the **OpenSky Network** as a fallback data source.

**Source:** https://opensky-network.org
**Credit note:** The OpenSky Network, "Bringing up OpenSky: A large-scale ADS-B sensor network for research," IPSN 2014.

> REVIEW: OpenSky's terms restrict operational use of their data to non-profit research and education (see terms-of-service.md §1 and the research document at docs/superpowers/research/2026-06-07-adsb-metadata-sources.md). OpenSky use as a live backend data source requires review or a written agreement with OpenSky. This attribution is included for completeness during the development phase; it should be updated or removed once the backend switches to adsb.lol as primary and OpenSky is no longer used operationally.

---

## Aircraft photos — Planespotters.net

Aircraft photographs shown in the app are provided by **Planespotters.net** via their API. Each photograph is credited to its individual photographer as returned by the API.

**Source:** https://www.planespotters.net
**Per-photo attribution:** Photographer name and link are displayed alongside each photo in the app, as required by Planespotters.net's terms of use.

> REVIEW: Review Planespotters.net's API terms before public beta and App Store launch to confirm that the photographer attribution displayed in the app satisfies their requirements. Their terms may specify minimum attribution display size or link requirements; confirm the in-app display meets the bar.

---

## Typography — B612 Mono

The B612 Mono typeface is used in the app's UI.

**License:** SIL Open Font License 1.1 (OFL 1.1)
**License text:** https://openfontlicense.org/
**Creator:** Airbus, via the B612 project
**Source:** https://b612-font.com

The OFL permits use, distribution, and modification of the font, provided the font is not sold by itself and derivative fonts use a different reserved font name.

---

*Last updated: 2026-06-11*
