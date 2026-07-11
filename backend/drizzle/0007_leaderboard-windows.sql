CREATE TABLE "alltime_toppers" (
	"device_id" uuid PRIMARY KEY NOT NULL,
	"first_topped_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "weekly_champions" (
	"week_start" date NOT NULL,
	"device_id" uuid NOT NULL,
	"points" integer NOT NULL,
	"catches" integer NOT NULL,
	"decided_at" timestamp with time zone NOT NULL,
	CONSTRAINT "weekly_champions_week_start_device_id_pk" PRIMARY KEY("week_start","device_id")
);
--> statement-breakpoint
ALTER TABLE "alltime_toppers" ADD CONSTRAINT "alltime_toppers_device_id_devices_id_fk" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "weekly_champions" ADD CONSTRAINT "weekly_champions_device_id_devices_id_fk" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id") ON DELETE no action ON UPDATE no action;