// Reloads when an addon's files change, as /reload would: the addons' code and TOCs are looked at a few times a second
// (their folders may be links to where the addon is developed, so they are walked through links). A served project's
// own addons are watched in its folders.
import { readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import type { Project } from "../project/config.ts";
import { findAddonDir } from "../project/select.ts";
import type { Config } from "./config.ts";
import type { LuaHost } from "./luaHost.ts";

const LOOK_MS = 800;
const SETTLE_MS = 250; // an editor saving several files: wait for the last
const BIG_TOC_BYTES = 1_000_000; // QuestieDB's data TOC, 18 MB, never changes while working
const SKIPPED_FOLDERS = new Set(["tests", ".git"]);

const addStamps = (folder: string, stamps: Map<string, number>): void => {
  let names: string[];
  try {
    names = readdirSync(folder);
  } catch {
    return;
  }
  for (const name of names) {
    const path = join(folder, name);
    let stats: ReturnType<typeof statSync>;
    try {
      stats = statSync(path); // (follows links)
    } catch {
      continue;
    }
    if (stats.isDirectory()) {
      if (!SKIPPED_FOLDERS.has(name)) addStamps(path, stamps);
    } else if (
      name.endsWith(".lua") ||
      name.endsWith(".xml") ||
      (name.endsWith(".toc") && stats.size < BIG_TOC_BYTES)
    ) {
      stamps.set(path, stats.mtimeMs);
    }
  }
};

const snapshot = (config: Config, project: Project | null): Map<string, number> => {
  const stamps = new Map<string, number>();
  for (const name of config.addons) addStamps(findAddonDir(project, config.addonsRoot, name), stamps);
  return stamps;
};

const isSame = (first: Map<string, number>, second: Map<string, number>): boolean => {
  if (first.size !== second.size) return false;
  for (const [path, stamp] of first) if (second.get(path) !== stamp) return false;
  return true;
};

export const watchAddons = async (host: LuaHost, config: Config, project: Project | null = null): Promise<never> => {
  let known = snapshot(config, project);
  for (;;) {
    await Bun.sleep(LOOK_MS);
    if (!config.autoReload) continue;
    const current = snapshot(config, project);
    if (isSame(current, known)) continue;
    known = current;
    await Bun.sleep(SETTLE_MS);
    await host.start();
  }
};
