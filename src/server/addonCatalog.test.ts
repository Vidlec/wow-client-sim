import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { type CatalogEntry, changeAddons, groupAddons, readCatalog, readToc } from "./addonCatalog.ts";
import { findAddonDir, listAddonSources } from "./addonSources.ts";
import type { Config } from "./config.ts";

const root = mkdtempSync(join(tmpdir(), "addonsim-catalog-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const addAddon = (name: string, toc: string, suffix = ""): void => {
  mkdirSync(join(root, name), { recursive: true });
  writeFileSync(join(root, name, `${name}${suffix}.toc`), toc);
};

addAddon("Lib", "## Title: |cff00ff00Lib|r\n## Version: 1.0\n");
addAddon(
  "Tracker",
  "﻿## Title: Tracker\n## Dependencies: Lib, Missing[optional]\n## SavedVariables: TrackerDB\n",
  "_Forever",
);
addAddon("Tracker", "## Title: Tracker (wrong client)\n");
mkdirSync(join(root, "NoToc"));

const config = { addonsRoot: root, addons: ["Lib"], tocSuffixes: ["_Forever", ""] } as unknown as Config;

describe("readToc", () => {
  test("reads the TOC this client would, keys in lower case, the first of each kept", () => {
    expect(readToc(join(root, "Tracker"), "Tracker", ["_Forever", ""])?.get("title")).toBe("Tracker");
  });
});

describe("readCatalog", () => {
  test("lists addons with a TOC, with their titles cleaned of colour codes", () => {
    const catalog = readCatalog(config);
    expect(catalog.map((entry) => entry.name)).toEqual(["Lib", "Tracker"]);
    expect(catalog[0]?.title).toBe("Lib");
    expect(catalog[0]?.enabled).toBe(true);
    expect(catalog[1]?.dependencies).toEqual(["Lib", "Missing"]);
    expect(catalog[1]?.savedVariables).toEqual(["TrackerDB"]);
  });
});

describe("changeAddons, one at a time", () => {
  test("switching one on brings what it needs; off takes it and what needs it", () => {
    expect(changeAddons({ ...config, addons: [] }, { on: ["Tracker"] })?.addons).toEqual(["Lib", "Tracker"]);
    expect(changeAddons(config, { off: ["lib"] })?.addons).toEqual([]);
    expect(changeAddons(config, { on: ["Nope"] })).toBeNull();
  });
});

describe("a project's own addons", () => {
  const projectRoot = mkdtempSync(join(tmpdir(), "addonsim-project-"));
  afterAll(() => rmSync(projectRoot, { recursive: true, force: true }));
  mkdirSync(join(projectRoot, "addons", "Lib"), { recursive: true });
  writeFileSync(join(projectRoot, "addons", "Lib", "Lib.toc"), "## Title: Lib (the project's)\n");
  mkdirSync(join(projectRoot, "addons", "Mine"), { recursive: true });
  writeFileSync(join(projectRoot, "addons", "Mine", "Mine.toc"), "## Title: Mine\n## Dependencies: Lib\n");
  const own = [
    { name: "Lib", dir: join(projectRoot, "addons", "Lib") },
    { name: "Mine", dir: join(projectRoot, "addons", "Mine") },
  ];

  test("are listed from the project's folder, over an installed one of the same name", () => {
    const catalog = readCatalog(config, own);
    expect(catalog.map((entry) => entry.name)).toEqual(["Lib", "Mine", "Tracker"]);
    expect(catalog[0]?.title).toBe("Lib (the project's)");
    expect(catalog.map((entry) => entry.isProject)).toEqual([true, true, false]);
  });

  test("switch on with what they need", () => {
    expect(changeAddons({ ...config, addons: [] }, { on: ["Mine"] }, own)?.addons).toEqual(["Lib", "Mine"]);
  });
});

describe("further addon folders", () => {
  // A folder of addons (one of them also in the AddOns folder), and a folder that is one addon itself
  const more = `${root}-more`;
  const single = `${root}-Single`;
  mkdirSync(join(more, "Lib"), { recursive: true });
  writeFileSync(join(more, "Lib", "Lib.toc"), "## Title: Lib (newer)\n## Version: 2.0\n");
  mkdirSync(join(more, "Retail"), { recursive: true });
  writeFileSync(join(more, "Retail", "Retail.toc"), "## Interface: 120105\n## Title: Retail only\n");
  mkdirSync(single, { recursive: true });
  const singleName = basename(single);
  writeFileSync(join(single, `${singleName}.toc`), "## Title: Single\n## Dependencies: Tracker\n");
  afterAll(() => {
    rmSync(more, { recursive: true, force: true });
    rmSync(single, { recursive: true, force: true });
  });
  const withMore = { ...config, addons: [], addonFolders: [more, single], interface: 16001 } as unknown as Config;

  test("an addon in a further folder wins over the AddOns folder's; a folder may be one addon", () => {
    const sources = listAddonSources(withMore);
    expect(sources.get("lib")?.dir).toBe(join(more, "Lib"));
    expect(sources.get("lib")?.origin).toBe("folder");
    expect(sources.get("tracker")?.origin).toBe("game");
    expect(sources.get(singleName.toLowerCase())?.dir).toBe(single);
    expect(findAddonDir(withMore, [], "Lib")).toBe(join(more, "Lib"));
    expect(findAddonDir(withMore, [], "Nowhere")).toBe(join(root, "Nowhere"));
  });

  test("the catalog lists them all, with where each is and whether this game lists it", () => {
    const catalog = readCatalog(withMore);
    const lib = catalog.find((entry) => entry.name === "Lib");
    expect(lib?.version).toBe("2.0");
    expect(lib?.root).toBe(more);
    expect(catalog.find((entry) => entry.name === "Retail")?.isForThisGame).toBe(false);
    expect(catalog.find((entry) => entry.name === singleName)?.isForThisGame).toBe(true);
  });

  test("several switched at once: their needs come too; an addon for another game is refused", () => {
    const plan = changeAddons(withMore, { on: [singleName] });
    expect(plan?.addons).toEqual(["Lib", "Tracker", singleName]);
    expect(plan?.broughtIn).toEqual(["Lib", "Tracker"]);
    expect(changeAddons(withMore, { on: ["Retail"] })).toBeNull();
    const on = { ...withMore, addons: ["Lib", "Tracker", singleName] } as unknown as Config;
    expect(changeAddons(on, { off: ["Lib"] })?.takenOut).toEqual(["Tracker", singleName]);
  });
});

describe("groupAddons", () => {
  const entry = (name: string, dependencies: string[] = [], group = "") =>
    ({ name, dependencies, group }) as unknown as CatalogEntry;
  test("as the game's AddOns list: ## Group when it names an addon, else the needed one its name begins with", () => {
    const catalog = [
      entry("Suite"),
      entry("SuiteBars", ["Suite"]),
      entry("SuiteOptions", ["SuiteBars"], "Suite"),
      entry("Plugin", ["Suite"], "Nowhere"),
      entry("SuiteBarsExtra", ["SuiteBars"]),
    ];
    groupAddons(catalog);
    expect(catalog.map((item) => item.group)).toEqual(["Suite", "Suite", "Suite", "Plugin", "Suite"]);
  });
});
