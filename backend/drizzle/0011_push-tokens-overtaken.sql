ALTER TABLE "challenge_participants" ADD COLUMN "last_placement" integer;--> statement-breakpoint
ALTER TABLE "challenge_participants" ADD COLUMN "overtaken_notified_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "devices" ADD COLUMN "apns_token" text;--> statement-breakpoint
ALTER TABLE "devices" ADD COLUMN "apns_environment" text;--> statement-breakpoint
ALTER TABLE "devices" ADD COLUMN "apns_updated_at" timestamp with time zone;