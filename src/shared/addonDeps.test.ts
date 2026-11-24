import { expect, test } from "bun:test";
import { isForThisGame, neededBy, planAddons } from "./addonDeps.ts";

// Core needs Lib; Raids needs Core; Lib needs nothing; Broken needs a library that is not installed
const CATALOG = [
  { name: "Lib", dependencies: [] },
  { name: "Core", dependencies: ["Lib", "Blizzard_UIParent"] },
  { name: "Raids", dependencies: ["Core"] },
  { name: "Other", dependencies: [] },
  { name: "Broken", dependencies: ["LibGone"] },
];

test("switched on: what it needs comes first, and theirs; the game's own are never asked for", () => {
  const plan = planAddons(CATALOG, ["Other"], ["Raids"], []);
  expect(plan.addons).toEqual(["Other", "Lib", "Core", "Raids"]);
  expect(plan.broughtIn).toEqual(["Lib", "Core"]);
  expect(plan.takenOut).toEqual([]);
  expect(plan.missing).toEqual([]);
});

test("switched off: what needs it goes off too, all the way up", () => {
  const plan = planAddons(CATALOG, ["Lib", "Core", "Raids", "Other"], [], ["Lib"]);
  expect(plan.addons).toEqual(["Other"]);
  expect(plan.takenOut.sort()).toEqual(["Core", "Raids"]);
});

test("names in any case, unknown ones dropped, nothing twice", () => {
  const plan = planAddons(CATALOG, ["other", "Nowhere"], ["core", "CORE", "lib"], []);
  expect(plan.addons).toEqual(["Other", "Lib", "Core"]);
  expect(plan.broughtIn).toEqual([]); // (Lib was asked for too)
});

test("a dependency that is not installed is told, and the addon still listed", () => {
  const plan = planAddons(CATALOG, [], ["Broken"], []);
  expect(plan.addons).toEqual(["Broken"]);
  expect(plan.missing).toEqual([{ addon: "Broken", needs: "LibGone" }]);
});

test("dependencies that need each other do not loop", () => {
  const plan = planAddons(
    [
      { name: "A", dependencies: ["B"] },
      { name: "B", dependencies: ["A"] },
    ],
    [],
    ["A"],
    [],
  );
  expect(plan.addons.sort()).toEqual(["A", "B"]);
});

test("what needs an addon, among those on", () => {
  expect(neededBy(CATALOG, new Set(["core", "raids"]), "Lib")).toEqual(["Core"]);
  expect(neededBy(CATALOG, new Set(["raids"]), "Lib")).toEqual([]);
});

test("an addon is for this game unless its TOC names only other game lines", () => {
  expect(isForThisGame("16001", 16001)).toBe(true);
  expect(isForThisGame("11509, 20506", 16001)).toBe(true); // an older number of the same line: out of date, listed
  expect(isForThisGame(undefined, 16001)).toBe(true);
  expect(isForThisGame("120105, 120107", 16001)).toBe(false); // Retail's
  expect(isForThisGame("50504", 16001)).toBe(false);
});
