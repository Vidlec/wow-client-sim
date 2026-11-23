// Texture atlases (what SetAtlas names) from three DB2 tables: UiTextureAtlas (the texture and its size),
// UiTextureAtlasMember (each element's rectangle, size and flags) and UiTextureAtlasElementSliceData (nine-slice
// margins). Keyed by lower-case name; the first member of a name wins.
import type { AtlasInfo } from "./types.ts";

type Row = Record<string, string>;

/** Python's int() of a DB2 column, 0 for an empty or missing one */
const toInt = (text: string | undefined): number => {
  const value = Number.parseInt(text ?? "", 10);
  return Number.isNaN(value) ? 0 : value;
};

export const buildAtlases = (textures: Row[], members: Row[], slices: Row[]): Record<string, AtlasInfo> => {
  const texturesById = new Map(textures.map((row) => [row.ID ?? "", row]));
  // Nine-slice margins (pixels of the element) and whether the middle stretches (0) or tiles (1)
  const slicesByElement = new Map(slices.map((row) => [row.UiTextureAtlasElementID ?? "", row]));
  const atlases: Record<string, AtlasInfo> = {};
  for (const member of members) {
    const texture = texturesById.get(member.UiTextureAtlasID ?? "");
    const name = (member.CommittedName ?? "").toLowerCase();
    if (texture === undefined || !name || Object.hasOwn(atlases, name)) continue;
    const atlasWidth = toInt(texture.AtlasWidth) || 1;
    const atlasHeight = toInt(texture.AtlasHeight) || 1;
    const flags = toInt(member.CommittedFlags);
    const info: AtlasInfo = {
      fdid: toInt(texture.FileDataID),
      width: toInt(member.OverrideWidth) || toInt(member.Width),
      height: toInt(member.OverrideHeight) || toInt(member.Height),
      left: toInt(member.CommittedLeft) / atlasWidth,
      right: toInt(member.CommittedRight) / atlasWidth,
      top: toInt(member.CommittedTop) / atlasHeight,
      bottom: toInt(member.CommittedBottom) / atlasHeight,
      tilesH: (flags & 0x4) !== 0,
      tilesV: (flags & 0x2) !== 0,
    };
    const slice = slicesByElement.get(member.UiTextureAtlasElementID ?? "");
    if (slice) {
      info.slice = [toInt(slice.Left), toInt(slice.Top), toInt(slice.Right), toInt(slice.Bottom)];
      info.sliceMode = toInt(slice.SliceMode);
    }
    atlases[name] = info;
  }
  return atlases;
};

/** An atlas by name (any case), as a copy; null when unknown */
export const findAtlas = (atlases: Record<string, AtlasInfo>, name: string): AtlasInfo | null => {
  if (!name) return null;
  const key = name.toLowerCase();
  const info = Object.hasOwn(atlases, key) ? atlases[key] : undefined;
  if (info) return { ...info, ...(info.slice ? { slice: [...info.slice] } : {}) };
  // The client picks an atlas's high-resolution member ("...-2x") when asked for the plain name
  const doubled = Object.hasOwn(atlases, `${key}-2x`) ? atlases[`${key}-2x`] : undefined;
  if (!doubled) return null;
  // Twice the pixels for the same size on screen; slice margins are in the member's pixels
  const result: AtlasInfo = { ...doubled, width: doubled.width / 2, height: doubled.height / 2 };
  if (doubled.slice) {
    const [left, top, right, bottom] = doubled.slice;
    result.slice = [left / 2, top / 2, right / 2, bottom / 2];
  }
  return result;
};
