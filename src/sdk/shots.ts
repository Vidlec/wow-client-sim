// Pictures of a scene: the page's own renderer (src/ui/engine/picture.ts, the ?shot= page shots.ts uses too) drawing
// it in headless Chrome or Edge, which saves a PNG. The page is served here, in this process, with the game's art,
// fonts and atlases (from the cache) and the scene to draw; so a picture needs no server of the page's running.
// What it costs: Chrome's start and the page's first draw, about a second (Chrome kept running would save half of
// it; not worth its upkeep for pictures an agent takes now and then).
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import type { Project } from "../project/config.ts";
import { Assets } from "../server/assets/index.ts";
import { CACHE_DIR, type Config } from "../server/config.ts";
import page from "./shotPage/index.html";
import type { Scene, ShotOptions, ShotResult } from "./types.ts";

const CHROME_TIMEOUT_MS = 60_000;

const findChrome = (): string | null => {
  const places =
    process.platform === "win32"
      ? [
          "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
          "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
          "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
          "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
        ]
      : [
          "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
          "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
          "/usr/bin/google-chrome",
          "/usr/bin/chromium",
          "/usr/bin/chromium-browser",
        ];
  return process.env.ADDONSIM_CHROME ?? places.find((path) => existsSync(path)) ?? null;
};

const notFound = (): Response => new Response("not found", { status: 404 });
/** Bytes as a body (never in a SharedArrayBuffer here: the body types want a plain ArrayBuffer behind them) */
const bytes = (data: Uint8Array, contentType: string): Response =>
  new Response(data as Uint8Array<ArrayBuffer>, { headers: { "Content-Type": contentType } });

export class Shooter {
  readonly #art: Assets;
  readonly #scenes = new Map<string, Scene>();
  #server: ReturnType<typeof Bun.serve> | null = null;
  #nextId = 0;
  #atlasesLoaded: Promise<unknown> | null = null;

  constructor(
    readonly project: Project,
    readonly config: Config,
  ) {
    this.#art = new Assets(CACHE_DIR, { build: config.build, locale: config.locale ?? "enUS" });
  }

