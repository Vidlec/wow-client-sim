// The SDK end to end, as a script or a test uses it: a game in this process (createSim) on the simulator's own
// project (its scenarios and the SimFixture addon). One game boots (2-3 s); the rest answers in milliseconds.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { simulatorProject } from "../project/select.ts";
import { createSim, type Sim } from "./index.ts";

let sim: Sim;

beforeAll(async () => {
  sim = await createSim({ project: simulatorProject() });
});

afterAll(async () => {
  await sim.close();
});

test("eval answers with values, and steps run in it", async () => {
  const answer = await sim.eval(
    'accept(844); return G.UnitLevel("player"), G.C_QuestLog.GetLogIndexForQuestID(844) ~= nil',
  );
  expect(answer.ok).toBe(true);
  expect(answer.failures).toEqual([]);
  expect(Array.isArray(answer.result)).toBe(true);
  expect((answer.result as unknown[])[1]).toBe(true);
  expect(answer.steps).toBe(1);
}, 30_000);

test("a failed check says its line, a Lua error its place", async () => {
  const failed = await sim.eval('local x = 1\nexpect(x == 2, "x is two")');
  expect(failed.failures).toEqual([{ kind: "check", message: "expected: x is two", file: "eval", line: 2 }]);
  const broken = await sim.eval("local t = nil\nreturn t.field");
  expect(broken.ok).toBe(false);
  expect(broken.line).toBe(2);
  const addonError = await sim.eval(
    'local f = G.CreateFrame("Frame"); f:SetScript("OnUpdate", function() error("boom") end); wait(0.1); f:SetScript("OnUpdate", nil)',
  );
  expect(addonError.failures.some((failure) => failure.kind === "lua" && failure.message.includes("boom"))).toBe(true);
});

test("steps as methods, frames as data, the state", async () => {
  await sim.slash("/simfixture");
  const frames = await sim.frames({ filter: "SimFixtureWindow" });
  const window = frames.frames.find((row) => row.label === "SimFixtureWindow");
  expect(window?.ref).toBe("SimFixtureWindow");
  expect(window?.w).toBeGreaterThan(0);
  const own = await sim.frames();
  expect(own.frames.some((row) => row.label === "SimFixtureWindow" && row.creator === "SimFixture")).toBe(true);
  const state = await sim.state();
  expect(state.questLog.some((quest) => quest.id === 844)).toBe(true);
  const clicked = await sim.click("#999999999");
  expect(clicked.failures[0]?.message).toContain("not on screen");
});

test("a scenario runs in a fresh game, which stays up", async () => {
  const run = await sim.run("smoke");
  expect(run.scenario).toBe("scenarios/smoke.lua");
  expect(run.failures).toEqual([]);
  expect(run.passed).toBe(true);
  const after = await sim.eval("return 1");
  expect(after.result).toBe(1);
}, 60_000);

test("the game's tables, without a game", async () => {
  const rows = await sim.db2("ChrClasses");
  expect(rows.some((row) => row.Filename === "MAGE")).toBe(true);
});

test("a picture of a frame", async () => {
  if (!existsSync("C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe") && process.platform === "win32") return;
  await sim.slash("/simfixture");
  const shot = await sim.shot({ frame: "SimFixtureWindow" });
  expect(existsSync(shot.path)).toBe(true);
  expect(shot.width).toBeGreaterThan(0);
}, 60_000);
