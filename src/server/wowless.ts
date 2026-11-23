// The client's API as wowless knows it (github.com/wowless/wowless, MIT): its data for one game product, such as
// WoW: Forever ("wowf"), fetched once into cache/wowless/<product>/ as JSON for the simulator to read as it starts
// (src/cli/wowless.ts runs it).
//
// What the simulator takes from it (lua/wowless.lua):
//   cvars       every console variable's default
//   globals     the client's constants (NUM_LE_LFG_CATEGORYS, Constants.*)
//   apis        each function's results: which may return nothing, the value a stand-in should give
//   config      the namespaces only the game's own secure addons see (C_StoreSecure...)
//   uiobjects, structures, events, xml   kept for what comes next (widget methods, XML attributes)
//
// wowless's files are YAML of a simple kind (block mappings and lists, quoted or plain scalars), and a reader for
// exactly that kind is here. The JSON is written as the Python version wrote it, byte for byte: mappings keep their
// order (a Map, since an object would move numeric keys first), and floats print as Python prints them ("1.0").
import { mkdir } from "node:fs/promises";
import { join } from "node:path";

export const FILES = ["build", "cvars", "globals", "apis", "config", "uiobjects", "structures", "events", "xml"];
export const REPOSITORY = "wowless/wowless";

/** A YAML float, kept apart from integers so it prints as Python prints a float */
export class PyFloat {
  constructor(readonly value: number) {}
}

export type YamlValue = null | boolean | number | bigint | PyFloat | string | YamlValue[] | YamlMap;
export type YamlMap = Map<string, YamlValue>;

const SIMPLE_ESCAPES: Readonly<Record<string, string>> = {
  n: "\n",
  t: "\t",
  r: "\r",
  "0": "\0",
  e: "\x1b",
  "\\": "\\",
  '"': '"',
  "/": "/",
  " ": " ",
};

export const parseScalar = (raw: string): YamlValue => {
  const text = raw.trim();
  if (text === "" || text === "~" || text === "null") return null;
  if (text.length >= 2 && text.startsWith("'") && text.endsWith("'")) return text.slice(1, -1).replaceAll("''", "'");
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    // YAML's escapes are JSON's plus \xNN, \e, \0 and the like
    return text.slice(1, -1).replace(/\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|.)/g, (_, code: string) => {
      const simple = SIMPLE_ESCAPES[code];
      if (simple !== undefined) return simple;
      if (code.length > 1 && "xuU".includes(code[0] ?? ""))
        return String.fromCodePoint(Number.parseInt(code.slice(1), 16));
      return code;
    });
  }
  if (text === "true" || text === "false") return text === "true";
  if (/^-?\d+$/.test(text)) {
    const value = Number(text);
    return Number.isSafeInteger(value) ? value : BigInt(text);
  }
  if (/^-?(\d+\.\d*|\.\d+|\d+)([eE][-+]?\d+)?$/.test(text)) return new PyFloat(Number(text));
  return text;
};

