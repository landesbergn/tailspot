ALTER TABLE "catches" DROP CONSTRAINT "catches_catch_uuid_unique";--> statement-breakpoint
CREATE UNIQUE INDEX "catches_device_catch_uuid_unique" ON "catches" USING btree ("device_id","catch_uuid");