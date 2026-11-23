// Each map's highlight art (UiMapArt.HighlightFileDataID: what lights up under the cursor on its parent's map) and
// where it covers: the texels inside the shape, as a mask the simulator hit-tests. The art is a dim glow (a zone) or a
// bare outline (a continent) on black; the inside is whatever the black round the edges cannot reach.
import type { ArtSource } from "./art.ts";
import { decodeBlp } from "./assets/blp.ts";

const MASK_SIZE = 128; // a mask's side at most, in texels

export type MapHighlight = {
  fileId: number;
  width: number;
  height: number;
  columns: number;
  rows: number;
  mask: string;
};
/** "_complete" is false when a texture could not be had: the file is built again at the next start */
export type MapHighlights = { _complete: boolean; [uiMapId: string]: MapHighlight | boolean };

/** Texels connected to the edge through pure black (the black round the shape is exactly 0): the outside */
const findOutside = (pixels: Uint8Array, width: number, height: number): Uint8Array => {
  const count = width * height;
  const outside = new Uint8Array(count);
  const isDark = (index: number): boolean => {
    const offset = index * 4;
    return (pixels[offset] ?? 0) === 0 && (pixels[offset + 1] ?? 0) === 0 && (pixels[offset + 2] ?? 0) === 0;
  };
  const stack = new Int32Array(count * 4 + 4 * (width + height));
  let top = 0;
  for (let x = 0; x < width; x++) {
    stack[top++] = x;
    stack[top++] = (height - 1) * width + x;
  }
  for (let y = 0; y < height; y++) {
    stack[top++] = y * width;
    stack[top++] = y * width + width - 1;
  }
  while (top > 0) {
    const index = stack[--top] ?? 0;
    if (outside[index] || !isDark(index)) continue;
    outside[index] = 1;
    const x = index % width;
    if (x > 0) stack[top++] = index - 1;
    if (x < width - 1) stack[top++] = index + 1;
    if (index >= width) stack[top++] = index - width;
    if (index < count - width) stack[top++] = index + width;
  }
  return outside;
};

const buildMask = (fileId: number, data: Uint8Array): MapHighlight | null => {
  let decoded: ReturnType<typeof decodeBlp>;
  try {
    decoded = decodeBlp(data);
  } catch {
    return null;
  }
  const { width, height, pixels } = decoded;
  const outside = findOutside(pixels, width, height);
  const step = Math.max(1, Math.floor(Math.max(width, height) / MASK_SIZE));
  const columns = Math.floor(width / step);
  const rows = Math.floor(height / step);
  const bits = new Uint8Array(columns * rows);
  for (let row = 0; row < rows; row++) {
    for (let column = 0; column < columns; column++) {
      bits[row * columns + column] = outside[row * step * width + column * step] ? 48 : 49; // "0" / "1"
    }
  }
  return { fileId, width, height, columns, rows, mask: new TextDecoder().decode(bits) };
};

export const buildMapHighlights = async (art: ArtSource): Promise<MapHighlights | null> => {
  const artRows = await art.getDb2Rows("UiMapArt");
  const links = await art.getDb2Rows("UiMapXMapArt");
  if (!artRows || !links) return null;
  const highlightByArt = new Map(artRows.map((row) => [row.ID ?? "", Number(row.HighlightFileDataID) || 0]));
  const result: MapHighlights = { _complete: true };
  for (const row of links) {
    const fileId = highlightByArt.get(row.UiMapArtID ?? "") ?? 0;
    const uiMapId = row.UiMapID ?? "";
    if (!fileId || uiMapId in result) continue;
    const data = await art.raw(fileId);
    if (!data) {
      result._complete = false;
      continue;
    }
    const mask = buildMask(fileId, data);
    if (mask) result[uiMapId] = mask;
  }
  return result;
};
