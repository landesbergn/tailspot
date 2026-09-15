CREATE TABLE "challenge_participants" (
	"challenge_id" uuid NOT NULL,
	"device_id" uuid NOT NULL,
	"joined_at" timestamp with time zone NOT NULL,
	"left_at" timestamp with time zone,
	"joined_as_new_device" boolean DEFAULT false NOT NULL,
	CONSTRAINT "challenge_participants_challenge_id_device_id_pk" PRIMARY KEY("challenge_id","device_id")
);
--> statement-breakpoint
CREATE TABLE "challenge_results" (
	"challenge_id" uuid NOT NULL,
	"device_id" uuid NOT NULL,
	"placement" integer NOT NULL,
	"points" integer NOT NULL,
	"catches" integer NOT NULL,
	"rarity_breakdown" jsonb NOT NULL,
	CONSTRAINT "challenge_results_challenge_id_device_id_pk" PRIMARY KEY("challenge_id","device_id")
);
--> statement-breakpoint
CREATE TABLE "challenges" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"kind" text DEFAULT 'private' NOT NULL,
	"code" text,
	"name" text NOT NULL,
	"creator_device_id" uuid NOT NULL,
	"starts_at" timestamp with time zone NOT NULL,
	"ends_at" timestamp with time zone NOT NULL,
	"duration_preset" text NOT NULL,
	"max_participants" integer DEFAULT 10 NOT NULL,
	"cancelled_at" timestamp with time zone,
	"finalized_at" timestamp with time zone,
	"outcome" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "challenges_code_unique" UNIQUE("code")
);
--> statement-breakpoint
ALTER TABLE "devices" ADD COLUMN "referred_by_challenge_id" uuid;--> statement-breakpoint
ALTER TABLE "challenge_participants" ADD CONSTRAINT "challenge_participants_challenge_id_challenges_id_fk" FOREIGN KEY ("challenge_id") REFERENCES "public"."challenges"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "challenge_participants" ADD CONSTRAINT "challenge_participants_device_id_devices_id_fk" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "challenge_results" ADD CONSTRAINT "challenge_results_challenge_id_challenges_id_fk" FOREIGN KEY ("challenge_id") REFERENCES "public"."challenges"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "challenge_results" ADD CONSTRAINT "challenge_results_device_id_devices_id_fk" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "challenges" ADD CONSTRAINT "challenges_creator_device_id_devices_id_fk" FOREIGN KEY ("creator_device_id") REFERENCES "public"."devices"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "challenge_participants_device_active_idx" ON "challenge_participants" USING btree ("device_id") WHERE "challenge_participants"."left_at" is null;--> statement-breakpoint
CREATE INDEX "challenges_creator_idx" ON "challenges" USING btree ("creator_device_id");--> statement-breakpoint
CREATE INDEX "challenges_pending_finalize_idx" ON "challenges" USING btree ("ends_at") WHERE "challenges"."finalized_at" is null;--> statement-breakpoint
CREATE INDEX "catches_device_caught_idx" ON "catches" USING btree ("device_id","caught_at");