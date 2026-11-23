// What the Lua host is started with (cache/runtime.json): the settings with their flavour's client (config.ts) plus
// where the game's data lies, building the files it reads once (the atlases, the map highlight masks, the listfile's
// paths and ids).
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { ArtSource } from "./art.ts";
import { CACHE_DIR, type Config, SAVED_DIR } from "./config.ts";
import { findFlavour } from "./flavours/index.ts";
import { buildMapHighlights } from "./mapHighlights.ts";

/** Whether a file built from the game's files has all it should (one built while a download failed has not) */
const isCompleteJson = (path: string): boolean => {
  try {
    const value = JSON.parse(readFileSync(path, "utf8")) as { _complete?: boolean } | null;
    return value !== null && typeof value === "object" && value._complete !== false;
  } catch {
    return false;
  }
};

const findDb2Dir = async (art: ArtSource, tables: readonly string[]): Promise<string | null> => {
  let folder: string | null = null;
  for (const table of tables) {
    const path = await art.db2Path(table);
    if (path) folder = dirname(path);
  }
  return folder;
};

/** The runtime config written into the cache (fileName: another than the server's runtime.json, so the runner and a
 * second server never write over the file a starting simulator is about to read) */
export const writeRuntimeConfig = async (
  config: Config,
  art: ArtSource,
  fileName = "runtime.json",
): Promise<string> => {
  const db2Dir = await findDb2Dir(art, findFlavour(config.flavour).db2Tables);
  const atlasFile = join(CACHE_DIR, `atlases-${config.build}.json`);
  if (!existsSync(atlasFile)) {
    // (None written while the tables cannot be had: an empty file would stand for good after a failed first download)
    const atlases = await art.loadAtlases();
    if (atlases) writeFileSync(atlasFile, JSON.stringify(atlases));
  }
  const highlightsFile = join(CACHE_DIR, `map-highlights-${config.build}.json`);
  if (db2Dir && !isCompleteJson(highlightsFile)) {
    const highlights = await buildMapHighlights(art);
    if (highlights) writeFileSync(highlightsFile, JSON.stringify(highlights));
  }
  // The listfile's paths and file ids, sorted, for GetFileIDFromPath (written once; none without the index)
  const fileIdsFile = await art.exportFileIds(join(CACHE_DIR, "file-ids.tsv")).catch(() => null);
  mkdirSync(SAVED_DIR, { recursive: true });
  const runtime = {
    ...config,
    fileIdsFile,
    mapHighlightsFile: highlightsFile,
    savedDir: SAVED_DIR,
    db2Dir,
    atlasFile,
    metricsFile: join(CACHE_DIR, "metrics.json"),
  };
  const path = join(CACHE_DIR, fileName);
  writeFileSync(path, JSON.stringify(runtime));
  return path;
};
