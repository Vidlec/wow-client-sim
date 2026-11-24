// The game's text codes, as the renderer reads them: |cAARRGGBB colours (nested, |r ends one), |H…|h links (shown as
// their text), |T…|t inline textures, |A…|a inline atlases, || a bar. Lines come already wrapped by Lua.
import { textureUrl } from "./textures.ts";

/** One code a match: [1] a colour's hex, [2] a texture's spec, [3] an atlas's spec (shared: reset lastIndex first) */
export const TEXT_CODE = /\|c([0-9a-fA-F]{8})|\|r|\|H[^|]*\|h|\|h|\|T([^|]*)\|t|\|A([^|]*)\|a|\|\|/g;

/** |Tpath:height:width:offsetX:offsetY:fileWidth:fileHeight:left:right:top:bottom:r:g:b|t, as the game reads it */
export type InlineTexture = {
  url: string | null;
  w: number;
  h: number;
  /** Shifted right and down (the game's y offset is up) */
  dx: number;
  dy: number;
  /** A piece of the file, in its pixels */
  crop: { fileWidth: number; fileHeight: number; left: number; right: number; top: number; bottom: number } | null;
  /** The colour the game multiplies by, as CSS */
  tint: string | null;
};

export const parseInlineTexture = (spec: string, lineHeight: number): InlineTexture => {
  const [path = "", height, width, offsetX, offsetY, fileWidth, fileHeight, left, right, top, bottom, r, g, b] =
    spec.split(":");
  // A height of 0 is the line's; a width of 0 is the height (square)
  const h = Number(height) > 0 ? Number(height) : lineHeight;
  const w = Number(width) > 0 ? Number(width) : h;
  const hasCrop = Number(fileWidth) > 0 && Number(fileHeight) > 0 && right !== undefined && bottom !== undefined;
  return {
    url: textureUrl(path),
    w,
    h,
    dx: Number(offsetX) || 0,
    dy: -(Number(offsetY) || 0),
    crop: hasCrop
      ? {
          fileWidth: Number(fileWidth),
          fileHeight: Number(fileHeight),
          left: Number(left),
          right: Number(right),
          top: Number(top),
          bottom: Number(bottom),
        }
      : null,
    tint: r !== undefined && g !== undefined && b !== undefined ? `rgb(${r},${g},${b})` : null,
  };
};

/**
 * |A:name:height:width:...|a (the game's CreateAtlasMarkup; the colon before the name is optional): an atlas at that
 * height (0: the line's) and width (0: as tall as it is)
 */
export const parseInlineAtlas = (spec: string, lineHeight: number): { name: string; w: number; h: number } => {
  const [name = "", height, width] = spec.replace(/^:/, "").split(":");
  const h = Number(height) > 0 ? Number(height) : lineHeight;
  return { name, w: Number(width) > 0 ? Number(width) : h, h };
};
