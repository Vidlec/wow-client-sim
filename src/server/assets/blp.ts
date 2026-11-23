// BLP2 decoder: mip level 0 of the game's textures to RGBA. Handles every encoding found in the client's files
// (palette with 0/1/4/8-bit alpha, DXT1/3/5, uncompressed BGRA); JPEG-compressed BLPs (type 0) are not used by it.
//
// Header (148 bytes, little-endian): "BLP2", type u32 (1 = direct), compression u8 (1 palette, 2 DXT, 3 BGRA),
// alphaDepth u8, alphaType u8 (7 = DXT5 when compression is 2), hasMips u8, width u32, height u32, 16 mip offsets
// u32, 16 mip sizes u32; then a 256-entry BGRA palette (1024 bytes) whatever the encoding.
//
// The decoders write whole pixels as little-endian u32 words (r | g << 8 | b << 16 | a << 24): every platform Bun
// runs on is little-endian.
import type { DecodedImage } from "./types.ts";

const HEADER_SIZE = 148;
const PALETTE_SIZE = 1024;
const MAX_SIDE = 8192;

export type BlpInfo = {
  type: number;
  compression: number;
  alphaDepth: number;
  alphaType: number;
  hasMips: number;
  width: number;
  height: number;
  mipOffsets: number[];
  mipSizes: number[];
};

export type BlpEncoding = string; // palette, palette1/4/8, dxt1, dxt3, dxt5, bgra or unknown<n>

const isBlp2 = (data: Uint8Array): boolean =>
  data[0] === 0x42 && data[1] === 0x4c && data[2] === 0x50 && data[3] === 0x32;

/** The BLP2 header fields (for diagnostics and tests), or null when it isn't a BLP2 file */
export const getBlpInfo = (data: Uint8Array): BlpInfo | null => {
  if (data.length < HEADER_SIZE || !isBlp2(data)) return null;
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const readWords = (start: number): number[] =>
    Array.from({ length: 16 }, (_, i) => view.getUint32(start + i * 4, true));
  return {
    type: view.getUint32(4, true),
    compression: view.getUint8(8),
    alphaDepth: view.getUint8(9),
    alphaType: view.getUint8(10),
    hasMips: view.getUint8(11),
    width: view.getUint32(12, true),
    height: view.getUint32(16, true),
    mipOffsets: readWords(20),
    mipSizes: readWords(84),
  };
};

/** Short label of a BLP's pixel format: palette1/4/8, palette, dxt1, dxt3, dxt5, bgra */
export const getBlpEncoding = (info: BlpInfo): BlpEncoding => {
  if (info.compression === 1) return info.alphaDepth ? `palette${info.alphaDepth}` : "palette";
  if (info.compression === 2) {
    if (info.alphaDepth <= 1) return "dxt1";
    return info.alphaType === 7 ? "dxt5" : "dxt3";
  }
  if (info.compression === 3) return "bgra";
  return `unknown${info.compression}`;
};

// ---------------------------------------------------------------------------
// DXT
// ---------------------------------------------------------------------------

