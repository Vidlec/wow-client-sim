// Game paths as addons write them: any case, \ or / (doubled or not), quoted, extension optional.

/** When a path is given without its extension, the file the client would pick: BLP before TGA before PNG/JPEG, TTF
 * before OTF; anything else last */
export const EXTENSION_RANK: Readonly<Record<string, number>> = {
  blp: 0,
  tga: 1,
  png: 2,
  jpg: 3,
  jpeg: 3,
  ttf: 0,
  otf: 1,
};

export const getExtensionRank = (extension: string): number => EXTENSION_RANK[extension] ?? 9;

/** The non-empty parts of a path, split at \ and /, after trimming spaces and quotes */
export const splitPath = (path: string): string[] =>
  path
    .trim()
    .replace(/^["']+|["']+$/g, "")
    .split(/[\\/]+/)
    .filter((part) => part !== "");

/** "name.ext" -> ["name", "ext"]; a name without a dot, or only a leading one, has no extension */
export const splitExtension = (name: string): [string, string] => {
  const dot = name.lastIndexOf(".");
  if (dot <= 0) return [name, ""];
  const extension = name.slice(dot + 1);
  if (extension.includes("/")) return [name, ""];
  return [name.slice(0, dot), extension];
};
