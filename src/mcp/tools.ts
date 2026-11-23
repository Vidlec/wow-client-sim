// The MCP server's tools: the CLI's commands, each answering as the CLI prints (short text; failures as file:line),
// the screenshot as an image. The game is the project's warm one (the daemon's), shared with the CLI.
import { readFileSync } from "node:fs";
import { renderDocs } from "../sdk/docs.ts";
import { formatEval, formatFrames, formatRun, formatShot, formatState, formatSuite } from "../sdk/format.ts";
import type { Sim } from "../sdk/sim.ts";

export type Content = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };
export type ToolAnswer = { content: Content[]; isError?: boolean };

type Schema = { type: "object"; properties: Record<string, unknown>; required?: string[] };
type Tool = {
  name: string;
  description: string;
  inputSchema: Schema;
  call: (sim: Sim, args: Record<string, unknown>) => Promise<ToolAnswer>;
};

const text = (value: string, isError = false): ToolAnswer => ({
  content: [{ type: "text", text: value }],
  ...(isError ? { isError: true } : {}),
});

const str = (value: unknown): string | undefined => (typeof value === "string" && value !== "" ? value : undefined);
const num = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined;

const evalAnswer = (result: Awaited<ReturnType<Sim["eval"]>>): ToolAnswer =>
  text(formatEval(result), !result.ok || result.failures.length > 0);

const target = (value: unknown): string | { x: number; y: number } => {
  const raw = String(value ?? "");
  const point = /^(\d+(?:\.\d+)?),\s*(\d+(?:\.\d+)?)$/.exec(raw);
  return point ? { x: Number(point[1]), y: Number(point[2]) } : raw;
};

