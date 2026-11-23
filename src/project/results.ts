// What a scenario run comes to, as data: the suite runner (playScenarios, src/cli/suite.ts) returns it, the CLI
// prints it (as text, or as JSON with --json), the SDK and the MCP server hand it on. Failures carry where they
// happened, so a reader (a person, or an AI agent) goes straight to the line.
import type { LoginSpec, Project } from "./config.ts";

export type Failure = {
  /** "check": an expect() or a step that failed; "lua": a Lua error (an addon's or the scenario's) */
  kind: "check" | "lua";
  message: string;
  /** The file and line it points at, when known (the scenario's line for a check, the erroring file for an error) */
  file?: string;
  line?: number;
  /** A Lua error's traceback, trimmed to the addon's and the scenario's own frames */
  traceback?: string;
};

export type RunResult = {
  /** The scenario's path, relative to the project's root, forward slashes */
  scenario: string;
  /** The character it logged in as ("race=Human,class=WARRIOR"), "" for the default */
  login: string;
  /** Which part of a sharded scenario ("2/4"), "" for a whole one */
  shard: string;
  passed: boolean;
  steps: number;
  failures: Failure[];
  seconds: number;
  /** Scenes the run saved (saveScene), as files: open them in the simulator's page, or have them drawn */
  scenes: string[];
  /** The run's whole printed output */
  output: string;
};

export type SuiteResult = {
  passed: number;
  failed: number;
  seconds: number;
  runs: RunResult[];
};

/** What the suite runner (playScenarios, src/cli/suite.ts) is asked to play */
export type PlayOptions = {
  /** The project whose scenarios, addons and plugins it plays (src/project/select.ts finds one) */
  project: Project;
  /** Scenario files or names ("smoke", "sim/scenarios/smoke.lua"); every *.lua of the scenarios folder by default */
  scenarios?: string[];
  /** One character for every run ("race=Orc,class=WARRIOR,level=12", or as fields), over a scenario's --@login */
  login?: string | LoginSpec;
  /** How many play side by side (one per processor by default) */
  jobs?: number;
  /** Seconds a run may take before it is ended as failed (900 by default) */
  timeLimit?: number;
  /** Write the reference snapshots afresh from this run */
  update?: boolean;
  /** Record which lines of the project's coverage addon ran, and write its report */
  coverage?: boolean;
  /** Each scenario once for every race and class */
  eachCharacter?: boolean;
  /** Each run as it ends */
  onRunDone?: (run: RunResult) => void;
  /** A single run's output as it comes (the CLI's one scenario, shown live) */
  onLiveOutput?: (text: string) => void;
};
