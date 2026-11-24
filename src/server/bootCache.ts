// Keeps the boot cache (cache/boot, lua/bootcache.lua) from growing without end. Every changed file there leaves
// its old entry behind (its key is the file's time and size), so a month of work is thousands of dead entries. Each
// boot lists the entries it used (used/<hash>.txt, bootcache.saveUsed); this deletes the entries no list from the
// last weeks names, and the folders of a LuaJIT or a cache version no run uses any more. At most once a day.
import { existsSync, readdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const DAY = 24 * 60 * 60 * 1000;

export type PruneOptions = {
  /** A run's list is honoured this long; an entry nobody listed in it is deleted */
  keepDays?: number;
  /** An entry younger than this is never deleted (a run going on now, which has not listed it yet) */
  graceHours?: number;
  /** Prune though it was done within the day */
  isForced?: boolean;
  now?: number;
};

export type PruneResult = { files: number; bytes: number; folders: number; isSkipped: boolean };

const ageOf = (path: string, now: number): number => {
  try {
    return now - statSync(path).mtimeMs;
  } catch {
    return Number.POSITIVE_INFINITY;
  }
};

const sizeOf = (path: string): number => {
  try {
    return statSync(path).size;
  } catch {
    return 0;
  }
};

const pruneFolder = (folder: string, keepMs: number, graceMs: number, now: number, result: PruneResult): void => {
  const usedFolder = join(folder, "used");
  const kept = new Set<string>();
  let recentLists = 0;
  if (existsSync(usedFolder)) {
    for (const name of readdirSync(usedFolder)) {
      if (!name.endsWith(".txt")) continue;
      const path = join(usedFolder, name);
      if (ageOf(path, now) > keepMs) {
        rmSync(path, { force: true });
        continue;
      }
      recentLists += 1;
      for (const entry of readFileSync(path, "utf8").split("\n")) if (entry) kept.add(entry);
    }
  }
  const entries = readdirSync(folder).filter((name) => name.endsWith(".luac") || name.endsWith(".tmp"));
  if (recentLists === 0) {
    // No run listed anything lately: the folder of an older LuaJIT or cache version, or a cache from before the lists.
    // Gone once nothing in it is recent.
    const isStale = entries.every((name) => ageOf(join(folder, name), now) > keepMs);
    if (isStale && ageOf(join(folder, ".made"), now) > keepMs) {
      for (const name of entries) result.bytes += sizeOf(join(folder, name));
      result.files += entries.length;
      result.folders += 1;
      rmSync(folder, { recursive: true, force: true });
    }
    return;
  }
  for (const name of entries) {
    if (kept.has(name)) continue;
    const path = join(folder, name);
    if (ageOf(path, now) <= graceMs) continue;
    result.bytes += sizeOf(path);
    result.files += 1;
    rmSync(path, { force: true });
  }
};

/** Deletes the boot cache's entries no recent run used (bootRoot: cache/boot) */
export const pruneBootCache = (bootRoot: string, options: PruneOptions = {}): PruneResult => {
  const now = options.now ?? Date.now();
  const keepMs = (options.keepDays ?? 14) * DAY;
  const graceMs = (options.graceHours ?? 24) * 60 * 60 * 1000;
  const result: PruneResult = { files: 0, bytes: 0, folders: 0, isSkipped: false };
  if (!existsSync(bootRoot)) return result;
  const marker = join(bootRoot, ".pruned");
  if (!options.isForced && ageOf(marker, now) < DAY) return { ...result, isSkipped: true };
  for (const name of readdirSync(bootRoot)) {
    const folder = join(bootRoot, name);
    try {
      if (statSync(folder).isDirectory()) pruneFolder(folder, keepMs, graceMs, now, result);
    } catch {
      // (a folder another run is deleting or writing: left for the next time)
    }
  }
  writeFileSync(marker, "");
  utimesSync(marker, now / 1000, now / 1000);
  return result;
};
