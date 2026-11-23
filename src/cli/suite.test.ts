import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import type { Project } from "../project/config.ts";
import { readFailures, runName } from "./suite.ts";

const project: Project = {
  root: "C:/Projects/Mine",
  configPath: null,
  addons: [{ name: "MyAddon", dir: join("C:/Projects/Mine", "addons", "MyAddon") }],
  installed: [],
  load: ["MyAddon"],
  scenariosDir: "C:/Projects/Mine/sim/scenarios",
  plugins: [],
  luaPath: [],
  coverageAddon: "MyAddon",
  login: null,
  flavour: null,
  galleryDir: null,
};

// As lua/play.lua reports them
const OUTPUT = [
  "Booted in 2.00s; playing C:/Projects/Mine/sim/scenarios/a.lua",
  "",
  "Lua error (2x): Interface/AddOns/MyAddon/Core.lua:12: attempt to index a nil value",
  "stack traceback:",
  "\t[C]: in function 'error'",
  "\tInterface/AddOns/MyAddon/Core.lua:12: in function 'update'",
  "",
  "Failed: expected: the window opens",
  "  at C:/Projects/Mine/sim/scenarios/a.lua:7",
  "",
  "Failed: snapshot map changed in 3 of 90 lines (bun run play --update to accept); first at line 4",
  "      was: k=t",
  "      now: k=s",
  "  at C:/Projects/Mine/sim/scenarios/a.lua:9",
  "",
  "Failed: the scenario itself failed: C:/Projects/Mine/sim/scenarios/a.lua:11: boom",
  "",
  "FAILED: 5 steps, 1 Lua errors, 3 failed checks",
].join("\n");

describe("readFailures", () => {
  const failures = readFailures(project, OUTPUT);

  test("a Lua error: its addon file on disk, its line, its own traceback", () => {
    expect(failures[0]?.kind).toBe("lua");
    expect(failures[0]?.file).toBe(join(project.addons[0]?.dir ?? "", "Core.lua"));
    expect(failures[0]?.line).toBe(12);
    expect(failures[0]?.traceback).toBe("\tInterface/AddOns/MyAddon/Core.lua:12: in function 'update'");
  });

  test("a check: the scenario's line", () => {
    expect(failures[1]).toEqual({
      kind: "check",
      message: "expected: the window opens",
      file: "C:/Projects/Mine/sim/scenarios/a.lua",
      line: 7,
    });
  });

  test("a message over several lines stays whole", () => {
    expect(failures[2]?.message.split("\n")).toHaveLength(3);
    expect(failures[2]?.line).toBe(9);
  });

  test("the scenario's own error: kind lua, its place from the message", () => {
    expect(failures[3]?.kind).toBe("lua");
    expect(failures[3]?.line).toBe(11);
  });

  test("nothing else", () => {
    expect(failures).toHaveLength(4);
  });
});

describe("runName", () => {
  test("the scenario, its login and its part", () => {
    expect(runName({ scenario: "sim/scenarios/a.lua", login: "race=Orc", shard: "2/4" })).toBe(
      "sim/scenarios/a.lua as race=Orc, part 2/4",
    );
  });
});
