// Game art for AddonSim: real WoW files fetched from wago.tools and converted for the browser. Everything downloaded
// is cached under cacheDir, shared by every process that runs (the server, the daemon, suite runs):
//
//   listfile.sqlite             path -> fileDataID index (interface/, fonts/ and the minimap tiles)
//   db2/<build>[-<locale>]/<Table>.csv   DB2 tables (UiTextureAtlas, UiTextureAtlasMember, UiMap...)
//   casc/<build>/<fdid>         raw game files; <fdid>.missing marks "not in this build"
//   png/<build>/<fdid>.png      converted textures (.jpg for JPEG pass-through)
import { mkdirSync } from "node:fs";
import { join, resolve as resolvePath } from "node:path";
import { DEFAULT_FLAVOUR } from "../flavours/index.ts";
import { buildAtlases, findAtlas } from "./atlases.ts";
import { CascStore } from "./casc.ts";
import { Db2Store } from "./db2.ts";
import { FailureMemory, SingleFlight } from "./flight.ts";
import { isFont } from "./fonts.ts";
import { Listfile, type ListfileRow } from "./listfile.ts";
import { AddonMedia } from "./media.ts";
import { getExtensionRank, splitExtension, splitPath } from "./paths.ts";
import { TextureStore } from "./textures.ts";
import type { AssetsStatus, AtlasInfo, Served } from "./types.ts";

/** The default flavour's build (a store is normally made for the settings' build) */
export const DEFAULT_BUILD: string = DEFAULT_FLAVOUR.wagoBuild;

export type AssetsOptions = { build: string; locale?: string };

/** The listfile row a path means: an exact match of name and extension, else the best extension of the name */
const chooseListfileRow = (rows: ListfileRow[], full: string, stem: string, extension: string): number | null => {
  for (const row of rows) {
    if (row.stem === stem && row.ext === extension) return row.fdid;
  }
  const exact = rows.filter((row) => row.stem === full); // a dotted name given without its extension
  const candidates = exact.length > 0 ? exact : rows.filter((row) => row.stem === stem);
  let best: ListfileRow | null = null;
  for (const row of candidates) {
    const rank = getExtensionRank(row.ext);
    const bestRank = best ? getExtensionRank(best.ext) : Number.POSITIVE_INFINITY;
    if (!best || rank < bestRank || (rank === bestRank && row.fdid < best.fdid)) best = row;
  }
  return best?.fdid ?? null;
};

/** Access to real WoW game art for one client build */
export class Assets {
  readonly cacheDir: string;
  readonly build: string;
  /** The language of the game's tables (interface strings, map, area and item names); enUS by default */
  readonly locale: string;
  readonly db2Folder: string;
  readonly listfilePath: string;

  private readonly listfile: Listfile;
  private readonly failures = new FailureMemory();
  private readonly casc: CascStore;
  private readonly textures: TextureStore;
  private readonly db2: Db2Store;
  private readonly addonMedia = new AddonMedia();
  private readonly flights = new SingleFlight();
  private readonly resolved = new Map<string, number | null>();
  private atlases: Record<string, AtlasInfo> | null = null;

  constructor(cacheDir: string, options: AssetsOptions) {
    this.cacheDir = resolvePath(cacheDir);
    this.build = options.build || DEFAULT_BUILD;
    this.locale = options.locale || "enUS";
    this.db2Folder = this.locale === "enUS" ? this.build : `${this.build}-${this.locale}`;
    const cascFolder = join(this.cacheDir, "casc", this.build);
    const pngFolder = join(this.cacheDir, "png", this.build);
    const db2Folder = join(this.cacheDir, "db2", this.db2Folder);
    for (const folder of [cascFolder, pngFolder, db2Folder]) mkdirSync(folder, { recursive: true });
    this.listfile = new Listfile(this.cacheDir);
    this.listfilePath = this.listfile.path;
    this.casc = new CascStore(cascFolder, this.build, this.failures);
    this.textures = new TextureStore(pngFolder, this.casc, this.failures);
    this.db2 = new Db2Store(db2Folder, this.build, this.locale, this.failures);
  }

  // -- listfile ------------------------------------------------------------

  /** True once the listfile index exists; starts building it in the background otherwise */
  isReady(): boolean {
    return this.listfile.isReady();
  }

