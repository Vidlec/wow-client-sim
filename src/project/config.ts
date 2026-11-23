// A project: a folder of addons developed together, with the scenarios that try them in the simulator. Its
// addonsim.config.ts says what is in it:
//
//   import { defineProject } from "addonsim";
//   export default defineProject({
//     addons: ["addons/MyAddon", "addons/MyOtherAddon"],         // the project's own addons (folders with a .toc)
//     installed: ["QuestieDB"],                                   // from the game's AddOns folder (the settings')
//     scenarios: "sim/scenarios",
//     plugins: ["sim/plugins/my-party.lua"],                      // Lua the simulator loads (party addons, helpers)
//     luaPath: ["sim/lib"],                                       // where scenarios and plugins require() from
//   });
//
// Paths are relative to the config file. Nothing else is needed: the game's files, LuaJIT and the interface source
// come from the simulator's own settings (its first-run setup).

/** A character to log in as: the runner's --login form ("race=Human,class=WARRIOR,level=12") as fields */
export type LoginSpec = {
  race?: string;
  class?: string;
  level?: number;
  name?: string;
  sex?: number;
  realm?: string;
};

export type ProjectConfig = {
  /** The project's own addons: folders (relative to the config) each holding the addon's .toc */
  addons?: string[];
  /** Addons the game's AddOns folder provides (by folder name), loaded too: libraries, databases, neighbours */
  installed?: string[];
  /** The addons that load when a scenario names none (--@addons), by folder name: the installed ones and the
   * project's own by default. Name fewer when one of the project's addons needs an addon the others must not meet
   * (it is still there for the scenarios that ask for it) */
  load?: string[];
  /** The scenarios' folder ("sim/scenarios" by default): every *.lua in it is a scenario of the suite */
  scenarios?: string;
  /** Lua files the simulator runs after its own modules, before the addons load: they extend the simulator
   * (a party member's addon, a helper for scenarios) through its plugin API (lua/plugins.lua) */
  plugins?: string[];
  /** Folders scenarios and plugins require() modules from, before the simulator's own */
  luaPath?: string[];
  /** The addon --coverage records (the first of addons by default) */
  coverage?: string;
  /** The character scenarios log in as unless they say otherwise (--@login) */
  login?: LoginSpec;
  /** The game flavour ("forever" by default: the settings') */
  flavour?: string;
  /** Where `bun run shots` puts the gallery's pictures (its scenarios are <scenarios>/shots/*.lua); "~" is the home */
  gallery?: string;
};

/** The config as written, typed (it returns it unchanged) */
export const defineProject = (config: ProjectConfig): ProjectConfig => config;

/** A project's addon: its folder name (the addon's name, as the game names it) and where it is */
export type ProjectAddon = { name: string; dir: string };

/** A project as loaded: every path absolute */
export type Project = {
  /** The folder holding the config */
  root: string;
  /** The config file (null: a folder without one, taken as a project of the addons in it) */
  configPath: string | null;
  addons: ProjectAddon[];
  installed: string[];
  /** The addons that load by default (the config's load, else the installed ones and the project's own) */
  load: string[];
  scenariosDir: string;
  plugins: string[];
  luaPath: string[];
  coverageAddon: string | null;
  login: LoginSpec | null;
  flavour: string | null;
  /** The gallery's output folder (absolute, "~" expanded), or null when the project names none */
  galleryDir: string | null;
};

export const CONFIG_FILE_NAMES = ["addonsim.config.ts", "addonsim.config.js", "addonsim.config.json"] as const;
