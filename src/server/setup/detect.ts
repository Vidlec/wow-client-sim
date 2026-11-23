// Looks on this computer for what the setup needs: the game's AddOns folders (one per client the game installs:
// World of Warcraft\_forever_\Interface\AddOns, _classic_, _retail_...) and checkouts of the interface source.
// Only folders are looked at, by name: nothing is read but a few small files (a checkout's version.txt and HEAD).
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import type { DetectedFolder, FolderCheck, FolderKind } from "../../shared/setup.ts";
import { readToc } from "../addonCatalog.ts";
import { FLAVOURS, type Flavour } from "../flavours/index.ts";
import { findLuajit, readLuajitVersion } from "../luajit.ts";
import { downloadedInterfaceRoot, SOURCE_ROOT } from "../paths.ts";

const REGISTRY_KEYS = [
  "HKLM\\SOFTWARE\\WOW6432Node\\Blizzard Entertainment\\World of Warcraft",
  "HKLM\\SOFTWARE\\Blizzard Entertainment\\World of Warcraft",
];
const REGISTRY_TIMEOUT_MS = 3000;
/** Where the game is put, under a drive's root (Windows) */
const DRIVE_FOLDERS = [
  "World of Warcraft",
  "Program Files (x86)\\World of Warcraft",
  "Program Files\\World of Warcraft",
  "Games\\World of Warcraft",
  "Blizzard\\World of Warcraft",
  "Battle.net\\World of Warcraft",
  "Program Files (x86)\\Battle.net\\World of Warcraft",
];

const isFolder = (path: string): boolean => {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
};

const listFolders = (path: string): string[] => {
  try {
    return readdirSync(path, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() || entry.isSymbolicLink())
      .map((entry) => entry.name);
  } catch {
    return [];
  }
};

const flavourOfInstall = (folderName: string): Flavour | undefined =>
  FLAVOURS.find((flavour) => flavour.installFolder.toLowerCase() === folderName.toLowerCase());

/** The game's install folders the registry names (Windows): InstallPath is one client's, "...\_forever_\" */
const readRegistry = (): string[] => {
  if (process.platform !== "win32") return [];
  const found: string[] = [];
  for (const key of REGISTRY_KEYS) {
    try {
      const result = Bun.spawnSync(["reg", "query", key, "/v", "InstallPath"], {
        stdout: "pipe",
        stderr: "ignore",
        timeout: REGISTRY_TIMEOUT_MS,
        windowsHide: true,
      });
      const match = /InstallPath\s+REG_\w+\s+(.+)/.exec(result.stdout.toString());
      if (match?.[1]) found.push(match[1].trim().replace(/[\\/]+$/, ""));
    } catch {
      // (no reg.exe: nothing from the registry)
    }
  }
  return found;
};

/** Every "World of Warcraft" folder that may hold the game, with where it was found */
const findGameFolders = (): { path: string; source: string }[] => {
  const found: { path: string; source: string }[] = [];
  for (const install of readRegistry()) {
    // InstallPath is a client's folder (_forever_); the game's folder is the one above it
    const isClientFolder = /^_.+_$/.test(install.split(/[\\/]/).at(-1) ?? "");
    found.push({ path: isClientFolder ? dirname(install) : install, source: "from the registry" });
  }
  if (process.platform === "win32") {
    for (let code = 67; code <= 90; code++) {
      const drive = `${String.fromCharCode(code)}:\\`;
      if (!existsSync(drive)) continue;
      for (const folder of DRIVE_FOLDERS) found.push({ path: join(drive, folder), source: `on ${drive.slice(0, 2)}` });
    }
  } else if (process.platform === "darwin") {
    found.push({ path: "/Applications/World of Warcraft", source: "in Applications" });
    found.push({ path: join(homedir(), "Applications", "World of Warcraft"), source: "in Applications" });
  } else {
    // Under Wine (Lutris, Bottles and a plain prefix put it here)
    for (const prefix of [
      join(homedir(), "Games", "battlenet"),
      join(homedir(), "Games", "world-of-warcraft"),
      join(homedir(), ".wine"),
    ]) {
      found.push({ path: join(prefix, "drive_c", "Program Files (x86)", "World of Warcraft"), source: "under Wine" });
    }
  }
  const seen = new Set<string>();
  return found.filter(({ path }) => {
    const key = resolve(path).toLowerCase();
    if (seen.has(key) || !isFolder(path)) return false;
    seen.add(key);
    return true;
  });
};

/** The addons in a folder: those with a TOC the flavour's client would read */
const countAddons = (folder: string, suffixes: readonly string[]): number =>
  listFolders(folder).filter((name) => readToc(join(folder, name), name, suffixes) !== null).length;

const plural = (count: number, word: string): string => `${count} ${word}${count === 1 ? "" : "s"}`;

/** The AddOns folders of every client installed, the chosen flavour's first */
export const detectAddonsRoots = (flavour: Flavour): DetectedFolder[] => {
  const found: DetectedFolder[] = [];
  for (const game of findGameFolders()) {
    for (const client of listFolders(game.path)) {
      if (!/^_.+_$/.test(client)) continue;
      const addons = join(game.path, client, "Interface", "AddOns");
      if (!isFolder(addons)) continue;
      const clientFlavour = flavourOfInstall(client);
      const count = countAddons(addons, clientFlavour?.tocSuffixes ?? flavour.tocSuffixes);
      const name = clientFlavour?.name ?? client;
      const folder: DetectedFolder = { path: addons, note: `${name}, ${game.source}: ${plural(count, "addon")}` };
      if (clientFlavour) folder.flavour = clientFlavour.id;
      found.push(folder);
    }
  }
  return found.sort((a, b) => Number(b.flavour === flavour.id) - Number(a.flavour === flavour.id));
};

