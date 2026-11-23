// Finding and reading a project (config.ts): the config file nearest above a folder, its paths made absolute, its
// addons' names read from their folders. A folder without a config that holds addons (folders with a .toc) is taken
// as a project of those addons, so `addonsim test` works in a plain addon folder too.
import { existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { CONFIG_FILE_NAMES, type LoginSpec, type Project, type ProjectAddon, type ProjectConfig } from "./config.ts";

const DEFAULT_SCENARIOS = "sim/scenarios";

const isFolder = (path: string): boolean => {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
};

/** A folder holds an addon when it has a .toc (any suffix) named after it, or any .toc at all */
export const hasToc = (dir: string): boolean => {
  try {
    return readdirSync(dir).some((name) => name.toLowerCase().endsWith(".toc"));
  } catch {
    return false;
  }
};

/** The config file in a folder, or null */
const configIn = (dir: string): string | null => {
  for (const name of CONFIG_FILE_NAMES) {
    const path = join(dir, name);
    if (existsSync(path)) return path;
  }
  return null;
};

/** The project a folder is in: the nearest config above it (itself included), or null */
export const findProjectRoot = (from: string): string | null => {
  let dir = resolve(from);
  for (;;) {
    if (configIn(dir)) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
};

const readConfig = async (path: string): Promise<ProjectConfig> => {
  if (path.endsWith(".json")) return (await Bun.file(path).json()) as ProjectConfig;
  const module = (await import(pathToFileURL(path).href)) as { default?: ProjectConfig };
  if (!module.default || typeof module.default !== "object") {
    throw new Error(`${path} exports no project (export default defineProject({ ... }))`);
  }
  return module.default;
};

/** A path with a leading "~" taken as the home folder */
export const expandHome = (path: string): string =>
  path === "~" || /^~[/\\]/.test(path) ? homedir() + path.slice(1) : path;

const toAddon = (root: string, path: string): ProjectAddon => {
  const dir = resolve(root, path);
  if (!isFolder(dir)) throw new Error(`The project's addon folder ${dir} is not there`);
  if (!hasToc(dir)) throw new Error(`The project's addon folder ${dir} has no .toc`);
  return { name: basename(dir), dir };
};

/** The project of a config file's folder, every path absolute */
export const loadProjectAt = async (root: string): Promise<Project> => {
  const configPath = configIn(root);
  if (!configPath) return implicitProject(root);
  const config = await readConfig(configPath);
  const addons = (config.addons ?? []).map((path) => toAddon(root, path));
  return {
    root,
    configPath,
    addons,
    installed: config.installed ?? [],
    load: config.load ?? [...(config.installed ?? []), ...addons.map((addon) => addon.name)],
    scenariosDir: resolve(root, config.scenarios ?? DEFAULT_SCENARIOS),
    plugins: (config.plugins ?? []).map((path) => resolve(root, path)),
    luaPath: (config.luaPath ?? []).map((path) => resolve(root, path)),
    coverageAddon: config.coverage ?? addons[0]?.name ?? null,
    login: config.login ?? null,
    flavour: config.flavour ?? null,
    galleryDir: config.gallery ? resolve(root, expandHome(config.gallery)) : null,
  };
};

/** A folder without a config: itself an addon (a .toc in it), or a folder of addons */
const implicitProject = (root: string): Project => {
  const addons: ProjectAddon[] = hasToc(root)
    ? [{ name: basename(root), dir: root }]
    : readdirSync(root)
        .map((name) => join(root, name))
        .filter((dir) => isFolder(dir) && hasToc(dir))
        .map((dir) => ({ name: basename(dir), dir }));
  return {
    root,
    configPath: null,
    addons,
    installed: [],
    load: addons.map((addon) => addon.name),
    scenariosDir: resolve(root, DEFAULT_SCENARIOS),
    plugins: [],
    luaPath: [],
    coverageAddon: addons[0]?.name ?? null,
    login: null,
    flavour: null,
    galleryDir: null,
  };
};

/** The project a folder belongs to (the nearest config above it), else the folder as an implicit project */
export const loadProject = async (from: string = process.cwd()): Promise<Project> =>
  loadProjectAt(findProjectRoot(from) ?? resolve(from));

/** The login spec in the runner's --login form */
export const loginText = (login: LoginSpec | null): string =>
  login
    ? Object.entries(login)
        .filter(([, value]) => value !== undefined)
        .map(([key, value]) => `${key}=${String(value)}`)
        .join(",")
    : "";

/** The runtime keys a project adds to the simulator's runtime config (read by lua/boot.lua and lua/play.lua):
 * - addonDirs: the project's addon folders, discovered besides the settings' addonsRoot (the project's own win)
 * - addons: which load: the config's load (the installed ones and the project's own by default; a scenario's --@addons
 *   still overrides)
 * - plugins, luaPath: as the config says
 * - projectRoot, scenariosDir: for scenario paths, golden snapshots and the last run's scenes */
export const projectRuntime = (project: Project): Record<string, unknown> => ({
  addonDirs: project.addons.map((addon) => addon.dir),
  addons: project.load,
  plugins: project.plugins,
  luaPath: project.luaPath,
  projectRoot: project.root,
  scenariosDir: project.scenariosDir,
  ...(project.coverageAddon ? { coverageAddon: project.coverageAddon } : {}),
});
