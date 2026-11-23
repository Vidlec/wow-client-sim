// Which project a command works on: the one asked for (--project <dir>), else the one the working folder is in (its
// nearest addonsim.config.ts above), else, in the simulator's own checkout, the simulator's self-test project: its
// scenarios/ played against the small fixture addon in scenarios/fixtures/addons (no other addon loads unless a
// scenario names it: QuestieDB, for those that need the quest database), with a plugin and a module folder of its
// own (scenarios/fixtures/plugins, scenarios/fixtures/lib), so the simulator tests itself.
import { existsSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { ROOT } from "../server/paths.ts";
import type { Project, ProjectAddon } from "./config.ts";
import { findProjectRoot, loadProject, loadProjectAt } from "./load.ts";

/** The fixture addon the simulator's own scenarios play with */
export const FIXTURE_ADDON = "SimFixture";

/** The simulator's self-test project: its scenarios/ folder, with the fixture addon */
export const simulatorProject = (): Project => {
  const scenariosDir = join(ROOT, "scenarios");
  const fixture: ProjectAddon = { name: FIXTURE_ADDON, dir: join(scenariosDir, "fixtures", "addons", FIXTURE_ADDON) };
  const addons = existsSync(fixture.dir) ? [fixture] : [];
  return {
    root: ROOT,
    configPath: null,
    addons,
    installed: [],
    load: addons.map((addon) => addon.name),
    scenariosDir,
    // A plugin and a module folder of its own, so the suite tries the plugin API and the project's luaPath too
    plugins: [join(scenariosDir, "fixtures", "plugins", "fixture-party.lua")],
    luaPath: [join(scenariosDir, "fixtures", "lib")],
    coverageAddon: addons[0]?.name ?? null,
    login: null,
    flavour: null,
    galleryDir: null,
  };
};

const isInside = (folder: string, parent: string): boolean => {
  const path = relative(resolve(parent), resolve(folder));
  return path === "" || (!path.startsWith("..") && !/^[a-z]:/i.test(path));
};

/** The project of --project <dir> (a folder, or its config file), else the working folder's, else the simulator's */
export const selectProject = async (projectDir: string | null, cwd: string = process.cwd()): Promise<Project> => {
  if (projectDir) {
    const dir = resolve(cwd, projectDir);
    return loadProjectAt(
      dir.endsWith(".ts") || dir.endsWith(".js") || dir.endsWith(".json") ? resolve(dir, "..") : dir,
    );
  }
  if (findProjectRoot(cwd)) return loadProject(cwd);
  if (isInside(cwd, ROOT)) return simulatorProject();
  return loadProject(cwd);
};

/** The project the server serves: --project <dir>, else the working folder's config; none (the settings) otherwise */
export const selectServedProject = async (
  projectDir: string | null,
  cwd: string = process.cwd(),
): Promise<Project | null> => {
  if (projectDir) return selectProject(projectDir, cwd);
  const root = findProjectRoot(cwd);
  return root ? loadProjectAt(root) : null;
};

/** "--project <dir>" or "--project=<dir>" in a command's arguments, and the arguments without it */
export const takeProjectFlag = (args: string[]): { projectDir: string | null; rest: string[] } => {
  const rest: string[] = [];
  let projectDir: string | null = null;
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] ?? "";
    if (arg === "--project") {
      projectDir = args[index + 1] ?? null;
      index += 1;
    } else if (arg.startsWith("--project=")) {
      projectDir = arg.slice("--project=".length);
    } else {
      rest.push(arg);
    }
  }
  return { projectDir, rest };
};

/** Where an addon the project loads lives: the project's own folder for it, else the AddOns folder's */
export const findAddonDir = (project: Project | null, addonsRoot: string, name: string): string => {
  const own = project?.addons.find((addon) => addon.name.toLowerCase() === name.toLowerCase());
  return own ? own.dir : join(addonsRoot, name);
};
