// The GPU's renderer: the scene's items drawn with WebGL2, as the game draws its interface. Every item becomes a few
// textured quads in one vertex buffer, drawn in the scene's order in as few calls as its textures allow; colour,
// alpha, greying, masks and clipping are done per pixel in the shader. Text is laid out and drawn once per string
// (Canvas 2D, the game's own fonts) and kept as a texture until it changes.
//
// Adding a kind of item: a case in drawItem that sets the corners, uvs and colour and adds quads with quad().
//
// The hot path (every item, every frame) allocates nothing: the quad being built lives in typed scratch arrays, the
// item's clip and mask in the closure's variables, the draw calls in a pool of batches reused from frame to frame.
import { type AtlasInfo, getAtlas } from "../atlas.ts";
import { fontFamily } from "../fonts.ts";
import type { BackdropItem, Color, FontStringItem, LineItem, SceneItems, TextureItem } from "../items.ts";
import { parseInlineAtlas, parseInlineTexture, TEXT_CODE } from "../text.ts";
import { artUrl, textureUrl } from "../textures.ts";

export type GlStats = { quads: number; draws: number; ms: number; texts: number };

export type GlRenderer = {
  readonly kind: "webgl2";
  readonly stats: GlStats;
  /** The screen's size in game units and the canvas's pixels per unit */
  resize: (width: number, height: number, pixelsPerUnit: number) => void;
  draw: (items: SceneItems) => void;
  /** An edit box with the focus was drawn (its cursor blinks) */
  hasCursor: () => boolean;
  /** Every string drawn again (the game's fonts arrived after the first were drawn with a stand-in) */
  resetText: () => void;
  blink: () => void;
  /** The canvas emptied (the page's elements draw instead) */
  clear: () => void;
  /** The GPU's memory given back at once (the screen is going) */
  dispose: () => void;
};

const VERTEX = `#version 300 es
in vec2 a_pos; in vec2 a_uv; in vec4 a_color; in vec2 a_maskN; in vec4 a_maskRect; in vec4 a_clip; in float a_flags;
uniform vec2 u_screen;
out vec2 v_uv; out vec4 v_color; out vec2 v_maskN; out vec4 v_maskRect; out vec4 v_clip; out float v_flags; out vec2 v_pos;
void main() {
  v_uv = a_uv; v_color = a_color; v_maskN = a_maskN; v_maskRect = a_maskRect; v_clip = a_clip; v_flags = a_flags; v_pos = a_pos;
  gl_Position = vec4(a_pos.x / u_screen.x * 2.0 - 1.0, 1.0 - a_pos.y / u_screen.y * 2.0, 0.0, 1.0);
}`;
const FRAGMENT = `#version 300 es
precision highp float;
uniform sampler2D u_tex; uniform sampler2D u_mask; uniform int u_mode;
in vec2 v_uv; in vec4 v_color; in vec2 v_maskN; in vec4 v_maskRect; in vec4 v_clip; in float v_flags; in vec2 v_pos;
out vec4 outColor;
void main() {
  if (v_pos.x < v_clip.x || v_pos.y < v_clip.y || v_pos.x > v_clip.z || v_pos.y > v_clip.w) discard;
  // (premultiplied; a little sharper than plain mipmapping, as the browser's own scaling of pictures is)
  vec4 texel = texture(u_tex, v_uv, -0.5);
  int flags = int(v_flags + 0.5);
  if ((flags & 1) != 0) { float grey = dot(texel.rgb, vec3(0.2126, 0.7152, 0.0722)); texel.rgb = vec3(grey); }
  vec4 color = vec4(texel.rgb * v_color.rgb, texel.a) * v_color.a;
  if ((flags & 2) != 0) {
    if (v_maskN.x < 0.0 || v_maskN.y < 0.0 || v_maskN.x > 1.0 || v_maskN.y > 1.0) discard;
    color *= texture(u_mask, v_maskRect.xy + v_maskN * v_maskRect.zw).a;
  }
  if (u_mode == 1) {
    // MOD: the screen times the colour, where the picture covers it
    vec3 straight = color.a > 0.0 ? color.rgb / color.a : vec3(1.0);
    outColor = vec4(mix(vec3(1.0), straight, color.a), 1.0);
  } else {
    outColor = color;
  }
}`;

