// The executable carries the simulator's Lua sources inside it (bun build's compile assets: lua/**); LuaJIT reads
// files from disk, so they are unpacked into the data folder's lua/ on the first run and whenever they differ from
// the ones unpacked before (a new version of the app). From a source checkout nothing is done: lua/ is right there.
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { APP_VERSION, IS_STANDALONE, LUA_DIR } from "./paths.ts";

const STAMP_FILE = ".bundle";

type Embedded = { path: string; blob: Blob };

/** The embedded files under lua/, by their path inside it */
const embeddedLuaFiles = (): Embedded[] =>
  Bun.embeddedFiles
    .map((blob) => ({ path: (blob as Blob & { name: string }).name.replaceAll("\\", "/"), blob }))
    .filter(({ path }) => path.startsWith("lua/"))
    .map(({ path, blob }) => ({ path: path.slice("lua/".length), blob }));

/** Unpacks the Lua sources when the ones on disk are not these; the number of files written (0: they were) */
export const unpackLua = async (): Promise<number> => {
  if (!IS_STANDALONE) return 0;
  const files = embeddedLuaFiles();
  if (files.length === 0) {
    throw new Error("this build of AddonSim carries no Lua sources (build it with bun run build)");
  }
  const contents = await Promise.all(files.map(async ({ blob }) => new Uint8Array(await blob.arrayBuffer())));
  let hash = 0n;
  files.forEach(({ path }, index) => {
    hash = Bun.hash.wyhash(contents[index] ?? new Uint8Array(0), Bun.hash.wyhash(path, hash));
  });
  const stamp = `${APP_VERSION} ${hash.toString(16)}`;
  const stampPath = join(LUA_DIR, STAMP_FILE);
  if (existsSync(stampPath) && readFileSync(stampPath, "utf8") === stamp) return 0;
  // Written beside and moved over the old folder, so a LuaJIT never reads half of one version and half of another
  const unpacking = `${LUA_DIR}.unpacking`;
  rmSync(unpacking, { recursive: true, force: true });
  files.forEach(({ path }, index) => {
    const target = join(unpacking, path);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, contents[index] ?? new Uint8Array(0));
  });
  writeFileSync(join(unpacking, STAMP_FILE), stamp);
  rmSync(LUA_DIR, { recursive: true, force: true });
  renameSync(unpacking, LUA_DIR);
  return files.length;
};
