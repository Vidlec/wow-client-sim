// Reloads when an addon's files change, as /reload would: the addons' code and TOCs are looked at a few times a second
// (their folders may be links to where the addon is developed, so they are walked through links). A served project's
// own addons are watched in its folders.
import type { Dirent } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import type { Project } from "../project/config.ts";
import { listAddonSources } from "./addonSources.ts";
import type { Config } from "./config.ts";
import type { LuaHost } from "./luaHost.ts";

const LOOK_MS = 800;
const SETTLE_MS = 250; // an editor saving several files: wait for the last
const BIG_TOC_BYTES = 1_000_000; // QuestieDB's data TOC, 18 MB, never changes while working
const SKIPPED_FOLDERS = new Set(["tests", ".git"]);

const isCodeName = (name: string): boolean => {
  const lower = name.toLowerCase();
  return lower.endsWith(".lua") || lower.endsWith(".xml") || lower.endsWith(".toc");
};

// Each folder listed with its entries' kinds, so only the code is looked at closely: an addon's art and sounds
// (WowfCZ and its dubbing packs: 110,000 files) are never stat'ed. And all of it asynchronously, off the server's
// thread: stat'ing every file at once took over half a second each look, frames waited and the page stuttered.
const addStamps = async (folder: string, stamps: Map<string, number>): Promise<void> => {
  let entries: Dirent[];
  try {
    entries = await readdir(folder, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const name = entry.name;
    const path = join(folder, name);
    let isFolder = entry.isDirectory();
    // A link or junction (the project's addon in the AddOns folder): what it points at decides
    if (entry.isSymbolicLink()) {
      try {
        isFolder = (await stat(path)).isDirectory();
      } catch {
        continue;
      }
    }
    if (isFolder) {
      if (!SKIPPED_FOLDERS.has(name)) await addStamps(path, stamps);
    } else if (isCodeName(name)) {
      try {
        const stats = await stat(path);
        if (!name.toLowerCase().endsWith(".toc") || stats.size < BIG_TOC_BYTES) stamps.set(path, stats.mtimeMs);
      } catch {
        // (gone between the listing and now: the next look sees it)
      }
    }
  }
};

/** The code files (.lua, .xml, .toc) in these addon folders, each with when it last changed */
export const snapshotFolders = async (folders: string[]): Promise<Map<string, number>> => {
  const stamps = new Map<string, number>();
  for (const folder of folders) await addStamps(folder, stamps);
  return stamps;
};

const snapshot = (config: Config, project: Project | null): Promise<Map<string, number>> => {
  const sources = listAddonSources(config, project?.addons);
  return snapshotFolders(
    config.addons.map((name) => sources.get(name.toLowerCase())?.dir ?? join(config.addonsRoot, name)),
  );
};

const isSame = (first: Map<string, number>, second: Map<string, number>): boolean => {
  if (first.size !== second.size) return false;
  for (const [path, stamp] of first) if (second.get(path) !== stamp) return false;
  return true;
};

export const watchAddons = async (host: LuaHost, config: Config, project: Project | null = null): Promise<never> => {
  let known = await snapshot(config, project);
  let knownAddons = config.addons.join("\n");
  for (;;) {
    await Bun.sleep(LOOK_MS);
    if (!config.autoReload) continue;
    try {
      const current = await snapshot(config, project);
      // (the addons switched on changed: whoever switched them started the game again; their files are no edit)
      const addons = config.addons.join("\n");
      if (addons !== knownAddons) {
        known = current;
        knownAddons = addons;
        continue;
      }
      if (isSame(current, known)) continue;
      known = current;
      await Bun.sleep(SETTLE_MS);
      await host.start();
    } catch (problem) {
      // (a look that failed is tried again at the next: the watching never stops)
      console.warn(`addon watcher: ${String(problem)}`);
    }
  }
};
