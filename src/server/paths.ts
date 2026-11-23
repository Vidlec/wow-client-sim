// Where the app keeps things. Two ways to run it:
//
//   from this source checkout (bun run start): the checkout is the simulator's root (its lua/, cache/, saved/ and
//   scenarios/ stay where they are)
//   as the bundled executable: the root is the user's local data folder, where the Lua sources are unpacked and the
//   cache and saved variables live
//
// Either way the settings are the user's own, in the system's settings folder:
//
//   Windows  %APPDATA%\AddonSim\settings.json        data: %LOCALAPPDATA%\AddonSim
//   macOS    ~/Library/Application Support/AddonSim  (settings and data)
//   Linux    $XDG_CONFIG_HOME/addonsim (~/.config)    data: $XDG_DATA_HOME/addonsim (~/.local/share)
//
// Developer overrides, never needed: ADDONSIM_HOME (settings, and the executable's data, in one folder: a second
// app beside the first, or a first run from nothing), ADDONSIM_SAVED_DIR (saved variables), ADDONSIM_PORT.
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import packageJson from "../../package.json" with { type: "json" };

export const APP_NAME = "AddonSim";
export const APP_VERSION: string = packageJson.version;

/** Running as the executable `bun run build` makes (its files inside it, not on disk) */
export const IS_STANDALONE: boolean = Bun.isStandaloneExecutable;

/** The source checkout (meaningless in the executable, whose sources are inside it) */
export const SOURCE_ROOT = resolve(import.meta.dir, "..", "..");

const HOME_OVERRIDE = process.env.ADDONSIM_HOME ? resolve(process.env.ADDONSIM_HOME) : null;
/** ADDONSIM_HOME given: a separate app, which reads no config.json of the checkout */
export const HOME_OVERRIDE_SET: boolean = HOME_OVERRIDE !== null;

const systemSettingsDir = (): string => {
  if (process.platform === "win32") return join(process.env.APPDATA ?? join(homedir(), "AppData", "Roaming"), APP_NAME);
  if (process.platform === "darwin") return join(homedir(), "Library", "Application Support", APP_NAME);
  return join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "addonsim");
};

const systemDataDir = (): string => {
  if (process.platform === "win32") {
    return join(process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local"), APP_NAME);
  }
  if (process.platform === "darwin") return join(homedir(), "Library", "Application Support", APP_NAME);
  return join(process.env.XDG_DATA_HOME ?? join(homedir(), ".local", "share"), "addonsim");
};

/** A source checkout: the server runs from the files, with lua/ beside src/ */
export const IS_SOURCE_CHECKOUT: boolean = !IS_STANDALONE && existsSync(join(SOURCE_ROOT, "lua", "boot.lua"));

export const SETTINGS_DIR: string = HOME_OVERRIDE ?? systemSettingsDir();
export const SETTINGS_PATH: string = join(SETTINGS_DIR, "settings.json");

/** The simulator's root: lua/ (the simulator), cache/ (the game's files), saved/ (the addons' saved variables) */
export const ROOT: string = IS_SOURCE_CHECKOUT ? SOURCE_ROOT : (HOME_OVERRIDE ?? systemDataDir());
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
