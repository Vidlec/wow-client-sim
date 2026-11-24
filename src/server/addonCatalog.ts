// Every addon in the AddOns folder, the further folders and the served project (addonSources.ts: a later one over one
// of the same name before it), with what its TOC says and whether the simulator loads it; switching some on brings
// the addons they need, switching one off takes those that need it (shared/addonDeps.ts)
import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import type { ProjectAddon } from "../project/config.ts";
import { type AddonPlan, isForThisGame, planAddons } from "../shared/addonDeps.ts";
import { type AddonOrigin, listAddonSources } from "./addonSources.ts";
import { type Config, SAVED_DIR } from "./config.ts";

export type CatalogEntry = {
  name: string;
  title: string;
  notes: string;
  version: string;
  author: string;
  dependencies: string[];
  /** Loaded first when they are on, not needed */
  optionalDependencies: string[];
  loadOnDemand: boolean;
  savedVariables: string[];
  enabled: boolean;
  savedBytes: number;
  /** One of the served project's own addons (from its folder, not the AddOns folder) */
  isProject: boolean;
  /** Where it was found: the game's AddOns folder, a further folder (the settings' addonFolders), the project */
  origin: AddonOrigin;
  /** The folder it was found in */
  root: string;
  /** Its TOC's ## Interface */
  interfaceVersion: string;
  /** Whether this client lists it: false when its TOC is only for other game lines (Retail's 120000s...) */
  isForThisGame: boolean;
  /** Its TOC's title as the game shows it, with its colour codes */
  richTitle: string;
  /** ## Category, with its colour codes: the game's AddOns list files it under this heading (none: after them) */
  category: string;
  /**
   * The addon it is listed under, as the game's AddOns list nests it: ## Group, else the one it needs whose name its
   * own starts with (EllesmereUIActionBars under EllesmereUI); its own name when it heads a group or stands alone
   */
  group: string;
  /** ## IconTexture: its icon in the game's list (empty: none) */
  iconTexture: string;
};

const DEPENDENCY_KEYS = ["dependencies", "requireddeps", "dep", "deps", "requireddep"];
const OPTIONAL_KEYS = ["optionaldeps", "optionaldep", "optionaldependencies"];

/** An addon's TOC metadata (## Key: value, keys in lower case), from the TOC this client would read */
export const readToc = (folder: string, name: string, suffixes: readonly string[]): Map<string, string> | null => {
  for (const suffix of suffixes) {
    const path = join(folder, `${name}${suffix}.toc`);
    if (!existsSync(path) || !statSync(path).isFile()) continue;
    const metadata = new Map<string, string>();
    for (const line of readFileSync(path, "utf8").replace(/^﻿/, "").split(/\r?\n/)) {
      if (!line.startsWith("##")) continue;
      const colon = line.indexOf(":");
      if (colon < 0) continue;
      const key = line.slice(2, colon).trim().toLowerCase();
      if (!metadata.has(key)) metadata.set(key, line.slice(colon + 1).trim());
    }
    return metadata;
  }
  return null;
};

/** A TOC text without its colour codes (|cffxxxxxx ... |r) and textures */
const stripCodes = (text: string | undefined): string =>
  (text ?? "").replace(/\|c[0-9a-fA-F]{8}|\|r|\|T[^|]*\|t/g, "").trim();

const splitList = (text: string): string[] =>
  text
    .replace(/ /g, "")
    .split(",")
    .filter((item) => item !== "");

const readDependencies = (metadata: Map<string, string>, keys: readonly string[] = DEPENDENCY_KEYS): string[] => {
  const found: string[] = [];
  for (const key of keys) {
    for (const item of splitList(metadata.get(key) ?? "")) {
      const name = item.split("[")[0] ?? "";
      if (name && !found.some((known) => known.toLowerCase() === name.toLowerCase())) found.push(name);
    }
  }
  return found;
};

