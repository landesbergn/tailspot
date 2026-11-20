ALTER TABLE "catches" ADD COLUMN "press_size" integer DEFAULT 1 NOT NULL;--> statement-breakpoint
-- Backfill (hand-written, scoring v10): every past press. Rows of one shutter
-- press share (device_id, caught_at) exactly; DISTINCT icao24 so a restored
-- duplicate row (same airframe, same instant) never reads as a multi-catch.
-- Points do not move here: the v9→v10 `npm run rescore` pays the bonus.
UPDATE "catches" AS c
SET "press_size" = p.n
FROM (
  SELECT "device_id", "caught_at", COUNT(DISTINCT "icao24")::integer AS n
  FROM "catches"
  GROUP BY "device_id", "caught_at"
  HAVING COUNT(DISTINCT "icao24") >= 2
) AS p
WHERE c."device_id" = p."device_id" AND c."caught_at" = p."caught_at";
