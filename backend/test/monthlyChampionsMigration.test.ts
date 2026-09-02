import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import { migrate } from "drizzle-orm/pglite/migrator";
import { describe, expect, it } from "vitest";

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, "../drizzle");

async function applyRawMigration(client: PGlite, filename: string): Promise<void> {
  const sqlText = readFileSync(join(migrationsDir, filename), "utf8");
  for (const statement of sqlText.split("--> statement-breakpoint")) {
    const trimmed = statement.trim();
    if (trimmed !== "") await client.exec(trimmed);
  }
}

async function applyThrough0007(client: PGlite): Promise<void> {
  const files = readdirSync(migrationsDir)
    .filter((filename) => filename.endsWith(".sql") && filename < "0008_")
    .sort();
  for (const filename of files) await applyRawMigration(client, filename);
}

const ALICE = "00000000-0000-4000-8000-000000000001";
const BOB = "00000000-0000-4000-8000-000000000002";

describe("0008 monthly champions migration", () => {
  it("upgrades a populated 0007 database without changing existing data", async () => {
    const client = new PGlite();
    await applyThrough0007(client);

    await client.exec(`
      insert into devices (id, token_hash, handle, created_at) values
        ('${ALICE}', 'alice-token-hash', 'Alice', '2026-06-01T00:00:00Z'),
        ('${BOB}', 'bob-token-hash', 'Bob', '2026-06-02T00:00:00Z');

      insert into catches (
        id, catch_uuid, device_id, icao24, points, caught_at,
        observer_lat, observer_lon
      ) values
        ('10000000-0000-4000-8000-000000000001',
         '20000000-0000-4000-8000-000000000001',
         '${ALICE}', 'abc123', 75, '2026-06-15T12:00:00Z', 37.8, -122.2),
        ('10000000-0000-4000-8000-000000000002',
         '20000000-0000-4000-8000-000000000002',
         '${BOB}', 'def456', 50, '2026-06-16T12:00:00Z', 37.8, -122.2);

      insert into weekly_champions
        (week_start, device_id, points, catches, decided_at)
      values ('2026-06-15', '${ALICE}', 75, 1, '2026-06-22T00:00:01Z');

      insert into alltime_toppers (device_id, first_topped_at)
      values ('${ALICE}', '2026-06-22T00:00:01Z');
    `);

    const before = await client.query(`
      select
        (select count(*)::int from devices) as devices,
        (select count(*)::int from catches) as catches,
        (select count(*)::int from weekly_champions) as weekly_champions,
        (select count(*)::int from alltime_toppers) as alltime_toppers,
        (select sum(points)::int from catches) as catch_points
    `);
    expect(before.rows[0]).toEqual({
      devices: 2,
      catches: 2,
      weekly_champions: 1,
      alltime_toppers: 1,
      catch_points: 125,
    });
    expect(
      (await client.query("select to_regclass('public.monthly_champions') as table_name")).rows[0],
    ).toEqual({ table_name: null });

    await applyRawMigration(client, "0008_wandering_ultimo.sql");

    const after = await client.query(`
      select
        (select count(*)::int from devices) as devices,
        (select count(*)::int from catches) as catches,
        (select count(*)::int from weekly_champions) as weekly_champions,
        (select count(*)::int from alltime_toppers) as alltime_toppers,
        (select sum(points)::int from catches) as catch_points,
        (select count(*)::int from monthly_champions) as monthly_champions
    `);
    expect(after.rows[0]).toEqual({
      ...before.rows[0],
      monthly_champions: 0,
    });

    // Shared crowns are representable: same month, two different devices.
    await client.exec(`
      insert into monthly_champions
        (month_start, device_id, points, catches, decided_at)
      values
        ('2026-06-01', '${ALICE}', 75, 1, '2026-07-01T00:00:01Z'),
        ('2026-06-01', '${BOB}', 75, 1, '2026-07-01T00:00:01Z')
    `);
    expect(
      (await client.query("select count(*)::int as count from monthly_champions")).rows[0],
    ).toEqual({ count: 2 });

    // The composite primary key blocks a duplicate crown for one device.
    await expect(
      client.exec(`
        insert into monthly_champions
          (month_start, device_id, points, catches, decided_at)
        values ('2026-06-01', '${ALICE}', 75, 1, '2026-07-01T00:00:02Z')
      `),
    ).rejects.toThrow();

    // The foreign key blocks orphaned champion rows.
    await expect(
      client.exec(`
        insert into monthly_champions
          (month_start, device_id, points, catches, decided_at)
        values (
          '2026-06-01', '00000000-0000-4000-8000-000000000099',
          75, 1, '2026-07-01T00:00:02Z'
        )
      `),
    ).rejects.toThrow();
  });

  it("is a no-op when the production migrator runs a second time", async () => {
    const client = new PGlite();
    const db = drizzle(client);

    await migrate(db, { migrationsFolder: migrationsDir });
    const first = await client.query(`
      select count(*)::int as count from drizzle.__drizzle_migrations
    `);

    await migrate(db, { migrationsFolder: migrationsDir });
    const second = await client.query(`
      select count(*)::int as count from drizzle.__drizzle_migrations
    `);

    expect(second.rows[0]).toEqual(first.rows[0]);
    expect(
      (await client.query("select to_regclass('public.monthly_champions') as table_name")).rows[0],
    ).toEqual({ table_name: "monthly_champions" });
  });
});
