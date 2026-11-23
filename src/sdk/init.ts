// `addonsim init [dir]`: a project made where there are addons: its config (the addon folders found there), a first
// scenario, a CLAUDE.md saying how to test and look, and a .luarc.json giving the editor the scenario API's
// definitions. A file already there is left as it is.
import { existsSync, mkdirSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { basename, join, relative } from "node:path";
import { hasToc } from "../project/load.ts";
import { SOURCE_ROOT } from "../server/paths.ts";

const isFolder = (path: string): boolean => {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
};

/** The addon folders in a project's folder: itself, its folders with a .toc, or those of its addons/ folder */
const findAddons = (dir: string): string[] => {
  if (hasToc(dir)) return ["."];
  const within = (folder: string): string[] =>
    isFolder(folder)
      ? readdirSync(folder)
          .filter((name) => isFolder(join(folder, name)) && hasToc(join(folder, name)))
          .map((name) => relative(dir, join(folder, name)).replaceAll("\\", "/"))
      : [];
  return [...within(dir), ...within(join(dir, "addons"))];
};

// (a plain object: the project need not have the addonsim package installed; with it, wrap it in defineProject from
// "addonsim" for its types)
const configText = (
  addons: string[],
): string => `// This project's addons for AddonSim (the addonsim CLI finds this file from any folder below it).
export default {
  // The project's own addons: folders holding the addon's .toc
  addons: ${JSON.stringify(addons)},
  // Addons from the game's AddOns folder that load too (libraries, databases): by folder name
  installed: [],
  scenarios: "sim/scenarios",
};
`;

const scenarioText = (
  addon: string,
): string => `-- A first scenario: logs in, lets the game run a second, and checks ${addon} loaded. A Lua error anywhere fails
-- it too. Run it with: addonsim run first
setProfile({ level = 10, race = "Human", class = "WARRIOR" })
wait(1)
expect(G.C_AddOns.IsAddOnLoaded("${addon}"), "${addon} loaded")
`;

const claudeText = (): string => `# Working on these addons with AddonSim

The addons run in AddonSim, a simulator of the WoW: Forever client. Test every change in it:

- \`addonsim run <scenario>\` plays one scenario of sim/scenarios in a warm game (no boot wait) and prints
  PASSED/FAILED with each failure as file:line. The game stays up afterwards: look at where it ended.
- \`addonsim ui [text]\` lists the shown frames (where, what they say, what a click takes); \`addonsim shot\` writes a
  PNG of the screen (\`--frame <ref>\` for one frame).
- \`addonsim eval '<lua>'\` runs Lua in the game: the scenario steps (\`accept(844)\`, \`click("Accept")\`, \`wait(1)\`), the
  game's globals in G. \`addonsim docs\` lists every step.
- \`addonsim test\` plays the whole suite; run it before you finish.

A new scenario is a Lua file in sim/scenarios: steps, then checks (\`expect(cond, "what")\`, \`expectText("...")\`).
`;

const luarcText = (dir: string): string => {
  const linked = join(dir, "node_modules", "addonsim", "types");
  const types = existsSync(linked) ? "node_modules/addonsim/types" : join(SOURCE_ROOT, "types").replaceAll("\\", "/");
  return `${JSON.stringify(
    {
      "runtime.version": "Lua 5.1",
      "workspace.library": [types],
      "diagnostics.globals": [],
    },
    null,
    2,
  )}\n`;
};

export const initProject = (dir: string): number => {
  mkdirSync(dir, { recursive: true });
  const addons = findAddons(dir);
  const firstAddon = basename(addons[0] === "." ? dir : (addons[0] ?? "MyAddon"));
  const files: [string, string][] = [
    ["addonsim.config.ts", configText(addons)],
    [join("sim", "scenarios", "first.lua"), scenarioText(firstAddon)],
    ["CLAUDE.md", claudeText()],
    [".luarc.json", luarcText(dir)],
  ];
  for (const [name, text] of files) {
    const path = join(dir, name);
    if (existsSync(path)) {
      process.stdout.write(`kept ${name} (already there)\n`);
      continue;
    }
    mkdirSync(join(path, ".."), { recursive: true });
    writeFileSync(path, text);
    process.stdout.write(`wrote ${name}\n`);
  }
  if (addons.length === 0)
    process.stdout.write("no addon folders found (a folder with a .toc): add them to addonsim.config.ts\n");
  process.stdout.write("next: addonsim run first\n");
  return 0;
};
