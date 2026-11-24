// Where a project's daemon is (daemon.ts): its file, cache/sdk/daemons/<hash of the project's folder>.json, with its
// port and token. Read by every command that talks to it, so kept free of the simulator's own code.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { CACHE_DIR, SOURCE_ROOT } from "../server/paths.ts";
import type { DaemonStatus } from "./types.ts";

export type DaemonFile = {
  root: string;
  port: number;
  pid: number;
  token: string;
  startedAt: string;
  /** When the simulator's TypeScript last changed as the daemon started (codeStamp) */
  codeStamp: number;
};

/** The newest write time of the simulator's TypeScript (not the page's): a daemon older than it runs old code, and
 * is started afresh. Some 5 ms */
export const codeStamp = (): number => {
  let newest = 0;
  const walk = (folder: string): void => {
    for (const entry of readdirSync(folder, { withFileTypes: true })) {
      if (entry.isDirectory()) {
        if (entry.name !== "ui") walk(join(folder, entry.name));
      } else if (entry.name.endsWith(".ts")) {
        newest = Math.max(newest, statSync(join(folder, entry.name)).mtimeMs);
      }
    }
  };
  walk(join(SOURCE_ROOT, "src"));
  return newest;
};

export const DAEMONS_DIR = join(CACHE_DIR, "sdk", "daemons");

const normalRoot = (root: string): string => {
  const forward = root.replaceAll("\\", "/").replace(/\/+$/, "");
  return process.platform === "win32" ? forward.toLowerCase() : forward;
};

export const daemonFilePath = (root: string): string =>
  join(DAEMONS_DIR, `${Bun.hash(normalRoot(root)).toString(16)}.json`);

export const readDaemonFile = (root: string): DaemonFile | null => {
  try {
    const file = JSON.parse(readFileSync(daemonFilePath(root), "utf8")) as DaemonFile;
    return normalRoot(file.root) === normalRoot(root) ? file : null;
  } catch {
    return null;
  }
};

/** Whether the daemon of a file answers (a file left by one that ended does not) */
export const pingDaemon = async (file: DaemonFile): Promise<DaemonStatus | null> => {
  try {
    const response = await fetch(`http://127.0.0.1:${file.port}/status`, {
      headers: { "X-AddonSim-Token": file.token },
      signal: AbortSignal.timeout(1500),
    });
    if (!response.ok) return null;
    const status = (await response.json()) as DaemonStatus;
    return normalRoot(status.root) === normalRoot(file.root) ? status : null;
  } catch {
    return null;
  }
};