export const TOOLS: Tool[] = [
  {
    name: "eval",
    description:
      "Run Lua in the live game, in a scenario's environment: the steps (accept, kill, click, key, wait...), G (the " +
      "game's globals: G.UIParent, an addon's G.MyAddonDB), require. A single expression's value is returned. " +
      "Prints the value, failed checks and Lua errors as file:line, chat and print output. The clock moves only in " +
      "steps (wait(1)). The game runs the addons' code on disk: after an edit it is made afresh. Reference: the docs tool.",
    inputSchema: {
      type: "object",
      properties: { code: { type: "string", description: "Lua code or one expression" } },
      required: ["code"],
    },
    call: async (sim, args) => evalAnswer(await sim.eval(String(args.code ?? ""))),
  },
  {
    name: "ui",
    description:
      "The shown frames as text: label, ref (what click takes: a name or #id), type, x,y (from the top left) " +
      "WxH, mouse, text. Default: the project's addons' frames; filter: frames whose name or text holds it (any " +
      "addon, with the frames they hang in); all: every addon's and the game's; frame: one frame in detail (JSON).",
    inputSchema: {
      type: "object",
      properties: {
        filter: { type: "string" },
        all: { type: "boolean" },
        frame: { type: "string", description: "A frame's ref (Name, Name.key, #id): its anchors, scripts, children" },
        limit: { type: "number" },
      },
    },
    call: async (sim, args) => {
      const frame = str(args.frame);
      if (frame) return text(JSON.stringify(await sim.frame(frame)));
      const filter = str(args.filter);
      const limit = num(args.limit);
      const result = await sim.frames({
        ...(filter ? { filter } : {}),
        all: args.all === true,
        ...(limit ? { limit } : {}),
      });
      return text(formatFrames(result, filter ? `with "${filter}"` : "of the project's addons (all: every addon's)"));
    },
  },
  {
    name: "screenshot",
    description:
      "A PNG of the live game's screen, of one frame of it (frame: Name, Name.key or #id), or of a scene a scenario " +
      "saved (scene: '<scenario>/<name>'). About a second; prefer the ui tool to read text and places.",
    inputSchema: {
      type: "object",
      properties: {
        frame: { type: "string" },
        scene: { type: "string" },
        scale: { type: "number", description: "Device pixels a screen pixel (1 by default)" },
      },
    },
    call: async (sim, args) => {
      const frame = str(args.frame);
      const scene = str(args.scene);
      const scale = num(args.scale);
      const shot = await sim.shot({
        ...(frame ? { frame } : {}),
        ...(scene ? { scene } : {}),
        ...(scale ? { scale } : {}),
      });
      return {
        content: [
          { type: "image", data: readFileSync(shot.path).toString("base64"), mimeType: "image/png" },
          { type: "text", text: formatShot(shot) },
        ],
      };
    },
  },
  {
    name: "click",
    description:
      "Click a target in the live game: a frame (Name, Name.key, #id from the ui tool), text shown on screen (the " +
      "topmost that says it), or 'x,y' from the top left. button: LeftButton (default) or RightButton.",
    inputSchema: {
      type: "object",
      properties: { target: { type: "string" }, button: { type: "string" } },
      required: ["target"],
    },
    call: async (sim, args) => evalAnswer(await sim.click(target(args.target), str(args.button) ?? "LeftButton")),
  },
  {
    name: "key",
    description: "Press and let go a key in the live game, by the client's name (M, ESCAPE, ENTER, SHIFT-1).",
    inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"] },
    call: async (sim, args) => evalAnswer(await sim.key(String(args.key ?? ""))),
  },
  {
    name: "event",
    description: "Fire a game event at the addons (as the game fires it), with its arguments.",
    inputSchema: {
      type: "object",
      properties: { event: { type: "string" }, args: { type: "array", items: {} } },
      required: ["event"],
    },
    call: async (sim, args) =>
      evalAnswer(await sim.fire(String(args.event ?? ""), ...(Array.isArray(args.args) ? args.args : []))),
  },
  {
    name: "slash",
    description: "Run a slash command in the live game, as typed in the chat box ('/reload', '/myaddon').",
    inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
    call: async (sim, args) => evalAnswer(await sim.slash(String(args.text ?? ""))),
  },
  {
    name: "run",
    description:
      "Play one scenario (a name in the project's scenarios folder, or a path) in a fresh game booted ahead (no " +
      "boot wait), which then stays the live game: look at where it ended with ui, screenshot, state, eval. " +
      "Prints PASSED/FAILED and each failure as file:line. update: rewrite its reference snapshots.",
    inputSchema: {
      type: "object",
      properties: { scenario: { type: "string" }, update: { type: "boolean" }, login: { type: "string" } },
      required: ["scenario"],
    },
    call: async (sim, args) => {
      const login = str(args.login);
      const run = await sim.run(String(args.scenario ?? ""), {
        update: args.update === true,
        ...(login ? { login } : {}),
      });
      return text(formatRun(run), !run.passed);
    },
  },
  {
    name: "test",
    description:
      "Play the project's suite (or the scenarios named), each in its own fresh game side by side. Prints each " +
      "failed run with its failures as file:line, then a summary. A whole suite takes some 20-30 s.",
    inputSchema: {
      type: "object",
      properties: { scenarios: { type: "array", items: { type: "string" } }, update: { type: "boolean" } },
    },
    call: async (sim, args) => {
      const scenarios = Array.isArray(args.scenarios) ? args.scenarios.map(String) : [];
      const suite = await sim.test({ scenarios, update: args.update === true });
      return text(formatSuite(suite), suite.failed > 0);
    },
  },
  {
    name: "reload",
    description:
      "Reload the live game's interface, as /reload does (saved variables and the character kept; the addons' " +
      "files read again). fresh: a new game instead, nothing played in it (at once: one is booted ahead).",
    inputSchema: { type: "object", properties: { fresh: { type: "boolean" } } },
    call: async (sim, args) => {
      if (args.fresh === true) {
        const reset = await sim.reset();
        return text(`a fresh game (${reset.wasWarm ? "warm" : "booted"}, ${reset.seconds.toFixed(2)} s)`);
      }
      return evalAnswer(await sim.reload());
    },
  },
  {
    name: "state",
    description: "The live game's character, position, quest log (objectives and counts), target, clock, last chat.",
    inputSchema: { type: "object", properties: {} },
    call: async (sim) => text(formatState(await sim.state())),
  },
  {
    name: "docs",
    description:
      "The scenario API reference (every step and global, one line each), or one step whole (step: its name).",
    inputSchema: { type: "object", properties: { step: { type: "string" } } },
    call: async (_sim, args) => {
      const docs = renderDocs(str(args.step));
      return docs ? text(docs) : text(`no step ${String(args.step)}`, true);
    },
  },
  {
    name: "data",
    description:
      "The game's data: a DB2 table (table: SpellEffect, ItemSparse, UiMap...; rows holding text), or quests / " +
      "creatures by name or id (table: 'quests' or 'npcs'), as the game's data (QuestieDB) has them.",
    inputSchema: {
      type: "object",
      properties: { table: { type: "string" }, text: { type: "string" }, limit: { type: "number" } },
      required: ["table"],
    },
    call: async (sim, args) => {
      const table = String(args.table ?? "");
      const query = str(args.text) ?? "";
      const limit = num(args.limit) ?? 20;
      if (table === "quests" || table === "npcs") {
        const rows = table === "quests" ? await sim.findQuests(query, limit) : await sim.findNpcs(query, limit);
        return text(rows.map((row) => JSON.stringify(row)).join("\n") || "nothing found");
      }
      const rows = await sim.db2(table);
      const needle = query.toLowerCase();
      const found = needle
        ? rows.filter((row) => Object.values(row).some((value) => value.toLowerCase().includes(needle)))
        : rows;
      const lines = found.slice(0, limit).map((row) => JSON.stringify(row));
      lines.push(`${found.length} of ${rows.length} rows${found.length > limit ? ` (the first ${limit})` : ""}`);
      return text(lines.join("\n"));
    },
  },
];
