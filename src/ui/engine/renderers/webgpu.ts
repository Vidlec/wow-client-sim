// The WebGPU backend (backend.ts): the renderer's quads drawn in render passes on the screen (and, for a flattened
// frame, on the layer it is put back from), a pipeline for each blend, a bind group for each texture, sampling and
// masks met (kept while those textures live). Mipmaps are made on the GPU, a level at a time from the one above.
import {
  type Backend,
  type Batch,
  type Blend,
  FLAG_ALPHAKEY,
  FLAG_BLACK_U,
  FLAG_BLACK_V,
  FLAG_SOLID,
  FLAG_WHITE_U,
  FLAG_WHITE_V,
  flagMask,
  flagMaskBlack,
  flagMaskWhite,
  type GpuTexture,
  GREY_OFFSET,
  MASKS,
  maskOffset,
  SAMPLING,
  SAMPLINGS,
  STRIDE,
} from "./backend.ts";

const EACH_MASK = Array.from({ length: MASKS }, (_, mask) => mask);

const SHADER = /* wgsl */ `
struct Screen { size: vec2f, unused: vec2f };
@group(0) @binding(0) var<uniform> screen: Screen;
@group(0) @binding(1) var art: texture_2d<f32>;
@group(0) @binding(2) var artSampler: sampler;
@group(0) @binding(3) var maskSampler: sampler;
${EACH_MASK.map((mask) => `@group(0) @binding(${4 + mask}) var mask${mask}: texture_2d<f32>;`).join("\n")}
override mode: u32 = 0u;

struct Vertex {
  @location(0) position: vec2f, @location(1) uv: vec2f, @location(2) color: vec4f, @location(3) clip: vec4f,
  @location(4) flags: f32, @location(11) grey: f32,
${EACH_MASK.map((mask) => `  @location(${5 + mask * 2}) maskN${mask}: vec2f, @location(${6 + mask * 2}) maskRect${mask}: vec4f,`).join("\n")}
};
struct Fragment {
  @builtin(position) place: vec4f, @location(0) uv: vec2f, @location(1) color: vec4f, @location(2) clip: vec4f,
  @location(3) @interpolate(flat) flags: u32, @location(4) position: vec2f, @location(11) @interpolate(flat) grey: f32,
${EACH_MASK.map((mask) => `  @location(${5 + mask * 2}) maskN${mask}: vec2f, @location(${6 + mask * 2}) maskRect${mask}: vec4f,`).join("\n")}
};

@vertex fn vertexMain(vertex: Vertex) -> Fragment {
  var out: Fragment;
  out.place = vec4f(vertex.position.x / screen.size.x * 2.0 - 1.0, 1.0 - vertex.position.y / screen.size.y * 2.0, 0.0, 1.0);
  out.uv = vertex.uv;
  out.color = vertex.color;
  out.clip = vertex.clip;
  out.flags = u32(vertex.flags + 0.5);
  out.grey = vertex.grey;
  out.position = vertex.position;
${EACH_MASK.map((mask) => `  out.maskN${mask} = vertex.maskN${mask};\n  out.maskRect${mask} = vertex.maskRect${mask};`).join("\n")}
  return out;
}

@fragment fn fragmentMain(in: Fragment) -> @location(0) vec4f {
  // (sampled first, where every pixel of the quad still runs: premultiplied; a little sharper than plain mipmapping,
  // as the browser's own scaling of pictures is; a mask read at its edge past its box)
  var texel = textureSampleBias(art, artSampler, in.uv, -0.5);
${EACH_MASK.map((mask) => `  let masked${mask} = textureSample(mask${mask}, maskSampler, in.maskRect${mask}.xy + clamp(in.maskN${mask}, vec2f(0.0), vec2f(1.0)) * in.maskRect${mask}.zw).a;`).join("\n")}
  if (in.position.x < in.clip.x || in.position.y < in.clip.y || in.position.x > in.clip.z || in.position.y > in.clip.w) {
    discard;
  }
  // Past the texture's own edges: nothing (CLAMPTOBLACKADDITIVE), or white (CLAMPTOWHITE), each way as it is set
  let isOutU = in.uv.x < -0.0001 || in.uv.x > 1.0001;
  let isOutV = in.uv.y < -0.0001 || in.uv.y > 1.0001;
  if ((isOutU && (in.flags & ${FLAG_BLACK_U}u) != 0u) || (isOutV && (in.flags & ${FLAG_BLACK_V}u) != 0u)) { discard; }
  if ((isOutU && (in.flags & ${FLAG_WHITE_U}u) != 0u) || (isOutV && (in.flags & ${FLAG_WHITE_V}u) != 0u)) {
    texel = vec4f(1.0);
  }
  if ((in.flags & ${FLAG_ALPHAKEY}u) != 0u) {
    if (texel.a < 0.5) { discard; }
    texel = vec4f(texel.rgb / texel.a, 1.0);
  } else if ((in.flags & ${FLAG_SOLID}u) != 0u) {
    texel = vec4f(select(vec3f(0.0), texel.rgb / texel.a, texel.a > 0.0), 1.0);
  }
  if (in.grey > 0.0) {
    texel = vec4f(mix(texel.rgb, vec3f(dot(texel.rgb, vec3f(0.2126, 0.7152, 0.0722))), in.grey), texel.a);
  }
  var color = vec4f(texel.rgb * in.color.rgb, texel.a) * in.color.a;
${EACH_MASK.map(
  (mask) => `  if ((in.flags & ${flagMask(mask)}u) != 0u) {
    let outside${mask} = any(in.maskN${mask} < vec2f(0.0)) || any(in.maskN${mask} > vec2f(1.0));
    if (outside${mask} && (in.flags & ${flagMaskBlack(mask)}u) != 0u) { discard; }
    if (!(outside${mask} && (in.flags & ${flagMaskWhite(mask)}u) != 0u)) { color *= masked${mask}; }
  }`,
).join("\n")}
  if (mode == 1u) {
    // MOD: the screen times the colour, where the picture covers it
    let straight = select(vec3f(1.0), color.rgb / color.a, color.a > 0.0);
    return vec4f(mix(vec3f(1.0), straight, color.a), 1.0);
  }
  return color;
}
`;

