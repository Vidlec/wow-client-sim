// PNG writer: 8-bit RGBA, no interlace, filter type 0 on every row (the textures are small and served once, so a
// filter search would cost more than it saves).
import { deflateSync } from "node:zlib";

export const PNG_SIGNATURE: Uint8Array = Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);

/** One chunk: length, kind, payload, then the CRC of kind + payload (computed in place, no copies) */
const createChunk = (kind: string, payload: Uint8Array): Uint8Array => {
  const chunk = new Uint8Array(12 + payload.length);
  const view = new DataView(chunk.buffer);
  view.setUint32(0, payload.length);
  for (let i = 0; i < 4; i++) chunk[4 + i] = kind.charCodeAt(i);
  chunk.set(payload, 8);
  view.setUint32(8 + payload.length, Bun.hash.crc32(chunk.subarray(4, 8 + payload.length)));
  return chunk;
};

/** Encode RGBA8 pixels (top row first) as a PNG file */
export const encodePng = (width: number, height: number, rgba: Uint8Array): Uint8Array => {
  const stride = width * 4;
  if (rgba.length !== stride * height || width <= 0 || height <= 0) {
    throw new Error("pixel buffer does not match dimensions");
  }
  const scanlines = new Uint8Array((stride + 1) * height); // each row: filter byte 0, then the row
  for (let y = 0; y < height; y++) {
    scanlines.set(rgba.subarray(y * stride, (y + 1) * stride), y * (stride + 1) + 1);
  }
  const header = new Uint8Array(13);
  const view = new DataView(header.buffer);
  view.setUint32(0, width);
  view.setUint32(4, height);
  header.set([8, 6, 0, 0, 0], 8); // bit depth 8, colour type 6 (RGBA), deflate, filter set 0, no interlace
  const parts = [
    PNG_SIGNATURE,
    createChunk("IHDR", header),
    createChunk("IDAT", deflateSync(scanlines, { level: 6 })),
    createChunk("IEND", new Uint8Array(0)),
  ];
  const result = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
};

/** Width and height of a PNG, or null when it isn't a valid PNG header */
export const getPngSize = (data: Uint8Array): { width: number; height: number } | null => {
  if (data.length < 33 || !PNG_SIGNATURE.every((byte, i) => data[i] === byte)) return null;
  if (String.fromCharCode(...data.subarray(12, 16)) !== "IHDR") return null;
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return { width: view.getUint32(16), height: view.getUint32(20) };
};
