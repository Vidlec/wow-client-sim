// Which builds of the client there are, for the settings to offer a newer one: what Blizzard's patch server says
// each region runs (the newest there is), what wago.tools has (the game's tables come from it: only those can be
// used), and which build the interface source is at, the one in use and the newest on its branch. Asked when the
// settings open, and kept for a while.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { ClientBuilds } from "../shared/setup.ts";
import { USER_AGENT, WAGO_URL } from "./assets/download.ts";
import type { Flavour } from "./flavours/types.ts";

const PATCH_SERVER = "http://us.patch.battle.net:1119";
const TIMEOUT_MS = 10_000;
const KEEP_MS = 10 * 60 * 1000;
/** wago.tools' builds offered, newest first */
const MAX_WAGO_BUILDS = 8;

const fetchText = async (url: string): Promise<string> => {
  const response = await fetch(url, { headers: { "User-Agent": USER_AGENT }, signal: AbortSignal.timeout(TIMEOUT_MS) });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.text();
};

const messageOf = (error: unknown): string => (error instanceof Error ? error.message : String(error));

/** "1.60.1.71091" after "1.60.1.71037": by each number in turn */
export const compareBuilds = (first: string, second: string): number => {
  const a = first.split(".").map(Number);
  const b = second.split(".").map(Number);
  for (let index = 0; index < Math.max(a.length, b.length); index++) {
    const difference = (a[index] ?? 0) - (b[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
};

/** The regions' builds from Blizzard's patch server ("Region!STRING:0|...|VersionsName!String:0|..." rows) */
export const readPatchVersions = (text: string): { region: string; build: string }[] => {
  const lines = text.split("\n").filter((line) => line.trim() !== "" && !line.startsWith("##"));
  const names = (lines[0] ?? "").split("|").map((field) => field.split("!")[0] ?? "");
  const regionAt = names.indexOf("Region");
  const buildAt = names.indexOf("VersionsName");
  if (regionAt < 0 || buildAt < 0) return [];
  return lines.slice(1).flatMap((line) => {
    const fields = line.split("|");
    const region = fields[regionAt] ?? "";
    const build = fields[buildAt] ?? "";
    return region && build ? [{ region, build }] : [];
  });
};

/** The build a checkout of the interface source says it is at (its version.txt, beside its Interface folder) */
const readInterfaceBuild = (interfaceRoot: string | undefined): string | null => {
  if (!interfaceRoot) return null;
  try {
    return readFileSync(join(dirname(interfaceRoot), "version.txt"), "utf8").trim() || null;
  } catch {
    return null;
  }
};

let kept: { at: number; key: string; builds: Omit<ClientBuilds, "current" | "interfaceInUse"> } | null = null;

export const readClientBuilds = async (
  flavour: Flavour,
  current: string,
  interfaceRoot: string | undefined,
): Promise<ClientBuilds> => {
  const key = flavour.id;
  if (!kept || kept.key !== key || Date.now() - kept.at > KEEP_MS) {
    const problems: string[] = [];
    const [blizzard, wago, interfaceLatest] = await Promise.all([
      fetchText(`${PATCH_SERVER}/${flavour.product}/versions`)
        .then(readPatchVersions)
        .catch((error: unknown) => {
          problems.push(`Blizzard's patch server: ${messageOf(error)}`);
          return [];
        }),
      fetchText(`${WAGO_URL}/api/builds`)
        .then((text) => {
          const all = JSON.parse(text) as Record<string, { version?: string }[]>;
          const versions = (all[flavour.product] ?? []).flatMap((entry) => (entry.version ? [entry.version] : []));
          return [...new Set(versions)].sort((a, b) => compareBuilds(b, a)).slice(0, MAX_WAGO_BUILDS);
        })
        .catch((error: unknown) => {
          problems.push(`wago.tools: ${messageOf(error)}`);
          return [];
        }),
      fetchText(
        `https://raw.githubusercontent.com/${flavour.interfaceSource.repository}/${flavour.interfaceSource.branch}/version.txt`,
      )
        .then((text) => text.trim() || null)
        .catch((error: unknown) => {
          problems.push(`the interface source on GitHub: ${messageOf(error)}`);
          return null;
        }),
    ]);
    kept = {
      at: Date.now(),
      key,
      builds: { flavourBuild: flavour.wagoBuild, blizzard, wago, interfaceLatest, problems },
    };
  }
  return { ...kept.builds, current, interfaceInUse: readInterfaceBuild(interfaceRoot) };
};
