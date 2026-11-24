// What the renderer (renderer.ts) asks of the GPU (webgpu.ts): textures made and dropped, and a frame drawn from one
// vertex buffer of quads cut into batches. Everything the game's drawing means (corners, slices, masks, text) is the
// renderer's; the GPU's part only moves the quads to it and draws them with one shader.

/** A texture takes up to three masks, as in the game */
export const MASKS = 3;
/**
 * Per vertex: position (2), uv (2), colour (4), clip (4), flags (1), how grey (1: 0 to 1, SetDesaturation), then for
 * each mask its place across its box (2, 0 to 1 inside it) and its piece of its sheet (4: left, top, width, height)
 */
export const FLOATS = 14 + MASKS * 6;
export const STRIDE = FLOATS * 4;
/** Where the grey amount and each mask's floats are in a vertex */
export const GREY_OFFSET = 13;
export const maskOffset = (mask: number): number => 14 + mask * 6;
/**
 * The shader's flags: cut at half its alpha and drawn solid (ALPHAKEY); drawn solid (DISABLE: no blending with what is
 * under it); for each mask: it applies, and what lies past its box (white: left be, black: cut; neither: the mask's
 * edge goes on); and past the texture's own edges, across and down (CLAMPTOBLACKADDITIVE: nothing; CLAMPTOWHITE: white)
 */
export const FLAG_ALPHAKEY = 2;
export const FLAG_SOLID = 4;
export const flagMask = (mask: number): number => 8 << mask;
export const flagMaskWhite = (mask: number): number => 64 << mask;
export const flagMaskBlack = (mask: number): number => 512 << mask;
export const FLAG_BLACK_U = 4096;
export const FLAG_BLACK_V = 8192;
export const FLAG_WHITE_U = 16384;
export const FLAG_WHITE_V = 32768;

/** A texture on the GPU (each backend's own inside) */
export type GpuTexture = { readonly width: number; readonly height: number };

/**
 * How a texture is read: mipmapped, each way clamped, repeated or mirrored past its edges (samplingFor: across times 3
 * plus down), or flat (text and layers: drawn at their size)
 */
export const WRAP = { clamp: 0, repeat: 1, mirror: 2 } as const;
export type Wrap = (typeof WRAP)[keyof typeof WRAP];
export const samplingFor = (across: Wrap, down: Wrap): number => across * 3 + down;
export const SAMPLING = { clamp: 0, repeat: 4, flat: 9 } as const;
export const SAMPLINGS = 10;
export type Sampling = number;

/**
 * How a quad meets what is under it: blended (premultiplied), added (ADD: glows), or multiplying the screen (MOD).
 * The game's ALPHAKEY and DISABLE draw as blended, the texel made solid by the shader (its flags).
 */
export type Blend = "blend" | "add" | "mod";

/** One draw: a run of quads sharing a texture, its sampling, a blend and masks, drawn on the screen or a layer */
export type Batch = {
  /** Drawn into the layer (a flattened frame's regions, which a quad then puts on the screen at the frame's alpha) */
  isLayer: boolean;
  texture: GpuTexture;
  sampling: Sampling;
  blend: Blend;
  mask0: GpuTexture | null;
  mask1: GpuTexture | null;
  mask2: GpuTexture | null;
  /** The first quad and how many */
  first: number;
  count: number;
};

export type Backend = {
  /** A 1×1 white texture: plain colours, no mask */
  readonly white: GpuTexture;
  /** The layer flattened frames are drawn into: the screen's size, cleared for each run of batches drawn into it */
  readonly layer: () => GpuTexture;
  /** The largest side a texture may have */
  readonly maxTextureSize: number;
  /** A decoded picture (premultiplied) as a mipmapped texture */
  createTexture: (bitmap: ImageBitmap) => GpuTexture;
  /** A canvas's drawing (text) as a texture, without mipmaps */
  createCanvasTexture: (canvas: HTMLCanvasElement | OffscreenCanvas) => GpuTexture;
  deleteTexture: (texture: GpuTexture) => void;
  /**
   * The frame drawn on the canvas: quadCount quads of vertices (FLOATS each corner, upper left, upper right, lower
   * left, lower right) in the batches given, over a cleared (transparent) canvas; screen is its size in game units
   */
  draw: (
    vertices: Float32Array,
    quadCount: number,
    batches: readonly Batch[],
    batchCount: number,
    screenWidth: number,
    screenHeight: number,
  ) => void;
  /** Settles once the GPU has done the work sent (the picture pages say "ready" after it) */
  finished: () => Promise<void>;
  /** Called once if the GPU is lost (a driver reset, the GPU switched): the renderer is made again */
  onLost: (listener: () => void) => void;
  dispose: () => void;
};
