// Gallery screenshots of a project's addon, from the simulator: runs the project's scenarios in <scenarios>/shots/
// (or those named), each of which saves its scenes and prints what to crop ("CROP<tab>name<tab>x,y,w,h", screen
// points from the top left), then has headless Chrome draw each scene on the sim's shot page and save it as a PNG.
//
//   bun run src/cli/shots.ts [output folder] [scenario ...]     (the output: the project's "gallery" by default)
//   ... --project <dir>                                          another project than the working folder's
//
// Needs the sim's server running and serving the same project (it draws the scenes from that project's scenarios
// folder): on port 8765, or ADDONSIM_PORT. The picture is twice the screen's size, as on a sharp display; behind the
// windows goes the zone's loading screen, as the world would be.
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Project } from "../project/config.ts";
import { expandHome } from "../project/load.ts";
import { selectProject, takeProjectFlag } from "../project/select.ts";
import { playScenarios } from "./suite.ts";

const CHROME = [
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
].find((path) => existsSync(path));
const BACKDROP = "Interface\\Glues\\LoadingScreens\\LoadScreenKalimdor";
const PORT = Number(process.env.ADDONSIM_PORT) || 8765;
const SCALE = 2;
const CHROME_TIMEOUT_MS = 120_000;

const say = (text: string): void => {
  process.stdout.write(`${text}\n`);
};

/** A shot scenario played by the runner: its whole output */
const playScenario = async (project: Project, name: string): Promise<string> => {
  const result = await playScenarios({ project, scenarios: [join(project.scenariosDir, "shots", `${name}.lua`)] });
  return (result.runs[0]?.output ?? "").replace(/\r\n/g, "\n");
};

/** Chrome draws one scene into target; false when it took too long and was ended */
const drawScene = async (
  chrome: string,
  target: string,
  width: number,
  height: number,
  query: string,
): Promise<boolean> => {
  // A fresh profile for each picture: a Chrome left behind by an earlier run holds a shared one, and the next waits
  // on it for good
  const profile = mkdtempSync(join(tmpdir(), "addonsim-shot-"));
  try {
    const child = Bun.spawn(
      [
        chrome,
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        "--no-first-run",
        `--user-data-dir=${profile}`,
        `--window-size=${width},${height}`,
        `--force-device-scale-factor=${SCALE}`,
        "--virtual-time-budget=15000",
        `--screenshot=${target}`,
        `http://localhost:${PORT}/?${query}`,
      ],
      { stdin: "ignore", stdout: "ignore", stderr: "ignore", windowsHide: true },
    );
    let isOverTime = false;
    const timer = setTimeout(() => {
      isOverTime = true;
      child.kill();
    }, CHROME_TIMEOUT_MS);
    await child.exited;
    clearTimeout(timer);
    return !isOverTime;
  } finally {
    rmSync(profile, { recursive: true, force: true, maxRetries: 3 });
  }
};

const main = async (): Promise<number> => {
  if (!CHROME) {
    say("shots: no Chrome or Edge found to draw the scenes with");
    return 1;
  }
  const { projectDir, rest: args } = takeProjectFlag(process.argv.slice(2));
  const project = await selectProject(projectDir);
  const outputArg = args[0] ?? project.galleryDir;
  if (!outputArg) {
    say(`shots: name the output folder, or set "gallery" in the project's addonsim.config.ts (${project.root})`);
    return 1;
  }
  const output = expandHome(outputArg);
  const named = args.slice(1);
  const shotsDir = join(project.scenariosDir, "shots");
  if (named.length === 0 && !existsSync(shotsDir)) {
    say(`shots: the project has no shot scenarios (${shotsDir})`);
    return 1;
  }
  const names =
    named.length > 0
      ? named
      : readdirSync(shotsDir)
          .filter((name) => name.endsWith(".lua"))
          .map((name) => name.slice(0, -4))
          .sort();
  mkdirSync(output, { recursive: true });

  for (const name of names) {
    const stdout = await playScenario(project, name);
    const lines = stdout.split("\n");
    const crops = lines.filter((line) => line.startsWith("CROP\t")).map((line) => line.split("\t"));
    if (!stdout.includes("PASSED") || crops.length === 0) {
      say(`${name}: the scenario failed`);
      const problems = lines.filter((line) => line.includes("FAIL") || line.includes("rror") || line.includes("✗"));
      say(problems.join("\n").slice(-2000));
      continue;
    }
    for (const [, shot = "", box = ""] of crops) {
      // x,y,w,h: the page crops to the box; Chrome's window is its size
      const [, , width = 0, height = 0] = box.split(",").map((value) => Number.parseInt(value, 10));
      const query = new URLSearchParams({
        shot: `.last-run/${name}/${shot}`,
        backdrop: BACKDROP,
        crop: box,
      }).toString();
      const target = join(output, `screenshot-${shot}.png`);
      if (!(await drawScene(CHROME, target, width, height, query))) say(`${shot}: Chrome took too long, skipped`);
      say(existsSync(target) ? `${shot}: ${target} (${width * SCALE}x${height * SCALE})` : `${shot}: no picture`);
    }
  }
  return 0;
};

process.exitCode = await main();
