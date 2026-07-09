ALTER TABLE "catches" ADD COLUMN "guess_kind" text;--> statement-breakpoint
ALTER TABLE "catches" ADD COLUMN "guess_value" text;--> statement-breakpoint
ALTER TABLE "catches" ADD COLUMN "guess_correct" boolean DEFAULT false NOT NULL;