/** The four colours of a DXT colour block, as RGBA words, into palette */
const composeDxtPalette = (
  palette: Uint32Array,
  color0: number,
  color1: number,
  isFourColor: boolean,
  hasPunchAlpha: boolean,
): void => {
  // RGB565 widened to 8 bits by repeating the top bits, as the GPU does
  const r0 = ((color0 >> 11) & 31) * 8 + (((color0 >> 11) & 31) >> 2);
  const g0 = ((color0 >> 5) & 63) * 4 + (((color0 >> 5) & 63) >> 4);
  const b0 = (color0 & 31) * 8 + ((color0 & 31) >> 2);
  const r1 = ((color1 >> 11) & 31) * 8 + (((color1 >> 11) & 31) >> 2);
  const g1 = ((color1 >> 5) & 63) * 4 + (((color1 >> 5) & 63) >> 4);
  const b1 = (color1 & 31) * 8 + ((color1 & 31) >> 2);
  const opaque = 0xff000000;
  palette[0] = (opaque | (b0 << 16) | (g0 << 8) | r0) >>> 0;
  palette[1] = (opaque | (b1 << 16) | (g1 << 8) | r1) >>> 0;
  if (isFourColor || color0 > color1) {
    const r2 = ((2 * r0 + r1) / 3) | 0;
    const g2 = ((2 * g0 + g1) / 3) | 0;
    const b2 = ((2 * b0 + b1) / 3) | 0;
    const r3 = ((r0 + 2 * r1) / 3) | 0;
    const g3 = ((g0 + 2 * g1) / 3) | 0;
    const b3 = ((b0 + 2 * b1) / 3) | 0;
    palette[2] = (opaque | (b2 << 16) | (g2 << 8) | r2) >>> 0;
    palette[3] = (opaque | (b3 << 16) | (g3 << 8) | r3) >>> 0;
  } else {
    // Three colours: the midpoint, and black that is transparent when the texture has 1-bit alpha (DXT1 punch-through)
    palette[2] = (opaque | (((b0 + b1) >> 1) << 16) | (((g0 + g1) >> 1) << 8) | ((r0 + r1) >> 1)) >>> 0;
    palette[3] = hasPunchAlpha ? 0 : opaque;
  }
};

/** The colour half of DXT1/3/5 blocks into an RGBA buffer padded to whole blocks */
const decodeDxtColors = (
  view: DataView,
  offset: number,
  blocksWide: number,
  blocksHigh: number,
  blockSize: number,
  isFourColor: boolean,
  hasPunchAlpha: boolean,
): Uint8Array => {
  const paddedWidth = blocksWide * 4;
  const pixels = new Uint8Array(paddedWidth * blocksHigh * 4 * 4);
  const words = new Uint32Array(pixels.buffer);
  const palette = new Uint32Array(4);
  let position = offset;
  for (let blockY = 0; blockY < blocksHigh; blockY++) {
    for (let blockX = 0; blockX < blocksWide; blockX++) {
      composeDxtPalette(
        palette,
        view.getUint16(position, true),
        view.getUint16(position + 2, true),
        isFourColor,
        hasPunchAlpha,
      );
      let bits = view.getUint32(position + 4, true); // 2 bits a pixel, a byte a row, first pixel lowest
      position += blockSize;
      let target = blockY * 4 * paddedWidth + blockX * 4;
      for (let row = 0; row < 4; row++) {
        words[target] = palette[bits & 3] ?? 0;
        words[target + 1] = palette[(bits >>> 2) & 3] ?? 0;
        words[target + 2] = palette[(bits >>> 4) & 3] ?? 0;
        words[target + 3] = palette[(bits >>> 6) & 3] ?? 0;
        bits >>>= 8;
        target += paddedWidth;
      }
    }
  }
  return pixels;
};

/** DXT3: 4-bit explicit alpha, 8 bytes a block ahead of its colours, low nibble first */
const decodeDxt3Alpha = (
  view: DataView,
  offset: number,
  blocksWide: number,
  blocksHigh: number,
  pixels: Uint8Array,
) => {
  const paddedWidth = blocksWide * 4;
  let position = offset;
  for (let blockY = 0; blockY < blocksHigh; blockY++) {
    for (let blockX = 0; blockX < blocksWide; blockX++) {
      let target = (blockY * 4 * paddedWidth + blockX * 4) * 4 + 3;
      for (let row = 0; row < 4; row++) {
        const low = view.getUint8(position + 2 * row);
        const high = view.getUint8(position + 2 * row + 1);
        pixels[target] = (low & 15) * 17;
        pixels[target + 4] = (low >> 4) * 17;
        pixels[target + 8] = (high & 15) * 17;
        pixels[target + 12] = (high >> 4) * 17;
        target += paddedWidth * 4;
      }
      position += 16;
    }
  }
};

