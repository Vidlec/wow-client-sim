// Shapes shared by the asset modules. Type aliases rather than interfaces, so they also fit Record<string, unknown>.

/** Decoded pixels: RGBA8, top row first, width * height * 4 bytes */
export type DecodedImage = { width: number; height: number; pixels: Uint8Array };

/** A file ready to serve */
export type Served = { data: Uint8Array; contentType: string };

/** Where an atlas element sits in its texture (texture coordinates 0..1) and how it repeats */
export type AtlasInfo = {
  fdid: number;
  width: number;
  height: number;
  left: number;
  right: number;
  top: number;
  bottom: number;
  tilesH: boolean;
  tilesV: boolean;
  /** Nine-slice margins in the element's pixels: left, top, right, bottom */
  slice?: [number, number, number, number];
  /** 0 when the middle stretches, 1 when it tiles */
  sliceMode?: number;
};

/** Diagnostics: readiness, the listfile's meta rows (row count, build time...) and the last error */
export type AssetsStatus = {
  ready: boolean;
  build: string;
  error: string | null;
  source?: string;
  downloadedBytes?: number;
  rows?: number;
  buildSeconds?: number;
  builtAt?: string;
};
