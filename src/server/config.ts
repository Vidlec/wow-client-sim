// What the simulator runs with: the user's settings (settings.ts) with their flavour's client filled in, under the
// keys the Lua side reads from the runtime config (cache/runtime.json). One object for the whole run: a change of
// settings updates it in place (applySettings), so whoever holds it sees the change.
import { existsSync } from "node:fs";
import { findFlavour } from "./flavours/index.ts";
import { downloadedInterfaceRoot } from "./paths.ts";
import { loadSettings, type StoredSettings } from "./settings.ts";

export { CACHE_DIR, ROOT, SAVED_DIR, SCENARIOS_DIR } from "./paths.ts";
export { readJsonFile } from "./settings.ts";

export type Config = {
  /** The flavour's id ("forever") */
  flavour: string;
  addonsRoot: string;
  /** More folders with addons (the settings' addonFolders) */
  addonFolders?: string[];
  addons: string[];
  /** The wago.tools build of the game's art and tables ("1.60.1.71037") */
  build: string;
  screenWidth: number;
  screenHeight: number;
  port: number;
  autoReload: boolean;
  tocSuffixes: string[];
  /** The game's own interface code (wow-ui-source at the client's build), read from here, never copied; none: unset */
  interfaceRoot?: string;
  locale?: string;
  /** The game's clock, frames a second */
  fps?: number;
  /** The atlas variant the client swaps in for a plain name ("-c60"); false for none (left out, Lua takes "-c60") */
  atlasVariant: string | false;
  /** The client has the keyring (C_ActionBar.ShouldShowKeyring) */
  hasKeyring?: boolean;
  [key: string]: unknown;
};

export const DEFAULT_FPS = 60;

/** The interface source the simulator reads: the one set, else the one the setup downloaded, else none */
export const resolveInterfaceRoot = (settings: StoredSettings): string | undefined => {
  if (settings.interfaceRoot) return settings.interfaceRoot;
  const downloaded = downloadedInterfaceRoot(settings.flavour);
  return existsSync(downloaded) ? downloaded : undefined;
};

/** The settings as the simulator reads them: the flavour's client first, the settings (and their extra keys) over it */
export const resolveConfig = (settings: StoredSettings): Config => {
  const flavour = findFlavour(settings.flavour);
  const {
    luajitPath: _luajit,
    openBrowser: _open,
    interfaceRoot: _interface,
    projectAddons: _projects,
    blizzardAddons,
    ...rest
  } = settings;
  const build = settings.build || flavour.wagoBuild;
  // A build set by hand names its own version and number (1.60.1.70959: "1.60.1", "70959")
  const isOwnBuild = build === flavour.wagoBuild;
  const config: Config = {
    version: isOwnBuild ? flavour.client.version : build.split(".").slice(0, 3).join("."),
    buildNumber: isOwnBuild ? flavour.client.buildNumber : (build.split(".").at(-1) ?? ""),
    buildDate: flavour.client.buildDate,
    interface: flavour.client.interface,
    projectId: flavour.client.projectId,
    gameTypes: flavour.gameTypes,
    family: flavour.family,
    game: flavour.game,
    interfaceTocSuffixes: flavour.interfaceTocSuffixes,
    wowlessProduct: flavour.wowlessProduct,
    hasKeyring: flavour.hasKeyring,
    ...rest,
    flavour: flavour.id,
    build,
    tocSuffixes: settings.tocSuffixes.length > 0 ? settings.tocSuffixes : flavour.tocSuffixes,
    atlasVariant: flavour.atlasVariant ?? false,
  };
  // "light": the simulator's own stand-in interface, which the Lua side runs when blizzardAddons is left out
  if (blizzardAddons !== "light") config.blizzardAddons = blizzardAddons;
  const interfaceRoot = resolveInterfaceRoot(settings);
  if (interfaceRoot) config.interfaceRoot = interfaceRoot;
  return config;
};

/** The run's config, from the settings as they are now */
export const loadConfig = (): Config => resolveConfig(loadSettings());

/** The config updated in place to new settings: keys gone from them are taken away */
export const applySettings = (config: Config, settings: StoredSettings): Config => {
  const next = resolveConfig(settings);
  for (const key of Object.keys(config)) if (!(key in next)) delete config[key];
  return Object.assign(config, next);
};
