// Builds AddonSim into one executable: the server, the page (bundled, its Tailwind CSS built now, as Bun's own server
// builds it from the sources as it serves them) and the simulator's Lua sources (unpacked into the user's data folder
// as it first starts). Nothing else is needed to run it but LuaJIT, which the page's setup finds or says how to get.
//
//   bun run build                       dist/addonsim(.exe), for this system
//   bun run build --target=bun-linux-x64   for another (bun-windows-x64, bun-darwin-arm64, bun-darwin-x64...)
import { rmSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import type { Build } from "bun";
import tailwind from "bun-plugin-tailwind";
import { APP_VERSION, SOURCE_ROOT } from "../server/paths.ts";

const DIST = join(SOURCE_ROOT, "dist");

const targetArg = process.argv.find((arg) => arg.startsWith("--target="))?.slice("--target=".length);
const isWindows = targetArg ? targetArg.includes("windows") : process.platform === "win32";
const outfile = join(DIST, isWindows ? "addonsim.exe" : "addonsim");

// (Compile assets are named by their path from here: lua/boot.lua)
process.chdir(SOURCE_ROOT);
rmSync(outfile, { force: true });
const started = performance.now();
const result = await Bun.build({
  entrypoints: [join(SOURCE_ROOT, "src", "server", "main.ts")],
  root: SOURCE_ROOT,
  plugins: [tailwind],
  minify: true,
  sourcemap: "none",
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
  compile: {
    outfile,
    ...(targetArg ? { target: targetArg as Build.CompileTarget } : {}),
    // The simulator itself: lua/** carried inside, under its own paths (lua/boot.lua...)
    assets: ["./lua"],
    // A bunfig.toml or .env where the user starts it must not change how it runs
    autoloadBunfig: false,
    autoloadDotenv: false,
    windows: {
      title: "AddonSim",
      description: "World of Warcraft addons in the browser",
      version: APP_VERSION,
    },
  },
});
if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}
const megabytes = (statSync(outfile).size / 1024 / 1024).toFixed(0);
const seconds = ((performance.now() - started) / 1000).toFixed(1);
console.log(`Built ${relative(SOURCE_ROOT, outfile)} (${megabytes} MB) in ${seconds} s`);
