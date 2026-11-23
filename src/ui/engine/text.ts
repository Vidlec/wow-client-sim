// The game's text codes, as both renderers read them: |cAARRGGBB colours (nested, |r ends one), |H…|h links (shown as
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

const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" };
export const escapeHtml = (text: string): string => text.replace(/[&<>"]/g, (character) => ESCAPES[character] ?? "");

/** The colours open at the end of a line, carried into the next (a colour code may span lines) */
export type LineState = { colors: string[] };

const inlineTextureHtml = (texture: InlineTexture): string => {
  const { url, w, h, crop, tint } = texture;
  const shift = `position:relative;left:${texture.dx}px;top:${texture.dy}px;vertical-align:middle`;
  if (!crop && !tint) return `<img src="${url}" style="height:${h}px;width:${w}px;${shift}">`;
  // The crop as a sized, shifted picture; a tint (the game multiplies by it) as the colour seen through the picture's
  // shape, which is the same for the white signs addons tint this way
  const scaleX = crop ? w / (crop.right - crop.left) : w;
  const scaleY = crop ? h / (crop.bottom - crop.top) : h;
  const size = crop ? `${crop.fileWidth * scaleX}px ${crop.fileHeight * scaleY}px` : "100% 100%";
  const position = crop ? `${-crop.left * scaleX}px ${-crop.top * scaleY}px` : "0 0";
  const paint = tint
    ? `background:${tint};-webkit-mask:url('${url}') ${position} / ${size} no-repeat;mask:url('${url}') ${position} / ${size} no-repeat`
    : `background:url('${url}') ${position} / ${size} no-repeat`;
  return `<span style="display:inline-block;width:${w}px;height:${h}px;${paint};${shift}"></span>`;
};

/**
 * A line as HTML: spans in its colours, inline textures as pictures, atlases as empty spans marked data-atlas (their
 * art is put in once known: renderers/dom.ts fillInlineAtlases). For the DOM renderer, and for the page's own lists
 * that show the game's text (chat).
 */
export const lineToHtml = (line: string, state: LineState, lineHeight: number): string => {
  const open = (): string => {
    const color = state.colors[state.colors.length - 1];
    return color ? `<span style="color:#${color.slice(2)}">` : "<span>";
  };
  let html = open();
  let last = 0;
  TEXT_CODE.lastIndex = 0;
  for (let match = TEXT_CODE.exec(line); match; match = TEXT_CODE.exec(line)) {
    html += escapeHtml(line.slice(last, match.index));
    last = TEXT_CODE.lastIndex;
    const token = match[0];
    if (match[1]) {
      state.colors.push(match[1]);
      html += `</span>${open()}`;
    } else if (token === "|r") {
      state.colors.pop();
      html += `</span>${open()}`;
    } else if (token === "||") html += "|";
    else if (match[2] !== undefined) html += inlineTextureHtml(parseInlineTexture(match[2], lineHeight));
    else if (match[3] !== undefined) {
      const { name, w, h } = parseInlineAtlas(match[3], lineHeight);
      html += `<span data-atlas="${escapeHtml(name)}" style="display:inline-block;width:${w}px;height:${h}px;vertical-align:middle"></span>`;
    }
  }
  return `${html}${escapeHtml(line.slice(last))}</span>`;
};