/** "name: value" -> ["name", "value"]; null when the line is not a key */
export const splitKey = (text: string): [string, string] | null => {
  const match = /^([^'"\s:][^:]*?|'[^']*'|"[^"]*"):(?:\s+(.*))?$/.exec(text);
  if (!match) return null;
  let key = match[1] ?? "";
  if (key.startsWith("'") || key.startsWith('"')) key = String(parseScalar(key));
  return [key, match[2] ?? ""];
};

// The line breaks of Python's str.splitlines()
// biome-ignore lint/suspicious/noControlCharactersInRegex: these control characters are line breaks to Python
const LINE_BREAK = /\r\n|[\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029]/;

export const parseYaml = (content: string): YamlValue => {
  const lines: { indent: number; text: string }[] = [];
  for (const raw of content.split(LINE_BREAK)) {
    const text = raw.trim();
    if (!text || text.startsWith("#")) continue;
    lines.push({ indent: raw.length - raw.replace(/^ +/, "").length, text });
  }
  let position = 0;
  const isItem = (text: string): boolean => text.startsWith("- ") || text === "-";
  const at = (index: number): { indent: number; text: string } => lines[index] ?? { indent: -1, text: "" };

  const parseBlock = (): YamlValue => {
    if (position >= lines.length) return null;
    const line = at(position);
    return isItem(line.text) ? parseList(line.indent) : parseMap(line.indent);
  };

  const valueAfter = (value: string, indent: number): YamlValue => {
    if (value !== "") return parseScalar(value);
    // Nested below, deeper (a list may sit at the key's own indent)
    const next = at(position);
    if (position < lines.length && (next.indent > indent || (next.indent === indent && next.text.startsWith("- ")))) {
      return parseBlock();
    }
    return null;
  };

  const parseMap = (indent: number): YamlMap => {
    const result: YamlMap = new Map();
    while (position < lines.length && at(position).indent === indent && !at(position).text.startsWith("- ")) {
      const pair = splitKey(at(position).text);
      if (pair === null) throw new Error(`line not understood: ${JSON.stringify(at(position).text)}`);
      position++;
      result.set(pair[0], valueAfter(pair[1], indent));
    }
    return result;
  };

  const parseList = (indent: number): YamlValue[] => {
    const result: YamlValue[] = [];
    while (position < lines.length && at(position).indent === indent && isItem(at(position).text)) {
      const line = at(position).text;
      const text = line === "-" ? "" : line.slice(2);
      position++;
      const pair = text ? splitKey(text) : null;
      if (pair !== null) {
        // "- key: value" opens a mapping whose further keys sit two deeper
        const itemIndent = indent + 2;
        const item: YamlMap = new Map([[pair[0], valueAfter(pair[1], itemIndent)]]);
        if (position < lines.length && at(position).indent === itemIndent && !at(position).text.startsWith("- ")) {
          for (const [key, value] of parseMap(itemIndent)) item.set(key, value);
        }
        result.push(item);
      } else if (text) {
        result.push(parseScalar(text));
      } else {
        result.push(position < lines.length && at(position).indent > indent ? parseBlock() : null);
      }
    }
    return result;
  };

  const value = parseBlock();
  if (position !== lines.length) throw new Error(`stopped at line ${position}: ${JSON.stringify(at(position))}`);
  return value;
};

/**
 * An empty value in a mapping says the key is there ("C_StoreSecure:" in a list of names), and the simulator's JSON
 * reader drops a null: true instead. An empty stub is a stand-in that gives nil: "stubnil".
 */
export const keepEmpty = (value: YamlValue): YamlValue => {
  if (value instanceof Map) {
    const result: YamlMap = new Map();
    for (const [key, item] of value) {
      if (item === null) result.set(key === "stub" ? "stubnil" : key, true);
      else result.set(key, keepEmpty(item));
    }
    return result;
  }
  if (Array.isArray(value)) return value.map(keepEmpty);
  return value;
};

/** A float as Python's repr() writes it: shortest round-trip digits, fixed between 1e-4 and 1e16, always a "." */
export const formatPythonFloat = (value: number): string => {
  if (Number.isNaN(value)) return "NaN";
  if (!Number.isFinite(value)) return value > 0 ? "Infinity" : "-Infinity";
  if (value === 0) return Object.is(value, -0) ? "-0.0" : "0.0";
  const sign = value < 0 ? "-" : "";
  const [mantissa = "", exponentText = "0"] = Math.abs(value).toExponential().split("e");
  const digits = mantissa.replace(".", "");
  const exponent = Number(exponentText);
  if (exponent >= -4 && exponent < 16) {
    if (exponent < 0) return `${sign}0.${"0".repeat(-exponent - 1)}${digits}`;
    const whole = digits.slice(0, exponent + 1).padEnd(exponent + 1, "0");
    return `${sign}${whole}.${digits.slice(exponent + 1) || "0"}`;
  }
  const fraction = digits.length > 1 ? `.${digits.slice(1)}` : "";
  const exponentSign = exponent < 0 ? "-" : "+";
  return `${sign}${digits[0]}${fraction}e${exponentSign}${String(Math.abs(exponent)).padStart(2, "0")}`;
};

/** JSON as Python's json.dumps(value, ensure_ascii=False, separators=(",", ":")) writes it */
export const toPythonJson = (value: YamlValue): string => {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number" || typeof value === "bigint") return String(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (value instanceof PyFloat) return formatPythonFloat(value.value);
  if (Array.isArray(value)) return `[${value.map(toPythonJson).join(",")}]`;
  const members: string[] = [];
  for (const [key, item] of value) members.push(`${JSON.stringify(key)}:${toPythonJson(item)}`);
  return `{${members.join(",")}}`;
};

const fetchText = async (url: string): Promise<string> => {
  const response = await fetch(url, { headers: { "User-Agent": "AddonSim" }, signal: AbortSignal.timeout(60_000) });
  if (!response.ok) throw new Error(`HTTP Error ${response.status}: ${response.statusText} (${url})`);
  return response.text();
};

/** What the Python printed for a file: its number of entries, or the value as str() shows it */
const describeSize = (data: YamlValue): string => {
  if (data instanceof Map) return String(data.size);
  if (Array.isArray(data)) return String(data.length);
  if (data === null) return "None";
  if (typeof data === "boolean") return data ? "True" : "False";
  if (data instanceof PyFloat) return formatPythonFloat(data.value);
  return String(data);
};

export type WowlessResult = { commit: string; product: string; folder: string };

/**
 * Fetches wowless's data for product at ref (a branch, tag or commit) into <cacheDir>/wowless/<product>/: one JSON
 * file a YAML file, and source.json naming the exact commit. log receives a line a file.
 */
export const updateWowless = async (
  cacheDir: string,
  product: string,
  ref: string,
  log: (line: string) => void = () => undefined,
): Promise<WowlessResult> => {
  // The exact commit, so what was read can be told and fetched again
  const commitInfo: unknown = JSON.parse(await fetchText(`https://api.github.com/repos/${REPOSITORY}/commits/${ref}`));
  const commit =
    typeof commitInfo === "object" && commitInfo !== null && "sha" in commitInfo && typeof commitInfo.sha === "string"
      ? commitInfo.sha
      : null;
  if (!commit) throw new Error(`no commit for ${REPOSITORY}@${ref}`);
  const folder = join(cacheDir, "wowless", product);
  await mkdir(folder, { recursive: true });
  for (const name of FILES) {
    const url = `https://raw.githubusercontent.com/${REPOSITORY}/${commit}/data/products/${product}/${name}.yaml`;
    const data = keepEmpty(parseYaml(await fetchText(url)));
    await Bun.write(join(folder, `${name}.json`), toPythonJson(data));
    log(`${name}: ${describeSize(data)}`);
  }
  // json.dump's default separators here: ", " and ": "
  const source = { repository: REPOSITORY, commit, product, license: "MIT" };
  await Bun.write(
    join(folder, "source.json"),
    `{${Object.entries(source)
      .map(([key, value]) => `${JSON.stringify(key)}: ${JSON.stringify(value)}`)
      .join(", ")}}`,
  );
  log(`wowless ${commit.slice(0, 10)}, product ${product} -> ${folder}`);
  return { commit, product, folder };
};
