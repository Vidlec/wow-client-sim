// Texture atlases (what SetAtlas names) from the client's tables: UiTextureAtlasElement (the names the game's code asks
// for), UiTextureAtlasMember (each element's art: a rectangle of a texture, at one resolution, for one variant),
// UiTextureAtlas (the texture and its size) and UiTextureAtlasElementSliceData (nine-slice margins).
//
// The client looks an atlas up by its element's name, and draws the member that suits it: WoW Forever's the "-c60"
// variant where the element has one ("common-stat-bar-BG" draws "common-stat-bar-BG-c60"), at normal resolution where
// there is one, else the high-resolution one at half size (the swing timer's only member is "...-2x-c60", the bag
// slots' "..._2xc60"). A member's own name is no name to ask by ("common-stat-bar-BG-c60" is unknown in the game,
// measured); an element may carry "-C60" in its own name (the spellbook's "spellbook-Page-Right-C60"). Keyed by
// lower-case name.
import type { AtlasInfo } from "./types.ts";

type Row = Record<string, string>;

/** Python's int() of a DB2 column, 0 for an empty or missing one */
const toInt = (text: string | undefined): number => {
  const value = Number.parseInt(text ?? "", 10);
  return Number.isNaN(value) ? 0 : value;
};

/** A member drawn at twice the pixels: "...-2x", "...-2x-c60", "..._2xc60" */
const isDoubled = (member: Row): boolean => /[-_]2x/i.test(member.CommittedName ?? "");

/**
 * @param elements the elements (none: an older table set, keyed by the members' own names as before)
 * @param variant the flavour's atlas variant ("-c60"), whose members stand for their element; none for none
 */
export const buildAtlases = (
  textures: Row[],
  members: Row[],
  slices: Row[],
  elements: Row[] = [],
  variant: string | null = null,
): Record<string, AtlasInfo> => {
  const texturesById = new Map(textures.map((row) => [row.ID ?? "", row]));
  // Nine-slice margins (pixels of the element) and whether the middle stretches (0) or tiles (1)
  const slicesByElement = new Map(slices.map((row) => [row.UiTextureAtlasElementID ?? "", row]));
  const toInfo = (member: Row): AtlasInfo | null => {
    const texture = texturesById.get(member.UiTextureAtlasID ?? "");
    if (texture === undefined) return null;
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
    return info;
  };
  const atlases: Record<string, AtlasInfo> = {};
  if (elements.length === 0) {
    for (const member of members) {
      const name = (member.CommittedName ?? "").toLowerCase();
      if (!name || Object.hasOwn(atlases, name)) continue;
      const info = toInfo(member);
      if (info) atlases[name] = info;
    }
    return atlases;
  }
  const membersByElement = new Map<string, Row[]>();
  for (const member of members) {
    const id = member.UiTextureAtlasElementID ?? "";
    const list = membersByElement.get(id);
    if (list) list.push(member);
    else membersByElement.set(id, [member]);
  }
  const variantMark = variant ? variant.replace(/^-/, "").toLowerCase() : null;
  const byId = (a: Row, b: Row): number => toInt(a.ID) - toInt(b.ID);
  for (const element of elements) {
    const name = (element.Name ?? "").toLowerCase();
    const list = membersByElement.get(element.ID ?? "");
    if (!name || !list || Object.hasOwn(atlases, name)) continue;
    // The variant's members where it has some, else all of them
    const ofVariant = variantMark
      ? list.filter((member) => (member.CommittedName ?? "").toLowerCase().includes(variantMark))
      : [];
    const pool = ofVariant.length > 0 ? ofVariant : list;
    // At normal resolution, the one named as the element (or its variant) first; else a high-resolution one, halved
    const single = pool.filter((member) => !isDoubled(member)).sort(byId);
    const named = single.find((member) => {
      const memberName = (member.CommittedName ?? "").toLowerCase();
      return memberName === name || (variant !== null && memberName === `${name}${variant.toLowerCase()}`);
    });
    const chosen = named ?? single[0];
    if (chosen) {
      const info = toInfo(chosen);
      if (info) atlases[name] = info;
      continue;
    }
    const doubled = pool.filter(isDoubled).sort(byId)[0];
    const info = doubled ? toInfo(doubled) : null;
    if (info) atlases[name] = halveAtlas(info);
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
  return doubled ? halveAtlas(doubled) : null;
};

/** A high-resolution member at the size it is drawn: twice the pixels for the same size on screen, its slice margins too */
export const halveAtlas = (doubled: AtlasInfo): AtlasInfo => {
  const result: AtlasInfo = { ...doubled, width: doubled.width / 2, height: doubled.height / 2 };
  if (doubled.slice) {
    const [left, top, right, bottom] = doubled.slice;
    result.slice = [left / 2, top / 2, right / 2, bottom / 2];
  }
  return result;
};
