import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readCatalog, readToc, switchAddon } from "./addonCatalog.ts";
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

describe("switchAddon", () => {
  test("switching one on brings what it needs; off takes only it", () => {
    expect(switchAddon({ ...config, addons: [] }, "Tracker", true)).toEqual(["Lib", "Tracker"]);
    expect(switchAddon(config, "lib", false)).toEqual([]);
    expect(switchAddon(config, "Nope", true)).toBeNull();
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
    expect(switchAddon({ ...config, addons: [] }, "Mine", true, own)).toEqual(["Lib", "Mine"]);
  });
});