// Mipmaps: each level drawn from the one above, a pixel the average of the four under it (one linear sample between
// them)
const MIP_SHADER = /* wgsl */ `
@group(0) @binding(0) var above: texture_2d<f32>;
@group(0) @binding(1) var aboveSampler: sampler;
struct Out { @builtin(position) place: vec4f, @location(0) uv: vec2f };
@vertex fn vertexMain(@builtin(vertex_index) index: u32) -> Out {
  let corner = vec2f(f32((index << 1u) & 2u), f32(index & 2u));
  var out: Out;
  out.place = vec4f(corner * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0);
  out.uv = corner;
  return out;
}
@fragment fn fragmentMain(in: Out) -> @location(0) vec4f { return textureSample(above, aboveSampler, in.uv); }
`;

const TEXTURE_FORMAT: GPUTextureFormat = "rgba8unorm";
// WebGPU's flags (the browser's GPUShaderStage, GPUBufferUsage, GPUTextureUsage, which TypeScript's DOM types leave out)
const STAGE_VERTEX = 1;
const STAGE_FRAGMENT = 2;
const BUFFER_COPY_DST = 8;
const BUFFER_INDEX = 16;
const BUFFER_VERTEX = 32;
const BUFFER_UNIFORM = 64;
const TEXTURE_COPY_DST = 2;
const TEXTURE_BINDING = 4;
const TEXTURE_RENDER_ATTACHMENT = 16;

type WebGpuTexture = GpuTexture & { readonly texture: GPUTexture; readonly view: GPUTextureView };

const blendState = (blend: Blend): GPUBlendState => {
  if (blend === "add") {
    return {
      color: { srcFactor: "one", dstFactor: "one", operation: "add" },
      alpha: { srcFactor: "zero", dstFactor: "one", operation: "add" },
    };
  }
  if (blend === "mod") {
    return {
      color: { srcFactor: "dst", dstFactor: "zero", operation: "add" },
      alpha: { srcFactor: "zero", dstFactor: "one", operation: "add" },
    };
  }
  return {
    color: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
    alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
  };
};

