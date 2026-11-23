// A game's failures as the contract's Failure (src/project/results.ts): a failed check's text with its "  at
// file:line" line (play.lua writes it, lua/sdkplay.lua for a command's own code), a Lua error's message with the
// addon file it names mapped to the file on disk, so a reader opens the line at once.
import { join, relative } from "node:path";
import type { Project } from "../project/config.ts";
import type { Failure, LuaError } from "./types.ts";

/** Forward slashes, relative to the project when inside it */
export const showPath = (project: Project, path: string): string => {
  const normal = path.replaceAll("\\", "/");
  const inside = relative(project.root, normal).replaceAll("\\", "/");
  return inside && !inside.startsWith("..") && !/^[a-z]:/i.test(inside) ? inside : normal;
};

/** A game path (Interface/AddOns/<Addon>/x.lua) as the file on disk: the project's addon, else the AddOns folder's */
export const addonFile = (project: Project, addonsRoot: string, path: string): string => {
  const match = /^Interface[/\\]AddOns[/\\]([^/\\]+)[/\\](.*)$/i.exec(path);
  if (!match) return path;
  const [, name = "", rest = ""] = match;
  const own = project.addons.find((addon) => addon.name.toLowerCase() === name.toLowerCase());
  return join(own ? own.dir : join(addonsRoot, name), rest);
};

/** A failed check: "text\n  at file:line" */
export const checkFailure = (project: Project, text: string): Failure => {
  const at = /\n {2}at (.+):(\d+)\s*$/.exec(text);
  if (!at) return { kind: "check", message: text };
  return {
    kind: "check",
    message: text.slice(0, at.index),
    file: showPath(project, at[1] ?? ""),
    line: Number(at[2]),
  };
};

/** The frames of a traceback worth reading: the addons' and the scenario's, not the simulator's or the game's own */
const trimTraceback = (stack: string): string =>
  stack
    .split("\n")
    .map((line) => line.trim())
    .filter(
      (line) =>
        line &&
        !/^\[C\]|lua[/\\](?!vendor)[\w]+\.lua:|^stack traceback|Interface[/\\]AddOns[/\\]Blizzard_|\(tail call\)/.test(
          line,
        ),
    )
    .slice(0, 8)
    .join("\n");

/** A Lua error an addon raised: where its message says it happened, as a file on disk */
export const luaFailure = (project: Project, addonsRoot: string, error: LuaError): Failure => {
  const at = /^(?:\[string "[^"]*"\]|([^:\n]+?\.(?:lua|xml))):(\d+): /.exec(error.message);
  const failure: Failure = {
    kind: "lua",
    message: error.count > 1 ? `${error.message} (${error.count}x)` : error.message,
  };
  if (at?.[1]) {
    failure.file = showPath(project, addonFile(project, addonsRoot, at[1]));
    failure.line = Number(at[2]);
  }
  const traceback = trimTraceback(error.stack);
  if (traceback) failure.traceback = traceback;
  return failure;
};

/** One line a reader goes to: "file:line: message" */
export const failureLine = (failure: Failure): string => {
  const where = failure.file ? `${failure.file}${failure.line ? `:${failure.line}` : ""}: ` : "";
  return `${where}${failure.kind === "lua" ? "Lua error: " : ""}${failure.message}`;
};

/** A value as a Lua literal (strings quoted, tables as constructors): how the SDK passes arguments to steps */
export const toLua = (value: unknown): string => {
  if (value === null || value === undefined) return "nil";
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : "nil";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "string") {
    return `"${value.replace(/[\\"\n\r\0]/g, (character) => ({ "\n": "\\n", "\r": "\\r", "\0": "\\0" })[character] ?? `\\${character}`)}"`;
  }
  if (Array.isArray(value)) return `{ ${value.map(toLua).join(", ")} }`;
  if (typeof value === "object") {
    const fields = Object.entries(value as Record<string, unknown>)
      .filter(([, item]) => item !== undefined)
      .map(([key, item]) => `${/^[A-Za-z_]\w*$/.test(key) ? key : `[${toLua(key)}]`} = ${toLua(item)}`);
    return `{ ${fields.join(", ")} }`;
  }
  return "nil";
};
