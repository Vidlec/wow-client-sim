// What a texture file is, and turning it into something a browser shows: BLP and TGA become PNG, PNG and JPEG pass.
import { decodeBlp } from "./blp.ts";
import { encodePng, PNG_SIGNATURE } from "./png.ts";
import { decodeTga } from "./tga.ts";
import type { Served } from "./types.ts";

export const CONTENT_TYPES: Readonly<Record<string, string>> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  ttf: "font/ttf",
  otf: "font/otf",
  ogg: "audio/ogg",
  mp3: "audio/mpeg",
  wav: "audio/wav",
};

export type ImageKind = "png" | "jpg" | "blp" | "tga";

/** png, jpg, blp or tga (a best guess: TGA has no magic) for raw image bytes, else null */
export const getImageKind = (data: Uint8Array): ImageKind | null => {
  if (data.length >= 8 && PNG_SIGNATURE.every((byte, i) => data[i] === byte)) return "png";
  if (data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff) return "jpg";
  if (data[0] === 0x42 && data[1] === 0x4c && data[2] === 0x50 && data[3] === 0x32) return "blp";
  const colorMapType = data[1] ?? -1;
  const imageType = data[2] ?? -1;
  const depth = data[16] ?? -1;
  if (data.length >= 18 && colorMapType <= 1 && [2, 3, 10, 11].includes(imageType) && [8, 16, 24, 32].includes(depth)) {
    return "tga";
  }
  return null;
};

/** BLP/TGA bytes as PNG; PNG and JPEG passed through. Throws when the bytes are no image it can read. */
export const convertImage = (data: Uint8Array): Served => {
  const kind = getImageKind(data);
  if (kind === "png" || kind === "jpg") return { data, contentType: CONTENT_TYPES[kind] ?? "image/png" };
  if (kind === "blp" || kind === "tga") {
    const { width, height, pixels } = kind === "blp" ? decodeBlp(data) : decodeTga(data);
    return { data: encodePng(width, height, pixels), contentType: "image/png" };
  }
  throw new Error("unknown image format");
};
