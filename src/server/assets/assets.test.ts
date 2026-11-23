// Assets against the real cache (cache/ beside the project). The first run downloads real game files from
// wago.tools; without the listfile, or without wago.tools and its files not cached yet, those tests are skipped.
import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CACHE_DIR } from "../config.ts";
import { decodeBlp, getBlpEncoding, getBlpInfo } from "./blp.ts";
import { cascUrl, download, NotFoundError } from "./download.ts";
import { FONT_MAGICS } from "./fonts.ts";
import { Assets, DEFAULT_BUILD } from "./index.ts";
import { encodePng, getPngSize } from "./png.ts";
import { ADDONS_ROOT, getAlphaValues, parsePng } from "./testSupport.ts";

const TAXI_ASSETS_FDID = 1455734; // interface/taxiframe/taxiassets, uncompressed BGRA
const MISSING_FDID = 999999999;
const HAS_ADDON_MEDIA = ADDONS_ROOT !== "" && existsSync(join(ADDONS_ROOT, "SimFixture", "Media", "Plus.tga"));

const shared = new Assets(CACHE_DIR, { build: DEFAULT_BUILD });
const isReady = await shared.waitReady(900_000);
if (!isReady) console.warn(`listfile unavailable, skipping: ${shared.getStatus().error}`);
// Game files at all: from the cache, or wago.tools answering
const hasArt = isReady && (await shared.raw("Interface\\Buttons\\UI-PlusButton-Up")) !== null;

const requireRaw = async (target: string | number): Promise<Uint8Array> => {
  const data = await shared.raw(target);
  if (data === null) throw new Error(`download failed: ${target}`);
  return data;
};

describe.skipIf(!isReady)("resolve", () => {
  test("path variants resolve to the same id", () => {
    const expected = shared.resolve("Interface\\Buttons\\UI-PlusButton-Up");
    expect(typeof expected).toBe("number");
    for (const variant of [
      "interface/buttons/ui-plusbutton-up",
      "INTERFACE\\BUTTONS\\UI-PLUSBUTTON-UP.BLP",
      "Interface/Buttons/UI-PlusButton-Up.tga",
      "Interface\\\\Buttons\\UI-PlusButton-Up",
    ]) {
      expect(shared.resolve(variant)).toBe(expected);
    }
  });

  test("numeric ids pass through", () => {
    expect(shared.resolve(130838)).toBe(130838);
    expect(shared.resolve("130838")).toBe(130838);
    expect(shared.resolve(0)).toBeNull();
  });

  test("font and unknown paths", () => {
    expect(typeof shared.resolve("Fonts\\FRIZQT__.TTF")).toBe("number");
    expect(shared.resolve("Interface\\Nope\\DoesNotExist")).toBeNull();
    expect(shared.resolve("")).toBeNull();
  });

  test("status reports the listfile", () => {
    const status = shared.getStatus();
    expect(status.ready).toBe(true);
    expect(status.rows).toBeGreaterThan(100000);
  });
});