export const readCatalog = (config: Config, projectAddons: readonly ProjectAddon[] = []): CatalogEntry[] => {
  const enabled = new Set(config.addons.map((name) => name.toLowerCase()));
  const clientInterface = Number(config.interface) || 0;
  const folders = [...listAddonSources(config, projectAddons).values()].sort((first, second) =>
    first.name.toLowerCase().localeCompare(second.name.toLowerCase()),
  );
  const catalog: CatalogEntry[] = [];
  for (const { name, dir: folder, origin, root } of folders) {
    if (!statSync(folder, { throwIfNoEntry: false })?.isDirectory()) continue;
    const metadata = readToc(folder, name, config.tocSuffixes);
    if (!metadata) continue;
    const saved = join(SAVED_DIR, `${name}.lua`);
    catalog.push({
      name,
      title: stripCodes(metadata.get("title")) || name,
      richTitle: metadata.get("title") || name,
      category: (metadata.get("category") ?? "").trim(),
      group: stripCodes(metadata.get("group")),
      iconTexture: metadata.get("icontexture") ?? "",
      notes: stripCodes(metadata.get("notes")),
      version: metadata.get("version") ?? "",
      author: stripCodes(metadata.get("author")),
      dependencies: readDependencies(metadata),
      optionalDependencies: readDependencies(metadata, OPTIONAL_KEYS),
      loadOnDemand: metadata.get("loadondemand") === "1",
      savedVariables: splitList(
        `${metadata.get("savedvariables") ?? ""},${metadata.get("savedvariablespercharacter") ?? ""}`,
      ),
      enabled: enabled.has(name.toLowerCase()),
      savedBytes: existsSync(saved) ? statSync(saved).size : 0,
      isProject: origin === "project",
      origin,
      root,
      interfaceVersion: metadata.get("interface") ?? "",
      isForThisGame: clientInterface ? isForThisGame(metadata.get("interface"), clientInterface) : true,
    });
  }
  groupAddons(catalog);
  return catalog;
};

/**
 * Each addon's group, as the game's AddOns list works it out: the ## Group it names when that is an addon here (its
 * exact name), else the addon it needs whose name its own begins with (the client groups "similar names and
 * dependencies"), else its own. One level deep: a group is headed by an addon that is its own group.
 */
export const groupAddons = (catalog: CatalogEntry[]): void => {
  const byName = new Map(catalog.map((entry) => [entry.name.toLowerCase(), entry]));
  const headOf = (entry: CatalogEntry): string => {
    const named = entry.group && byName.get(entry.group.toLowerCase());
    if (named) return named.name;
    const own = entry.name.toLowerCase();
    const parent = entry.dependencies
      .map((dependency) => byName.get(dependency.toLowerCase()))
      .find(
        (candidate) =>
          candidate && own.startsWith(candidate.name.toLowerCase()) && own !== candidate.name.toLowerCase(),
      );
    return parent ? parent.name : entry.name;
  };
  const heads = new Map(catalog.map((entry) => [entry, headOf(entry)]));
  for (const entry of catalog) {
    const head = heads.get(entry) ?? entry.name;
    const headEntry = byName.get(head.toLowerCase());
    // (under an addon that is itself under another: under that one's group, as one level deep)
    entry.group = headEntry && headEntry !== entry ? (heads.get(headEntry) ?? head) : entry.name;
  }
};

/**
 * The addons on after switching some on (each with what it needs) and some off (with what needs it); an addon this
 * client does not list (another game line's) is never switched on. Null when a name is no addon here.
 */
export const changeAddons = (
  config: Config,
  change: { on?: readonly string[]; off?: readonly string[] },
  projectAddons: readonly ProjectAddon[] = [],
): AddonPlan | null => {
  const catalog = readCatalog(config, projectAddons).filter((entry) => entry.isForThisGame);
  const known = new Set(catalog.map((entry) => entry.name.toLowerCase()));
  const named = [...(change.on ?? []), ...(change.off ?? [])];
  if (named.some((name) => !known.has(name.toLowerCase()))) return null;
  return planAddons(catalog, config.addons, change.on ?? [], change.off ?? []);
};
