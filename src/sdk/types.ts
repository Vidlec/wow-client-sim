// What the SDK answers, as types: the same for a game in this process (createSim) and one in the project's daemon
// (connect), and what the CLI and the MCP server print from.
import type { Failure, RunResult, SuiteResult } from "../project/results.ts";

export type { Failure, RunResult, SuiteResult };

/** A Lua error an addon (or the game) raised: as the game's error frame has it */
export type LuaError = { message: string; stack: string; count: number };

/** What a piece of Lua did in the live game (eval, a step, a click...) */
export type EvalResult = {
  ok: boolean;
  /** What it returned, as JSON (frames as "<Button Name #id>", tables a few levels deep); several values: an array */
  result?: unknown;
  /** Its own error, when it raised one, with the line of the code it was in and the frames above it */
  error?: string;
  traceback?: string;
  file?: string;
  line?: number;
  /** What failed while it ran: checks and steps (expect, a step that could not be done) with their line, and Lua
   * errors raised meanwhile (an addon's, the game's) with the addon file and line they name */
  failures: Failure[];
  /** Chat lines written meanwhile, colour codes taken out */
  chat: string[];
  /** What it printed (print, the steps' notes) */
  output: string[];
  /** Steps it took, the game seconds they took, the real seconds the whole took */
  steps: number;
  gameSeconds: number;
  seconds: number;
  /** Said when the game was made afresh first (the addons' files changed) or is older than them */
  notice?: string;
};

/** One shown frame. x, y from the screen's top left (as clicks count), in screen pixels */
export type FrameRow = {
  id: number;
  /** Its name, else its parent's name and the key it is kept under (Parent.key), else <Type #id> */
  label: string;
  /** What click() and frame() take for it: its global name, else "#id" */
  ref: string;
  type: string;
  depth: number;
  x?: number;
  y?: number;
  w?: number;
  h?: number;
  /** The text its font strings show, " | " between them, colour codes taken out */
  text: string;
  creator?: string;
  mouse?: boolean;
  alpha?: number;
};

export type FramesResult = { frames: FrameRow[]; isCut?: boolean; width: number; height: number; notice?: string };

export type FramesOptions = {
  /** Only rows whose label or text holds this (any case), with the frames they hang in */
  filter?: string;
  /** Every addon's frames and the game's, not only the project's (no filter) */
  all?: boolean;
  /** Rows at most (300) */
  limit?: number;
};

/** The character and the game, compact */
export type GameState = {
  name: string;
  race: string;
  class: string;
  level: number;
  money: number;
  position: { uiMapId: number; x: number; y: number; zone?: string };
  questLog: { id: number; title: string; level: number; complete?: boolean; objectives: string[] }[];
  completedQuests: number;
  target?: { name: string; level: number; health: number; healthMax: number };
  inCombat: boolean;
  /** The game's clock, seconds since login */
  now: number;
  screen: { width: number; height: number };
  errors: number;
  lastChat: string[];
  notice?: string;
};

/** A drawn scene, as the page draws it (lua/scene.lua's export) */
export type Scene = { width: number; height: number; items: Record<string, unknown>[] };

export type ShotOptions = {
  /** A frame (its name, Name.key or #id): the picture is cut to it */
  frame?: string;
  /** A scene saved by a scenario (saveScene/snapshot): a .scene.json file, or "<scenario>/<name>" of the last run */
  scene?: string;
  /** Where to write the PNG (a temporary file by default) */
  out?: string;
  /** Device pixels per screen pixel (1 by default: what an AI reads cheaply; 2 for a sharp picture) */
  scale?: number;
  /** Behind the interface, as the world would be: a texture path (none by default) */
  backdrop?: string;
};

export type ShotResult = { path: string; width: number; height: number; seconds: number; notice?: string };

/** A scenario run in a warm game, which stays up afterwards to be looked at */
export type RunOptions = {
  /** Write its reference snapshots afresh */
  update?: boolean;
  /** Log in as ("race=Orc,class=WARRIOR,level=12"), over the scenario's own --@login */
  login?: string;
};

export type DaemonStatus = {
  root: string;
  pid: number;
  port: number;
  startedAt: string;
  /** The live game: whether one runs, and since when (seconds), and whether files changed since it booted */
  live: { running: boolean; scenario?: string; ageSeconds?: number; stale?: boolean };
  /** Games booted ahead, by what they were booted for */
  warm: { key: string; ready: boolean }[];
};
