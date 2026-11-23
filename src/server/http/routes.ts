// The server's HTTP API: what the page reads (the state, the scene, the game's art and data) and the changes it asks
// for (input, slash commands, game actions, settings, the addons switched on or off). The setup's own routes are in
// setupRoutes.ts.
import { existsSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, sep } from "node:path";
import type { SetupNeeded } from "../../shared/setup.ts";
import { readCatalog, switchAddon } from "../addonCatalog.ts";
import type { App } from "../app.ts";
import { CACHE_DIR, SAVED_DIR, SCENARIOS_DIR } from "../config.ts";
import type { InputEvent } from "../sceneStream.ts";
import { bytes, cachedBytes, json, jsonText, notFound, readBody } from "./respond.ts";
import { createSetupRoutes } from "./setupRoutes.ts";

type Handler = (request: Request, url: URL) => Promise<Response> | Response;
export type RouteTable = Record<string, { GET?: Handler; POST?: Handler }>;

const SAVED_READ_LIMIT = 2_000_000;
const FINDERS = ["findQuests", "findNpcs", "sources"] as const;

/**
 * The state as the simulator wrote it (200 KB: not parsed here), the server's own fields added before its last brace.
 * Before the setup is done: SetupNeeded, for the page's setup screen; while the simulator starts: at once, not after
 * the start (which may fetch the game's files for minutes the first time)
 */
const readState = async (app: App): Promise<Response> => {
  const { host, stream, config } = app;
  const problems = app.problems();
  if (problems.length > 0 && !host.isRunning) {
    const error = `the setup is not done: ${problems[0]?.message ?? ""}`;
    return json({ setupNeeded: true, problems, error } satisfies SetupNeeded);
  }
  if (host.status.state === "starting" && !host.isRunning) {
    return json({ error: "the simulator is starting", starting: true, boot: host.boot, generation: host.generation });
  }
  const text = await host.requestRaw({ op: "state" });
  if (text.slice(0, 40).includes('"error"') || !text.endsWith("}")) return jsonText(text);
  const extra = JSON.stringify({
    generation: host.generation,
    boot: host.boot,
    paused: host.isPaused,
    speed: host.speed,
    autoReload: config.autoReload,
    artReady: app.art.isReady(),
    config: { addons: config.addons, addonsRoot: config.addonsRoot, build: config.build, flavour: config.flavour },
    // The project served (bun run start --project <dir>): its folder and its own addons
    project: app.project
      ? {
          root: app.project.root,
          addons: app.project.addons.map((addon) => addon.name),
          scenariosDir: app.project.scenariosDir,
        }
      : null,
    perf: stream.perf(),
  });
  return jsonText(`${text.slice(0, -1)},${extra.slice(1)}`);
};

/** An addon's saved variables file (saved/<Addon>.lua), its name kept to a plain file name */
const savedFile = (addon: unknown): { name: string; path: string } => {
  const name = basename(String(addon ?? ""));
  return { name, path: join(SAVED_DIR, `${name}.lua`) };
};

/** A saved scene of the runner, for the comparison page: only files under the scenarios folder (the served
 * project's, else the simulator's own), read only */
const readSnapshot = (scenariosDir: string, relative: string): Response => {
  if (!existsSync(scenariosDir)) return notFound();
  const root = realpathSync(scenariosDir);
  const full = join(root, decodeURIComponent(relative));
  if (!existsSync(full)) return notFound();
  const real = realpathSync(full);
  if (!real.startsWith(root + sep) || !statSync(real).isFile()) return notFound();
  return bytes(readFileSync(real), "application/json");
};

