// The setup's routes (src/shared/setup.ts has the contract): the settings and what is missing, changes to them, the
// interface source's download, and help with folders (what a path holds, the page's folder browser).
import {
  type FolderCheckRequest,
  type FolderKind,
  type FolderListRequest,
  type ResetChoice,
  SETUP_ROUTES,
  type SettingsChange,
} from "../../shared/setup.ts";
import type { App } from "../app.ts";
import { readClientBuilds } from "../clientBuilds.ts";
import { resolveInterfaceRoot } from "../config.ts";
import { findFlavour } from "../flavours/index.ts";
import { listFolder } from "../setup/browse.ts";
import { checkFolder } from "../setup/detect.ts";
import { json, readBody } from "./respond.ts";
import type { RouteTable } from "./routes.ts";

const FOLDER_KINDS: readonly FolderKind[] = ["addons", "interface", "luajit"];

const readKind = (value: unknown): FolderKind | null =>
  FOLDER_KINDS.includes(value as FolderKind) ? (value as FolderKind) : null;

export const createSetupRoutes = (app: App): RouteTable => ({
  [SETUP_ROUTES.setup]: {
    // ?refresh=1: look for folders and LuaJIT again now (the setup's Check), not from what was found before
    GET: (_request, url) => json(app.setupState(url.searchParams.get("refresh") === "1")),
    POST: async (request) => json(app.change((await readBody(request)) as SettingsChange)),
  },
  [SETUP_ROUTES.downloadInterface]: { POST: () => json(app.downloadInterface()) },
  // What the cache holds of the game's art and tables (the settings' "The game's art")
  [SETUP_ROUTES.art]: { GET: () => json(app.readArtInfo()) },
  // The client's builds: in use, the newest on Blizzard's servers, those wago.tools has, the interface source's
  [SETUP_ROUTES.builds]: {
    GET: async () =>
      json(
        await readClientBuilds(findFlavour(app.settings.flavour), app.config.build, resolveInterfaceRoot(app.settings)),
      ),
  },
  // Back to a fresh setup: the settings, and what the body chooses ({ interface, cache, saved }) deleted
  [SETUP_ROUTES.reset]: {
    POST: async (request) => {
      const body = (await readBody(request)) as Partial<ResetChoice>;
      return json(
        await app.reset({ interface: body.interface === true, cache: body.cache === true, saved: body.saved === true }),
      );
    },
  },
  [SETUP_ROUTES.checkFolder]: {
    POST: async (request) => {
      const body = (await readBody(request)) as Partial<FolderCheckRequest>;
      const kind = readKind(body.kind);
      if (!kind) return json({ error: "kind should be addons, interface or luajit" }, 400);
      return json(checkFolder(kind, String(body.path ?? ""), findFlavour(app.settings.flavour)));
    },
  },
  [SETUP_ROUTES.listFolder]: {
    POST: async (request) => {
      const body = (await readBody(request)) as Partial<FolderListRequest>;
      const kind = readKind(body.kind);
      if (!kind) return json({ error: "kind should be addons, interface or luajit" }, 400);
      const path = typeof body.path === "string" ? body.path : undefined;
      return json(listFolder(kind, path, findFlavour(app.settings.flavour)));
    },
  },
});
