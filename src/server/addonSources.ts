// Where each addon is: the game's AddOns folder, then the settings' further folders (addonFolders), then the served
// project's own, each over one of the same name before it, as the Lua side discovers them (lua/boot.lua). One place
// for the catalog, the media route, the file watcher and the SDK to agree on an addon's folder.
import { type Dirent, existsSync, readdirSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import type { ProjectAddon } from "../project/config.ts";

export type AddonOrigin = "game" | "folder" | "project";

export type AddonSource = {
  /** The addon's folder name, as the game knows it */
  name: string;
  /** Its folder */
  dir: string;
  origin: AddonOrigin;
  /** The folder it was found in (the AddOns folder, a further folder, the project's): for the page to say */
  root: string;
};

/** What the lookup needs of the config */
export type AddonRoots = { addonsRoot: string; addonFolders?: readonly string[]; tocSuffixes?: readonly string[] };

const DEFAULT_SUFFIXES = ["", "_Mainline"];

const isFolder = (path: string): boolean => statSync(path, { throwIfNoEntry: false })?.isDirectory() === true;

/** Whether a folder is an addon itself: it holds a TOC of its own name */
export const isAddonFolder = (folder: string, suffixes: readonly string[] = DEFAULT_SUFFIXES): boolean => {
  const name = basename(folder.replace(/[\\/]+$/, ""));
  return [...suffixes, ""].some((suffix) => existsSync(join(folder, `${name}${suffix}.toc`)));
};

// (listed with each entry's kind: a stat only for a link or junction, OneMoreQuest's in the AddOns folder; the file
// watcher looks every 800 ms)
const addFolderOfAddons = (root: string, origin: AddonOrigin, into: Map<string, AddonSource>): void => {
  let entries: Dirent[];
  try {
    entries = readdirSync(root, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const dir = join(root, entry.name);
    if (entry.isDirectory() || (entry.isSymbolicLink() && isFolder(dir))) {
      into.set(entry.name.toLowerCase(), { name: entry.name, dir, origin, root });
    }
  }
};

/** Every addon folder, by lower-case name: later sources over earlier ones of the same name */
export const listAddonSources = (
  roots: AddonRoots,
  projectAddons: readonly ProjectAddon[] = [],
): Map<string, AddonSource> => {
  const sources = new Map<string, AddonSource>();
  if (roots.addonsRoot) addFolderOfAddons(roots.addonsRoot, "game", sources);
  for (const folder of roots.addonFolders ?? []) {
    if (!folder || !isFolder(folder)) continue;
    // A folder that is one addon (its own TOC), or one holding addons
    if (isAddonFolder(folder, roots.tocSuffixes)) {
      const name = basename(folder.replace(/[\\/]+$/, ""));
      sources.set(name.toLowerCase(), { name, dir: folder, origin: "folder", root: folder });
    } else {
      addFolderOfAddons(folder, "folder", sources);
    }
  }
  for (const addon of projectAddons) {
    sources.set(addon.name.toLowerCase(), {
      name: basename(addon.dir),
      dir: addon.dir,
      origin: "project",
      root: addon.dir,
    });
  }
  return sources;
};

/** One addon's folder: where it is found, else where it would be in the AddOns folder */
export const findAddonDir = (roots: AddonRoots, projectAddons: readonly ProjectAddon[], name: string): string => {
  const own = projectAddons.find((addon) => addon.name.toLowerCase() === name.toLowerCase());
  if (own) return own.dir;
  // (the further folders only when the addon is not a project's: listing them is a directory read each)
  return listAddonSources(roots).get(name.toLowerCase())?.dir ?? join(roots.addonsRoot, name);
};

// The sources kept for a moment, for callers asked often (the media route, a texture request each): folders are read
// again after CACHE_MS, or at once when the roots change
const CACHE_MS = 2000;
let cached: { key: string; at: number; sources: Map<string, AddonSource> } | null = null;

/** listAddonSources, read again at most every two seconds */
export const listAddonSourcesCached = (
  roots: AddonRoots,
  projectAddons: readonly ProjectAddon[] = [],
): Map<string, AddonSource> => {
  const key = JSON.stringify([roots.addonsRoot, roots.addonFolders ?? [], projectAddons.map((addon) => addon.dir)]);
  const now = Date.now();
  if (cached && cached.key === key && now - cached.at < CACHE_MS) return cached.sources;
  cached = { key, at: now, sources: listAddonSources(roots, projectAddons) };
  return cached.sources;
};
