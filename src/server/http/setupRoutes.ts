// The setup's routes (src/shared/setup.ts has the contract): the settings and what is missing, changes to them, the
// interface source's download, and help with folders (what a path holds, the system's folder dialog).
import {
  type FolderCheckRequest,
  type FolderKind,
  type FolderPickRequest,
  SETUP_ROUTES,
  type SettingsChange,
} from "../../shared/setup.ts";
import type { App } from "../app.ts";
import { findFlavour } from "../flavours/index.ts";
import { checkFolder } from "../setup/detect.ts";
import { pickFolder } from "../setup/pickFolder.ts";
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
  [SETUP_ROUTES.checkFolder]: {
    POST: async (request) => {
      const body = (await readBody(request)) as Partial<FolderCheckRequest>;
      const kind = readKind(body.kind);
      if (!kind) return json({ error: "kind should be addons, interface or luajit" }, 400);
      return json(checkFolder(kind, String(body.path ?? ""), findFlavour(app.settings.flavour)));
    },
  },
  [SETUP_ROUTES.pickFolder]: {
    POST: async (request) => {
      const body = (await readBody(request)) as Partial<FolderPickRequest>;
      const kind = readKind(body.kind);
      if (!kind) return json({ error: "kind should be addons, interface or luajit" }, 400);
      const pick: FolderPickRequest = { kind };
      if (typeof body.startPath === "string" && body.startPath) pick.startPath = body.startPath;
      return json(await pickFolder(pick));
    },
  },
});
