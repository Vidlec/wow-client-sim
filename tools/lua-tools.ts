// The Lua tools: StyLua formats (stylua.toml), luacheck lints (.luacheckrc). Run from a project's folder:
//   bun tools/lua-tools.ts format [folders...]   format the Lua in place
//   bun tools/lua-tools.ts check [folders...]    is it formatted, and does luacheck pass (exit 1 if not)
//   bun tools/lua-tools.ts install               fetch the pinned tools into tools/bin (Windows; elsewhere, says how)
// The tools are looked for in tools/bin beside this script, then on PATH. Another project (WowAddons) runs this same
// script through its link to AddonSim (node_modules/addonsim/tools/lua-tools.ts), naming its own folders.
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const BIN = join(import.meta.dir, "bin");
const IS_WINDOWS = process.platform === "win32";

// The pinned releases, with the SHA-256 of each file as downloaded and checked when pinned
const STYLUA = {
  version: "v2.6.0",
  url: "https://github.com/JohnnyMorganz/StyLua/releases/download/v2.6.0/stylua-windows-x86_64.zip",
  sha256: "fd13b4014e3b779c244bbc03f2c282e357f15bc526de6a6fa5ecbc447538313c",
};
const LUACHECK = {
  version: "v1.2.0",
  url: "https://github.com/lunarmodules/luacheck/releases/download/v1.2.0/luacheck.exe",
  sha256: "0f1c69c4d09f1ebb4d8df14c215e4553e2e639bd4cb7bf3c639b0daa6198317b",
};

const findTool = (name: string): string | null => {
  const local = join(BIN, IS_WINDOWS ? `${name}.exe` : name);
  if (existsSync(local)) return local;
  return Bun.which(name);
};

const run = (command: string[]): number => {
  const result = Bun.spawnSync(command, { stdout: "inherit", stderr: "inherit" });
  return result.exitCode ?? 1;
};

const missing = (name: string): never => {
  console.error(`${name} is not installed: bun tools/lua-tools.ts install (in AddonSim)`);
  process.exit(1);
};

const download = async (url: string, sha256: string): Promise<Uint8Array> => {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  const digest = createHash("sha256").update(bytes).digest("hex");
  if (digest !== sha256) throw new Error(`${url}: checksum ${digest}, expected ${sha256}`);
  return bytes;
};

const install = async (): Promise<void> => {
  if (!IS_WINDOWS) {
    console.log("On macOS: brew install stylua luacheck");
    console.log("On Linux: cargo install stylua (or its release binary), and luarocks install luacheck");
    return;
  }
  mkdirSync(BIN, { recursive: true });
  const zip = await download(STYLUA.url, STYLUA.sha256);
  const zipPath = join(BIN, "stylua.zip");
  writeFileSync(zipPath, zip);
  // Windows' own tar reads zip files (by its full path: Git's GNU tar, first on Git Bash's PATH, does not, and takes
  // "C:" for a remote host)
  const windowsTar = join(process.env.SystemRoot ?? "C:\\Windows", "System32", "tar.exe");
  if (run([windowsTar, "-xf", zipPath, "-C", BIN]) !== 0) throw new Error("could not unpack StyLua");
  await Bun.file(zipPath).delete();
  writeFileSync(join(BIN, "luacheck.exe"), await download(LUACHECK.url, LUACHECK.sha256));
  console.log(`StyLua ${STYLUA.version} and luacheck ${LUACHECK.version} are in ${BIN}`);
};

const [action, ...folders] = process.argv.slice(2);
const targets = folders.length > 0 ? folders : ["."];

if (action === "install") {
  await install();
} else if (action === "format") {
  process.exit(run([findTool("stylua") ?? missing("StyLua"), ...targets]));
} else if (action === "check") {
  const formatted = run([findTool("stylua") ?? missing("StyLua"), "--check", ...targets]);
  const linted = run([findTool("luacheck") ?? missing("luacheck"), "--no-color", "--codes", ...targets]);
  process.exit(formatted === 0 && linted === 0 ? 0 : 1);
} else {
  console.error("bun tools/lua-tools.ts format|check|install [folders...]");
  process.exit(2);
}
