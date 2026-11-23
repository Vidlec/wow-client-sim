// AddonSim's SDK, for scripts and tests (bun test) driving the simulator:
//
//   import { connect } from "addonsim";
//   const sim = await connect();               // the project's warm game (its daemon; started when none runs)
//   const run = await sim.run("smoke");        // a scenario in a fresh game, which stays up afterwards
//   const ui = await sim.frames({ filter: "Plainstrider" });
//   await sim.click("Accept");
//   const shot = await sim.shot({ frame: "QuestFrame" });
//
// createSim() is the same in this process, with games of its own (a test's own, nothing shared). Both hand out a Sim
// (sim.ts). A project's config imports defineProject from here: this module loads nothing heavy until asked.
import type { Project } from "../project/config.ts";
import type { Sim } from "./sim.ts";

export type { LoginSpec, Project, ProjectConfig } from "../project/config.ts";
export { defineProject } from "../project/config.ts";
export type { Sim, SimInfo } from "./sim.ts";
export type * from "./types.ts";

export type SimOptions = {
  /** The project's folder (or a folder in it); the working folder's by default */
  project?: string | Project;
  /** Boot a game ahead for the next run (createSim: false by default; the daemon always does) */
  warm?: boolean;
};

const projectOf = async (project: string | Project | undefined): Promise<Project> => {
  if (project && typeof project === "object") return project;
  const { selectProject } = await import("../project/select.ts");
  return selectProject(project ?? null);
};

/** A simulator in this process: its own live game and pool, closed with sim.close() */
export const createSim = async (options: SimOptions = {}): Promise<Sim> => {
  const { LocalSim } = await import("./local.ts");
  return new LocalSim(await projectOf(options.project), { warm: options.warm ?? false });
};

/** The project's daemon (started when none runs): the warm game the CLI and the MCP server share */
export const connect = async (options: SimOptions = {}): Promise<Sim> => {
  const { connectDaemon } = await import("./remote.ts");
  return connectDaemon(await projectOf(options.project));
};