describe.skipIf(!hasArt)("real BLP", () => {
  // Real textures from the target build; the encoding is checked so each decoder path is exercised
  const cases: [string | number, string, number, number][] = [
    ["Interface\\Buttons\\UI-PlusButton-Up", "dxt3", 16, 16],
    ["Interface\\Tooltips\\UI-Tooltip-Border", "dxt3", 128, 16],
    ["Interface\\Icons\\INV_Misc_Book_09", "dxt1", 64, 64],
    ["Interface\\Minimap\\MiniMap-TrackingBorder", "dxt5", 64, 64],
    ["Interface\\Cursor\\Point", "palette1", 32, 32],
    ["Interface\\Cursor\\Buy", "palette8", 32, 32],
    [TAXI_ASSETS_FDID, "bgra", 128, 512],
  ];

  test.each(cases)("decode and PNG: %p", async (path, encoding, width, height) => {
    const raw = await requireRaw(path);
    const info = getBlpInfo(raw);
    expect(info && getBlpEncoding(info)).toBe(encoding);
    const decoded = decodeBlp(raw);
    expect([decoded.width, decoded.height]).toEqual([width, height]);
    const png = await shared.png(path);
    expect(png).not.toBeNull();
    expect(getPngSize(png ?? new Uint8Array(0))).toEqual({ width, height });
    const parsed = parsePng(png ?? new Uint8Array(0));
    expect([parsed.width, parsed.height]).toEqual([width, height]);
    expect(Buffer.from(parsed.pixels).equals(Buffer.from(decoded.pixels))).toBe(true);
  });

  test("alpha is plausible", async () => {
    const white = decodeBlp(await requireRaw("Interface\\Buttons\\WHITE8X8")).pixels;
    expect(white.every((byte) => byte === 255) && white.length === 8 * 8 * 4).toBe(true); // DXT1 without alpha bits

    const book = decodeBlp(await requireRaw("Interface\\Icons\\INV_Misc_Book_09")).pixels;
    expect(getAlphaValues(book)).toEqual(new Set([0, 255])); // DXT1 with 1-bit alpha
    expect(book[3]).toBe(0); // the icon's corner is punched out
    expect(book[(32 * 64 + 32) * 4 + 3]).toBe(255); // its centre is opaque

    const { width, height, pixels: ring } = decodeBlp(await requireRaw("Interface\\Minimap\\MiniMap-TrackingBorder"));
    expect(ring[(19 * width + 19) * 4 + 3]).toBe(0); // the ring fills the top-left ~38x38; its centre is transparent
    expect(ring[((height - 1) * width + width - 1) * 4 + 3]).toBe(0); // the unused area is transparent
    const ringAlphas = getAlphaValues(ring);
    expect(ringAlphas.has(255)).toBe(true);
    expect(ringAlphas.size).toBeGreaterThan(8); // DXT5 alpha has gradients

    const cursor = decodeBlp(await requireRaw("Interface\\Cursor\\Point")).pixels;
    expect(getAlphaValues(cursor)).toEqual(new Set([0, 255])); // 1-bit alpha

    const plus = decodeBlp(await requireRaw("Interface\\Buttons\\UI-PlusButton-Up")).pixels;
    for (const alpha of getAlphaValues(plus)) expect(alpha % 17).toBe(0); // DXT3 alpha is 4-bit
  });

  test("DXT decode is fast", async () => {
    const raw = await requireRaw("Interface\\WorldMap\\UI-WorldMap-Top1"); // 256x256 DXT
    const startedAt = performance.now();
    const { width, height } = decodeBlp(raw);
    expect([width, height]).toEqual([256, 256]);
    expect(performance.now() - startedAt).toBeLessThan(500);
  });

  test("concurrent requests agree", async () => {
    const results = await Promise.all(Array.from({ length: 8 }, () => shared.png(137056)));
    expect(results.length).toBe(8);
    const first = Buffer.from(results[0] ?? new Uint8Array(0));
    expect(first.length).toBeGreaterThan(0);
    for (const result of results) expect(first.equals(Buffer.from(result ?? new Uint8Array(0)))).toBe(true);
  });
});

// A file not in the build is remembered as such: only testable when that is known or wago.tools can say so
const missingPath = join(CACHE_DIR, "casc", DEFAULT_BUILD, `${MISSING_FDID}.missing`);
const canTellMissing =
  isReady &&
  (existsSync(missingPath) ||
    (await download(cascUrl(MISSING_FDID, DEFAULT_BUILD)).then(
      () => false,
      (error: unknown) => error instanceof NotFoundError,
    )));

describe.skipIf(!canTellMissing)("missing files", () => {
  test("a missing file is remembered", async () => {
    expect(await shared.png(MISSING_FDID)).toBeNull();
    expect(existsSync(missingPath)).toBe(true);
    expect(await shared.png(MISSING_FDID)).toBeNull();
  });
});

