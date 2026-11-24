// The setup's pieces that need no server: settings checked key by key, the config the simulator gets from them, what
// a typed folder holds, and the folder dialog's script (parsed by PowerShell, never shown).
import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveConfig } from "../config.ts";
import { forever } from "../flavours/forever.ts";
import { checkChange, defaultSettings, type StoredSettings } from "../settings.ts";
import { listFolder } from "./browse.ts";
import { checkFolder } from "./detect.ts";

describe("settings", () => {
  test("a change is checked key by key: the good kept, the bad refused with why", () => {
    const { accepted, errors } = checkChange({ fps: 30, port: 0, locale: "deDE", screenWidth: 12 } as never);
    expect(accepted).toEqual({ fps: 30, locale: "deDE" });
    expect(errors.map((error) => error.key).sort()).toEqual(["port", "screenWidth"]);
    expect(checkChange({ nonsense: true } as never).errors[0]?.key).toBe("settings");
  });

  test("the config fills in the flavour's client under the keys Lua reads", () => {
    const settings: StoredSettings = {
      ...defaultSettings(),
      addonsRoot: "X",
      blizzardAddons: "light",
      gameWorldMap: true,
    };
    const config = resolveConfig(settings);
    expect(config.build).toBe(forever.wagoBuild);
    expect(config.buildNumber).toBe("71037");
    expect(config.interface).toBe(16001);
    expect(config.tocSuffixes).toEqual(forever.tocSuffixes);
    expect(config.atlasVariant).toBe("-c60");
    expect(config.gameTypes).toEqual(["mainline", "camelot"]);
    expect(config.wowlessProduct).toBe("wowf");
    expect("blizzardAddons" in config).toBe(false); // (left out: the light interface)
    expect(config.gameWorldMap).toBe(true); // (a developer's own key, passed on)
    expect("luajitPath" in config).toBe(false);
  });

  test("a build set by hand gives its own version and number", () => {
    const config = resolveConfig({ ...defaultSettings(), build: "1.60.1.70959" });
    expect([config.version, config.buildNumber]).toEqual(["1.60.1", "70959"]);
  });
});

describe("folders", () => {
  test("an addons folder, and the AddOns folder inside a game folder", () => {
    const root = mkdtempSync(join(tmpdir(), "addonsim-setup-"));
    try {
      const addons = join(root, "_forever_", "Interface", "AddOns");
      mkdirSync(join(addons, "Thing"), { recursive: true });
      writeFileSync(join(addons, "Thing", "Thing.toc"), "## Title: Thing\n");
      expect(checkFolder("addons", addons, forever)).toMatchObject({ isValid: true, message: "1 addon" });
      expect(checkFolder("addons", root, forever)).toMatchObject({ isValid: false, suggestion: addons });
      expect(checkFolder("addons", join(root, "nope"), forever).isValid).toBe(false);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("an interface source, and its Interface folder inside a checkout", () => {
    const root = mkdtempSync(join(tmpdir(), "addonsim-setup-"));
    try {
      const interfaceRoot = join(root, "Interface");
      mkdirSync(join(interfaceRoot, "AddOns", "Blizzard_SharedXML"), { recursive: true });
      writeFileSync(join(root, "version.txt"), forever.wagoBuild);
      expect(checkFolder("interface", interfaceRoot, forever)).toMatchObject({ isValid: true });
      expect(checkFolder("interface", root, forever)).toMatchObject({ isValid: false, suggestion: interfaceRoot });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

describe("the folder browser", () => {
  test("lists a folder's folders, the AddOns folder pointed out, and checks the folder itself", () => {
    const root = mkdtempSync(join(tmpdir(), "addonsim-browse-"));
    try {
      const addons = join(root, "Interface", "AddOns");
      mkdirSync(join(addons, "Mine"), { recursive: true });
      writeFileSync(join(addons, "Mine", "Mine.toc"), "## Title: Mine\n");
      mkdirSync(join(root, ".hidden"));
      writeFileSync(join(root, "notes.txt"), "");
      const top = listFolder("addons", root, forever);
      expect(top.entries.map((entry) => entry.name)).toEqual(["Interface"]);
      expect(top.entries[0]?.hint).toBe("holds AddOns");
      const inside = listFolder("addons", join(root, "Interface"), forever);
      expect(inside.entries[0]?.hint).toBe("an AddOns folder");
      expect(inside.parent).toBe(root);
      expect(listFolder("addons", addons, forever).check?.isValid).toBe(true);
      // (a folder that is not there: the nearest one that is, and said so)
      const missing = listFolder("addons", join(addons, "Gone", "Deeper"), forever);
      expect(missing.path).toBe(addons);
      expect(missing.error).toContain("not there");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