/** DXT5: two alpha endpoints and 3-bit indices (48 bits, 12 a row) into an 8-step ramp */
const decodeDxt5Alpha = (
  view: DataView,
  offset: number,
  blocksWide: number,
  blocksHigh: number,
  pixels: Uint8Array,
) => {
  const paddedWidth = blocksWide * 4;
  const ramp = new Uint8Array(8);
  let position = offset;
  for (let blockY = 0; blockY < blocksHigh; blockY++) {
    for (let blockX = 0; blockX < blocksWide; blockX++) {
      const alpha0 = view.getUint8(position);
      const alpha1 = view.getUint8(position + 1);
      ramp[0] = alpha0;
      ramp[1] = alpha1;
      if (alpha0 > alpha1) {
        for (let i = 1; i < 7; i++) ramp[i + 1] = (((7 - i) * alpha0 + i * alpha1) / 7) | 0;
      } else {
        for (let i = 1; i < 5; i++) ramp[i + 1] = (((5 - i) * alpha0 + i * alpha1) / 5) | 0;
        ramp[6] = 0;
        ramp[7] = 255;
      }
      // 24 bits hold two rows: rows 0-1 from bytes 2-4, rows 2-3 from bytes 5-7
      const lowBits =
        view.getUint8(position + 2) | (view.getUint8(position + 3) << 8) | (view.getUint8(position + 4) << 16);
      const highBits =
        view.getUint8(position + 5) | (view.getUint8(position + 6) << 8) | (view.getUint8(position + 7) << 16);
      let target = (blockY * 4 * paddedWidth + blockX * 4) * 4 + 3;
      for (let row = 0; row < 4; row++) {
        const bits = row < 2 ? lowBits >> (row * 12) : highBits >> ((row - 2) * 12);
        pixels[target] = ramp[bits & 7] ?? 0;
        pixels[target + 4] = ramp[(bits >> 3) & 7] ?? 0;
        pixels[target + 8] = ramp[(bits >> 6) & 7] ?? 0;
        pixels[target + 12] = ramp[(bits >> 9) & 7] ?? 0;
        target += paddedWidth * 4;
      }
      position += 16;
    }
  }
};

/** Drop the padding of a width or height that is not a multiple of 4 */
const cropPixels = (pixels: Uint8Array, paddedWidth: number, width: number, height: number): Uint8Array => {
  if (paddedWidth === width) {
    return pixels.length === width * height * 4 ? pixels : pixels.slice(0, width * height * 4);
  }
  const sourceStride = paddedWidth * 4;
  const stride = width * 4;
  const cropped = new Uint8Array(stride * height);
  for (let y = 0; y < height; y++) {
    cropped.set(pixels.subarray(y * sourceStride, y * sourceStride + stride), y * stride);
  }
  return cropped;
};

// ---------------------------------------------------------------------------
// Palette and BGRA
// ---------------------------------------------------------------------------

/** A palette texture's alpha plane (after its indices) into the pixels' alpha bytes: 8, 4 (low nibble first) or 1
 * bit a pixel (lowest bit first) */
const expandAlpha = (data: Uint8Array, offset: number, alphaDepth: number, count: number, pixels: Uint8Array): void => {
  if (alphaDepth !== 8 && alphaDepth !== 4 && alphaDepth !== 1) {
    throw new Error(`unsupported BLP alpha depth ${alphaDepth}`);
  }
  const needed = Math.ceil((count * alphaDepth) / 8);
  if (data.length - offset < needed) throw new Error("truncated BLP alpha data");
  if (alphaDepth === 8) {
    for (let i = 0; i < count; i++) pixels[i * 4 + 3] = data[offset + i] ?? 0;
  } else if (alphaDepth === 4) {
    for (let i = 0; i < count; i++) {
      const byte = data[offset + (i >> 1)] ?? 0;
      pixels[i * 4 + 3] = (i & 1 ? byte >> 4 : byte & 15) * 17;
    }
  } else {
    for (let i = 0; i < count; i++) {
      pixels[i * 4 + 3] = ((data[offset + (i >> 3)] ?? 0) >> (i & 7)) & 1 ? 255 : 0;
    }
  }
};