// Per vertex: position (2), uv (2), colour (4), mask place (2), mask's piece of its sheet (4), clip (4), flags (1)
const FLOATS = 19;
const STRIDE = FLOATS * 4;
const ATTRIBUTES = [
  ["a_pos", 2, 0],
  ["a_uv", 2, 2],
  ["a_color", 4, 4],
  ["a_maskN", 2, 8],
  ["a_maskRect", 4, 10],
  ["a_clip", 4, 14],
  ["a_flags", 1, 18],
] as const;
const FLAG_GREY = 1;
const FLAG_MASK = 2;
const FAR = 1e9;
const FULL = [0, 1, 0, 1] as const;
const FULL_WHITE = [1, 1, 1, 1] as const;
const TEXT_KEEP_FRAMES = 600;
const TEXT_SWEEP_FRAMES = 300;

type Blend = "blend" | "add" | "mod";
type TextureEntry = {
  state: "loading" | "ready" | "failed";
  texture: WebGLTexture | null;
  width: number;
  height: number;
  /** The decoded picture, which text with icons draws from */
  bitmap: ImageBitmap | null;
};
type ReadyTexture = TextureEntry & { texture: WebGLTexture };
type Batch = {
  texture: WebGLTexture;
  sampler: WebGLSampler;
  blend: Blend;
  mask: WebGLTexture | null;
  first: number;
  count: number;
};

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
  texture: WebGLTexture;
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

