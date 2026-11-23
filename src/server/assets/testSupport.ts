// Helpers for the asset tests: a strict PNG reader and writers of small BLP and TGA files.
import { expect } from "bun:test";
import { join } from "node:path";
import { inflateSync } from "node:zlib";
import { SOURCE_ROOT } from "../paths.ts";
import { PNG_SIGNATURE } from "./png.ts";
import type { DecodedImage } from "./types.ts";

/** An addon's own media: the simulator's fixture addon's folder (SimFixture, whose Media/Plus.tga is a 32x32 plus) */
export const ADDONS_ROOT = join(SOURCE_ROOT, "scenarios", "fixtures", "addons");
const IEND_CRC = 0xae426082; // the CRC every PNG's IEND chunk carries: checks the CRC routine itself

const concat = (parts: Uint8Array[]): Uint8Array => {
  const result = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
};

/** Validates a PNG's structure and CRCs; returns its pixels (8-bit RGBA, every row filter type 0, as encodePng writes) */
export const parsePng = (data: Uint8Array): DecodedImage => {
  expect([...data.subarray(0, 8)]).toEqual([...PNG_SIGNATURE]);
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const chunks: { kind: string; payload: Uint8Array }[] = [];
  let position = 8;
  while (position < data.length) {
    const length = view.getUint32(position);
    const kind = String.fromCharCode(...data.subarray(position + 4, position + 8));
    const payload = data.subarray(position + 8, position + 8 + length);
    const crc = view.getUint32(position + 8 + length);
    expect(crc).toBe(Bun.hash.crc32(data.subarray(position + 4, position + 8 + length)));
    if (kind === "IEND") expect(crc).toBe(IEND_CRC);
    chunks.push({ kind, payload });
    position += 12 + length;
  }
  expect(chunks[0]?.kind).toBe("IHDR");
  expect(chunks.at(-1)?.kind).toBe("IEND");
  const header = chunks[0]?.payload ?? new Uint8Array(13);
  const headerView = new DataView(header.buffer, header.byteOffset, header.byteLength);
  const width = headerView.getUint32(0);
  const height = headerView.getUint32(4);
  expect([header[8], header[9], header[12]]).toEqual([8, 6, 0]); // depth, colour type, interlace
  const scanlines = inflateSync(concat(chunks.filter((chunk) => chunk.kind === "IDAT").map((chunk) => chunk.payload)));
  const stride = width * 4;
  expect(scanlines.length).toBe((stride + 1) * height);
  const pixels = new Uint8Array(stride * height);
  for (let y = 0; y < height; y++) {
    const start = y * (stride + 1);
    expect(scanlines[start]).toBe(0); // the writer only emits filter type 0
    pixels.set(scanlines.subarray(start + 1, start + 1 + stride), y * stride);
  }
  return { width, height, pixels };
};

/** The distinct alpha values of RGBA pixels */
export const getAlphaValues = (rgba: Uint8Array): Set<number> => {
  const values = new Set<number>();
  for (let i = 3; i < rgba.length; i += 4) values.add(rgba[i] ?? 0);
  return values;
};

/** A BLP2 file with one mip level right after the header and palette */
export const composeBlp = (
  width: number,
  height: number,
  compression: number,
  alphaDepth: number,
  alphaType: number,
  pixelData: Uint8Array,
  palette: Uint8Array = new Uint8Array(0),
): Uint8Array => {
  const headerSize = 20 + 64 + 64;
  const result = new Uint8Array(headerSize + 1024 + pixelData.length);
  const view = new DataView(result.buffer);
  result.set([0x42, 0x4c, 0x50, 0x32], 0); // "BLP2"
  view.setUint32(4, 1, true);
  result.set([compression, alphaDepth, alphaType, 0], 8);
  view.setUint32(12, width, true);
  view.setUint32(16, height, true);
  view.setUint32(20, headerSize + 1024, true); // mip 0 offset
  view.setUint32(84, pixelData.length, true); // mip 0 size
  result.set(palette.subarray(0, 1024), headerSize);
  result.set(pixelData, headerSize + 1024);
  return result;
};

/** A 32-bit TGA from bottom-up BGRA rows, stored top-down or bottom-up, raw or with run-length packets */
export const composeTga = (
  width: number,
  height: number,
  bgraRowsBottomUp: Uint8Array[],
  isTopLeft = false,
  isRle = false,
): Uint8Array => {
  const rows = isTopLeft ? [...bgraRowsBottomUp].reverse() : bgraRowsBottomUp;
  let pixels = concat(rows);
  if (isRle) {
    // Alternate raw and run packets every 4 pixels (a run only where the 4 pixels are the same)
    const body: number[] = [];
    for (let index = 0; index < pixels.length; index += 16) {
      const chunk = pixels.subarray(index, index + 16);
      const count = chunk.length / 4;
      const first = chunk.subarray(0, 4);
      const isUniform = Array.from({ length: count }, (_, i) => chunk.subarray(i * 4, i * 4 + 4)).every((pixel) =>
        pixel.every((byte, b) => byte === first[b]),
      );
      if ((index / 16) % 2 && isUniform) body.push(0x80 | (count - 1), ...first);
      else body.push(count - 1, ...chunk);
    }
    pixels = Uint8Array.from(body);
  }
  const header = new Uint8Array(18);
  const view = new DataView(header.buffer);
  header[2] = isRle ? 10 : 2;
  view.setUint16(12, width, true);
  view.setUint16(14, height, true);
  header[16] = 32;
  header[17] = 8 | (isTopLeft ? 0x20 : 0);
  return concat([header, pixels]);
};

/** A TGA header for the given type, size, depth and descriptor (no id, no colour map) */
export const composeTgaHeader = (
  imageType: number,
  width: number,
  height: number,
  depth: number,
  descriptor: number,
) => {
  const header = new Uint8Array(18);
  const view = new DataView(header.buffer);
  header[2] = imageType;
  view.setUint16(12, width, true);
  view.setUint16(14, height, true);
  header[16] = depth;
  header[17] = descriptor;
  return header;
};

export { concat };
