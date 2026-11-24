// An addon's own files (Interface\AddOns\<Addon>\...), read from the addons folder: textures converted for the
// browser, sounds and fonts as they are. Addons name their files in any case and often without the extension, and
// the client finds "Plus" as Plus.tga or Plus.blp, so the lookup tries the same.
import { readdir, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { readIfExists } from "./files.ts";
import { CONTENT_TYPES, convertImage } from "./image.ts";
import { splitExtension, splitPath } from "./paths.ts";
import type { Served } from "./types.ts";

export const MEDIA_EXTENSIONS = [".tga", ".blp", ".png", ".jpg", ".jpeg"];
const IMAGE_EXTENSIONS = new Set(["tga", "blp", "png", "jpg", "jpeg"]);
const MAX_CACHED = 512;

const isFile = async (path: string): Promise<boolean> => (await stat(path).catch(() => null))?.isFile() ?? false;

/** root joined with parts, matching each part in any case where the exact name is not there */
const findFile = async (root: string, parts: string[]): Promise<string | null> => {
  const direct = join(root, ...parts);
  if (await isFile(direct)) return direct;
  let current = root;
  for (const part of parts) {
    // Case-insensitive walk, for case-sensitive file systems
    const wanted = part.toLowerCase();
    const names = await readdir(current).catch(() => null);
    const match = names?.find((name) => name.toLowerCase() === wanted);
    if (match === undefined) return null;
    current = join(current, match);
  }
  return (await isFile(current)) ? current : null;
};

export class AddonMedia {
  /** Converted files by path, size and modification time, so an edited file is read again */
  private readonly cache = new Map<string, Served>();

  /** The file for an Interface\AddOns\<Addon>\... path, or null when there is none (or the path leaves the folder) */
  async get(addonsRoot: string, path: string): Promise<Served | null> {
    if (!addonsRoot) return null; // (no AddOns folder chosen, and the addon is in no other folder)
    const parts = splitPath(path);
    if (parts.length < 4 || parts[0]?.toLowerCase() !== "interface" || parts[1]?.toLowerCase() !== "addons")
      return null;
    const relativeParts = parts.slice(2);
    if (relativeParts.some((part) => part === "." || part === ".." || part.includes("\0") || part.includes(":"))) {
      return null;
    }
    const fileName = relativeParts.at(-1) ?? "";
    const folders = relativeParts.slice(0, -1);
    const [stem, extension] = splitExtension(fileName);
    const names: string[] = extension ? [fileName] : [];
    for (const candidate of MEDIA_EXTENSIONS) {
      if (candidate.slice(1) !== extension.toLowerCase()) names.push(stem + candidate);
    }
    if (!extension) names.push(stem);
    for (const name of names) {
      const filePath = await findFile(addonsRoot, [...folders, name]);
      if (filePath) return this.read(filePath);
    }
    return null;
  }

  private async read(filePath: string): Promise<Served | null> {
    const info = await stat(filePath, { bigint: true }).catch(() => null);
    if (!info) return null;
    const key = `${filePath}\0${info.mtimeNs}\0${info.size}`;
    const cached = this.cache.get(key);
    if (cached) return cached;
    const data = await readIfExists(filePath).catch(() => null);
    if (!data) return null;
    const extension = splitExtension(basename(filePath))[1].toLowerCase();
    let result: Served;
    if (IMAGE_EXTENSIONS.has(extension)) {
      try {
        result = convertImage(data);
      } catch {
        return null; // (a broken image is looked at again next time)
      }
    } else {
      result = { data, contentType: CONTENT_TYPES[extension] ?? "application/octet-stream" };
    }
    if (this.cache.size > MAX_CACHED) this.cache.clear();
    this.cache.set(key, result);
    return result;
  }
}
