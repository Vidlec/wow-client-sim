// `addonsim docs`: the scenario API's reference, made from its LuaLS definitions (types/addonsim.lua), so the
// reference, the editor's hints and an agent's read of the API never disagree. One line a step by default; a step's
// name gives it whole.
import definitions from "../../types/addonsim.lua" with { type: "text" };

type Entry = { name: string; signature: string; description: string; params: string[]; returns: string[] };
type Section = { title: string; entries: Entry[] };

/** A LuaLS type at the start of text (a table or function type taken whole, brackets balanced), and the rest */
const splitType = (text: string): [string, string] => {
  let depth = 0;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (character === "{" || character === "(" || character === "<") depth += 1;
    else if (character === "}" || character === ")" || character === ">") depth -= 1;
    else if (character === " " && depth === 0 && text[index - 1] !== "," && text[index - 1] !== ":") {
      return [text.slice(0, index), text.slice(index + 1).trim()];
    }
  }
  return [text, ""];
};

/** The definitions read: sections ("-- ## Title"), each a list of documented functions and globals */
export const readDefinitions = (text: string = definitions): Section[] => {
  const sections: Section[] = [];
  let section: Section | null = null;
  let description: string[] = [];
  let params: { name: string; type: string; text: string }[] = [];
  let returns: string[] = [];
  let type: string | null = null;
  const reset = (): void => {
    description = [];
    params = [];
    returns = [];
    type = null;
  };
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trimEnd();
    const heading = /^-- ## (.+)$/.exec(line);
    if (heading) {
      section = { title: heading[1] ?? "", entries: [] };
      sections.push(section);
      reset();
      continue;
    }
    if (line.startsWith("---@param ")) {
      const body = line.slice("---@param ".length);
      const space = body.indexOf(" ");
      const name = space < 0 ? body : body.slice(0, space);
      const [paramType, rest] = splitType(space < 0 ? "" : body.slice(space + 1));
      params.push({ name, type: paramType, text: rest });
    } else if (line.startsWith("---@return ")) {
      returns.push(line.slice("---@return ".length));
    } else if (line.startsWith("---@type ")) {
      type = line.slice("---@type ".length);
    } else if (line.startsWith("---@")) {
      // (generic and other annotations: for the editor only)
    } else if (line.startsWith("---")) {
      description.push(line.slice(3).trim());
    } else if (section) {
      const fn = /^function (\w+)\((.*)\) end$/.exec(line);
      const global = /^(\w+) = /.exec(line);
      if (fn) {
        const signature = `${fn[1]}(${params
          .map((param) => `${param.name}${param.type.endsWith("?") ? "?" : ""}`)
          .join(", ")})`;
        section.entries.push({
          name: fn[1] ?? "",
          signature,
          description: description.join(" "),
          params: params.map((param) => `${param.name}: ${param.type}${param.text ? `  ${param.text}` : ""}`),
          returns,
        });
      } else if (global) {
        section.entries.push({
          name: global[1] ?? "",
          signature: `${global[1]}: ${type ?? "any"}`,
          description: description.join(" "),
          params: [],
          returns: [],
        });
      }
      if (fn || global || line === "") reset();
    }
  }
  return sections;
};

const firstSentence = (text: string): string => {
  const end = text.search(/\.(\s|$)/);
  return end >= 0 ? text.slice(0, end + 1) : text;
};

/** The whole reference (one line a step), or one step whole; null when there is no such step */
export const renderDocs = (name?: string): string | null => {
  const sections = readDefinitions();
  if (name) {
    for (const section of sections) {
      const entry = section.entries.find((item) => item.name.toLowerCase() === name.toLowerCase());
      if (!entry) continue;
      const lines = [entry.signature, entry.description];
      for (const param of entry.params) lines.push(`  ${param}`);
      for (const returned of entry.returns) lines.push(`  returns ${returned}`);
      return lines.filter((line) => line !== "").join("\n");
    }
    return null;
  }
  const lines = [
    "AddonSim scenario API: a scenario's globals (also in `addonsim eval`). The game's own globals are in G.",
    "Each step runs the clock 0.1 s after it; a step that cannot be done is a failed check (the run goes on).",
    "`addonsim docs <step>` gives one whole; `addonsim docs cli` the commands. Definitions: types/addonsim.lua.",
  ];
  for (const section of sections) {
    lines.push("", `## ${section.title}`);
    for (const entry of section.entries) {
      const returned = entry.returns[0] ? ` -> ${entry.returns[0].split(" ")[0]}` : "";
      lines.push(`${entry.signature}${returned}  ${firstSentence(entry.description)}`);
    }
  }
  return lines.join("\n");
};