const decodePalette = (data: Uint8Array, offset: number, count: number, alphaDepth: number): Uint8Array => {
  if (data.length < HEADER_SIZE + PALETTE_SIZE) throw new Error("truncated BLP palette");
  if (data.length - offset < count) throw new Error("truncated BLP palette indices");
  const palette = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    const at = HEADER_SIZE + i * 4; // stored BGRA; its alpha byte is unused
    palette[i] = (0xff000000 | ((data[at] ?? 0) << 16) | ((data[at + 1] ?? 0) << 8) | (data[at + 2] ?? 0)) >>> 0;
  }
  const pixels = new Uint8Array(count * 4);
  const words = new Uint32Array(pixels.buffer);
  for (let i = 0; i < count; i++) words[i] = palette[data[offset + i] ?? 0] ?? 0;
  if (alphaDepth) expandAlpha(data, offset + count, alphaDepth, count, pixels);
  return pixels;
};

const decodeBgra = (data: Uint8Array, offset: number, count: number, alphaDepth: number): Uint8Array => {
  if (data.length - offset < count * 4) throw new Error("truncated BGRA data");
  const pixels = data.slice(offset, offset + count * 4);
  for (let i = 0; i < pixels.length; i += 4) {
    const blue = pixels[i] ?? 0;
    pixels[i] = pixels[i + 2] ?? 0;
    pixels[i + 2] = blue;
    if (!alphaDepth) pixels[i + 3] = 255;
  }
  return pixels;
};

/** Decode mip level 0 of a BLP2 texture to RGBA; throws on anything it cannot read */
export const decodeBlp = (data: Uint8Array): DecodedImage => {
  const info = getBlpInfo(data);
  if (info === null) throw new Error("not a BLP2 file");
  if (info.type !== 1) throw new Error("JPEG-compressed BLP is not supported");
  const { width, height, alphaDepth } = info;
  const offset = info.mipOffsets[0] ?? 0;
  const count = width * height;
  if (width <= 0 || height <= 0 || width > MAX_SIDE || height > MAX_SIDE || offset >= data.length) {
    throw new Error("invalid BLP dimensions or mip offset");
  }
  const encoding = getBlpEncoding(info);

  if (info.compression === 1) return { width, height, pixels: decodePalette(data, offset, count, alphaDepth) };

  if (info.compression === 2) {
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const blocksWide = (width + 3) >> 2;
    const blocksHigh = (height + 3) >> 2;
    const blockSize = encoding === "dxt1" ? 8 : 16;
    if (offset + blocksWide * blocksHigh * blockSize > data.length) throw new Error("truncated DXT data");
    let pixels: Uint8Array;
    if (encoding === "dxt1") {
      pixels = decodeDxtColors(view, offset, blocksWide, blocksHigh, 8, false, alphaDepth > 0);
    } else {
      // DXT3/5 blocks: 8 bytes of alpha, then a colour block that always has four colours
      pixels = decodeDxtColors(view, offset + 8, blocksWide, blocksHigh, 16, true, false);
      if (encoding === "dxt5") decodeDxt5Alpha(view, offset, blocksWide, blocksHigh, pixels);
      else decodeDxt3Alpha(view, offset, blocksWide, blocksHigh, pixels);
    }
    return { width, height, pixels: cropPixels(pixels, blocksWide * 4, width, height) };
  }

  if (info.compression === 3) return { width, height, pixels: decodeBgra(data, offset, count, alphaDepth) };

  throw new Error(`unsupported BLP compression ${info.compression}`);
};
