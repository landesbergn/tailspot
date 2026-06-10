CREATE TABLE "catches" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"catch_uuid" uuid NOT NULL,
	"device_id" uuid NOT NULL,
	"icao24" text NOT NULL,
	"callsign" text,
	"typecode" text,
	"rarity" text,
	"points" integer NOT NULL,
	"caught_at" timestamp with time zone NOT NULL,
	"observer_lat" double precision NOT NULL,
	"observer_lon" double precision NOT NULL,
	"heading_deg" double precision,
	"elevation_deg" double precision,
	"heading_accuracy_deg" double precision,
	"aircraft_lat" double precision NOT NULL,
	"aircraft_lon" double precision NOT NULL,
	"aircraft_altitude_meters" double precision NOT NULL,
	"aircraft_position_timestamp" timestamp with time zone,
	"validation" jsonb,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "catches_catch_uuid_unique" UNIQUE("catch_uuid")
);
--> statement-breakpoint
CREATE TABLE "devices" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"token_hash" text NOT NULL,
	"handle" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "devices_token_hash_unique" UNIQUE("token_hash")
);
--> statement-breakpoint
ALTER TABLE "catches" ADD CONSTRAINT "catches_device_id_devices_id_fk" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "catches_device_idx" ON "catches" USING btree ("device_id");--> statement-breakpoint
CREATE INDEX "catches_icao_idx" ON "catches" USING btree ("icao24");--> statement-breakpoint
CREATE UNIQUE INDEX "devices_handle_lower_unique" ON "devices" USING btree (lower("handle")) WHERE "devices"."handle" is not null;