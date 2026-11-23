// Every addon in the addons folder (and the served project's own, which win over one of the same name there), with
// what its TOC says and whether the simulator loads it; switching one on brings the addons it needs, as the game's
// AddOns list does
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import type { ProjectAddon } from "../project/config.ts";
import { type Config, SAVED_DIR } from "./config.ts";

export type CatalogEntry = {
  name: string;
  title: string;
  notes: string;
  version: string;
  author: string;
  dependencies: string[];
  loadOnDemand: boolean;
  savedVariables: string[];
  enabled: boolean;
  savedBytes: number;
  /** One of the served project's own addons (from its folder, not the AddOns folder) */
  isProject: boolean;
};

const DEPENDENCY_KEYS = ["dependencies", "requireddeps", "dep", "deps", "requireddep"];

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

const readDependencies = (metadata: Map<string, string>): string[] => {
  const found: string[] = [];
  for (const key of DEPENDENCY_KEYS) {
    for (const item of splitList(metadata.get(key) ?? "")) {
      const name = item.split("[")[0] ?? "";
      if (name && !found.some((known) => known.toLowerCase() === name.toLowerCase())) found.push(name);
    }
  }
  return found;
};

/** The addon folders to list: the AddOns folder's, then the project's own over those of the same name */
const listFolders = (config: Config, projectAddons: readonly ProjectAddon[]): Map<string, ProjectAddon> => {
  const folders = new Map<string, ProjectAddon>();
  const root = config.addonsRoot;
  if (root && existsSync(root)) {
    for (const name of readdirSync(root)) folders.set(name.toLowerCase(), { name, dir: join(root, name) });
  }
  for (const addon of projectAddons)
    folders.set(addon.name.toLowerCase(), { name: basename(addon.dir), dir: addon.dir });
  return folders;
};

export const readCatalog = (config: Config, projectAddons: readonly ProjectAddon[] = []): CatalogEntry[] => {
  const enabled = new Set(config.addons.map((name) => name.toLowerCase()));
  const isProject = new Set(projectAddons.map((addon) => addon.name.toLowerCase()));
  const folders = [...listFolders(config, projectAddons).values()].sort((first, second) =>
    first.name.toLowerCase().localeCompare(second.name.toLowerCase()),
  );
  const catalog: CatalogEntry[] = [];
  for (const { name, dir: folder } of folders) {
    if (!statSync(folder, { throwIfNoEntry: false })?.isDirectory()) continue;
    const metadata = readToc(folder, name, config.tocSuffixes);
    if (!metadata) continue;
    const saved = join(SAVED_DIR, `${name}.lua`);
    catalog.push({
      name,
      title: stripCodes(metadata.get("title")) || name,
      notes: stripCodes(metadata.get("notes")),
      version: metadata.get("version") ?? "",
      author: stripCodes(metadata.get("author")),
      dependencies: readDependencies(metadata),
      loadOnDemand: metadata.get("loadondemand") === "1",
      savedVariables: splitList(
        `${metadata.get("savedvariables") ?? ""},${metadata.get("savedvariablespercharacter") ?? ""}`,
      ),
      enabled: enabled.has(name.toLowerCase()),
      savedBytes: existsSync(saved) ? statSync(saved).size : 0,
      isProject: isProject.has(name.toLowerCase()),
    });
  }
  return catalog;
};

/** The addons to load once one is switched on (with what it needs, before it) or off */
export const switchAddon = (
  config: Config,
  name: string,
  isOn: boolean,
  projectAddons: readonly ProjectAddon[] = [],
): string[] | null => {
  const catalog = new Map(readCatalog(config, projectAddons).map((entry) => [entry.name.toLowerCase(), entry]));
  if (!catalog.has(name.toLowerCase())) return null;
  if (!isOn) return config.addons.filter((addon) => addon.toLowerCase() !== name.toLowerCase());
  const wanted = [...config.addons];
  const seen = new Set<string>();
  const add = (addonName: string): void => {
    const entry = catalog.get(addonName.toLowerCase());
    if (!entry || seen.has(addonName.toLowerCase())) return;
    seen.add(addonName.toLowerCase());
    for (const dependency of entry.dependencies) add(dependency);
    if (!wanted.some((known) => known.toLowerCase() === entry.name.toLowerCase())) wanted.push(entry.name);
  };
  add(name);
  return wanted;
};