  /** Waits for the listfile index (or the timeout, or a failed build); true when it is ready */
  waitReady(timeoutMs: number): Promise<boolean> {
    return this.listfile.waitReady(timeoutMs);
  }

  /** Diagnostics: readiness, listfile row count and build time, last error */
  getStatus(): AssetsStatus {
    const status: AssetsStatus = { ready: this.listfile.isBuilt, build: this.build, error: this.listfile.error };
    if (status.ready) {
      try {
        Object.assign(status, this.listfile.getMeta());
      } catch (error) {
        status.error = error instanceof Error ? error.message : String(error);
      }
    }
    return status;
  }

  /** Game path (any case, / or \, extension optional) or numeric id -> fileDataID; null when unknown or not ready */
  resolve(target: string | number): number | null {
    if (typeof target === "number") return Number.isInteger(target) && target > 0 ? target : null;
    const text = target.trim();
    if (/^\d+$/.test(text)) return Number(text) || null;
    const parts = splitPath(text.toLowerCase());
    if (parts.length === 0) return null;
    const full = parts.join("/");
    const known = this.resolved.get(full);
    if (known !== undefined) return known;
    if (!this.isReady()) return null;
    const [stem, extension] = splitExtension(full);
    const fdid = chooseListfileRow(this.listfile.lookup(full, stem), full, stem, extension);
    this.resolved.set(full, fdid);
    return fdid;
  }

  /** cache/file-ids.tsv and the like: every listfile path with its id, sorted, for GetFileIDFromPath (see Listfile) */
  exportFileIds(path: string): Promise<string | null> {
    return this.listfile.exportFileIds(path);
  }

  // -- files and textures --------------------------------------------------

  /** Raw bytes of a game file by fileDataID or path (downloaded once, then cached) */
  async raw(target: string | number): Promise<Uint8Array | null> {
    const fdid = this.resolve(target);
    return fdid === null ? null : this.casc.get(fdid);
  }

  /** A texture for the browser: PNG, or JPEG passed through untouched */
  async image(target: string | number): Promise<Served | null> {
    const fdid = this.resolve(target);
    return fdid === null ? null : this.textures.get(fdid);
  }

  /** The bytes of image(): PNG for a texture (a JPEG source comes back as JPEG) */
  async png(target: string | number): Promise<Uint8Array | null> {
    return (await this.image(target))?.data ?? null;
  }

  /** TTF/OTF bytes for a game font path such as Fonts\FRIZQT__.TTF; null for a file that is no font */
  async font(path: string): Promise<Uint8Array | null> {
    const data = await this.raw(path);
    return data && isFont(data) ? data : null;
  }

  /** An addon's file (Interface\AddOns\<Addon>\...) read from addonsRoot: textures as PNG, other files as they are */
  media(addonsRoot: string, path: string): Promise<Served | null> {
    return this.addonMedia.get(addonsRoot, path);
  }

  // -- DB2 tables and atlases ----------------------------------------------

  /** A DB2 table's rows keyed by column name, downloaded on first use; null when it cannot be had */
  getDb2Rows(table: string): Promise<Record<string, string>[] | null> {
    return this.db2.getRows(table);
  }

  /** The local CSV of a DB2 table for the build, downloaded on first use; null when it cannot be had */
  db2Path(table: string): Promise<string | null> {
    return this.db2.getLocalPath(table);
  }

  /** Every atlas by lower-case name, loaded once (null while the tables cannot be had) */
  loadAtlases(): Promise<Record<string, AtlasInfo> | null> {
    return this.flights.run("atlases", async () => {
      if (this.atlases) return this.atlases;
      const textures = await this.getDb2Rows("UiTextureAtlas");
      const members = await this.getDb2Rows("UiTextureAtlasMember");
      if (!textures || !members) return null;
      const slices = (await this.getDb2Rows("UiTextureAtlasElementSliceData")) ?? [];
      this.atlases = buildAtlases(textures, members, slices);
      return this.atlases;
    });
  }

  /**
   * Atlas info by name (any case), or null when unknown. Answers from the loaded atlases: before loadAtlases() has
   * finished it starts loading and gives null, so the server awaits loadAtlases() as it starts.
   */
  atlas(name: string): AtlasInfo | null {
    if (!this.atlases) {
      void this.loadAtlases();
      return null;
    }
    return findAtlas(this.atlases, name);
  }
}
