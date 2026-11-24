// Where the app keeps things. It runs from its source checkout (bun run start, or the Docker image's copy of it),
// which is the simulator's root: its lua/, cache/ (the game's files), saved/ (the addons' saved variables),
// interface/ (the downloaded interface source) and scenarios/ stay there. The settings are the user's own, in the
// system's settings folder:
//
//   Windows  %APPDATA%\AddonSim\settings.json
//   macOS    ~/Library/Application Support/AddonSim/settings.json
//   Linux    $XDG_CONFIG_HOME/addonsim/settings.json (~/.config)
//
// Developer overrides, never needed: ADDONSIM_HOME (the settings in that folder: a second app beside the first, or a
// first run from nothing), ADDONSIM_SAVED_DIR (saved variables), ADDONSIM_PORT, ADDONSIM_HOST (the address served on).
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import packageJson from "../../package.json" with { type: "json" };

export const APP_NAME = "AddonSim";
export const APP_VERSION: string = packageJson.version;

/** The source checkout */
export const SOURCE_ROOT = resolve(import.meta.dir, "..", "..");

const HOME_OVERRIDE = process.env.ADDONSIM_HOME ? resolve(process.env.ADDONSIM_HOME) : null;
/** ADDONSIM_HOME given: separate settings, which read no config.json of the checkout */
export const HOME_OVERRIDE_SET: boolean = HOME_OVERRIDE !== null;

const systemSettingsDir = (): string => {
  if (process.platform === "win32") return join(process.env.APPDATA ?? join(homedir(), "AppData", "Roaming"), APP_NAME);
  if (process.platform === "darwin") return join(homedir(), "Library", "Application Support", APP_NAME);
  return join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "addonsim");
};

export const SETTINGS_DIR: string = HOME_OVERRIDE ?? systemSettingsDir();
export const SETTINGS_PATH: string = join(SETTINGS_DIR, "settings.json");

/** The simulator's root: lua/ (the simulator), cache/ (the game's files), saved/ (the addons' saved variables) */
export const ROOT: string = SOURCE_ROOT;
export const CACHE_DIR: string = join(ROOT, "cache");
/** The addons' saved variables and the simulator's own state; another folder for a second server beside the first */
export const SAVED_DIR: string = process.env.ADDONSIM_SAVED_DIR
  ? resolve(process.env.ADDONSIM_SAVED_DIR)
  : join(ROOT, "saved");
export const SCENARIOS_DIR: string = join(ROOT, "scenarios");
export const LUA_DIR: string = join(ROOT, "lua");
/** The checkout's config.json from before the settings: read into the settings (see settings.ts) */
export const LEGACY_CONFIG_PATH: string = join(SOURCE_ROOT, "config.json");

/** Where the setup unpacks a flavour's interface source (its Interface folder inside) */
export const interfaceDownloadDir = (flavourId: string): string => join(ROOT, "interface", flavourId);
export const downloadedInterfaceRoot = (flavourId: string): string =>
  join(interfaceDownloadDir(flavourId), "Interface");
