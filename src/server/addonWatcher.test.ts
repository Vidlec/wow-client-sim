import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { snapshotFolders } from "./addonWatcher.ts";

const root = mkdtempSync(join(tmpdir(), "addonsim-watch-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

// An addon with code, and a lot of sound files beside it (a dubbing pack's): only the code is watched
const addon = join(root, "Dubbed");
mkdirSync(join(addon, "sounds", "npc"), { recursive: true });
mkdirSync(join(addon, "tests"));
writeFileSync(join(addon, "Dubbed.toc"), "## Title: Dubbed\nCore.lua\n");
writeFileSync(join(addon, "Core.lua"), "-- code\n");
writeFileSync(join(addon, "Frames.XML"), "<Ui/>\n");
writeFileSync(join(addon, "tests", "Core.lua"), "-- a test: not watched\n");
for (let index = 0; index < 200; index++) writeFileSync(join(addon, "sounds", "npc", `line${index}.ogg`), "");

test("only an addon's code is watched, not its media or tests", async () => {
  const stamps = await snapshotFolders([addon]);
  const names = [...stamps.keys()].map((path) => path.slice(addon.length + 1).replaceAll("\\", "/")).sort();
  expect(names).toEqual(["Core.lua", "Dubbed.toc", "Frames.XML"]);
});

test("a changed code file changes the snapshot", async () => {
  const before = await snapshotFolders([addon]);
  const later = new Date(Date.now() + 5000);
  utimesSync(join(addon, "Core.lua"), later, later);
  const after = await snapshotFolders([addon]);
  expect(after.get(join(addon, "Core.lua"))).not.toBe(before.get(join(addon, "Core.lua")));
});

test("a missing folder is no addon, not an error", async () => {
  expect((await snapshotFolders([join(root, "Nowhere")])).size).toBe(0);
});