/** A renderer on the canvas; null without WebGL2. Throws when its shaders do not build */
export const createGlRenderer = (canvas: HTMLCanvasElement, onArtArrived: () => void): GlRenderer | null => {
  const gl = canvas.getContext("webgl2", {
    alpha: true,
    premultipliedAlpha: true,
    antialias: true,
    depth: false,
    stencil: false,
    preserveDrawingBuffer: true,
  });
  if (!gl) return null;

  // Shaders
  const compile = (type: number, source: string): WebGLShader => {
    const shader = gl.createShader(type);
    if (!shader) throw new Error("no shader");
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader) ?? "shader");
    return shader;
  };
  const program = gl.createProgram();
  gl.attachShader(program, compile(gl.VERTEX_SHADER, VERTEX));
  gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAGMENT));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program) ?? "program");
  // biome-ignore lint/correctness/useHookAtTopLevel: WebGL's useProgram, not a React hook
  gl.useProgram(program);
  const uniform = (name: string): WebGLUniformLocation | null => gl.getUniformLocation(program, name);
  const uScreen = uniform("u_screen");
  const uMode = uniform("u_mode");
  gl.uniform1i(uniform("u_tex"), 0);
  gl.uniform1i(uniform("u_mask"), 1);

  // The vertex buffer, and the indices of its quads (two triangles each)
  const vao = gl.createVertexArray();
  gl.bindVertexArray(vao);
  const vertexBuffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, vertexBuffer);
  for (const [name, size, offset] of ATTRIBUTES) {
    const location = gl.getAttribLocation(program, name);
    gl.enableVertexAttribArray(location);
    gl.vertexAttribPointer(location, size, gl.FLOAT, false, STRIDE, offset * 4);
  }
  const indexBuffer = gl.createBuffer();
  gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer);
  let capacity = 0;
  let vertices = new Float32Array(0);
  const ensureCapacity = (quads: number): void => {
    if (quads <= capacity) return;
    capacity = Math.max(quads, capacity * 2, 4096);
    const grown = new Float32Array(capacity * 4 * FLOATS);
    grown.set(vertices);
    vertices = grown;
    const indices = new Uint32Array(capacity * 6);
    for (let quad = 0; quad < capacity; quad++) {
      const base = quad * 4;
      const at = quad * 6;
      indices[at] = base;
      indices[at + 1] = base + 1;
      indices[at + 2] = base + 2;
      indices[at + 3] = base + 2;
      indices[at + 4] = base + 1;
      indices[at + 5] = base + 3;
    }
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, indices, gl.STATIC_DRAW);
  };
  ensureCapacity(4096);

  // Samplers: clamped (most art), repeating (tiled art, coordinates past the edge), and flat (text, colours)
  const makeSampler = (wrap: number, isMipmapped: boolean): WebGLSampler => {
    const sampler = gl.createSampler();
    gl.samplerParameteri(sampler, gl.TEXTURE_WRAP_S, wrap);
    gl.samplerParameteri(sampler, gl.TEXTURE_WRAP_T, wrap);
    gl.samplerParameteri(sampler, gl.TEXTURE_MIN_FILTER, isMipmapped ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR);
    gl.samplerParameteri(sampler, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    return sampler;
  };
  const CLAMP = makeSampler(gl.CLAMP_TO_EDGE, true);
  const REPEAT = makeSampler(gl.REPEAT, true);
  const FLAT = makeSampler(gl.CLAMP_TO_EDGE, false);

  // Textures, by URL: loaded once, kept
  const textures = new Map<string, TextureEntry>();
  const white = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, white);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([255, 255, 255, 255]));
  let isDisposed = false;
  const loadTexture = async (url: string, entry: TextureEntry): Promise<void> => {
    try {
      const response = await fetch(url);
      if (!response.ok) throw new Error(String(response.status));
      const bitmap = await createImageBitmap(await response.blob(), {
        premultiplyAlpha: "premultiply",
        colorSpaceConversion: "none",
      });
      if (isDisposed) return;
      const texture = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bitmap);
      gl.generateMipmap(gl.TEXTURE_2D);
      entry.texture = texture;
      entry.width = bitmap.width;
      entry.height = bitmap.height;
      entry.bitmap = bitmap;
      entry.state = "ready";
    } catch {
      entry.state = "failed";
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

  // The frame being built: quads in order, cut into draws where the texture, mask, sampler or blend changes
  let quadCount = 0;
  const batches: Batch[] = [];
  let batchCount = 0;
  let batch: Batch | null = null;
  const begin = (texture: WebGLTexture, sampler: WebGLSampler, blend: Blend, mask: WebGLTexture | null): void => {
    if (
      batch &&
      batch.texture === texture &&
      batch.sampler === sampler &&
      batch.blend === blend &&
      batch.mask === mask
    ) {
      return;
    }
    let next = batches[batchCount];
    if (next) {
      next.texture = texture;
      next.sampler = sampler;
      next.blend = blend;
      next.mask = mask;
      next.first = quadCount;
      next.count = 0;
    } else {
      next = { texture, sampler, blend, mask, first: quadCount, count: 0 };
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
  let maskTexture: WebGLTexture | null = null;
  const maskRect = new Float64Array(4);
  const maskBox = new Float64Array(4);

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
    maskTexture = null;
  };
  const isOutside = (x: number, y: number, w: number, h: number): boolean =>
    x >= clipX1 || y >= clipY1 || x + w <= clipX0 || y + h <= clipY0;

  /** The quad as it stands added to the batch begun */
  const quad = (): void => {
    ensureCapacity(quadCount + 1);
    const hasMask = maskTexture !== null;
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
      vertices[at + 7] = colors[color + 3] as number;
      if (hasMask) {
        vertices[at + 8] = (x - (maskBox[0] as number)) / (maskBox[2] || 1);
        vertices[at + 9] = (y - (maskBox[1] as number)) / (maskBox[3] || 1);
        vertices[at + 10] = maskRect[0] as number;
        vertices[at + 11] = maskRect[1] as number;
        vertices[at + 12] = maskRect[2] as number;
        vertices[at + 13] = maskRect[3] as number;
      } else {
        vertices[at + 8] = 0;
        vertices[at + 9] = 0;
        vertices[at + 10] = 0;
        vertices[at + 11] = 0;
        vertices[at + 12] = 1;
        vertices[at + 13] = 1;
      }
      vertices[at + 14] = clipX0;
      vertices[at + 15] = clipY0;
      vertices[at + 16] = clipX1;
      vertices[at + 17] = clipY1;
      vertices[at + 18] = flags;
      at += FLOATS;
    }
    quadCount += 1;
    (batch as Batch).count += 1;
  };

  const blendOf = (blend: string | undefined): Blend => (blend === "ADD" ? "add" : blend === "MOD" ? "mod" : "blend");

  // A mask over a texture: its texture (or an atlas's piece of a sheet) and where it is on the screen. False while
  // its art loads: the item waits for it rather than flash unmasked
  const prepareMask = (item: TextureItem): boolean => {
    if (!item.mask && !item.maskAtlas) return true;
    let entry: ReadyTexture | null;
    if (item.maskAtlas) {
      const atlas = getAtlas(item.maskAtlas);
      if (atlas === undefined) return false;
      if (!atlas) return true;
      entry = getTexture(artUrl(atlas.fdid));
      maskRect[0] = atlas.left;
      maskRect[1] = atlas.top;
      maskRect[2] = atlas.right - atlas.left;
      maskRect[3] = atlas.bottom - atlas.top;
    } else {
      const url = textureUrl(item.mask);
      entry = getTexture(url);
      if (hasFailed(url)) return true;
      maskRect[0] = 0;
      maskRect[1] = 0;
      maskRect[2] = 1;
      maskRect[3] = 1;
    }
    if (!entry) return false;
    maskTexture = entry.texture;
    const box = item.maskBox;
    maskBox[0] = box ? (box[0] ?? 0) : item.x;
    maskBox[1] = box ? (box[1] ?? 0) : item.y;
    maskBox[2] = box ? (box[2] ?? 0) : item.w;
    maskBox[3] = box ? (box[3] ?? 0) : item.h;
    return true;
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

  // Nine-sliced, as the game draws it: corners at their own size, edges and middle stretched
  const drawSlices = (item: TextureItem, atlas: AtlasInfo, slice: readonly number[]): void => {
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
        setRect(item.x + x, item.y + y, width, height);
        setUvRect(u0, u0 + sourceWidth / fileWidth, v0, v0 + sourceHeight / fileHeight);
        quad();
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
    if (!prepareMask(item)) return;
    flags = (item.ds ? FLAG_GREY : 0) | (maskTexture ? FLAG_MASK : 0);
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
      begin(white, FLAT, blend, maskTexture);
      placeCorners(item, x, y, w, h);
      setUvRect(0, 1, 0, 1);
      quad();
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
      begin(white, FLAT, blend, maskTexture);
      placeCorners(item, x, y, w, h);
      setUvRect(0, 1, 0, 1);
      quad();
      return;
    }
    if (item.atlas) {
      const atlas = getAtlas(item.atlas);
      if (!atlas) return; // (loading, or none)
      const sheet = getTexture(artUrl(atlas.fdid));
      if (!sheet) return;
      setTint(item.vc, alpha);
      begin(sheet.texture, CLAMP, blend, maskTexture);
      if (atlas.slice) {
        drawSlices(item, atlas, atlas.slice);
        return;
      }
      // Coordinates set after the atlas are the atlas's own, 0 to 1 across it, as in the game (the game's top tabs
      // turn theirs over with 0, 1, 1, 0): a part of the atlas, or the atlas turned over
      const tc = item.tc && !item.tcTurned ? item.tc : FULL;
      const spanX = atlas.right - atlas.left;
      const spanY = atlas.bottom - atlas.top;
      placeCorners(item, x, y, w, h);
      setUvRect(
        atlas.left + (tc[0] ?? 0) * spanX,
        atlas.left + (tc[1] ?? 1) * spanX,
        atlas.top + (tc[2] ?? 0) * spanY,
        atlas.top + (tc[3] ?? 1) * spanY,
      );
      quad();
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
    let isRepeating = Math.max(left, right, top, bottom) > 1.001 || Math.min(left, right, top, bottom) < -0.001;
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
      isRepeating = true;
    } else {
      setUvRect(left, right, top, bottom);
    }
    setTint(item.vc, alpha);
    begin(texture.texture, isRepeating ? REPEAT : CLAMP, blend, maskTexture);
    placeCorners(item, x, y, w, h);
    quad();
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
        begin(texture.texture, isTiled ? REPEAT : CLAMP, "blend", null);
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
    begin(texture.texture, REPEAT, "blend", null);
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
      begin(texture.texture, CLAMP, "blend", null);
    } else {
      const c = item.c ?? FULL_WHITE;
      setColor(c[0] ?? 1, c[1] ?? 1, c[2] ?? 1, (c[3] ?? 1) * alpha);
      begin(white, FLAT, "blend", null);
    }
    quad();
  };

  // Text: each string laid out as the page's text was (lines as Lua wrapped them, colour codes, inline icons, shadow
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

  const parseLine = (line: string, colors: string[], lineHeight: number): Run[] => {
    const runs: Run[] = [];
    let last = 0;
    const color = (): string | null => {
      const top = colors[colors.length - 1];
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
      if (match[1]) colors.push(match[1]);
      else if (token === "|r") colors.pop();
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
    // Tinted: the colour seen through the picture's shape, as the page's text drew it
    const pw = Math.max(1, Math.ceil(run.w * resolution));
    const ph = Math.max(1, Math.ceil(run.h * resolution));
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
      item.w,
      item.h,
      item.cursor && isCursorOn,
      resolution,
    ]);

  const layoutText = (item: FontStringItem) => {
    const font = `${item.fs}px ${fontFamily(item.f)}`;
    const metrics = metricsOf(font);
    textContext.font = font;
    const colors: string[] = [];
    const lines = item.lines.map((line) => parseLine(line, colors, item.lh));
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
    // Centred in its line as the page's text was: the font's ascent and descent rounded to pixels, the room left
    // shared out above and below (the upper share rounded down)
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
      if (width > item.w) x = 0; // too long for its box: from the start, running over the end (as the page's text did)
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

  const rasterizeText = (item: FontStringItem): TextValue => {
    const layout = layoutText(item);
    const width = Math.max(1, Math.ceil((layout.maxX - layout.minX) * resolution));
    const height = Math.max(1, Math.ceil((layout.maxY - layout.minY) * resolution));
    textCanvas.width = width;
    textCanvas.height = height;
    const context = textContext;
    context.setTransform(resolution, 0, 0, resolution, -layout.minX * resolution, -layout.minY * resolution);
    context.clearRect(layout.minX, layout.minY, layout.maxX - layout.minX, layout.maxY - layout.minY);
    context.font = layout.font;
    context.textBaseline = "alphabetic";
    let isComplete = true;
    const passes: [number, number][] = [];
    if (item.sh) passes.push([item.sh[0] ?? 0, -(item.sh[1] ?? 0)]);
    if (item.fl && /OUTLINE/.test(item.fl)) passes.push([-1, 0], [1, 0], [0, -1], [0, 1]);
    // Shadows and outline first, in black, under the text (pictures cast none)
    for (const [ox, oy] of passes) {
      context.fillStyle = "#000";
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
            drawPicture(context, picture.entry, picture.crop, run, cursor + run.dx, top);
          }
          cursor += run.w;
        }
      }
    }
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, textCanvas);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    return {
      texture,
      x: layout.minX,
      y: layout.minY,
      w: width / resolution,
      h: height / resolution,
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
      if (!value?.isComplete) {
        if (value) gl.deleteTexture(value.texture);
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
    begin(value.texture, FLAT, "blend", null);
    setRect(x, y, value.w, value.h);
    setUvRect(0, 1, 0, 1);
    setColor(1, 1, 1, item.a ?? 1);
    quad();
  };
  const forgetOldText = (): void => {
    for (const [key, value] of textCache) {
      if (frameNumber - value.used > TEXT_KEEP_FRAMES) {
        gl.deleteTexture(value.texture);
        textCache.delete(key);
      }
    }
  };

  const setBlend = (blend: Blend): void => {
    if (blend === "add") {
      gl.blendFuncSeparate(gl.ONE, gl.ONE, gl.ZERO, gl.ONE);
      gl.uniform1i(uMode, 0);
    } else if (blend === "mod") {
      gl.blendFuncSeparate(gl.DST_COLOR, gl.ZERO, gl.ZERO, gl.ONE);
      gl.uniform1i(uMode, 1);
    } else {
      gl.blendFuncSeparate(gl.ONE, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      gl.uniform1i(uMode, 0);
    }
  };

  let screenWidth = 1;
  let screenHeight = 1;
  let hasCursor = false;
  const stats: GlStats = { quads: 0, draws: 0, ms: 0, texts: 0 };

  const draw = (items: SceneItems): void => {
    const started = performance.now();
    frameNumber += 1;
    quadCount = 0;
    batchCount = 0;
    batch = null;
    hasCursor = false;
    for (let index = 0; index < items.length; index++) {
      const item = items[index];
      if (!item) continue;
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
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.enable(gl.BLEND);
    gl.useProgram(program);
    gl.bindVertexArray(vao);
    gl.uniform2f(uScreen, screenWidth, screenHeight);
    gl.bindBuffer(gl.ARRAY_BUFFER, vertexBuffer);
    // (the part of the buffer used, without a view made of it each frame)
    gl.bufferData(gl.ARRAY_BUFFER, vertices, gl.STREAM_DRAW, 0, quadCount * 4 * FLOATS);
    let blend: Blend | null = null;
    for (let index = 0; index < batchCount; index++) {
      const each = batches[index] as Batch;
      if (!each.count) continue;
      if (each.blend !== blend) {
        setBlend(each.blend);
        blend = each.blend;
      }
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, each.texture);
      gl.bindSampler(0, each.sampler);
      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, each.mask ?? white);
      gl.bindSampler(1, CLAMP);
      gl.drawElements(gl.TRIANGLES, each.count * 6, gl.UNSIGNED_INT, each.first * 6 * 4);
    }
    if (frameNumber % TEXT_SWEEP_FRAMES === 0) forgetOldText();
    stats.quads = quadCount;
    stats.draws = batchCount;
    stats.ms = performance.now() - started;
    stats.texts = textCache.size;
  };

  return {
    kind: "webgl2",
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
      for (const value of textCache.values()) gl.deleteTexture(value.texture);
      textCache.clear();
      fontMetrics.clear();
      textEntries = new WeakMap();
      textGeneration += 1;
    },
    blink: () => {
      isCursorOn = !isCursorOn;
    },
    clear: () => {
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
    },
    dispose: () => {
      isDisposed = true;
      gl.getExtension("WEBGL_lose_context")?.loseContext();
    },
  };
};
