// The renderer: the scene's items drawn on the GPU, as the game draws its interface. Every item becomes a few textured
// quads in one vertex buffer, drawn in the scene's order in as few draws as its textures allow; colour, alpha,
// greying, masks and clipping are done per pixel in the shader. Text is laid out and drawn once per string (Canvas
// 2D, the game's own fonts) and kept as a texture until it changes. The GPU itself is WebGPU's (backend.ts, webgpu.ts).
//
// Adding a kind of item: a case in draw that sets the corners, uvs and colour and adds quads with emit().
//
// The hot path (every item, every frame) allocates nothing: the quad being built lives in typed scratch arrays, the
// item's clip and mask in the closure's variables, the draws in a pool of batches reused from frame to frame.
import { type AtlasInfo, getAtlas } from "../atlas.ts";
import { fontFamily } from "../fonts.ts";
import type { BackdropItem, Color, FontStringItem, LineItem, MaskItem, SceneItems, TextureItem } from "../items.ts";
import { parseInlineAtlas, parseInlineTexture, TEXT_CODE } from "../text.ts";
import { artUrl, textureUrl } from "../textures.ts";
import {
  type Backend,
  type Batch,
  type Blend,
  FLAG_ALPHAKEY,
  FLAG_BLACK_U,
  FLAG_BLACK_V,
  FLAG_SOLID,
  FLAG_WHITE_U,
  FLAG_WHITE_V,
  FLOATS,
  flagMask,
  flagMaskBlack,
  flagMaskWhite,
  type GpuTexture,
  GREY_OFFSET,
  MASKS,
  maskOffset,
  SAMPLING,
  type Sampling,
  samplingFor,
  WRAP,
  type Wrap,
} from "./backend.ts";
import { createWebGpuBackend } from "./webgpu.ts";

export type RenderStats = { quads: number; draws: number; ms: number; texts: number };

export type Renderer = {
  readonly stats: RenderStats;
  /** The screen's size in game units and the canvas's pixels per unit */
  resize: (width: number, height: number, pixelsPerUnit: number) => void;
  draw: (items: SceneItems) => void;
  /** An edit box with the focus was drawn (its cursor blinks) */
  hasCursor: () => boolean;
  /** Every string drawn again (the game's fonts arrived after the first were drawn with a stand-in) */
  resetText: () => void;
  blink: () => void;
  /** No picture asked for is still on its way */
  isSettled: () => boolean;
  /** Settles once the GPU has drawn what it was sent */
  finished: () => Promise<void>;
  /** Called once if the GPU is lost: a renderer is made again on a new canvas */
  onLost: (listener: () => void) => void;
  /** The GPU's memory given back at once (the screen is going) */
  dispose: () => void;
};

const FAR = 1e9;
const FULL = [0, 1, 0, 1] as const;
const FULL_WHITE = [1, 1, 1, 1] as const;
const TEXT_KEEP_FRAMES = 600;
const TEXT_SWEEP_FRAMES = 300;

type TextureEntry = {
  state: "loading" | "ready" | "failed";
  texture: GpuTexture | null;
  width: number;
  height: number;
  /** The decoded picture, which text with icons draws from */
  bitmap: ImageBitmap | null;
};
type ReadyTexture = TextureEntry & { texture: GpuTexture };

// Text, as runs of a line: text in a colour, or a picture (a file or an atlas) of a size
type TextRun = { kind: "text"; text: string; color: string | null; width: number; isCursor: boolean };
type PictureRun = {
  kind: "picture";
  url: string | null;
  atlas: string | null;
  w: number;
  h: number;
  dx: number;
  dy: number;
  /** left, right, top, bottom, 0 to 1 */
  crop: readonly number[] | null;
  tint: string | null;
};
type Run = TextRun | PictureRun;
type FontMetrics = { ascent: number; descent: number; xHeight: number };
type LaidLine = { runs: Run[]; x: number; baseline: number };
type TextValue = {
  texture: GpuTexture;
  x: number;
  y: number;
  w: number;
  h: number;
  isComplete: boolean;
  used: number;
};
type TextEntry = { key: string; value: TextValue; resolution: number; cursorOn: boolean; generation: number };
type Picture = { missing: true } | { missing: false; entry: TextureEntry; crop: readonly number[] };

const rgbaText = (color: Color | undefined): string => {
  if (!color) return "rgba(255,255,255,1)";
  const byte = (value: number | null | undefined): number => Math.round((value ?? 1) * 255);
  return `rgba(${byte(color[0])},${byte(color[1])},${byte(color[2])},${color[3] ?? 1})`;
};

/** A renderer on the canvas, drawn with WebGPU; null in a browser without it */
export const createRenderer = async (canvas: HTMLCanvasElement, onArtArrived: () => void): Promise<Renderer | null> => {
  const backend = await createWebGpuBackend(canvas);
  return backend ? createRendererOn(canvas, backend, onArtArrived) : null;
};

