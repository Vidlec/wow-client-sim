// AddonSim: run World of Warcraft addons in the browser, for developing them. Serves the page, and once the setup is
// done (in the page) starts the Lua host (LuaJIT, the game's Lua 5.1, with the addons), ticks its clock, and streams
// the frames it draws with the game's real art.
//
//     bun run start            (or the executable bun run build makes), then open http://127.0.0.1:8765/
//     bun run start --project <dir>    serve a project (its addonsim.config.ts): its addons, plugins, Lua path
//
// Settings are kept by the app in the user's settings folder (paths.ts), changed from the page's setup. Started in a
// project's folder (one with an addonsim.config.ts, or below one), it serves that project without being told.
import { selectServedProject, takeProjectFlag } from "../project/select.ts";
import index from "../ui/index.html";
import { watchAddons } from "./addonWatcher.ts";
import { App } from "./app.ts";
import { runClock } from "./clock.ts";
import { findFlavour } from "./flavours/index.ts";
import { json, notFound } from "./http/respond.ts";
import { createRoutes } from "./http/routes.ts";
import { unpackLua } from "./luaBundle.ts";
import { openBrowser } from "./openBrowser.ts";
import { APP_VERSION, IS_STANDALONE, ROOT, SETTINGS_PATH } from "./paths.ts";
import type { InputEvent } from "./sceneStream.ts";

type PageData = { needsWhole: boolean };
type SocketMessage = { t?: string; e?: InputEvent };

/** Ports tried after the settings' one when it is taken by something else */
const SPARE_PORTS = 10;

const unpacked = await unpackLua();
if (unpacked > 0) console.log(`Unpacked the simulator's ${unpacked} Lua files into ${ROOT}`);

const project = await selectServedProject(takeProjectFlag(process.argv.slice(2)).projectDir);
const app = new App(project);
const { host, stream, config } = app;

/**
 * Whether a request may reach the API: a page of another site must not drive the app (the API runs code), so a
 * request to a name other than this computer's (a rebound DNS name) is refused, and so is a change a browser sends
 * from another origin
 */
const isLocalName = (request: Request): boolean =>
  /^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/i.test(request.headers.get("Host") ?? "");

const isOwnRequest = (request: Request): boolean => {
  if (!isLocalName(request)) return false;
  const origin = request.headers.get("Origin");
  if (origin === null) return true; // (not from a browser's page: the CLI tools, curl)
  try {
    return new URL(origin).host.toLowerCase() === (request.headers.get("Host") ?? "").toLowerCase();
  } catch {
    return false; // ("null": a file or a sandboxed frame)
  }
};

// Bun's routes take (request, server); ours read the URL too
const routes = Object.fromEntries(
  Object.entries(createRoutes(app)).map(([path, methods]) => [
    path,
    Object.fromEntries(
      Object.entries(methods).map(([method, handler]) => [
        method,
        (request: Request) =>
          !isLocalName(request) || (method !== "GET" && !isOwnRequest(request))
            ? json({ error: "refused: not from the app's own page" }, 403)
            : handler(request, new URL(request.url)),
      ]),
    ),
  ]),
);

/** The page's server, on the settings' port (ADDONSIM_PORT: another, beside a server already running) */
const serve = (port: number): ReturnType<typeof Bun.serve<PageData>> =>
  Bun.serve<PageData>({
    hostname: "127.0.0.1",
    port,
    // From the sources, Bun transpiles the page as it serves it (no hot reload: the game screen keeps its socket and
    // state, and a change to the page is seen at the next refresh); the executable serves the page built into it
    development: IS_STANDALONE ? false : { hmr: false, console: false },
    routes: { "/": index, "/index.html": index, ...routes },
    fetch: (request, bunServer) => {
      const url = new URL(request.url);
      if (url.pathname === "/ws" && isOwnRequest(request)) {
        if (bunServer.upgrade(request, { data: { needsWhole: true } })) return undefined;
      }
      return notFound();
    },
    websocket: {
      open: (socket) => stream.add(socket),
      close: (socket) => stream.remove(socket),
      // The page's input, taken with the next frame (at once), or a page asking for the whole scene again
      message: (socket, text) => {
        let message: SocketMessage;
        try {
          message = JSON.parse(String(text)) as SocketMessage;
        } catch {
          return;
        }
        if (message.t === "input") stream.queueInput(message.e ?? {});
        else if (message.t === "whole") stream.requestWhole(socket);
      },
    },
  });

/** Whether an AddonSim already answers on the port (the app started twice: the first one is the one to use) */
const isAddonSimAt = async (port: number): Promise<boolean> => {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/api/setup`, { signal: AbortSignal.timeout(2000) });
    const body = (await response.json()) as { version?: unknown };
    return typeof body.version === "string";
  } catch {
    return false;
  }
};

const isPortTaken = (error: unknown): boolean =>
  error instanceof Error &&
  /EADDRINUSE|address already in use|port .* in use/i.test(
    `${error.message} ${String((error as { code?: unknown }).code)}`,
  );

const startServer = async (): Promise<ReturnType<typeof serve> | null> => {
  const asked = Number(process.env.ADDONSIM_PORT) || config.port;
  for (let port = asked; port <= asked + SPARE_PORTS; port++) {
    try {
      return serve(port);
    } catch (error) {
      if (!isPortTaken(error)) throw error;
      if (port === asked && (await isAddonSimAt(port))) {
        const url = `http://127.0.0.1:${port}/`;
        console.log(`AddonSim already runs on ${url}; opening it.`);
        if (app.settings.openBrowser && !process.env.ADDONSIM_PORT) openBrowser(url);
        return null;
      }
      console.log(`Port ${port} is taken; trying ${port + 1}.`);
    }
  }
  throw new Error(`no free port from ${asked} to ${asked + SPARE_PORTS}`);
};

const server = await startServer();
if (!server) process.exit(0);

const url = server.url.href;
const flavour = findFlavour(app.settings.flavour);
const isReady = app.isReady;
const lines = [
  "",
  `  AddonSim ${APP_VERSION}  (${flavour.name} ${flavour.client.version}.${flavour.client.buildNumber})`,
  "",
  `  Open ${url}`,
  "",
  isReady
    ? "  The simulator is starting (the first time it fetches the game's art and tables, which takes a while)."
    : "  The setup is not done: the page asks for what it needs.",
  ...(project ? [`  Project:  ${project.root} (${project.addons.map((addon) => addon.name).join(", ")})`] : []),
  `  Settings: ${SETTINGS_PATH}`,
  `  Data:     ${ROOT}`,
  "  Ctrl+C stops it.",
  "",
];
console.log(lines.join("\n"));
// The browser opened for the executable (double-clicked, it has nothing else to show) and for a first run from the
// sources; not at each restart of bun run dev
if (app.settings.openBrowser && !process.env.ADDONSIM_PORT && (IS_STANDALONE || !isReady)) openBrowser(url);

void runClock(host, stream, config);
void watchAddons(host, config, project);
void app.startSimulator().catch((error: unknown) => {
  process.stderr.write(`simulator: ${error instanceof Error ? error.message : String(error)}\n`);
});

const shutDown = async (): Promise<void> => {
  await host.stop(true);
  process.exit(0);
};
process.on("SIGINT", () => void shutDown());
process.on("SIGTERM", () => void shutDown());
