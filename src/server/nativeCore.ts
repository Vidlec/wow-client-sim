// AddonSim's native core (native/, Rust): the scene's walk and layout, and the stream's item store. The simulator does
// not run without it (lua/native.lua), so it is built here, with cargo, before a simulator starts when it is missing or
// older than its sources. Without cargo a build already there is used as it is (the Docker image has one and no
// cargo); with none at all, the start is refused with how to get one.
import { existsSync, readdirSync, statSync, utimesSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { ROOT } from "./paths.ts";

const NATIVE_DIR = join(ROOT, "native");
const MANIFEST = join(NATIVE_DIR, "Cargo.toml");

const libraryName = (): string => {
  if (process.platform === "win32") return "addonsim_native.dll";
  if (process.platform === "darwin") return "libaddonsim_native.dylib";
  return "libaddonsim_native.so";
};

/** Where cargo puts the built library (lua/native.lua loads a copy of it) */
export const nativeLibraryPath = (): string => join(NATIVE_DIR, "target", "release", libraryName());

const INSTALL_RUST = "Install Rust (https://rustup.rs), then run `bun run native` or start AddonSim again";

/** cargo on the PATH, else where rustup puts it */
const findCargo = (): string | null => {
  const found = Bun.which("cargo");
  if (found) return found;
  const inHome = join(homedir(), ".cargo", "bin", process.platform === "win32" ? "cargo.exe" : "cargo");
  return existsSync(inHome) ? inHome : null;
};

const getModifiedMs = (path: string): number => (existsSync(path) ? statSync(path).mtimeMs : 0);

/** When the native core's sources last changed: its Rust files and Cargo's two files */
const getNewestSourceMs = (): number => {
  let newest = Math.max(getModifiedMs(MANIFEST), getModifiedMs(join(NATIVE_DIR, "Cargo.lock")));
  const sources = join(NATIVE_DIR, "src");
  if (!existsSync(sources)) return newest;
  for (const entry of readdirSync(sources, { recursive: true, withFileTypes: true })) {
    if (entry.isFile()) newest = Math.max(newest, getModifiedMs(join(entry.parentPath, entry.name)));
  }
  return newest;
};

const isOutOfDate = (library: string): boolean => !existsSync(library) || getModifiedMs(library) < getNewestSourceMs();

const build = async (library: string): Promise<string | null> => {
  const cargo = findCargo();
  if (!cargo) return existsSync(library) ? null : `AddonSim's native core is not built. ${INSTALL_RUST}.`;
  process.stderr.write("Building AddonSim's native core (Rust)...\n");
  // (cargo's progress goes to stderr; stdout stays clean for the CLI's --json and the MCP server)
  const child = Bun.spawn([cargo, "build", "--release", "--manifest-path", MANIFEST], {
    cwd: ROOT,
    stdin: "ignore",
    stdout: "ignore",
    stderr: "inherit",
    windowsHide: true,
  });
  const code = await child.exited;
  if (code !== 0) return `AddonSim's native core did not build (cargo exited with ${code}): see cargo's output above.`;
  if (!existsSync(library)) return `AddonSim's native core built, but there is no ${library}.`;
  // (cargo leaves a library it had no need to build again as it was: dated now, sources touched but unchanged are
  // not built again at every start)
  const now = new Date();
  utimesSync(library, now, now);
  return null;
};

let building: Promise<string | null> | null = null;

/**
 * The native core built when it is missing or older than its sources: null when it is ready to load, else why it is
 * not (a message for the user)
 */
export const ensureNativeCore = async (): Promise<string | null> => {
  if (building) return building;
  const library = nativeLibraryPath();
  if (!isOutOfDate(library)) return null;
  building = build(library).finally(() => {
    building = null;
  });
  return building;
};

/** ensureNativeCore, for callers that cannot go on without it: an error with the message */
export const requireNativeCore = async (): Promise<void> => {
  const problem = await ensureNativeCore();
  if (problem) throw new Error(problem);
};
