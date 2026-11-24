# Data notices

## notable-airframes.json

Derived from **plane-alert-db**, a community-maintained list of notable
aircraft: https://github.com/sdr-enthusiasts/plane-alert-db

Copyright (C) 2022-2024 by SDR-Enthusiasts, Ramon F. Kolb (kx1t), and contributors

plane-alert-db is made available under the Open Database License (ODbL) 1.0:
https://opendatacommons.org/licenses/odbl/1-0/

`notable-airframes.json` is a filtered and re-mapped extract of that database
(see `src/notable/mapping.ts` for the rules, `npm run notable:snapshot` to
regenerate it). As a derivative database it is offered under the same licence,
ODbL 1.0. The running server also reads the upstream file directly, once a
day.