describe.skipIf(!hasArt)("atlas", () => {
  test("QuestNormal", async () => {
    await shared.loadAtlases();
    const info = shared.atlas("QuestNormal");
    expect(info).not.toBeNull();
    if (!info) return;
    expect(Object.keys(info).sort()).toEqual(
      ["fdid", "width", "height", "left", "right", "top", "bottom", "tilesH", "tilesV"].sort(),
    );
    expect([info.width, info.height]).toEqual([32, 32]);
    for (const edge of [info.left, info.right, info.top, info.bottom]) {
      expect(edge).toBeGreaterThanOrEqual(0);
      expect(edge).toBeLessThanOrEqual(1);
    }
    expect(info.left).toBeLessThan(info.right);
    expect(info.top).toBeLessThan(info.bottom);
    expect(getPngSize((await shared.png(info.fdid)) ?? new Uint8Array(0))).toEqual({ width: 1024, height: 1024 });
  });

  test("tiling flags", async () => {
    await shared.loadAtlases();
    const both = shared.atlas("Garr_WoodFrame-BackgroundTile");
    expect([both?.tilesH, both?.tilesV]).toEqual([true, true]);
    const horizontal = shared.atlas("_Garr_WoodFrameTile-Top");
    expect([horizontal?.tilesH, horizontal?.tilesV]).toEqual([true, false]);
    const vertical = shared.atlas("!Garr_WoodFrameTile-Left");
    expect([vertical?.tilesH, vertical?.tilesV]).toEqual([false, true]);
  });

  test("unknown", async () => {
    await shared.loadAtlases();
    expect(shared.atlas("no-such-atlas")).toBeNull();
    expect(shared.atlas("")).toBeNull();
  });

  test("DB2 rows and paths", async () => {
    const rows = await shared.getDb2Rows("UiTextureAtlas");
    expect(rows?.length).toBeGreaterThan(100);
    expect(rows?.[0]).toHaveProperty("FileDataID");
    expect(await shared.db2Path("UiTextureAtlas")).toBe(join(CACHE_DIR, "db2", DEFAULT_BUILD, "UiTextureAtlas.csv"));
  });
});

describe.skipIf(!hasArt)("font", () => {
  test("Friz Quadrata", async () => {
    const data = await shared.font("Fonts\\FRIZQT__.TTF");
    expect(data).not.toBeNull();
    if (!data) return;
    expect(FONT_MAGICS).toContain(String.fromCharCode(...data.subarray(0, 4)));
    expect(data.length).toBeGreaterThan(10000);
    const again = await shared.font("fonts/frizqt__");
    expect(Buffer.from(again ?? new Uint8Array(0)).equals(Buffer.from(data))).toBe(true);
  });

  test("a texture is not a font", async () => {
    expect(await shared.font("Interface\\Buttons\\UI-PlusButton-Up")).toBeNull();
  });
});

describe("media", () => {
  test
    .skipIf(!HAS_ADDON_MEDIA)
    .each([
      "Interface\\AddOns\\SimFixture\\Media\\Plus.tga",
      "interface/addons/simfixture/media/plus",
      "Interface\\AddOns\\SimFixture\\Media\\Plus.blp",
    ])("an addon's TGA: %p", async (path) => {
    const result = await shared.media(ADDONS_ROOT, path);
    expect(result).not.toBeNull();
    expect(result?.contentType).toBe("image/png");
    const parsed = parsePng(result?.data ?? new Uint8Array(0));
    expect([parsed.width, parsed.height]).toEqual([32, 32]);
  });

  test.each([
    "Interface\\AddOns\\SimFixture\\..\\..\\.zshrc",
    "Interface\\AddOns\\SimFixture",
    "Interface\\Buttons\\UI-PlusButton-Up",
    "Interface\\AddOns\\NoSuchAddon\\x.tga",
  ])("rejects traversal and non-addon paths: %p", async (path) => {
    expect(await shared.media(ADDONS_ROOT || tmpdir(), path)).toBeNull();
  });

  test("case-insensitive lookup and pass-through", async () => {
    const root = mkdtempSync(join(tmpdir(), "addonsim-media-"));
    try {
      const folder = join(root, "MyAddon", "Art");
      mkdirSync(folder, { recursive: true });
      const png = encodePng(1, 1, Uint8Array.of(1, 2, 3, 4));
      writeFileSync(join(folder, "Icon.PNG"), png);
      const result = await shared.media(root, "Interface\\AddOns\\myaddon\\art\\icon");
      expect(result?.contentType).toBe("image/png");
      expect(Buffer.from(result?.data ?? new Uint8Array(0)).equals(Buffer.from(png))).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