/** The build an interface source says it is for (its checkout's version.txt), and the branch it has out */
const readCheckout = (interfaceRoot: string): { build: string | null; branch: string | null } => {
  const checkout = dirname(interfaceRoot);
  let build: string | null = null;
  let branch: string | null = null;
  try {
    build = readFileSync(join(checkout, "version.txt"), "utf8").trim() || null;
  } catch {}
  try {
    branch = /ref: refs\/heads\/(.+)/.exec(readFileSync(join(checkout, ".git", "HEAD"), "utf8"))?.[1]?.trim() ?? null;
  } catch {}
  return { build, branch };
};

const isInterfaceRoot = (path: string): boolean => isFolder(join(path, "AddOns", "Blizzard_SharedXML"));

/** Checkouts of the interface source in the usual places, the downloaded one too */
export const detectInterfaceRoots = (flavour: Flavour): DetectedFolder[] => {
  const home = homedir();
  const parents = [
    home,
    ...["src", "code", "dev", "git", "repos", "Projects", "Documents", "Source"].map((name) => join(home, name)),
    dirname(SOURCE_ROOT),
  ];
  const candidates: { path: string; note: string }[] = [];
  const downloaded = downloadedInterfaceRoot(flavour.id);
  candidates.push({ path: downloaded, note: "downloaded by the setup" });
  for (const parent of parents) {
    for (const name of listFolders(parent)) {
      if (!/wow-?ui-?source/i.test(name)) continue;
      candidates.push({ path: join(parent, name, "Interface"), note: "" });
    }
  }
  const seen = new Set<string>();
  const found: DetectedFolder[] = [];
  for (const candidate of candidates) {
    const key = resolve(candidate.path).toLowerCase();
    if (seen.has(key) || !isInterfaceRoot(candidate.path)) continue;
    seen.add(key);
    const { build, branch } = readCheckout(candidate.path);
    const parts = [candidate.note, branch ? `branch ${branch}` : "", build ? `build ${build}` : ""].filter(Boolean);
    const folder: DetectedFolder = { path: candidate.path, note: parts.join(", ") || "the interface source" };
    const matches = FLAVOURS.find((each) => each.interfaceSource.branch === branch || each.wagoBuild === build);
    if (matches) folder.flavour = matches.id;
    else if (candidate.path === downloaded) folder.flavour = flavour.id;
    found.push(folder);
  }
  return found.sort((a, b) => Number(b.flavour === flavour.id) - Number(a.flavour === flavour.id));
};

/** What a path typed in the setup holds, and a better one nearby when it is a folder above the right one */
export const checkFolder = (kind: FolderKind, path: string, flavour: Flavour): FolderCheck => {
  const typed = path.trim();
  if (!typed) return { path: typed, isValid: false, message: "No path given" };
  if (kind === "luajit") {
    const executable = findLuajit(typed);
    const version = executable ? readLuajitVersion(executable) : null;
    if (version) return { path: typed, isValid: true, message: version };
    return {
      path: typed,
      isValid: false,
      message: executable ? "This does not run as LuaJIT" : "There is no such file",
    };
  }
  if (!isFolder(typed)) return { path: typed, isValid: false, message: "There is no such folder" };
  if (kind === "interface") {
    if (isInterfaceRoot(typed)) {
      const { build, branch } = readCheckout(typed);
      const what = [branch ? `branch ${branch}` : "", build ? `build ${build}` : ""].filter(Boolean).join(", ");
      const isOther = build !== null && build !== flavour.wagoBuild;
      const message = `The interface source${what ? ` (${what})` : ""}${isOther ? `; ${flavour.name} is ${flavour.wagoBuild}` : ""}`;
      return { path: typed, isValid: true, message };
    }
    const inside = join(typed, "Interface");
    if (isInterfaceRoot(inside)) {
      return {
        path: typed,
        isValid: false,
        message: "This is the checkout; the Interface folder inside it is wanted",
        suggestion: inside,
      };
    }
    return { path: typed, isValid: false, message: "No interface source here (no AddOns\\Blizzard_SharedXML)" };
  }
  const count = countAddons(typed, flavour.tocSuffixes);
  if (count > 0) return { path: typed, isValid: true, message: plural(count, "addon") };
  for (const inside of [
    join(typed, "AddOns"),
    join(typed, "Interface", "AddOns"),
    join(typed, flavour.installFolder, "Interface", "AddOns"),
  ]) {
    if (isFolder(inside)) {
      return { path: typed, isValid: false, message: "The AddOns folder is further in", suggestion: inside };
    }
  }
  // An empty AddOns folder is a fine start: the addons go in later
  const isAddOns = (typed.split(/[\\/]/).filter(Boolean).at(-1) ?? "").toLowerCase() === "addons";
  return { path: typed, isValid: isAddOns, message: isAddOns ? "No addons in it yet" : "No addons here" };
};
