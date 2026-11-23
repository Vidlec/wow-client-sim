// TGA decoder for addon media: true-colour (24/32-bit) or greyscale (8/16-bit), raw or RLE, any origin.
import type { DecodedImage } from "./types.ts";

/** Run-length packets: a header byte (top bit = run, low 7 bits = count - 1), then one pixel or count pixels */
const decodeRle = (data: Uint8Array, offset: number, pixelSize: number, count: number): Uint8Array => {
  const output = new Uint8Array(count * pixelSize);
  let written = 0;
  let position = offset;
  while (written < output.length) {
    if (position >= data.length) throw new Error("truncated TGA RLE data");
    const header = data[position++] ?? 0;
    const run = (header & 0x7f) + 1;
    if (header & 0x80) {
      if (position + pixelSize > data.length) throw new Error("truncated TGA RLE data");
      const pixel = data.subarray(position, position + pixelSize);
      position += pixelSize;
      for (let i = 0; i < run && written < output.length; i++) {
        output.set(pixel.subarray(0, Math.min(pixelSize, output.length - written)), written);
        written += pixelSize;
      }
    } else {
      const bytes = data.subarray(position, Math.min(position + run * pixelSize, data.length));
      position += run * pixelSize;
      const kept = bytes.subarray(0, Math.min(bytes.length, output.length - written));
      output.set(kept, written);
      written += kept.length;
    }
  }
  return output;
};

/** Decode a true-colour or greyscale TGA (raw or RLE) to RGBA */
export const decodeTga = (data: Uint8Array): DecodedImage => {
  if (data.length < 18) throw new Error("not a TGA file");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const idLength = view.getUint8(0);
  const colorMapType = view.getUint8(1);
  const imageType = view.getUint8(2);
  const mapLength = view.getUint16(5, true);
  const mapEntryBits = view.getUint8(7);
  const width = view.getUint16(12, true);
  const height = view.getUint16(14, true);
  const bitsPerPixel = view.getUint8(16);
  const descriptor = view.getUint8(17);
  if (![2, 3, 10, 11].includes(imageType) || colorMapType > 1 || width === 0 || height === 0) {
    throw new Error(`unsupported TGA image type ${imageType}`);
  }
  const isGrey = imageType === 3 || imageType === 11;
  if (
    (isGrey && bitsPerPixel !== 8 && bitsPerPixel !== 16) ||
    (!isGrey && bitsPerPixel !== 24 && bitsPerPixel !== 32)
  ) {
    throw new Error(`unsupported TGA depth ${bitsPerPixel}`);
  }
  // A colour map may sit ahead of true-colour pixels; it is skipped
  const offset = 18 + idLength + (colorMapType ? mapLength * ((mapEntryBits + 7) >> 3) : 0);
  const pixelSize = bitsPerPixel >> 3;
  const count = width * height;
  let source: Uint8Array;
  if (imageType === 10 || imageType === 11) {
    source = decodeRle(data, offset, pixelSize, count);
  } else {
    if (data.length - offset < count * pixelSize) throw new Error("truncated TGA pixel data");
    source = data.subarray(offset, offset + count * pixelSize);
  }

  // Rows are stored bottom-up unless bit 5 of the descriptor is set, right-to-left when bit 4 is
  const isRightToLeft = (descriptor & 0x10) !== 0;
  const isTopDown = (descriptor & 0x20) !== 0;
  const pixels = new Uint8Array(count * 4);
  let from = 0;
  for (let sourceY = 0; sourceY < height; sourceY++) {
    const y = isTopDown ? sourceY : height - 1 - sourceY;
    for (let sourceX = 0; sourceX < width; sourceX++) {
      const x = isRightToLeft ? width - 1 - sourceX : sourceX;
      const to = (y * width + x) * 4;
      if (isGrey) {
        const grey = source[from] ?? 0;
        pixels[to] = grey;
        pixels[to + 1] = grey;
        pixels[to + 2] = grey;
        pixels[to + 3] = pixelSize === 2 ? (source[from + 1] ?? 0) : 255;
      } else {
        pixels[to] = source[from + 2] ?? 0;
        pixels[to + 1] = source[from + 1] ?? 0;
        pixels[to + 2] = source[from] ?? 0;
        pixels[to + 3] = pixelSize === 4 ? (source[from + 3] ?? 0) : 255;
      }
      from += pixelSize;
    }
  }
  return { width, height, pixels };
};