  /** The folder an addon's files are read from for /media: the project's own folder of it, else the AddOns folder */
  #mediaRoot(path: string): string {
    const name = /^interface[/\\]addons[/\\]([^/\\]+)/i.exec(path)?.[1]?.toLowerCase();
    const own = this.project.addons.find((addon) => addon.name.toLowerCase() === name);
    return own ? dirname(own.dir) : this.config.addonsRoot;
  }

  #serve(): ReturnType<typeof Bun.serve> {
    if (this.#server) return this.#server;
    const art = this.#art;
    const variant = this.config.atlasVariant ? this.config.atlasVariant.toLowerCase() : null;
    this.#atlasesLoaded ??= art.loadAtlases();
    this.#server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      development: false,
      routes: {
        "/": page,
        "/art": async (request) => {
          const target = new URL(request.url).searchParams.get("p") ?? "";
          const image = await art.image(/^\d+$/.test(target) ? Number(target) : target);
          return image ? bytes(image.data, image.contentType) : Response.json({ error: "unknown" }, { status: 404 });
        },
        // As the client resolves a name (the same rule as the server's /atlas)
        "/atlas": async (request) => {
          await this.#atlasesLoaded;
          const name = (new URL(request.url).searchParams.get("n") ?? "").toLowerCase();
          if (!variant) return Response.json(art.atlas(name) ?? {});
          if (name.endsWith(variant)) return Response.json({});
          return Response.json(art.atlas(`${name}${variant}`) ?? art.atlas(name) ?? {});
        },
        "/font": async (request) => {
          const font = await art.font(new URL(request.url).searchParams.get("p") ?? "");
          return font ? bytes(font, "font/ttf") : notFound();
        },
        "/media": async (request) => {
          const path = new URL(request.url).searchParams.get("p") ?? "";
          const media = await art.media(this.#mediaRoot(path), path);
          return media ? bytes(media.data, media.contentType) : notFound();
        },
        "/api/metrics": () => Response.json({ ok: true }),
        "/snapshots/*": (request) => {
          const name = decodeURIComponent(new URL(request.url).pathname.slice("/snapshots/".length));
          const scene = this.#scenes.get(name.replace(/\.scene\.json$/, ""));
          return scene ? Response.json(scene) : notFound();
        },
      },
      fetch: () => notFound(),
    });
    return this.#server;
  }

  /** A scene a scenario saved: a .scene.json file, or "<scenario>/<name>" of its last run (or a snapshot's) */
  readScene(name: string): Scene {
    const candidates = [
      resolve(name),
      resolve(this.project.root, name),
      join(this.project.scenariosDir, ".last-run", `${name}.scene.json`),
      join(this.project.scenariosDir, `${name}.scene.json`),
      join(this.project.scenariosDir, "golden", `${name}.scene.json`),
    ];
    const path = candidates.find((candidate) => candidate.endsWith(".json") && existsSync(candidate));
    if (!path) throw new Error(`no saved scene ${name} (scenarios save them with saveScene("name"))`);
    return JSON.parse(readFileSync(path, "utf8")) as Scene;
  }

  /** The scene drawn into a PNG, the whole screen or the part crop says (x, y, width, height from the top left) */
  async draw(
    scene: Scene,
    options: ShotOptions & { crop?: [number, number, number, number] | null },
  ): Promise<ShotResult> {
    const chrome = findChrome();
    if (!chrome) throw new Error("no Chrome or Edge found to draw the picture with (ADDONSIM_CHROME names one)");
    const started = performance.now();
    const server = this.#serve();
    this.#nextId += 1;
    const id = `sdk/${this.#nextId}`;
    this.#scenes.set(id, scene);
    const [x, y, width, height] = options.crop ?? [0, 0, scene.width, scene.height];
    const query = new URLSearchParams({ shot: id, crop: `${x},${y},${width},${height}` });
    if (options.backdrop) query.set("backdrop", options.backdrop);
    // (ADDONSIM_SHOT_RENDERER=gl: drawn by the GPU's renderer, as the live page draws, to compare the two)
    if (process.env.ADDONSIM_SHOT_RENDERER === "gl") query.set("renderer", "gl");
    const scale = options.scale ?? 1;
    const out = options.out ? (isAbsolute(options.out) ? options.out : resolve(options.out)) : null;
    const target = out ?? join(tmpdir(), "addonsim-shots", `shot-${Date.now()}-${this.#nextId}.png`);
    mkdirSync(dirname(target), { recursive: true });
    rmSync(target, { force: true });
    // A fresh profile each time: one left behind by another Chrome holds it, and the next waits on it for good
    const profile = mkdtempSync(join(tmpdir(), "addonsim-chrome-"));
    try {
      const child = Bun.spawn(
        [
          chrome,
          "--headless=new",
          "--disable-gpu",
          "--hide-scrollbars",
          "--no-first-run",
          "--no-default-browser-check",
          "--disable-extensions",
          `--user-data-dir=${profile}`,
          `--window-size=${Math.max(1, Math.round(width))},${Math.max(1, Math.round(height))}`,
          `--force-device-scale-factor=${scale}`,
          "--virtual-time-budget=10000",
          `--screenshot=${target}`,
          `${server.url.href}?${query.toString()}`,
        ],
        { stdin: "ignore", stdout: "ignore", stderr: "ignore", windowsHide: true },
      );
      const timer = setTimeout(() => child.kill(), CHROME_TIMEOUT_MS);
      await child.exited;
      clearTimeout(timer);
    } finally {
      this.#scenes.delete(id);
      rmSync(profile, { recursive: true, force: true, maxRetries: 3 });
    }
    if (!existsSync(target)) throw new Error(`Chrome drew no picture (${basename(chrome)})`);
    return {
      path: target,
      width: Math.round(width * scale),
      height: Math.round(height * scale),
      seconds: (performance.now() - started) / 1000,
    };
  }

  async close(): Promise<void> {
    await this.#server?.stop(true);
    this.#server = null;
  }
}
