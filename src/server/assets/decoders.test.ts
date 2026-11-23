// The decoders and parsers on their own, from synthetic files (encodings not found among sampled real files:
// palette 0/4-bit, DXT1 punch-through alpha) and the configured addons folder's TGA media.
import { describe, expect, test } from "bun:test";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { findAtlas } from "./atlases.ts";
import { decodeBlp } from "./blp.ts";
import { parseCsv } from "./csv.ts";
import { convertImage } from "./image.ts";
import { encodePng, getPngSize } from "./png.ts";
import {
  ADDONS_ROOT,
  composeBlp,
  composeTga,
  composeTgaHeader,
  concat,
  getAlphaValues,
  parsePng,
} from "./testSupport.ts";
import { decodeTga } from "./tga.ts";
import type { AtlasInfo } from "./types.ts";

const ADDON_MEDIA = join(ADDONS_ROOT, "SimFixture", "Media");
const HAS_ADDON_MEDIA = ADDONS_ROOT !== "" && existsSync(join(ADDON_MEDIA, "Plus.tga"));

/** A little-endian DXT colour block: two RGB565 endpoints and 2-bit indices */
const dxtBlock = (color0: number, color1: number, bits: number): Uint8Array => {
  const block = new Uint8Array(8);
  const view = new DataView(block.buffer);
  view.setUint16(0, color0, true);
  view.setUint16(2, color1, true);
  view.setUint32(4, bits >>> 0, true);
  return block;
};

describe("synthetic BLP", () => {
  const palette = Uint8Array.from({ length: 1024 }, (_, i) => {
    const entry = i >> 2;
    return [entry, 255 - entry, entry >> 1, 0][i & 3] ?? 0; // BGRA
  });
  const indices = Uint8Array.from({ length: 8 }, (_, i) => i);

  test("palette without alpha", () => {
    const { width, height, pixels } = decodeBlp(composeBlp(4, 2, 1, 0, 0, indices, palette));
    expect([width, height]).toEqual([4, 2]);
    expect([...pixels.subarray(4, 8)]).toEqual([0, 254, 1, 255]);
    expect(getAlphaValues(pixels)).toEqual(new Set([255]));
  });

  test("palette with 4-bit alpha", () => {
    const alpha = Uint8Array.of(0x10, 0x32, 0x54, 0xf6); // nibbles low-first: 0,1,2,3,4,5,6,15
    const { pixels } = decodeBlp(composeBlp(4, 2, 1, 4, 0, concat([indices, alpha]), palette));
    expect(Array.from({ length: 8 }, (_, i) => pixels[i * 4 + 3])).toEqual([0, 17, 34, 51, 68, 85, 102, 255]);
  });

  test("palette with 1-bit and 8-bit alpha", () => {
    const oneBit = decodeBlp(composeBlp(4, 2, 1, 1, 0, concat([indices, Uint8Array.of(0b10100101)]), palette));
    expect(Array.from({ length: 8 }, (_, i) => oneBit.pixels[i * 4 + 3])).toEqual([255, 0, 255, 0, 0, 255, 0, 255]);
    const alpha = Uint8Array.of(9, 8, 7, 6, 5, 4, 3, 2);
    const eightBit = decodeBlp(composeBlp(4, 2, 1, 8, 0, concat([indices, alpha]), palette));
    expect(Array.from({ length: 8 }, (_, i) => eightBit.pixels[i * 4 + 3])).toEqual([...alpha]);
  });

  test("DXT1 punch-through alpha", () => {
    const block = dxtBlock(0x001f, 0xf800, 0xffffffff); // c0 <= c1: index 3 is transparent
    expect(getAlphaValues(decodeBlp(composeBlp(4, 4, 2, 1, 0, block)).pixels)).toEqual(new Set([0]));
    expect(getAlphaValues(decodeBlp(composeBlp(4, 4, 2, 0, 0, block)).pixels)).toEqual(new Set([255]));
  });

  test("a size not a multiple of four is cropped", () => {
    const { width, height, pixels } = decodeBlp(composeBlp(2, 2, 2, 0, 0, dxtBlock(0xf800, 0x001f, 0)));
    expect([width, height, pixels.length]).toEqual([2, 2, 16]);
    expect([...pixels.subarray(0, 4)]).toEqual([255, 0, 0, 255]);
  });

  test("BGRA swaps to RGBA", () => {
    const { pixels } = decodeBlp(composeBlp(1, 1, 3, 8, 0, Uint8Array.of(1, 2, 3, 4)));
    expect([...pixels]).toEqual([3, 2, 1, 4]);
  });

  test("garbage is rejected", () => {
    expect(() => decodeBlp(concat([new TextEncoder().encode("BLP2"), new Uint8Array(10)]))).toThrow();
    expect(() => convertImage(new TextEncoder().encode("hello world"))).toThrow();
    expect(() => decodeBlp(composeBlp(4, 4, 2, 0, 0, new Uint8Array(4)))).toThrow("truncated DXT data");
  });
});

