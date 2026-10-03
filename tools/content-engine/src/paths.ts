import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** tools/content-engine/ */
export const ENGINE_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
/** Repo root (two levels up). */
export const REPO_ROOT = resolve(ENGINE_DIR, "..", "..");

/** The app's own type table — the source of truth for rarity tiers. */
export const AIRCRAFT_TYPES_PATH = join(REPO_ROOT, "ios/Tailspot/Tailspot/AircraftTypes.json");
/** Noah's own catch photos (the only photos this engine may use). */
export const CATCH_PHOTOS_DIR = join(REPO_ROOT, "marketing/catch-photos");
/** B612 Mono ships with the app; reuse it rather than vendoring a copy. */
export const B612_DIR = join(REPO_ROOT, "ios/Tailspot/Tailspot");
export const APP_ICON_PATH = join(REPO_ROOT, "ios/Tailspot/Tailspot/Assets.xcassets/AppIcon.appiconset/icon-dark.png");
export const INTER_FONT_PATH = join(ENGINE_DIR, "assets/fonts/Inter-latin-var.woff2");
export const FIXTURES_DIR = join(ENGINE_DIR, "fixtures");
export const DEFAULT_OUT_DIR = join(ENGINE_DIR, "out");