export const createRoutes = (app: App): RouteTable => {
  const { host, stream, config } = app;
  const ask = async (request: Record<string, unknown> & { op: string }): Promise<Response> =>
    json(await host.request(request));

  const routes: RouteTable = {
    ...createSetupRoutes(app),
    "/api/state": { GET: () => readState(app) },
    "/api/scene": {
      // The whole scene, when newer than the page's (a page without WebSockets polls this)
      GET: async (_request, url) => {
        const sinceText = url.searchParams.get("since");
        const since = sinceText && /^-?\d+$/.test(sinceText) ? Number(sinceText) : null;
        const text = await stream.waitWhole(host, since);
        return jsonText(text ?? JSON.stringify({ version: since, unchanged: true, generation: host.generation }));
      },
    },
    "/api/addonCatalog": {
      GET: () => json(readCatalog(config, app.project?.addons)),
      // An addon switched on or off: the settings' "addons", then a reload, as the game's AddOns list needs one
      POST: async (request) => {
        const body = await readBody(request);
        const name = String(body.name ?? "");
        const addons = switchAddon(config, name, Boolean(body.enabled), app.project?.addons);
        if (!addons) return json({ error: `no such addon: ${name}` }, 404);
        app.keepAddons(addons);
        const boot = await host.start();
        return json({ catalog: readCatalog(config, app.project?.addons), boot });
      },
    },
    "/api/saved": {
      GET: (_request, url) => {
        const { name, path } = savedFile(url.searchParams.get("addon"));
        if (!name || !existsSync(path)) return json({ addon: name, text: null });
        const text = readFileSync(path, "utf8").slice(0, SAVED_READ_LIMIT);
        return json({ addon: name, text, bytes: statSync(path).size });
      },
    },
    "/api/maps": {
      GET: async () => {
        const rows = (await app.art.getDb2Rows("UiMap")) ?? [];
        return json(
          rows.map((row) => ({
            id: Number(row.ID),
            name: row.Name_lang,
            type: Number(row.Type),
            parent: Number(row.ParentUiMapID),
          })),
        );
      },
    },
    "/art": {
      GET: async (request, url) => {
        const art = app.art;
        const target = url.searchParams.get("p") ?? "";
        const image = await art.image(/^\d+$/.test(target) ? Number(target) : target);
        if (!image) return json({ error: "unknown", ready: art.isReady() }, art.isReady() ? 404 : 503);
        return cachedBytes(request, config.build, image.data, image.contentType);
      },
    },
    "/atlas": {
      // As the client resolves a name: where the flavour has an atlas variant (Forever's "-c60"), the plain name
      // gives its variant where it has one, and a variant's name itself is unknown (the same rule as
      // W.getAtlasInfo in lua/boot.lua)
      GET: (_request, url) => {
        const name = (url.searchParams.get("n") ?? "").toLowerCase();
        const variant = config.atlasVariant ? config.atlasVariant.toLowerCase() : null;
        if (!variant) return json(app.art.atlas(name) ?? {});
        if (name.endsWith(variant)) return json({});
        return json(app.art.atlas(`${name}${variant}`) ?? app.art.atlas(name) ?? {});
      },
    },
    "/media": {
      GET: async (_request, url) => {
        const path = url.searchParams.get("p") ?? "";
        // One of the project's own addons is read from its folder, wherever that is
        const own = app.project?.addons.find((addon) => {
          const parts = path.replaceAll("\\", "/").split("/");
          return parts[0]?.toLowerCase() === "interface" && parts[2]?.toLowerCase() === addon.name.toLowerCase();
        });
        const media = await app.art.media(own ? dirname(own.dir) : config.addonsRoot, path);
        return media ? bytes(media.data, media.contentType) : json({ error: "unknown" }, 404);
      },
    },
    "/font": {
      GET: async (request, url) => {
        const font = await app.art.font(url.searchParams.get("p") ?? "");
        return font ? cachedBytes(request, config.build, font, "font/ttf") : json({ error: "unknown" }, 404);
      },
    },
    "/api/input": {
      POST: async (request) => {
        const answer = await host.request({ op: "input", event: (await readBody(request)) as InputEvent });
        stream.wake(); // its effect drawn at once, not at the next frame of the clock
        return json(answer);
      },
    },
    "/api/exec": { POST: async (request) => ask({ op: "exec", code: (await readBody(request)).code ?? "" }) },
    "/api/slash": { POST: async (request) => ask({ op: "slash", text: (await readBody(request)).text ?? "" }) },
    "/api/event": {
      POST: async (request) => {
        const body = await readBody(request);
        return ask({ op: "event", name: body.name, args: body.args ?? [] });
      },
    },
    "/api/game": { POST: async (request) => ask({ ...(await readBody(request)), op: "game" }) },
    "/api/frameInfo": { POST: async (request) => ask({ op: "frameInfo", frameId: (await readBody(request)).id }) },
    "/api/inspect": {
      POST: async (request) => {
        const body = await readBody(request);
        return ask({ op: "inspect", x: body.x ?? 0, y: body.y ?? 0, drawnOnly: body.drawnOnly ?? true });
      },
    },
    "/api/clearErrors": { POST: () => ask({ op: "clearErrors" }) },
    "/api/metrics": {
      POST: async (request) => {
        const metrics = await readBody(request);
        writeFileSync(join(CACHE_DIR, "metrics.json"), JSON.stringify(metrics));
        return ask({ op: "metrics", metrics });
      },
    },
    "/api/reload": { POST: async () => json(await host.start()) },
    "/api/savedReset": {
      // An addon's saved variables cleared: the file goes, and the addon starts fresh at the reload. Stopped without
      // saving first: the running addon would write them back as it closes
      POST: async (request) => {
        const { name, path } = savedFile((await readBody(request)).addon);
        await host.stop(false);
        if (name && existsSync(path)) rmSync(path);
        return json({ boot: await host.start() });
      },
    },
    "/api/settings": {
      // The run's own switches (not kept between runs); the kept settings are changed through /api/setup
      POST: async (request) => {
        const body = await readBody(request);
        if ("paused" in body) host.isPaused = Boolean(body.paused);
        if ("speed" in body) host.speed = Math.max(0.1, Math.min(10, Number(body.speed) || 1));
        if ("autoReload" in body) config.autoReload = Boolean(body.autoReload);
        return json({ paused: host.isPaused, speed: host.speed, autoReload: config.autoReload });
      },
    },
  };
  for (const finder of FINDERS) {
    routes[`/api/${finder}`] = { POST: async (request) => ask({ ...(await readBody(request)), op: finder }) };
  }
  routes["/snapshots/*"] = {
    GET: (_request, url) =>
      readSnapshot(app.project?.scenariosDir ?? SCENARIOS_DIR, url.pathname.slice("/snapshots/".length)),
  };
  return routes;
};
