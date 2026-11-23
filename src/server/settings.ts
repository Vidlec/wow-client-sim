// The user's settings (paths.ts says where): read once as the app starts, changed through the setup API, written
// back whole. Keys the app does not know (developer switches such as gameWorldMap or extraEvents) are kept as they
// are and passed to the simulator.
//
// From a source checkout, the config.json of before is read in: on the first run, and again whenever it is changed
// after that (so editing it by hand still works); what the page changes goes to the settings.
import { existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { EditModeLayout, Settings, SettingsChange, SetupProblem } from "../shared/setup.ts";
import { DEFAULT_FLAVOUR, findFlavour, isKnownFlavour } from "./flavours/index.ts";
import { HOME_OVERRIDE_SET, IS_SOURCE_CHECKOUT, LEGACY_CONFIG_PATH, SETTINGS_PATH } from "./paths.ts";

/** The settings and the unknown keys kept beside them */
export type StoredSettings = Settings & { [key: string]: unknown };

const MIN_FPS = 10;
const MAX_FPS = 240;
const LAYOUTS: readonly EditModeLayout[] = ["modern", "classic", "gamepad"];
/** When config.json was last read in (its write time), kept in the settings file */
const IMPORTED_KEY = "_importedConfigTime";

export const defaultSettings = (): Settings => ({
  flavour: DEFAULT_FLAVOUR.id,
  addonsRoot: "",
  interfaceRoot: "",
  addons: [...DEFAULT_FLAVOUR.defaultAddons],
  blizzardAddons: "all",
  strictApi: true,
  locale: "enUS",
  screenWidth: 1366,
  screenHeight: 768,
  editModeLayout: "modern",
  achievementSet: "a",
  autoReload: true,
  fps: 60,
  port: 8765,
  openBrowser: true,
  luajitPath: "",
  build: "",
  tocSuffixes: [],
});

/** A JSON file's text without the byte-order mark Windows PowerShell writes */
export const readJsonFile = <T>(path: string): T => JSON.parse(readFileSync(path, "utf8").replace(/^﻿/, "")) as T;

const readObject = (path: string): Record<string, unknown> | null => {
  try {
    const value = readJsonFile<unknown>(path);
    return value !== null && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
};

const isStringList = (value: unknown): value is string[] =>
  Array.isArray(value) && value.every((item) => typeof item === "string");

const isWholeNumber = (value: unknown, min: number, max: number): value is number =>
  typeof value === "number" && Number.isInteger(value) && value >= min && value <= max;

type Check = (value: unknown) => string | null;

const CHECKS: { [K in keyof Settings]: Check } = {
  flavour: (value) => (typeof value === "string" && isKnownFlavour(value) ? null : "an unknown flavour"),
  addonsRoot: (value) => (typeof value === "string" ? null : "should be a folder's path"),
  interfaceRoot: (value) => (typeof value === "string" ? null : "should be a folder's path"),
  addons: (value) => (isStringList(value) ? null : "should be a list of addon folder names"),
  blizzardAddons: (value) => (value === "all" || value === "light" ? null : 'should be "all" or "light"'),
  strictApi: (value) => (typeof value === "boolean" ? null : "should be true or false"),
  locale: (value) => (typeof value === "string" && /^[a-z]{2}[A-Z]{2}$/.test(value) ? null : "should be like enUS"),
  screenWidth: (value) => (isWholeNumber(value, 640, 7680) ? null : "should be 640 to 7680"),
  screenHeight: (value) => (isWholeNumber(value, 480, 4320) ? null : "should be 480 to 4320"),
  editModeLayout: (value) =>
    LAYOUTS.includes(value as EditModeLayout) ? null : "should be modern, classic or gamepad",
  achievementSet: (value) => (value === "a" || value === "b" ? null : 'should be "a" or "b"'),
  autoReload: (value) => (typeof value === "boolean" ? null : "should be true or false"),
  fps: (value) => (isWholeNumber(value, MIN_FPS, MAX_FPS) ? null : `should be ${MIN_FPS} to ${MAX_FPS}`),
  port: (value) => (isWholeNumber(value, 1, 65535) ? null : "should be 1 to 65535"),
  openBrowser: (value) => (typeof value === "boolean" ? null : "should be true or false"),
  luajitPath: (value) => (typeof value === "string" ? null : "should be a file's path"),
  build: (value) =>
    typeof value === "string" && /^(\d+\.\d+\.\d+\.\d+)?$/.test(value) ? null : "should be like 1.60.1.71037",
  tocSuffixes: (value) => (isStringList(value) ? null : 'should be a list such as ["_Forever", ""]'),
};

const SETTING_KEYS = Object.keys(CHECKS) as (keyof Settings)[];

/**
 * The settings from what a file holds: each known key that passes its check, the defaults for the rest, the
 * unknown keys kept. config.json's ways of saying things are read too (blizzardAddons left out: the light
 * interface; a build that is the flavour's own)
 */
const fromStored = (stored: Record<string, unknown>): StoredSettings => {
  const settings: StoredSettings = { ...stored, ...defaultSettings() };
  const known = settings as Record<string, unknown>;
  for (const key of SETTING_KEYS) {
    if (key in stored && CHECKS[key](stored[key]) === null) known[key] = stored[key];
  }
  if (Array.isArray(stored.blizzardAddons)) known.blizzardAddons = stored.blizzardAddons; // (a list of the game's addons)
  return settings;
};

/** config.json's keys as settings: only those it has (defaults are not its to set) */
const fromLegacyConfig = (legacy: Record<string, unknown>): Record<string, unknown> => {
  const result: Record<string, unknown> = { ...legacy };
  if (!("blizzardAddons" in legacy)) result.blizzardAddons = "light";
  const flavour = findFlavour(typeof legacy.flavour === "string" ? legacy.flavour : undefined);
  if (legacy.build === flavour.wagoBuild) result.build = "";
  if (JSON.stringify(legacy.tocSuffixes) === JSON.stringify(flavour.tocSuffixes)) result.tocSuffixes = [];
  return result;
};

const legacyConfigTime = (): number | null => {
  if (!IS_SOURCE_CHECKOUT || HOME_OVERRIDE_SET || !existsSync(LEGACY_CONFIG_PATH)) return null;
  return statSync(LEGACY_CONFIG_PATH).mtimeMs;
};

export const writeSettings = (settings: StoredSettings): void => {
  mkdirSync(dirname(SETTINGS_PATH), { recursive: true });
  // Written beside and moved over: a settings file is never left half written
  const temporary = `${SETTINGS_PATH}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(settings, null, 2)}\n`);
  renameSync(temporary, SETTINGS_PATH);
};

/**
 * The settings as they are now: the file's, config.json's read in when it is new or changed since (and written to the
 * settings file, unless isWritten is false: a test looking)
 */
export const loadSettings = ({ isWritten = true }: { isWritten?: boolean } = {}): StoredSettings => {
  const stored = readObject(SETTINGS_PATH);
  const configTime = legacyConfigTime();
  if (configTime === null || (stored && stored[IMPORTED_KEY] === configTime)) return fromStored(stored ?? {});
  const legacy = readObject(LEGACY_CONFIG_PATH);
  if (!legacy) return fromStored(stored ?? {});
  const settings = fromStored({ ...(stored ?? {}), ...fromLegacyConfig(legacy), [IMPORTED_KEY]: configTime });
  if (!isWritten) return settings;
  try {
    writeSettings(settings);
  } catch {
    // (A settings folder that cannot be written: the settings still hold for this run)
  }
  return settings;
};

/** A change checked key by key: what may be saved, and what was refused with why */
export const checkChange = (change: SettingsChange): { accepted: Partial<Settings>; errors: SetupProblem[] } => {
  const accepted: Record<string, unknown> = {};
  const errors: SetupProblem[] = [];
  for (const [key, value] of Object.entries(change)) {
    const check = CHECKS[key as keyof Settings] as Check | undefined;
    if (!check) {
      errors.push({ key: "settings", message: `${key}: not a setting` });
      continue;
    }
    const problem = check(value);
    if (problem) errors.push({ key: key as keyof Settings, message: problem });
    else accepted[key] = typeof value === "string" ? value.trim() : value;
  }
  return { accepted: accepted as Partial<Settings>, errors };
};

/** The settings as the page sees them: the known keys only */
export const publicSettings = (settings: StoredSettings): Settings => {
  const result = defaultSettings() as Record<string, unknown>;
  for (const key of SETTING_KEYS) result[key] = settings[key];
  if (Array.isArray(settings.blizzardAddons)) result.blizzardAddons = "all";
  return result as Settings;
};
