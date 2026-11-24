// The page's folder browser: a folder's folders as the server sees them, so a folder is chosen in the page itself
// (a browser page cannot learn a path of its own, and in a container no system dialog could open). In a container the
// host's folders are those mounted into it (ADDONSIM_BROWSE, /host in the image), and browsing starts there. Only
// names are read, and the folder looked into is checked for the kind looked for (its addons, its interface source).
import { existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, parse, resolve } from "node:path";
import type { FolderEntry, FolderKind, FolderListing } from "../../shared/setup.ts";
import type { Flavour } from "../flavours/index.ts";
import { checkFolder } from "./detect.ts";

/** The host's folders mounted into a container (the image's /host), or none outside one */
export const BROWSE_ROOT: string | null = process.env.ADDONSIM_BROWSE ? resolve(process.env.ADDONSIM_BROWSE) : null;

const isFolder = (path: string): boolean => {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
};

/** Where browsing may start over: the host's folders, the home, the drives (Windows) or the root */
const listRoots = (): { name: string; path: string }[] => {
  const roots: { name: string; path: string }[] = [];
  if (BROWSE_ROOT && isFolder(BROWSE_ROOT)) roots.push({ name: "The host's folders", path: BROWSE_ROOT });
  if (!BROWSE_ROOT) roots.push({ name: "Home", path: homedir() });
  if (process.platform === "win32") {
    for (let code = 65; code <= 90; code++) {
      const drive = `${String.fromCharCode(code)}:\\`;
      if (existsSync(drive)) roots.push({ name: drive.slice(0, 2), path: drive });
    }
  } else if (!BROWSE_ROOT) {
    roots.push({ name: "/", path: "/" });
  }
  return roots;
};

/** What a name seems to be, for the kind looked for */
const hintOf = (kind: FolderKind, name: string): string | undefined => {
  if (/^world of warcraft$/i.test(name)) return "the game";
  if (kind === "addons") {
    if (/^addons$/i.test(name)) return "an AddOns folder";
    if (/^_.+_$/.test(name)) return "one of the game's clients";
    if (/^interface$/i.test(name)) return "holds AddOns";
  }
  if (kind === "interface") {
    if (/^interface$/i.test(name)) return "an Interface folder";
    if (/^wow-ui-source/i.test(name)) return "an interface source";
  }
  if (kind === "luajit" && /^luajit/i.test(name)) return "LuaJIT";
  return undefined;
};

/** The folder to show: the one asked for, else the nearest that is there, else where browsing starts */
const startingFolder = (asked: string | undefined): { path: string; error?: string } => {
  const fallback = BROWSE_ROOT && isFolder(BROWSE_ROOT) ? BROWSE_ROOT : homedir();
  if (!asked?.trim()) return { path: fallback };
  let path = resolve(asked.trim());
  // (a file named, LuaJIT's: its folder)
  if (existsSync(path) && !isFolder(path)) path = dirname(path);
  if (isFolder(path)) return { path };
  for (let up = dirname(path); up !== path; path = up, up = dirname(up)) {
    if (isFolder(up)) return { path: up, error: `${asked} is not there: shown is the nearest folder that is` };
  }
  return { path: fallback, error: `${asked} is not there` };
};

export const listFolder = (kind: FolderKind, asked: string | undefined, flavour: Flavour): FolderListing => {
  const { path, error } = startingFolder(asked);
  const entries: FolderEntry[] = [];
  let readError = error;
  try {
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      // (hidden and the system's own: never where addons are)
      if (entry.name.startsWith(".") || entry.name.startsWith("$")) continue;
      const full = join(path, entry.name);
      const isEntryFolder = entry.isDirectory() || (entry.isSymbolicLink() && isFolder(full));
      if (!isEntryFolder && !(kind === "luajit" && /^luajit/i.test(entry.name))) continue;
      const item: FolderEntry = { name: entry.name, path: full, isFolder: isEntryFolder };
      const hint = hintOf(kind, entry.name);
      if (hint) item.hint = hint;
      entries.push(item);
    }
  } catch (problem) {
    readError = `${path} could not be read (${problem instanceof Error ? problem.message : String(problem)})`;
  }
  entries.sort(
    (first, second) =>
      Number(second.isFolder) - Number(first.isFolder) ||
      first.name.localeCompare(second.name, undefined, { sensitivity: "base", numeric: true }),
  );
  const isRoot = parse(path).root === path || (BROWSE_ROOT !== null && resolve(path) === BROWSE_ROOT);
  const listing: FolderListing = {
    path,
    parent: isRoot ? null : dirname(path),
    roots: listRoots(),
    entries,
    check: kind === "luajit" ? null : checkFolder(kind, path, flavour),
  };
  if (readError) listing.error = readError;
  return listing;
};
