CREATE TABLE "registry" (
	"icao24" text PRIMARY KEY NOT NULL,
	"registration" text,
	"manufacturer_raw" text,
	"model_raw" text,
	"typecode" text,
	"source" text DEFAULT 'faa' NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "typecodes" (
	"typecode" text PRIMARY KEY NOT NULL,
	"manufacturer" text,
	"model" text,
	"type" text,
	"rarity" text
);