const createRendererOn = (canvas: HTMLCanvasElement, backend: Backend, onArtArrived: () => void): Renderer => {
  const white = backend.white;
  const maxTextureSize = backend.maxTextureSize;

  // The quads being built, grown as needed
  let capacity = 0;
  let vertices = new Float32Array(0);
  const ensureCapacity = (quads: number): void => {
    if (quads <= capacity) return;
    capacity = Math.max(quads, capacity * 2, 4096);
    const grown = new Float32Array(capacity * 4 * FLOATS);
    grown.set(vertices);
    vertices = grown;
  };
  ensureCapacity(4096);

  // Textures, by URL: loaded once, kept
  const textures = new Map<string, TextureEntry>();
  let loading = 0;
  let isDisposed = false;
  const loadTexture = async (url: string, entry: TextureEntry): Promise<void> => {
    loading += 1;
    try {
      const response = await fetch(url);
      if (!response.ok) throw new Error(String(response.status));
      let bitmap = await createImageBitmap(await response.blob(), {
        premultiplyAlpha: "premultiply",
        colorSpaceConversion: "none",
      });
      const largest = Math.max(bitmap.width, bitmap.height);
      if (largest > maxTextureSize) {
        // (larger than the GPU takes: made smaller, its uvs unchanged)
        const shrink = maxTextureSize / largest;
        const original = bitmap;
        bitmap = await createImageBitmap(original, {
          resizeWidth: Math.max(1, Math.floor(bitmap.width * shrink)),
          resizeHeight: Math.max(1, Math.floor(bitmap.height * shrink)),
          resizeQuality: "high",
          premultiplyAlpha: "premultiply",
          colorSpaceConversion: "none",
        });
        original.close();
      }
      if (isDisposed) {
        bitmap.close();
        return;
      }
      entry.texture = backend.createTexture(bitmap);
      entry.width = bitmap.width;
      entry.height = bitmap.height;
      entry.bitmap = bitmap;
      entry.state = "ready";
    } catch {
      entry.state = "failed";
    } finally {
      loading -= 1;
    }
    if (!isDisposed) onArtArrived();
  };
  // The texture at a URL when it has arrived; null while it loads or if there is none
  const getTexture = (url: string | null): ReadyTexture | null => {
    if (!url) return null;
    let entry = textures.get(url);
    if (!entry) {
      entry = { state: "loading", texture: null, width: 0, height: 0, bitmap: null };
      textures.set(url, entry);
      void loadTexture(url, entry);
    }
    return entry.state === "ready" ? (entry as ReadyTexture) : null;
  };
  const hasFailed = (url: string | null): boolean => url !== null && textures.get(url)?.state === "failed";

  // The frame being built: quads in order, cut into draws where the texture, mask, sampling or blend changes
  let quadCount = 0;
  const batches: Batch[] = [];
  let batchCount = 0;
  let batch: Batch | null = null;
  /** The quads from here drawn with this texture, sampling and blend, under the item's masks (set by prepareMasks) */
  const begin = (texture: GpuTexture, sampling: Sampling, blend: Blend): void => {
    const mask0 = maskTextures[0] ?? null;
    const mask1 = maskTextures[1] ?? null;
    const mask2 = maskTextures[2] ?? null;
    if (
      batch &&
      batch.isLayer === isDrawingLayer &&
      batch.texture === texture &&
      batch.sampling === sampling &&
      batch.blend === blend &&
      batch.mask0 === mask0 &&
      batch.mask1 === mask1 &&
      batch.mask2 === mask2
    ) {
      return;
    }
    let next = batches[batchCount];
    if (next) {
      next.texture = texture;
      next.sampling = sampling;
      next.blend = blend;
      next.mask0 = mask0;
      next.mask1 = mask1;
      next.mask2 = mask2;
      next.isLayer = isDrawingLayer;
      next.first = quadCount;
      next.count = 0;
    } else {
      next = { isLayer: isDrawingLayer, texture, sampling, blend, mask0, mask1, mask2, first: quadCount, count: 0 };
      batches.push(next);
    }
    batchCount += 1;
    batch = next;
  };

  // The quad being built: corners upper left, upper right, lower left, lower right (x, y each); uvs likewise; one
  // colour, or one per corner
  const corners = new Float64Array(8);
  const uvs = new Float64Array(8);
  const colors = new Float64Array(16);
  let isColorPerCorner = false;
  // The item's clip (x0, y0, x1, y1), flags and mask: where its sheet's piece is and where it is on the screen
  let clipX0 = -FAR;
  let clipY0 = -FAR;
  let clipX1 = FAR;
  let clipY1 = FAR;
  let flags = 0;
  let grey = 0;
  // Drawing into the layer (a flattened frame's regions: put on the screen at its alpha after them)
  let isDrawingLayer = false;
  // The item's masks (up to three): each one's texture; its piece of its sheet (left, top, width, height) and its box on
  // the screen (x, y, w, h); nine-sliced, its margins on the screen (left, top, right, bottom) and as fractions of its
  // piece
  const maskTextures: (GpuTexture | null)[] = [null, null, null];
  let maskCount = 0;
  const maskRects = new Float64Array(MASKS * 4);
  const maskBoxes = new Float64Array(MASKS * 4);
  const maskSliced: boolean[] = [false, false, false];
  let isAnyMaskSliced = false;
  const maskSlicePx = new Float64Array(MASKS * 4);
  const maskSliceUv = new Float64Array(MASKS * 4);
  /** Where a point falls on a mask, 0 to 1 across its piece: piecewise when it is nine-sliced */
  const maskAt = (
    position: number,
    boxStart: number,
    boxSize: number,
    startPx: number,
    endPx: number,
    startUv: number,
    endUv: number,
  ): number => {
    const along = position - boxStart;
    if (along <= startPx) return startPx > 0 ? (along / startPx) * startUv : along / (boxSize || 1);
    if (along >= boxSize - endPx) return endPx > 0 ? 1 - ((boxSize - along) / endPx) * endUv : along / (boxSize || 1);
    const middle = boxSize - startPx - endPx;
    return startUv + ((along - startPx) / (middle || 1)) * (1 - startUv - endUv);
  };

  const setRect = (x: number, y: number, w: number, h: number): void => {
    corners[0] = x;
    corners[1] = y;
    corners[2] = x + w;
    corners[3] = y;
    corners[4] = x;
    corners[5] = y + h;
    corners[6] = x + w;
    corners[7] = y + h;
  };
  const setUvRect = (left: number, right: number, top: number, bottom: number): void => {
    uvs[0] = left;
    uvs[1] = top;
    uvs[2] = right;
    uvs[3] = top;
    uvs[4] = left;
    uvs[5] = bottom;
    uvs[6] = right;
    uvs[7] = bottom;
  };
  const setColor = (r: number, g: number, b: number, a: number): void => {
    colors[0] = r;
    colors[1] = g;
    colors[2] = b;
    colors[3] = a;
    isColorPerCorner = false;
  };
  const setCornerColor = (corner: number, color: readonly number[]): void => {
    const at = corner * 4;
    colors[at] = color[0] ?? 1;
    colors[at + 1] = color[1] ?? 1;
    colors[at + 2] = color[2] ?? 1;
    colors[at + 3] = color[3] ?? 1;
    isColorPerCorner = true;
  };
  /** The vertex colour times the item's alpha (the game multiplies the art by it) */
  const setTint = (vc: Color | undefined, alpha: number): void => {
    if (vc) setColor(vc[0] ?? 1, vc[1] ?? 1, vc[2] ?? 1, (vc[3] ?? 1) * alpha);
    else setColor(1, 1, 1, alpha);
  };
  const setClip = (cl: readonly number[] | undefined): void => {
    if (cl) {
      clipX0 = cl[0] ?? 0;
      clipY0 = cl[1] ?? 0;
      clipX1 = clipX0 + (cl[2] ?? 0);
      clipY1 = clipY0 + (cl[3] ?? 0);
    } else {
      clipX0 = -FAR;
      clipY0 = -FAR;
      clipX1 = FAR;
      clipY1 = FAR;
    }
    flags = 0;
    grey = 0;
    maskCount = 0;
    maskTextures[0] = null;
    maskTextures[1] = null;
    maskTextures[2] = null;
    isAnyMaskSliced = false;
  };
  const isOutside = (x: number, y: number, w: number, h: number): boolean =>
    x >= clipX1 || y >= clipY1 || x + w <= clipX0 || y + h <= clipY0;

  /** The quad as it stands added to the batch begun */
  const quad = (): void => {
    ensureCapacity(quadCount + 1);
    // A straight quad thinner than a pixel of the canvas (a 1-pixel border of a 4K game drawn on a smaller canvas): a
    // pixel wide, as faint as it is thin, so it shows evenly instead of dropping out where it falls between pixels
    let coverage = 1;
    if (
      corners[0] === corners[4] &&
      corners[2] === corners[6] &&
      corners[1] === corners[3] &&
      corners[5] === corners[7]
    ) {
      const pixel = 1 / resolution;
      const width = (corners[2] as number) - (corners[0] as number);
      const height = (corners[5] as number) - (corners[1] as number);
      if (width > 0 && width < pixel) {
        const middle = ((corners[0] as number) + (corners[2] as number)) / 2;
        corners[0] = corners[4] = middle - pixel / 2;
        corners[2] = corners[6] = middle + pixel / 2;
        coverage *= width / pixel;
      }
      if (height > 0 && height < pixel) {
        const middle = ((corners[1] as number) + (corners[5] as number)) / 2;
        corners[1] = corners[3] = middle - pixel / 2;
        corners[5] = corners[7] = middle + pixel / 2;
        coverage *= height / pixel;
      }
    }
    let at = quadCount * 4 * FLOATS;
    for (let corner = 0; corner < 4; corner++) {
      const x = corners[corner * 2] as number;
      const y = corners[corner * 2 + 1] as number;
      const color = isColorPerCorner ? corner * 4 : 0;
      vertices[at] = x;
      vertices[at + 1] = y;
      vertices[at + 2] = uvs[corner * 2] as number;
      vertices[at + 3] = uvs[corner * 2 + 1] as number;
      vertices[at + 4] = colors[color] as number;
      vertices[at + 5] = colors[color + 1] as number;
      vertices[at + 6] = colors[color + 2] as number;
      vertices[at + 7] = (colors[color + 3] as number) * coverage;
      for (let mask = 0; mask < MASKS; mask++) {
        const to = at + maskOffset(mask);
        if (mask >= maskCount) {
          vertices[to] = 0;
          vertices[to + 1] = 0;
          vertices[to + 2] = 0;
          vertices[to + 3] = 0;
          vertices[to + 4] = 1;
          vertices[to + 5] = 1;
          continue;
        }
        const box = mask * 4;
        if (maskSliced[mask]) {
          vertices[to] = maskAt(
            x,
            maskBoxes[box] as number,
            maskBoxes[box + 2] as number,
            maskSlicePx[box] as number,
            maskSlicePx[box + 2] as number,
            maskSliceUv[box] as number,
            maskSliceUv[box + 2] as number,
          );
          vertices[to + 1] = maskAt(
            y,
            maskBoxes[box + 1] as number,
            maskBoxes[box + 3] as number,
            maskSlicePx[box + 1] as number,
            maskSlicePx[box + 3] as number,
            maskSliceUv[box + 1] as number,
            maskSliceUv[box + 3] as number,
          );
        } else {
          vertices[to] = (x - (maskBoxes[box] as number)) / (maskBoxes[box + 2] || 1);
          vertices[to + 1] = (y - (maskBoxes[box + 1] as number)) / (maskBoxes[box + 3] || 1);
        }
        vertices[to + 2] = maskRects[box] as number;
        vertices[to + 3] = maskRects[box + 1] as number;
        vertices[to + 4] = maskRects[box + 2] as number;
        vertices[to + 5] = maskRects[box + 3] as number;
      }
      vertices[at + 8] = clipX0;
      vertices[at + 9] = clipY0;
      vertices[at + 10] = clipX1;
      vertices[at + 11] = clipY1;
      vertices[at + 12] = flags;
      vertices[at + GREY_OFFSET] = grey;
      at += FLOATS;
    }
    quadCount += 1;
    (batch as Batch).count += 1;
  };

  /** A wrap mode's letter (scene.lua: r repeats, m mirrors; b, w and c clamp, b and w by the shader's flags) */
  const wrapOf = (letter: string | undefined): Wrap =>
    letter === "r" ? WRAP.repeat : letter === "m" ? WRAP.mirror : WRAP.clamp;
  const wrapFlags = (wr: string | undefined): number => {
    if (!wr) return 0;
    return (
      (wr[0] === "b" ? FLAG_BLACK_U : wr[0] === "w" ? FLAG_WHITE_U : 0) |
      (wr[1] === "b" ? FLAG_BLACK_V : wr[1] === "w" ? FLAG_WHITE_V : 0)
    );
  };

  /** The game's blend mode: how the GPU blends, and the shader's flags for the texel (ALPHAKEY, DISABLE) */
  const blendOf = (blend: string | undefined): Blend => (blend === "ADD" ? "add" : blend === "MOD" ? "mod" : "blend");
  const blendFlags = (blend: string | undefined): number =>
    blend === "ALPHAKEY" ? FLAG_ALPHAKEY : blend === "DISABLE" ? FLAG_SOLID : 0;

  // One mask over a texture: its texture (or an atlas's piece of a sheet), where it is on the screen, its slices and
  // what lies past it. False while its art loads: the item waits for it rather than flash unmasked
  const prepareMask = (mask: MaskItem): boolean => {
    const index = maskCount;
    const at = index * 4;
    let entry: ReadyTexture | null;
    if (mask.atlas) {
      const atlas = getAtlas(mask.atlas);
      if (atlas === undefined) return false;
      if (!atlas) return true;
      entry = getTexture(artUrl(atlas.fdid));
      maskRects[at] = atlas.left;
      maskRects[at + 1] = atlas.top;
      maskRects[at + 2] = atlas.right - atlas.left;
      maskRects[at + 3] = atlas.bottom - atlas.top;
    } else {
      const url = textureUrl(mask.tex);
      entry = getTexture(url);
      if (!url || hasFailed(url)) return true;
      maskRects[at] = 0;
      maskRects[at + 1] = 0;
      maskRects[at + 2] = 1;
      maskRects[at + 3] = 1;
    }
    if (!entry) return false;
    maskTextures[index] = entry.texture;
    maskCount += 1;
    flags |=
      flagMask(index) | (mask.wr === "white" ? flagMaskWhite(index) : mask.wr === "black" ? flagMaskBlack(index) : 0);
    const box = mask.b;
    maskBoxes[at] = box[0] ?? 0;
    maskBoxes[at + 1] = box[1] ?? 0;
    maskBoxes[at + 2] = box[2] ?? 0;
    maskBoxes[at + 3] = box[3] ?? 0;
    maskSliced[index] = false;
    const slice = mask.sl;
    if (slice) {
      // Its piece's size in texels: the whole file, or the atlas's part of its sheet
      const pieceWidth = entry.width * (maskRects[at + 2] as number);
      const pieceHeight = entry.height * (maskRects[at + 3] as number);
      const scale = mask.sc || 1;
      const left = slice[0] ?? 0;
      const top = slice[1] ?? 0;
      const right = slice[2] ?? 0;
      const bottom = slice[3] ?? 0;
      if (pieceWidth > 0 && pieceHeight > 0 && left + top + right + bottom > 0) {
        // Corners at their own size, shrunk together when the mask is smaller than its margins (as the client)
        const fit = Math.min(
          1,
          (maskBoxes[at + 2] as number) / ((left + right) * scale || 1),
          (maskBoxes[at + 3] as number) / ((top + bottom) * scale || 1),
        );
        maskSlicePx[at] = left * scale * fit;
        maskSlicePx[at + 1] = top * scale * fit;
        maskSlicePx[at + 2] = right * scale * fit;
        maskSlicePx[at + 3] = bottom * scale * fit;
        maskSliceUv[at] = left / pieceWidth;
        maskSliceUv[at + 1] = top / pieceHeight;
        maskSliceUv[at + 2] = right / pieceWidth;
        maskSliceUv[at + 3] = bottom / pieceHeight;
        maskSliced[index] = true;
        isAnyMaskSliced = true;
      }
    }
    return true;
  };
  /** The item's masks made ready (flags set after: setClip cleared them); false while one's art loads */
  const prepareMasks = (item: TextureItem): boolean => {
    const masks = item.mk;
    if (!masks) return true;
    for (let index = 0; index < masks.length && maskCount < MASKS; index++) {
      if (!prepareMask(masks[index] as MaskItem)) return false;
    }
    return true;
  };

  // A quad under nine-sliced masks, cut at their slice lines: a mask is placed piecewise, so each piece is drawn on its
  // own (its texture coordinates and colours shared out as they lie across the quad). A turned quad is
  // drawn whole.
  const cuts: number[] = [];
  const cutsY: number[] = [];
  const savedCorners = new Float64Array(8);
  const savedUvs = new Float64Array(8);
  const savedColors = new Float64Array(16);
  // (the corners' values blended for a point at fractions s across and t down: upper left, upper right, lower left,
  // lower right)
  const bilinear = (values: Float64Array, stride: number, offset: number, s: number, t: number): number =>
    (values[offset] as number) * (1 - s) * (1 - t) +
    (values[stride + offset] as number) * s * (1 - t) +
    (values[stride * 2 + offset] as number) * (1 - s) * t +
    (values[stride * 3 + offset] as number) * s * t;
  /** Sorted cut lines without the ones a hair from the one before (two masks cut at the same line) */
  const dropRepeats = (lines: number[]): void => {
    let kept = 1;
    for (let index = 1; index < lines.length; index++) {
      if ((lines[index] as number) - (lines[kept - 1] as number) > 0.01) lines[kept++] = lines[index] as number;
    }
    lines.length = kept;
  };
  const emit = (): void => {
    if (!isAnyMaskSliced) {
      quad();
      return;
    }
    const x0 = corners[0] as number;
    const y0 = corners[1] as number;
    const x1 = corners[6] as number;
    const y1 = corners[7] as number;
    const isAxisAligned = corners[2] === x1 && corners[3] === y0 && corners[4] === x0 && corners[5] === y1;
    if (!isAxisAligned || x1 <= x0 || y1 <= y0) {
      quad();
      return;
    }
    cuts.length = 0;
    cutsY.length = 0;
    cuts.push(x0);
    cutsY.push(y0);
    for (let mask = 0; mask < maskCount; mask++) {
      if (!maskSliced[mask]) continue;
      const at = mask * 4;
      const cutX0 = (maskBoxes[at] as number) + (maskSlicePx[at] as number);
      const cutX1 = (maskBoxes[at] as number) + (maskBoxes[at + 2] as number) - (maskSlicePx[at + 2] as number);
      if (cutX0 > x0 + 0.01 && cutX0 < x1 - 0.01) cuts.push(cutX0);
      if (cutX1 > x0 + 0.01 && cutX1 < x1 - 0.01) cuts.push(cutX1);
      const cutY0 = (maskBoxes[at + 1] as number) + (maskSlicePx[at + 1] as number);
      const cutY1 = (maskBoxes[at + 1] as number) + (maskBoxes[at + 3] as number) - (maskSlicePx[at + 3] as number);
      if (cutY0 > y0 + 0.01 && cutY0 < y1 - 0.01) cutsY.push(cutY0);
      if (cutY1 > y0 + 0.01 && cutY1 < y1 - 0.01) cutsY.push(cutY1);
    }
    cuts.push(x1);
    cutsY.push(y1);
    if (cuts.length === 2 && cutsY.length === 2) {
      quad();
      return;
    }
    cuts.sort((a, b) => a - b);
    cutsY.sort((a, b) => a - b);
    dropRepeats(cuts);
    dropRepeats(cutsY);
    savedCorners.set(corners);
    savedUvs.set(uvs);
    savedColors.set(colors);
    const perCorner = isColorPerCorner;
    for (let row = 0; row + 1 < cutsY.length; row++) {
      for (let column = 0; column + 1 < cuts.length; column++) {
        const left = cuts[column] as number;
        const right = cuts[column + 1] as number;
        const top = cutsY[row] as number;
        const bottom = cutsY[row + 1] as number;
        setRect(left, top, right - left, bottom - top);
        for (let corner = 0; corner < 4; corner++) {
          const s = ((corner % 2 === 0 ? left : right) - x0) / (x1 - x0);
          const t = ((corner < 2 ? top : bottom) - y0) / (y1 - y0);
          uvs[corner * 2] = bilinear(savedUvs, 2, 0, s, t);
          uvs[corner * 2 + 1] = bilinear(savedUvs, 2, 1, s, t);
          if (perCorner) {
            for (let channel = 0; channel < 4; channel++) {
              colors[corner * 4 + channel] = bilinear(savedColors, 4, channel, s, t);
            }
          }
        }
        isColorPerCorner = perCorner;
        quad();
      }
    }
    corners.set(savedCorners);
    uvs.set(savedUvs);
    colors.set(savedColors);
    isColorPerCorner = perCorner;
  };

  // Corners turned about the box's middle by -rot (the game turns counter-clockwise), or moved to the shape the
  // texture's corners were given (SetVertexOffset: fractions of the box)
  const placeCorners = (item: TextureItem, x: number, y: number, w: number, h: number): void => {
    const p = item.poly;
    if (p) {
      // (upper left, upper right, lower right, lower left)
      corners[0] = x + (p[0] ?? 0) * w;
      corners[1] = y + (p[1] ?? 0) * h;
      corners[2] = x + (p[2] ?? 0) * w;
      corners[3] = y + (p[3] ?? 0) * h;
      corners[4] = x + (p[6] ?? 0) * w;
      corners[5] = y + (p[7] ?? 0) * h;
      corners[6] = x + (p[4] ?? 0) * w;
      corners[7] = y + (p[5] ?? 0) * h;
    } else {
      setRect(x, y, w, h);
    }
    if (item.rot) {
      const cx = x + w / 2;
      const cy = y + h / 2;
      const cos = Math.cos(item.rot);
      const sin = Math.sin(item.rot);
      for (let at = 0; at < 8; at += 2) {
        const dx = (corners[at] as number) - cx;
        const dy = (corners[at + 1] as number) - cy;
        corners[at] = cx + dx * cos + dy * sin;
        corners[at + 1] = cy - dx * sin + dy * cos;
      }
    }
  };

  // A sweep of the box (a cooldown's swipe, a radial progress bar: pie, from and to in turns clockwise from the top):
  // triangles from its middle to its edge, cut at the corners, each point's uv and colour where it lies in the box
  const pieCuts: number[] = [];
  const drawPie = (x: number, y: number, w: number, h: number, from: number, to: number): void => {
    if (to <= from || w <= 0 || h <= 0) return;
    savedUvs.set(uvs);
    savedColors.set(colors);
    const perCorner = isColorPerCorner;
    const cx = x + w / 2;
    const cy = y + h / 2;
    const corner = Math.atan2(w / 2, h / 2) / (Math.PI * 2);
    pieCuts.length = 0;
    pieCuts.push(from);
    for (const cut of [corner, 0.5 - corner, 0.5 + corner, 1 - corner]) if (cut > from && cut < to) pieCuts.push(cut);
    pieCuts.push(to);
    // a point on the box's edge at a turn, its place across the box (s, t from the upper left) into corners[at]
    const edgeAt = (turn: number, at: number): void => {
      const angle = turn * Math.PI * 2;
      const dx = Math.sin(angle);
      const dy = -Math.cos(angle);
      const reach = Math.min(
        Math.abs(dx) > 1e-9 ? w / 2 / Math.abs(dx) : FAR,
        Math.abs(dy) > 1e-9 ? h / 2 / Math.abs(dy) : FAR,
      );
      corners[at] = cx + dx * reach;
      corners[at + 1] = cy + dy * reach;
    };
    const shade = (corner: number): void => {
      const s = ((corners[corner * 2] as number) - x) / w;
      const t = ((corners[corner * 2 + 1] as number) - y) / h;
      uvs[corner * 2] = bilinear(savedUvs, 2, 0, s, t);
      uvs[corner * 2 + 1] = bilinear(savedUvs, 2, 1, s, t);
      if (perCorner) {
        for (let channel = 0; channel < 4; channel++)
          colors[corner * 4 + channel] = bilinear(savedColors, 4, channel, s, t);
      }
    };
    for (let index = 0; index + 1 < pieCuts.length; index++) {
      // (a triangle: the middle, and two points of the edge; its fourth corner the third's again)
      corners[0] = cx;
      corners[1] = cy;
      edgeAt(pieCuts[index] as number, 2);
      edgeAt(pieCuts[index + 1] as number, 4);
      corners[6] = corners[4] as number;
      corners[7] = corners[5] as number;
      for (let each = 0; each < 4; each++) shade(each);
      isColorPerCorner = perCorner;
      quad();
    }
    uvs.set(savedUvs);
    colors.set(savedColors);
    isColorPerCorner = perCorner;
  };
  /** The item's quad as its box (turned, or its corners moved), or only its sweep */
  const place = (item: TextureItem, x: number, y: number, w: number, h: number): void => {
    const pie = item.pie;
    if (pie && !item.rot && !item.poly) {
      drawPie(x, y, w, h, pie[0] ?? 0, pie[1] ?? 1);
      return;
    }
    placeCorners(item, x, y, w, h);
    emit();
  };

  // Nine-sliced, as the game draws it: corners at their own size, edges and middle stretched (or, in tiled mode, repeated
  // at their own size from the corners on, the last piece cut short)
  const TILES_MOST = 400;
  const drawSlices = (item: TextureItem, atlas: AtlasInfo, slice: readonly number[]): void => {
    const isTiled = item.slm === 1;
    const scale = item.sc || 1;
    const marginLeft = slice[0] ?? 0;
    const marginTop = slice[1] ?? 0;
    const marginRight = slice[2] ?? 0;
    const marginBottom = slice[3] ?? 0;
    const fileWidth = atlas.width / (atlas.right - atlas.left);
    const fileHeight = atlas.height / (atlas.bottom - atlas.top);
    // Corners shrink together when the texture is smaller than its margins
    const fit = Math.min(
      1,
      item.w / ((marginLeft + marginRight) * scale || 1),
      item.h / ((marginTop + marginBottom) * scale || 1),
    );
    const left = marginLeft * scale * fit;
    const right = marginRight * scale * fit;
    const top = marginTop * scale * fit;
    const bottom = marginBottom * scale * fit;
    for (let row = 0; row < 3; row++) {
      const sourceY = row === 0 ? 0 : row === 1 ? marginTop : atlas.height - marginBottom;
      const sourceHeight = row === 0 ? marginTop : row === 1 ? atlas.height - marginTop - marginBottom : marginBottom;
      const y = row === 0 ? 0 : row === 1 ? top : item.h - bottom;
      const height = row === 0 ? top : row === 1 ? item.h - top - bottom : bottom;
      if (height <= 0) continue;
      for (let column = 0; column < 3; column++) {
        const sourceX = column === 0 ? 0 : column === 1 ? marginLeft : atlas.width - marginRight;
        const sourceWidth =
          column === 0 ? marginLeft : column === 1 ? atlas.width - marginLeft - marginRight : marginRight;
        const x = column === 0 ? 0 : column === 1 ? left : item.w - right;
        const width = column === 0 ? left : column === 1 ? item.w - left - right : right;
        if (width <= 0) continue;
        const u0 = atlas.left + sourceX / fileWidth;
        const v0 = atlas.top + sourceY / fileHeight;
        const u1 = u0 + sourceWidth / fileWidth;
        const v1 = v0 + sourceHeight / fileHeight;
        // (a piece's own size on the screen: an edge or the middle repeats at it when tiled)
        const tileWidth = sourceWidth * scale * fit;
        const tileHeight = sourceHeight * scale * fit;
        const tilesAcross = isTiled && column === 1 && tileWidth > 0.5 ? Math.ceil(width / tileWidth - 0.001) : 1;
        const tilesDown = isTiled && row === 1 && tileHeight > 0.5 ? Math.ceil(height / tileHeight - 0.001) : 1;
        if (tilesAcross * tilesDown <= 1 || tilesAcross * tilesDown > TILES_MOST) {
          setRect(item.x + x, item.y + y, width, height);
          setUvRect(u0, u1, v0, v1);
          emit();
          continue;
        }
        for (let down = 0; down < tilesDown; down++) {
          const pieceY = tilesDown > 1 ? down * tileHeight : 0;
          const pieceHeight = tilesDown > 1 ? Math.min(tileHeight, height - pieceY) : height;
          const pieceV1 = tilesDown > 1 ? v0 + (v1 - v0) * (pieceHeight / tileHeight) : v1;
          for (let across = 0; across < tilesAcross; across++) {
            const pieceX = tilesAcross > 1 ? across * tileWidth : 0;
            const pieceWidth = tilesAcross > 1 ? Math.min(tileWidth, width - pieceX) : width;
            const pieceU1 = tilesAcross > 1 ? u0 + (u1 - u0) * (pieceWidth / tileWidth) : u1;
            setRect(item.x + x + pieceX, item.y + y + pieceY, pieceWidth, pieceHeight);
            setUvRect(u0, pieceU1, v0, pieceV1);
            emit();
          }
        }
      }
    }
  };

  const drawTexture = (item: TextureItem): void => {
    setClip(item.cl);
    const { x, y } = item;
    let { w, h } = item;
    if (item.seam) {
      // Map tiles overlap a hair, so no seams show
      w += 1;
      h += 1;
    }
    if (w <= 0 || h <= 0 || isOutside(x, y, w, h)) return;
    const blend = blendOf(item.bl);
    flags = blendFlags(item.bl);
    grey = item.ds === true ? 1 : typeof item.ds === "number" ? item.ds : 0;
    if (!prepareMasks(item)) return;
    const alpha = item.a ?? 1;
    const c = item.c;
    if (item.gr && (c || (item.tex === undefined && !item.atlas))) {
      // A gradient tints its colour from one end to the other, as vertex colours do in the game
      const base = c ?? FULL_WHITE;
      const tint = (color: Color): number[] => [
        (base[0] ?? 1) * (color[0] ?? 1),
        (base[1] ?? 1) * (color[1] ?? 1),
        (base[2] ?? 1) * (color[2] ?? 1),
        (base[3] ?? 1) * (color[3] ?? 1) * alpha,
      ];
      const from = tint(item.gr.from);
      const to = tint(item.gr.to);
      const isHorizontal = item.gr.orientation === "HORIZONTAL";
      setCornerColor(0, isHorizontal ? from : to);
      setCornerColor(1, to);
      setCornerColor(2, from);
      setCornerColor(3, isHorizontal ? to : from);
      begin(white, SAMPLING.flat, blend);
      setUvRect(0, 1, 0, 1);
      place(item, x, y, w, h);
      return;
    }
    if (c) {
      const vc = item.vc;
      setColor(
        (c[0] ?? 1) * (vc?.[0] ?? 1),
        (c[1] ?? 1) * (vc?.[1] ?? 1),
        (c[2] ?? 1) * (vc?.[2] ?? 1),
        (c[3] ?? 1) * (vc?.[3] ?? 1) * alpha,
      );
      begin(white, SAMPLING.flat, blend);
      setUvRect(0, 1, 0, 1);
      place(item, x, y, w, h);
      return;
    }
    if (item.atlas) {
      const atlas = getAtlas(item.atlas);
      if (!atlas) return; // (loading, or none)
      const sheet = getTexture(artUrl(atlas.fdid));
      if (!sheet) return;
      setTint(item.vc, alpha);
      begin(sheet.texture, SAMPLING.clamp, blend);
      if (atlas.slice) {
        drawSlices(item, atlas, atlas.slice);
        return;
      }
      // Coordinates set after the atlas are the atlas's own, 0 to 1 across it, as in the game (the game's top tabs
      // turn theirs over with 0, 1, 1, 0): a part of the atlas, or the atlas turned over
      const tc = item.tc && !item.tcTurned ? item.tc : FULL;
      const spanX = atlas.right - atlas.left;
      const spanY = atlas.bottom - atlas.top;
      setUvRect(
        atlas.left + (tc[0] ?? 0) * spanX,
        atlas.left + (tc[1] ?? 1) * spanX,
        atlas.top + (tc[2] ?? 0) * spanY,
        atlas.top + (tc[3] ?? 1) * spanY,
      );
      place(item, x, y, w, h);
      return;
    }
    if (item.tex === undefined || item.tex === null) return;
    const texture = getTexture(textureUrl(item.tex));
    if (!texture) return;
    const tc = item.tc ?? FULL;
    const left = tc[0] ?? 0;
    const right = tc[1] ?? 1;
    const top = tc[2] ?? 0;
    const bottom = tc[3] ?? 1;
    // Past its edges each way as its wrap modes say (the client's default clamps); tiled, it repeats
    let across: Wrap = wrapOf(item.wr?.[0]);
    let down: Wrap = wrapOf(item.wr?.[1]);
    flags |= wrapFlags(item.wr);
    if (item.tcTurned) {
      // Turned a quarter (the game's backdrop edges): u runs down the screen, v across it (left, right, top, bottom
      // are u at the top, u at the bottom, v at the left, v at the right)
      uvs[0] = left;
      uvs[1] = top;
      uvs[2] = left;
      uvs[3] = bottom;
      uvs[4] = right;
      uvs[5] = top;
      uvs[6] = right;
      uvs[7] = bottom;
    } else if (item.tile && (item.tile[0] || item.tile[1])) {
      // Tiled: the art at its own size, repeated across the box from its upper left
      const spanX = item.tile[0] ? w / texture.width : right - left;
      const spanY = item.tile[1] ? h / texture.height : bottom - top;
      setUvRect(left, left + spanX, top, top + spanY);
      if (item.tile[0]) across = WRAP.repeat;
      if (item.tile[1]) down = WRAP.repeat;
    } else {
      setUvRect(left, right, top, bottom);
    }
    setTint(item.vc, alpha);
    begin(texture.texture, samplingFor(across, down), blend);
    if (item.sl && !item.tcTurned && !item.rot && !item.poly) {
      // Nine-sliced (SetTextureSliceMargins): the texture's part (its coordinates) as an atlas's piece of a sheet
      drawSlices(
        item,
        {
          left,
          right,
          top,
          bottom,
          width: texture.width * (right - left),
          height: texture.height * (bottom - top),
        } as AtlasInfo,
        item.sl,
      );
      return;
    }
    place(item, x, y, w, h);
  };

  // A backdrop: the background, tiled or stretched, and the classic eight-piece edge (left, right, top, bottom, then
  // the four corners, each an eighth of the edge file; the top and bottom stored turned on their side)
  const drawBackdrop = (item: BackdropItem): void => {
    setClip(item.cl);
    if (isOutside(item.x, item.y, item.w, item.h)) return;
    const alpha = item.a ?? 1;
    const insets = item.ins ?? {};
    if (item.bg) {
      const texture = getTexture(textureUrl(item.bg));
      if (texture) {
        const bx = item.x + (insets.left || 0);
        const by = item.y + (insets.top || 0);
        const bw = item.w - (insets.left || 0) - (insets.right || 0);
        const bh = item.h - (insets.top || 0) - (insets.bottom || 0);
        const isTiled = Boolean(item.tile && item.ts);
        const tileSize = item.ts ?? 1;
        setTint(item.c, alpha);
        begin(texture.texture, isTiled ? SAMPLING.repeat : SAMPLING.clamp, "blend");
        if (bw > 0 && bh > 0) {
          setRect(bx, by, bw, bh);
          setUvRect(0, isTiled ? bw / tileSize : 1, 0, isTiled ? bh / tileSize : 1);
          quad();
        }
      }
    }
    if (!item.edge) return;
    const texture = getTexture(textureUrl(item.edge));
    if (!texture) return;
    setTint(item.bc, alpha);
    const edge = Math.min(item.es || 16, item.w / 2, item.h / 2);
    begin(texture.texture, SAMPLING.repeat, "blend");
    const { x, y, w, h } = item;
    const lengthX = w - 2 * edge;
    const lengthY = h - 2 * edge;
    // Left and right: the strip repeated down
    if (lengthY > 0) {
      setRect(x, y + edge, edge, lengthY);
      setUvRect(0 / 8, 1 / 8, 0, lengthY / edge);
      quad();
      setRect(x + w - edge, y + edge, edge, lengthY);
      setUvRect(1 / 8, 2 / 8, 0, lengthY / edge);
      quad();
    }
    // Top and bottom: the strip turned so its left side is at the top, repeated across
    if (lengthX > 0) {
      const repeat = lengthX / edge;
      for (let piece = 2; piece <= 3; piece++) {
        const u0 = piece / 8;
        const u1 = (piece + 1) / 8;
        setRect(x + edge, piece === 2 ? y : y + h - edge, lengthX, edge);
        uvs[0] = u0;
        uvs[1] = repeat;
        uvs[2] = u0;
        uvs[3] = 0;
        uvs[4] = u1;
        uvs[5] = repeat;
        uvs[6] = u1;
        uvs[7] = 0;
        quad();
      }
    }
    // The corners: upper left, upper right, lower left, lower right
    for (let piece = 4; piece <= 7; piece++) {
      const isRight = piece === 5 || piece === 7;
      const isBottom = piece >= 6;
      setRect(isRight ? x + w - edge : x, isBottom ? y + h - edge : y, edge, edge);
      setUvRect(piece / 8, (piece + 1) / 8, 0, 1);
      quad();
    }
  };

  const drawLine = (item: LineItem): void => {
    const dx = item.x2 - item.x1;
    const dy = item.y2 - item.y1;
    const length = Math.hypot(dx, dy);
    if (length <= 0) return;
    const half = (item.th || 1) / 2;
    const nx = (-dy / length) * half;
    const ny = (dx / length) * half;
    corners[0] = item.x1 + nx;
    corners[1] = item.y1 + ny;
    corners[2] = item.x2 + nx;
    corners[3] = item.y2 + ny;
    corners[4] = item.x1 - nx;
    corners[5] = item.y1 - ny;
    corners[6] = item.x2 - nx;
    corners[7] = item.y2 - ny;
    setClip(item.cl);
    setUvRect(0, 1, 0, 1);
    const alpha = item.a ?? 1;
    if (item.tex) {
      const texture = getTexture(textureUrl(item.tex));
      if (!texture) return;
      setTint(item.vc, alpha);
      begin(texture.texture, SAMPLING.clamp, "blend");
    } else {
      const c = item.c ?? FULL_WHITE;
      setColor(c[0] ?? 1, c[1] ?? 1, c[2] ?? 1, (c[3] ?? 1) * alpha);
      begin(white, SAMPLING.flat, "blend");
    }
    quad();
  };

  // Text: each string laid out as the game lays it out (lines as Lua wrapped them, colour codes, inline icons, shadow
  // and outline) on a canvas at the screen's resolution, kept as a texture by what it shows
  const textCanvas = document.createElement("canvas");
  const textContext = textCanvas.getContext("2d", { willReadFrequently: false }) as CanvasRenderingContext2D;
  const tintCanvas = document.createElement("canvas");
  const tintContext = tintCanvas.getContext("2d") as CanvasRenderingContext2D;
  const textCache = new Map<string, TextValue>();
  let frameNumber = 0;
  let resolution = 1;
  let isCursorOn = true;
  let textGeneration = 0;
  const fontMetrics = new Map<string, FontMetrics>();
  const metricsOf = (font: string): FontMetrics => {
    let metrics = fontMetrics.get(font);
    if (!metrics) {
      textContext.font = font;
      const sample = textContext.measureText("Hg");
      const ex = textContext.measureText("x");
      metrics = {
        ascent: sample.fontBoundingBoxAscent,
        descent: sample.fontBoundingBoxDescent,
        xHeight: ex.actualBoundingBoxAscent,
      };
      // (kept once the fonts are in: measured before, they were the stand-in's)
      if (document.fonts.status === "loaded") fontMetrics.set(font, metrics);
    }
    return metrics;
  };

  const parseLine = (line: string, colorStack: string[], lineHeight: number): Run[] => {
    const runs: Run[] = [];
    let last = 0;
    const color = (): string | null => {
      const top = colorStack[colorStack.length - 1];
      return top ? `#${top.slice(2)}` : null;
    };
    const addText = (text: string): void => {
      if (text) runs.push({ kind: "text", text, color: color(), width: 0, isCursor: false });
    };
    TEXT_CODE.lastIndex = 0;
    for (let match = TEXT_CODE.exec(line); match; match = TEXT_CODE.exec(line)) {
      addText(line.slice(last, match.index));
      last = TEXT_CODE.lastIndex;
      const token = match[0];
      if (match[1]) colorStack.push(match[1]);
      else if (token === "|r") colorStack.pop();
      else if (token === "||") addText("|");
      else if (match[2] !== undefined) {
        const texture = parseInlineTexture(match[2], lineHeight);
        const crop = texture.crop;
        runs.push({
          kind: "picture",
          url: texture.url,
          atlas: null,
          w: texture.w,
          h: texture.h,
          dx: texture.dx,
          dy: texture.dy,
          crop: crop
            ? [
                crop.left / crop.fileWidth,
                crop.right / crop.fileWidth,
                crop.top / crop.fileHeight,
                crop.bottom / crop.fileHeight,
              ]
            : null,
          tint: texture.tint,
        });
      } else if (match[3] !== undefined) {
        const { name, w, h } = parseInlineAtlas(match[3], lineHeight);
        runs.push({ kind: "picture", url: null, atlas: name, w, h, dx: 0, dy: 0, crop: null, tint: null });
      }
    }
    addText(line.slice(last));
    return runs;
  };

  // A picture in a line: its texture's decoded image and its piece; null while it loads
  const pictureOf = (run: PictureRun): Picture | null => {
    if (run.atlas !== null) {
      const atlas = getAtlas(run.atlas);
      if (atlas === undefined) return null;
      if (!atlas) return { missing: true };
      const url = artUrl(atlas.fdid);
      const entry = getTexture(url);
      if (!entry) return hasFailed(url) ? { missing: true } : null;
      return { missing: false, entry, crop: [atlas.left, atlas.right, atlas.top, atlas.bottom] };
    }
    const entry = getTexture(run.url);
    if (!entry) return hasFailed(run.url) ? { missing: true } : null;
    return { missing: false, entry, crop: run.crop ?? FULL };
  };
  const drawPicture = (
    context: CanvasRenderingContext2D,
    entry: TextureEntry,
    crop: readonly number[],
    run: PictureRun,
    x: number,
    y: number,
    scale: number,
  ): void => {
    const bitmap = entry.bitmap;
    if (!bitmap) return;
    const left = crop[0] ?? 0;
    const right = crop[1] ?? 1;
    const top = crop[2] ?? 0;
    const bottom = crop[3] ?? 1;
    const sx = Math.min(left, right) * bitmap.width;
    const sy = Math.min(top, bottom) * bitmap.height;
    const sw = Math.max(1, Math.abs(right - left) * bitmap.width);
    const sh = Math.max(1, Math.abs(bottom - top) * bitmap.height);
    if (!run.tint) {
      context.drawImage(bitmap, sx, sy, sw, sh, x, y, run.w, run.h);
      return;
    }
    // Tinted: the colour seen through the picture's shape
    const pw = Math.max(1, Math.ceil(run.w * scale));
    const ph = Math.max(1, Math.ceil(run.h * scale));
    tintCanvas.width = pw;
    tintCanvas.height = ph;
    tintContext.globalCompositeOperation = "source-over";
    tintContext.drawImage(bitmap, sx, sy, sw, sh, 0, 0, pw, ph);
    tintContext.globalCompositeOperation = "source-in";
    tintContext.fillStyle = run.tint;
    tintContext.fillRect(0, 0, pw, ph);
    context.drawImage(tintCanvas, x, y, run.w, run.h);
  };

  const textKey = (item: FontStringItem): string =>
    JSON.stringify([
      item.lines,
      item.f,
      item.fs,
      item.fl,
      item.c,
      item.jh,
      item.jv,
      item.lh,
      item.sp,
      item.sh,
      item.shc,
      item.ag,
      item.w,
      item.h,
      item.cursor && isCursorOn,
      resolution,
    ]);

  const layoutText = (item: FontStringItem) => {
    const font = `${item.fs}px ${fontFamily(item.f)}`;
    const metrics = metricsOf(font);
    textContext.font = font;
    const colorStack: string[] = [];
    const lines = item.lines.map((line) => parseLine(line, colorStack, item.lh));
    if (item.cursor && isCursorOn) {
      if (lines.length === 0) lines.push([]);
      (lines[lines.length - 1] as Run[]).push({ kind: "text", text: "|", color: null, width: 0, isCursor: true });
    }
    const lineHeight = item.lh;
    const gap = item.sp || 0;
    const total = lines.length * lineHeight + Math.max(0, lines.length - 1) * gap;
    const startY = item.jv === "TOP" ? 0 : item.jv === "BOTTOM" ? item.h - total : (item.h - total) / 2;
    let minX = 0;
    let maxX = item.w;
    let minY = Math.min(0, startY);
    let maxY = Math.max(item.h, startY + total);
    // Centred in its line: the font's ascent and descent rounded to pixels, the room left shared out above and below
    // (the upper share rounded down)
    const ascent = Math.round(metrics.ascent);
    const descent = Math.round(metrics.descent);
    const laid: LaidLine[] = lines.map((runs, index) => {
      let width = 0;
      for (const run of runs) {
        if (run.kind === "text") {
          run.width = textContext.measureText(run.text).width + (run.isCursor ? 1 : 0);
          width += run.width;
        } else width += run.w;
      }
      const lineTop = startY + index * (lineHeight + gap);
      const baseline = lineTop + Math.floor((lineHeight - (ascent + descent)) / 2) + ascent;
      let x = item.jh === "LEFT" ? 0 : item.jh === "RIGHT" ? item.w - width : (item.w - width) / 2;
      if (width > item.w) x = 0; // too long for its box: from the start, running over the end
      minX = Math.min(minX, x);
      maxX = Math.max(maxX, x + width);
      minY = Math.min(minY, baseline - metrics.ascent - 2);
      maxY = Math.max(maxY, baseline + metrics.descent + 2);
      for (const run of runs) {
        if (run.kind === "picture") {
          const top = baseline - metrics.xHeight / 2 - run.h / 2 + run.dy;
          minY = Math.min(minY, top);
          maxY = Math.max(maxY, top + run.h);
        }
      }
      return { runs, x, baseline };
    });
    const margin = 2 + Math.max(Math.abs(item.sh?.[0] ?? 0), Math.abs(item.sh?.[1] ?? 0));
    return { font, laid, metrics, minX: minX - margin, maxX: maxX + margin, minY: minY - margin, maxY: maxY + margin };
  };

  // SetAlphaGradient: what is drawn shown up to a character (counted through the string from 0), then fading out over
  // a width, nothing after; the lines after the one it is in are gone
  const fadeFrom = (
    context: CanvasRenderingContext2D,
    layout: ReturnType<typeof layoutText>,
    start: number,
    length: number,
  ): void => {
    let counted = 0;
    let fadeX: number | null = null;
    let fadeLine = -1;
    layout.laid.forEach(({ runs, x }, lineIndex) => {
      if (fadeX !== null) return;
      let cursor = x;
      for (const run of runs) {
        const runLength = run.kind === "text" ? [...run.text].length : 1;
        if (counted + runLength > start) {
          const part = run.kind === "text" ? [...run.text].slice(0, start - counted).join("") : "";
          fadeX = cursor + (part ? context.measureText(part).width : 0);
          fadeLine = lineIndex;
          return;
        }
        counted += runLength;
        cursor += run.kind === "text" ? run.width : run.w;
      }
    });
    if (fadeX === null) return;
    const fadeBaseline = layout.laid[fadeLine]?.baseline ?? 0;
    const lineTop = fadeBaseline - layout.metrics.ascent - 2;
    const lineBottom = fadeBaseline + layout.metrics.descent + 2;
    // (taken away: the fade line from its character on, more and more over the width; every line below it)
    context.save();
    context.globalCompositeOperation = "destination-out";
    const gradient = context.createLinearGradient(fadeX, 0, fadeX + Math.max(length, 0.01), 0);
    gradient.addColorStop(0, "rgba(0,0,0,0)");
    gradient.addColorStop(1, "rgba(0,0,0,1)");
    context.fillStyle = gradient;
    context.fillRect(fadeX, lineTop, layout.maxX - fadeX, lineBottom - lineTop);
    context.fillStyle = "rgba(0,0,0,1)";
    context.fillRect(layout.minX, lineBottom, layout.maxX - layout.minX, layout.maxY - lineBottom);
    context.restore();
  };

  const rasterizeText = (item: FontStringItem): TextValue => {
    const layout = layoutText(item);
    // (at the screen's resolution, or less for a string larger than the GPU takes)
    const scale = Math.min(
      resolution,
      maxTextureSize / Math.max(1, layout.maxX - layout.minX),
      maxTextureSize / Math.max(1, layout.maxY - layout.minY),
    );
    const width = Math.max(1, Math.min(maxTextureSize, Math.ceil((layout.maxX - layout.minX) * scale)));
    const height = Math.max(1, Math.min(maxTextureSize, Math.ceil((layout.maxY - layout.minY) * scale)));
    textCanvas.width = width;
    textCanvas.height = height;
    const context = textContext;
    context.setTransform(scale, 0, 0, scale, -layout.minX * scale, -layout.minY * scale);
    context.clearRect(layout.minX, layout.minY, layout.maxX - layout.minX, layout.maxY - layout.minY);
    context.font = layout.font;
    context.textBaseline = "alphabetic";
    let isComplete = true;
    // (each: its offset and colour: the shadow's in its own, the outline's in black)
    const passes: [number, number, string][] = [];
    if (item.sh) passes.push([item.sh[0] ?? 0, -(item.sh[1] ?? 0), item.shc ? rgbaText(item.shc) : "#000"]);
    if (item.fl && /OUTLINE/.test(item.fl)) {
      // The outline: the glyphs drawn round them in black, a pixel out (THICKOUTLINE two, and its corners)
      const reach = /THICK/.test(item.fl) ? 2 : 1;
      for (let dy = -reach; dy <= reach; dy++) {
        for (let dx = -reach; dx <= reach; dx++) {
          if ((dx !== 0 || dy !== 0) && (reach === 1 ? dx === 0 || dy === 0 : true)) passes.push([dx, dy, "#000"]);
        }
      }
    }
    // Shadows and outline first, under the text (pictures cast none)
    for (const [ox, oy, passColor] of passes) {
      context.fillStyle = passColor;
      for (const { runs, x, baseline } of layout.laid) {
        let cursor = x;
        for (const run of runs) {
          if (run.kind === "text") {
            context.fillText(run.text, cursor + ox + (run.isCursor ? 1 : 0), baseline + oy);
            cursor += run.width;
          } else cursor += run.w;
        }
      }
    }
    const base = rgbaText(item.c);
    for (const { runs, x, baseline } of layout.laid) {
      let cursor = x;
      for (const run of runs) {
        if (run.kind === "text") {
          context.fillStyle = run.color ?? base;
          context.fillText(run.text, cursor + (run.isCursor ? 1 : 0), baseline);
          cursor += run.width;
        } else {
          const picture = pictureOf(run);
          if (!picture) isComplete = false;
          else if (!picture.missing) {
            const top = baseline - layout.metrics.xHeight / 2 - run.h / 2 + run.dy;
            drawPicture(context, picture.entry, picture.crop, run, cursor + run.dx, top, scale);
          }
          cursor += run.w;
        }
      }
    }
    if (item.ag) fadeFrom(context, layout, item.ag[0] ?? 0, item.ag[1] ?? 0);
    // MONOCHROME: no smoothing, each pixel the glyph's or nothing (alpha cut at a half)
    if (item.fl && /MONOCHROME/.test(item.fl)) {
      const pixels = context.getImageData(0, 0, width, height);
      const data = pixels.data;
      for (let at = 3; at < data.length; at += 4) data[at] = (data[at] as number) >= 128 ? 255 : 0;
      context.putImageData(pixels, 0, 0);
    }
    return {
      texture: backend.createCanvasTexture(textCanvas),
      x: layout.minX,
      y: layout.minY,
      w: width / scale,
      h: height / scale,
      isComplete,
      used: frameNumber,
    };
  };

  // item -> its cache entry (items unchanged between frames are the same objects: no key worked out for them)
  let textEntries = new WeakMap<FontStringItem, TextEntry>();
  const drawFontString = (item: FontStringItem): void => {
    setClip(item.cl);
    let entry = textEntries.get(item);
    if (
      !entry ||
      entry.resolution !== resolution ||
      entry.generation !== textGeneration ||
      (item.cursor && entry.cursorOn !== isCursorOn) ||
      !entry.value.isComplete ||
      !textCache.has(entry.key)
    ) {
      const key = textKey(item);
      let value = textCache.get(key);
      // (made again while its art loads, but once a frame: an earlier item of this frame may be drawing the old one)
      if (!value?.isComplete && value?.used !== frameNumber) {
        if (value) backend.deleteTexture(value.texture);
        value = rasterizeText(item);
        textCache.set(key, value);
      }
      entry = { key, value, resolution, cursorOn: isCursorOn, generation: textGeneration };
      textEntries.set(item, entry);
    }
    const value = entry.value;
    value.used = frameNumber;
    const x = item.x + value.x;
    const y = item.y + value.y;
    if (isOutside(x, y, value.w, value.h)) return;
    begin(value.texture, SAMPLING.flat, "blend");
    setRect(x, y, value.w, value.h);
    setUvRect(0, 1, 0, 1);
    setColor(1, 1, 1, item.a ?? 1);
    quad();
  };
  const forgetOldText = (): void => {
    for (const [key, value] of textCache) {
      if (frameNumber - value.used > TEXT_KEEP_FRAMES) {
        backend.deleteTexture(value.texture);
        textCache.delete(key);
      }
    }
  };

  let screenWidth = 1;
  let screenHeight = 1;
  let hasCursor = false;
  const stats: RenderStats = { quads: 0, draws: 0, ms: 0, texts: 0 };

  /** The layer, as drawn so far, put on the screen at an alpha (the screen drawn on again after) */
  const putLayer = (alpha: number): void => {
    isDrawingLayer = false;
    setClip(undefined);
    begin(backend.layer(), SAMPLING.flat, "blend");
    setRect(0, 0, screenWidth, screenHeight);
    setUvRect(0, 1, 0, 1);
    setColor(1, 1, 1, alpha);
    quad();
  };

  const draw = (items: SceneItems): void => {
    if (isDisposed) return;
    const started = performance.now();
    frameNumber += 1;
    quadCount = 0;
    batchCount = 0;
    batch = null;
    hasCursor = false;
    isDrawingLayer = false;
    let layerGroup: number | string | undefined;
    let layerAlpha = 1;
    for (let index = 0; index < items.length; index++) {
      const item = items[index];
      if (!item) continue;
      // A flattened frame's regions: drawn into the layer, then the layer put on the screen at the frame's alpha
      if (item.fg !== layerGroup) {
        if (layerGroup !== undefined) putLayer(layerAlpha);
        layerGroup = item.fg;
        layerAlpha = item.fa ?? 1;
        isDrawingLayer = layerGroup !== undefined;
      }
      switch (item.k) {
        case "t":
          drawTexture(item);
          break;
        case "s":
          if (item.cursor) hasCursor = true;
          drawFontString(item);
          break;
        case "b":
          drawBackdrop(item);
          break;
        case "ln":
          drawLine(item);
          break;
      }
    }
    if (layerGroup !== undefined) putLayer(layerAlpha);
    backend.draw(vertices, quadCount, batches, batchCount, screenWidth, screenHeight);
    if (frameNumber % TEXT_SWEEP_FRAMES === 0) forgetOldText();
    stats.quads = quadCount;
    stats.draws = batchCount;
    stats.ms = performance.now() - started;
    stats.texts = textCache.size;
  };

  return {
    stats,
    resize: (width, height, pixelsPerUnit) => {
      screenWidth = width;
      screenHeight = height;
      resolution = Math.max(0.5, Math.min(pixelsPerUnit, 4));
      const pixelWidth = Math.max(1, Math.round(width * resolution));
      const pixelHeight = Math.max(1, Math.round(height * resolution));
      if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
        canvas.width = pixelWidth;
        canvas.height = pixelHeight;
      }
      canvas.style.width = `${width}px`;
      canvas.style.height = `${height}px`;
    },
    draw,
    hasCursor: () => hasCursor,
    resetText: () => {
      for (const value of textCache.values()) backend.deleteTexture(value.texture);
      textCache.clear();
      fontMetrics.clear();
      textEntries = new WeakMap();
      textGeneration += 1;
    },
    blink: () => {
      isCursorOn = !isCursorOn;
    },
    isSettled: () => loading === 0,
    finished: () => backend.finished(),
    onLost: backend.onLost,
    dispose: () => {
      isDisposed = true;
      for (const value of textCache.values()) backend.deleteTexture(value.texture);
      textCache.clear();
      for (const entry of textures.values()) {
        if (entry.texture) backend.deleteTexture(entry.texture);
        entry.bitmap?.close();
      }
      textures.clear();
      backend.dispose();
    },
  };
};
