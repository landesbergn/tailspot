CREATE TABLE "monthly_champions" (
	"month_start" date NOT NULL,
	"device_id" uuid NOT NULL,
	"points" integer NOT NULL,
	"catches" integer NOT NULL,
	"decided_at" timestamp with time zone NOT NULL,
	CONSTRAINT "monthly_champions_month_start_device_id_pk" PRIMARY KEY("month_start","device_id")
);
--> statement-breakpoint
ALTER TABLE "monthly_champions" ADD CONSTRAINT "monthly_champions_device_id_devices_id_fk" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id") ON DELETE no action ON UPDATE no action;