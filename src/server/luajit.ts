// LuaJIT, which runs the simulator: the one set in the settings, else the one on the PATH, else one in the places
// its installers put it. Never downloaded: when there is none, the setup says how to install it.
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { LuajitInfo } from "../shared/setup.ts";

const VERSION_TIMEOUT_MS = 5000;

const knownPlaces = (): string[] => {
  const home = homedir();
  if (process.platform === "win32") {
    const local = process.env.LOCALAPPDATA ?? join(home, "AppData", "Local");
    return [
      join(local, "Programs", "LuaJIT", "bin", "luajit.exe"), // winget install DEVCOM.LuaJIT
      join(home, "scoop", "shims", "luajit.exe"),
      "C:\\ProgramData\\chocolatey\\bin\\luajit.exe",
      "C:\\Program Files\\LuaJIT\\bin\\luajit.exe",
      "C:\\LuaJIT\\luajit.exe",
      "C:\\msys64\\ucrt64\\bin\\luajit.exe",
      "C:\\msys64\\mingw64\\bin\\luajit.exe",
    ];
  }
  return [
    "/opt/homebrew/bin/luajit",
    "/usr/local/bin/luajit",
    "/opt/local/bin/luajit",
    "/usr/bin/luajit",
    join(home, ".local", "bin", "luajit"),
  ];
};

export const installInstructions = (): string => {
  if (process.platform === "win32") {
    return "Install LuaJIT with `winget install DEVCOM.LuaJIT` (or `scoop install luajit`), then press Check again.";
  }
  if (process.platform === "darwin") return "Install LuaJIT with `brew install luajit`, then press Check again.";
  return "Install LuaJIT with your system's packages (`sudo apt install luajit`, `sudo dnf install luajit`), then press Check again.";
};

/** The executable to run: the setting's, the PATH's, a known place's; null when there is none */
export const findLuajit = (setting: string): string | null => {
  if (setting) return existsSync(setting) ? setting : null;
  return Bun.which("luajit") ?? knownPlaces().find((path) => existsSync(path)) ?? null;
};

const versions = new Map<string, string | null>();

/** "LuaJIT 2.1.1720049189", asked once for each executable; null when it does not run */
export const readLuajitVersion = (path: string): string | null => {
  const known = versions.get(path);
  if (known !== undefined) return known;
  let version: string | null = null;
  try {
    const result = Bun.spawnSync([path, "-v"], {
      stdout: "pipe",
      stderr: "pipe",
      timeout: VERSION_TIMEOUT_MS,
      windowsHide: true,
    });
    const text = `${result.stdout.toString()}${result.stderr.toString()}`;
    version =
      result.exitCode === 0 ? (/^(LuaJIT \S+)/m.exec(text)?.[1] ?? text.trim().split(/\r?\n/)[0] ?? null) : null;
  } catch {
    version = null;
  }
  versions.set(path, version);
  return version;
};

export const describeLuajit = (setting: string): LuajitInfo => {
  const path = findLuajit(setting);
  const version = path ? readLuajitVersion(path) : null;
  if (path && version) return { path, version };
  if (path) return { path, instructions: `${path} does not run as LuaJIT. ${installInstructions()}` };
  if (setting) return { path: null, instructions: `There is no ${setting}. ${installInstructions()}` };
  return { path: null, instructions: installInstructions() };
};

/** Forget what was asked, so a LuaJIT installed since is seen (the setup's Check) */
export const forgetLuajitVersions = (): void => versions.clear();