describe("PNG", () => {
  test("round trip", () => {
    const rgba = Uint8Array.from({ length: 3 * 2 * 4 }, (_, i) => (i * 37) & 255);
    const png = encodePng(3, 2, rgba);
    expect(getPngSize(png)).toEqual({ width: 3, height: 2 });
    const parsed = parsePng(png);
    expect([parsed.width, parsed.height]).toEqual([3, 2]);
    expect([...parsed.pixels]).toEqual([...rgba]);
  });

  test("a buffer of the wrong size is refused", () => {
    expect(() => encodePng(2, 2, new Uint8Array(4))).toThrow();
    expect(getPngSize(new Uint8Array(10))).toBeNull();
  });
});

describe("TGA", () => {
  test("24-bit, top-left origin", () => {
    const header = composeTgaHeader(2, 2, 1, 24, 0x20);
    const { pixels } = decodeTga(concat([header, Uint8Array.of(1, 2, 3, 4, 5, 6)]));
    expect([...pixels]).toEqual([3, 2, 1, 255, 6, 5, 4, 255]);
  });

  test("greyscale with alpha, right to left", () => {
    const header = composeTgaHeader(3, 2, 1, 16, 0x30);
    const { pixels } = decodeTga(concat([header, Uint8Array.of(10, 20, 30, 40)]));
    expect([...pixels]).toEqual([30, 30, 30, 40, 10, 10, 10, 20]);
  });

  describe.skipIf(!HAS_ADDON_MEDIA)("addon media", () => {
    const plus = HAS_ADDON_MEDIA ? new Uint8Array(readFileSync(join(ADDON_MEDIA, "Plus.tga"))) : new Uint8Array(0);

    test("an addon's plus", () => {
      const { width, height, pixels } = decodeTga(plus);
      expect([width, height]).toEqual([32, 32]);
      const alphas = getAlphaValues(pixels);
      expect(alphas.has(0)).toBe(true);
      expect(alphas.has(255)).toBe(true);
      expect(pixels[3]).toBe(0); // plus sign corners are transparent
      expect(pixels[(16 * 32 + 16) * 4 + 3]).toBe(255); // plus sign centre is opaque
    });

    test("all addon media decode", () => {
      for (const name of readdirSync(ADDON_MEDIA).filter((file) => file.toLowerCase().endsWith(".tga"))) {
        const { width, height, pixels } = decodeTga(new Uint8Array(readFileSync(join(ADDON_MEDIA, name))));
        expect(pixels.length).toBe(width * height * 4);
      }
    });

    test("origins and RLE agree", () => {
      const expected = decodeTga(plus);
      const { width, height } = expected;
      const offset = 18 + (plus[0] ?? 0);
      const bottomUpRows = Array.from({ length: height }, (_, y) =>
        plus.subarray(offset + y * width * 4, offset + (y + 1) * width * 4),
      );
      for (const isTopLeft of [false, true]) {
        for (const isRle of [false, true]) {
          const decoded = decodeTga(composeTga(width, height, bottomUpRows, isTopLeft, isRle));
          expect([decoded.width, decoded.height]).toEqual([width, height]);
          expect(Buffer.from(decoded.pixels).equals(Buffer.from(expected.pixels))).toBe(true);
        }
      }
    });
  });
});

describe("CSV", () => {
  test("quotes, line endings and blank lines as Python's csv module reads them", () => {
    const text = '\uFEFFID,Name,Text\r\n1,a,"x, ""y""\nz"\r\n\r\n2,b\n3,"q"r,s,extra\n';
    expect(parseCsv(text)).toEqual([
      { ID: "1", Name: "a", Text: 'x, "y"\nz' },
      { ID: "2", Name: "b", Text: "" },
      { ID: "3", Name: "qr", Text: "s" },
    ]);
  });

  test("no trailing newline, empty last field", () => {
    expect(parseCsv("A,B\n1,")).toEqual([{ A: "1", B: "" }]);
    expect(parseCsv("")).toEqual([]);
  });
});

describe("atlas lookup", () => {
  const element: AtlasInfo = {
    fdid: 1,
    width: 64,
    height: 32,
    left: 0,
    right: 0.5,
    top: 0,
    bottom: 0.25,
    tilesH: false,
    tilesV: false,
    slice: [8, 4, 8, 4],
    sliceMode: 0,
  };

  test("the plain name falls back to its -2x member at half size", () => {
    const atlases = { "frame-2x": element };
    expect(findAtlas(atlases, "Frame")).toEqual({ ...element, width: 32, height: 16, slice: [4, 2, 4, 2] });
    expect(findAtlas(atlases, "frame-2x")).toEqual(element);
    expect(findAtlas(atlases, "")).toBeNull();
    expect(findAtlas(atlases, "nope")).toBeNull();
  });

  test("results are copies", () => {
    const atlases = { frame: element };
    const copy = findAtlas(atlases, "frame");
    copy?.slice?.fill(0);
    expect(element.slice).toEqual([8, 4, 8, 4]);
  });
});