/** The GPU's device, asked for once for the page (every canvas shares it); null where WebGPU is not to be had */
let devicePromise: Promise<GPUDevice | null> | null = null;
const getDevice = (): Promise<GPUDevice | null> => {
  devicePromise ??= (async () => {
    try {
      const adapter = await navigator.gpu?.requestAdapter();
      if (!adapter) return null;
      const device = await adapter.requestDevice();
      // (lost: the next renderer asks for a device again)
      void device.lost.then(() => {
        devicePromise = null;
      });
      device.addEventListener("uncapturederror", (event) => {
        console.warn("AddonSim WebGPU:", (event as GPUUncapturedErrorEvent).error.message);
      });
      return device;
    } catch (problem) {
      console.warn("AddonSim: no WebGPU", problem);
      return null;
    }
  })();
  return devicePromise;
};

/** The backend on the canvas; null without WebGPU */
export const createWebGpuBackend = async (canvas: HTMLCanvasElement): Promise<Backend | null> => {
  const device = await getDevice();
  if (!device) return null;
  const context = canvas.getContext("webgpu") as GPUCanvasContext | null;
  if (!context) return null;
  const canvasFormat = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format: canvasFormat, alphaMode: "premultiplied" });

  const module = device.createShaderModule({ code: SHADER });
  const layout = device.createBindGroupLayout({
    entries: [
      { binding: 0, visibility: STAGE_VERTEX, buffer: { type: "uniform" } },
      { binding: 1, visibility: STAGE_FRAGMENT, texture: {} },
      { binding: 2, visibility: STAGE_FRAGMENT, sampler: {} },
      { binding: 3, visibility: STAGE_FRAGMENT, sampler: {} },
      ...EACH_MASK.map((mask) => ({ binding: 4 + mask, visibility: STAGE_FRAGMENT, texture: {} })),
    ],
  });
  const pipelineLayout = device.createPipelineLayout({ bindGroupLayouts: [layout] });
  const vertexLayout: GPUVertexBufferLayout = {
    arrayStride: STRIDE,
    attributes: [
      { shaderLocation: 0, offset: 0, format: "float32x2" },
      { shaderLocation: 1, offset: 8, format: "float32x2" },
      { shaderLocation: 2, offset: 16, format: "float32x4" },
      { shaderLocation: 3, offset: 32, format: "float32x4" },
      { shaderLocation: 4, offset: 48, format: "float32" },
      { shaderLocation: 11, offset: GREY_OFFSET * 4, format: "float32" },
      ...EACH_MASK.flatMap((mask): GPUVertexAttribute[] => [
        { shaderLocation: 5 + mask * 2, offset: maskOffset(mask) * 4, format: "float32x2" },
        { shaderLocation: 6 + mask * 2, offset: (maskOffset(mask) + 2) * 4, format: "float32x4" },
      ]),
    ],
  };
  const makePipeline = (blend: Blend): GPURenderPipeline =>
    device.createRenderPipeline({
      layout: pipelineLayout,
      vertex: { module, entryPoint: "vertexMain", buffers: [vertexLayout] },
      fragment: {
        module,
        entryPoint: "fragmentMain",
        constants: { mode: blend === "mod" ? 1 : 0 },
        targets: [{ format: canvasFormat, blend: blendState(blend) }],
      },
      primitive: { topology: "triangle-list" },
    });
  const pipelines: Record<Blend, GPURenderPipeline> = {
    blend: makePipeline("blend"),
    add: makePipeline("add"),
    mod: makePipeline("mod"),
  };

  const screenBuffer = device.createBuffer({ size: 16, usage: BUFFER_UNIFORM | BUFFER_COPY_DST });
  const screenValues = new Float32Array(4);
  // Mipmapped, each way clamped, repeated or mirrored (backend.ts: samplingFor), and flat
  const MODES: GPUAddressMode[] = ["clamp-to-edge", "repeat", "mirror-repeat"];
  const samplers: GPUSampler[] = [];
  for (let across = 0; across < 3; across++) {
    for (let down = 0; down < 3; down++) {
      samplers[across * 3 + down] = device.createSampler({
        addressModeU: MODES[across] as GPUAddressMode,
        addressModeV: MODES[down] as GPUAddressMode,
        magFilter: "linear",
        minFilter: "linear",
        mipmapFilter: "linear",
      });
    }
  }
  samplers[SAMPLING.flat] = device.createSampler({ magFilter: "linear", minFilter: "linear" });
  const maskSampler = samplers[SAMPLING.clamp] as GPUSampler;

  // Mipmaps, made on the GPU
  const mipModule = device.createShaderModule({ code: MIP_SHADER });
  const mipPipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: { module: mipModule, entryPoint: "vertexMain" },
    fragment: { module: mipModule, entryPoint: "fragmentMain", targets: [{ format: TEXTURE_FORMAT }] },
    primitive: { topology: "triangle-list" },
  });
  const mipSampler = device.createSampler({ magFilter: "linear", minFilter: "linear" });
  const makeMipmaps = (texture: GPUTexture): void => {
    const encoder = device.createCommandEncoder();
    for (let level = 1; level < texture.mipLevelCount; level++) {
      const group = device.createBindGroup({
        layout: mipPipeline.getBindGroupLayout(0),
        entries: [
          { binding: 0, resource: texture.createView({ baseMipLevel: level - 1, mipLevelCount: 1 }) },
          { binding: 1, resource: mipSampler },
        ],
      });
      const pass = encoder.beginRenderPass({
        colorAttachments: [
          {
            view: texture.createView({ baseMipLevel: level, mipLevelCount: 1 }),
            loadOp: "clear",
            storeOp: "store",
            clearValue: [0, 0, 0, 0],
          },
        ],
      });
      pass.setPipeline(mipPipeline);
      pass.setBindGroup(0, group);
      pass.draw(3);
      pass.end();
    }
    device.queue.submit([encoder.finish()]);
  };

  const wrap = (texture: GPUTexture): WebGpuTexture => ({
    width: texture.width,
    height: texture.height,
    texture,
    view: texture.createView(),
  });
  const upload = (source: ImageBitmap | HTMLCanvasElement | OffscreenCanvas, isMipmapped: boolean): WebGpuTexture => {
    const width = Math.max(1, source.width);
    const height = Math.max(1, source.height);
    const levels = isMipmapped ? Math.floor(Math.log2(Math.max(width, height))) + 1 : 1;
    const texture = device.createTexture({
      size: [width, height],
      format: TEXTURE_FORMAT,
      mipLevelCount: levels,
      usage: TEXTURE_BINDING | TEXTURE_COPY_DST | TEXTURE_RENDER_ATTACHMENT,
    });
    device.queue.copyExternalImageToTexture({ source }, { texture, premultipliedAlpha: true }, [width, height]);
    if (levels > 1) makeMipmaps(texture);
    return wrap(texture);
  };

  const whiteTexture = device.createTexture({
    size: [1, 1],
    format: TEXTURE_FORMAT,
    usage: TEXTURE_BINDING | TEXTURE_COPY_DST,
  });
  device.queue.writeTexture({ texture: whiteTexture }, new Uint8Array([255, 255, 255, 255]), {}, [1, 1]);
  const white = wrap(whiteTexture);

  // A bind group for each texture, sampling and masks met: kept as long as its textures are (weakly, by them)
  type Groups = WeakMap<WebGpuTexture, Groups | GPUBindGroup>;
  const groups: Groups[] = Array.from({ length: SAMPLINGS }, () => new WeakMap());
  const groupFor = (batch: Batch): GPUBindGroup => {
    const texture = batch.texture as WebGpuTexture;
    const masks = [batch.mask0 ?? white, batch.mask1 ?? white, batch.mask2 ?? white] as WebGpuTexture[];
    let level = groups[batch.sampling] as Groups;
    for (const key of [texture, masks[0], masks[1]] as WebGpuTexture[]) {
      let next = level.get(key) as Groups | undefined;
      if (!next) {
        next = new WeakMap();
        level.set(key, next);
      }
      level = next;
    }
    let group = level.get(masks[2] as WebGpuTexture) as GPUBindGroup | undefined;
    if (!group) {
      group = device.createBindGroup({
        layout,
        entries: [
          { binding: 0, resource: { buffer: screenBuffer } },
          { binding: 1, resource: texture.view },
          { binding: 2, resource: samplers[batch.sampling] as GPUSampler },
          { binding: 3, resource: maskSampler },
          ...masks.map((mask, index) => ({ binding: 4 + index, resource: mask.view })),
        ],
      });
      level.set(masks[2] as WebGpuTexture, group);
    }
    return group;
  };

  // The vertex buffer (grown as needed) and the quads' indices (two triangles each)
  let capacity = 0;
  let vertexBuffer: GPUBuffer | null = null;
  let indexBuffer: GPUBuffer | null = null;
  const ensureCapacity = (quads: number): void => {
    if (quads <= capacity && vertexBuffer && indexBuffer) return;
    capacity = Math.max(quads, capacity * 2, 4096);
    vertexBuffer?.destroy();
    indexBuffer?.destroy();
    vertexBuffer = device.createBuffer({
      size: capacity * 4 * STRIDE,
      usage: BUFFER_VERTEX | BUFFER_COPY_DST,
    });
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
    indexBuffer = device.createBuffer({ size: indices.byteLength, usage: BUFFER_INDEX | BUFFER_COPY_DST });
    device.queue.writeBuffer(indexBuffer, 0, indices);
  };
  ensureCapacity(4096);

  // The layer flattened frames are drawn into: the screen's size, made again when that changes
  let layer: WebGpuTexture | null = null;
  const getLayer = (): WebGpuTexture => {
    if (!layer || layer.width !== canvas.width || layer.height !== canvas.height) {
      layer?.texture.destroy();
      layer = wrap(
        device.createTexture({
          size: [Math.max(1, canvas.width), Math.max(1, canvas.height)],
          format: canvasFormat,
          usage: TEXTURE_BINDING | TEXTURE_RENDER_ATTACHMENT,
        }),
      );
    }
    return layer;
  };

  let isDisposed = false;
  const lostListeners: (() => void)[] = [];
  void device.lost.then(() => {
    if (isDisposed) return;
    for (const listener of lostListeners) listener();
  });

  return {
    white,
    layer: getLayer,
    maxTextureSize: device.limits.maxTextureDimension2D,
    createTexture: (bitmap) => upload(bitmap, true),
    createCanvasTexture: (source) => upload(source, false),
    deleteTexture: (texture) => {
      if (texture !== white) (texture as WebGpuTexture).texture.destroy();
    },
    draw: (vertices, quadCount, batches, batchCount, screenWidth, screenHeight) => {
      if (isDisposed || canvas.width === 0 || canvas.height === 0) return;
      ensureCapacity(quadCount);
      screenValues[0] = screenWidth;
      screenValues[1] = screenHeight;
      device.queue.writeBuffer(screenBuffer, 0, screenValues);
      if (quadCount > 0) {
        device.queue.writeBuffer(
          vertexBuffer as GPUBuffer,
          0,
          vertices.buffer,
          vertices.byteOffset,
          quadCount * 4 * STRIDE,
        );
      }
      const encoder = device.createCommandEncoder();
      const screenView = context.getCurrentTexture().createView();
      // A pass on the screen (cleared the first time, kept after) or on the layer (cleared for each run drawn into it)
      let isScreenStarted = false;
      const beginPass = (isLayer: boolean): GPURenderPassEncoder => {
        const view = isLayer ? getLayer().view : screenView;
        const loadOp: GPULoadOp = isLayer || !isScreenStarted ? "clear" : "load";
        if (!isLayer) isScreenStarted = true;
        const opened = encoder.beginRenderPass({
          colorAttachments: [{ view, loadOp, storeOp: "store", clearValue: [0, 0, 0, 0] }],
        });
        opened.setVertexBuffer(0, vertexBuffer);
        opened.setIndexBuffer(indexBuffer as GPUBuffer, "uint32");
        return opened;
      };
      let isOnLayer = false;
      let pass = beginPass(false);
      let blend: Blend | null = null;
      for (let index = 0; index < batchCount; index++) {
        const batch = batches[index] as Batch;
        if (!batch.count) continue;
        if (batch.isLayer !== isOnLayer) {
          pass.end();
          isOnLayer = batch.isLayer;
          pass = beginPass(isOnLayer);
          blend = null;
        }
        if (batch.blend !== blend) {
          pass.setPipeline(pipelines[batch.blend]);
          blend = batch.blend;
        }
        pass.setBindGroup(0, groupFor(batch));
        pass.drawIndexed(batch.count * 6, 1, batch.first * 6);
      }
      pass.end();
      device.queue.submit([encoder.finish()]);
    },
    finished: () => device.queue.onSubmittedWorkDone(),
    onLost: (listener) => {
      lostListeners.push(listener);
    },
    dispose: () => {
      isDisposed = true;
      vertexBuffer?.destroy();
      indexBuffer?.destroy();
      layer?.texture.destroy();
      whiteTexture.destroy();
      screenBuffer.destroy();
      context.unconfigure();
    },
  };
};
