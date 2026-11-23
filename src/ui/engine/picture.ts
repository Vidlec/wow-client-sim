// The picture pages: a saved scene drawn once, nothing live (no socket, no controller). src/cli/shots.ts and the
// scenario runner's links depend on these addresses and on the title saying "ready".
//
//   ?shot=path            one saved scene alone, at its own size and nothing round it, for headless Chrome to take a
//                         picture of. &backdrop=<texture> puts a picture of the game's behind it, as the world would
//                         be (a loading screen: "Interface\Glues\LoadingScreens\LoadScreenBarrens"); &crop=x,y,w,h
//                         shows only that part of the screen; &renderer=gl draws it with the GPU's renderer (else the
//                         page's elements). The title says "ready" once its art has arrived ("missing": no scene).
//   ?compare=a|b          two saved scenes side by side (the reference and now), each with what differs outlined;
//                         one alone with ?compare=a. &scale= draws them larger, to look at small things.
import "./engine.css";
import { loadFonts } from "./fonts.ts";
import type { SavedScene, SceneItem } from "./items.ts";
import { createDomRenderer } from "./renderers/dom.ts";
import { createGlRenderer } from "./renderers/gl.ts";

// Art described by atlases arrives a moment later: drawn again a few times (headless Chrome's virtual time runs on)
const REDRAW_MS = 400;
const SHOT_REDRAWS = 8;
const COMPARE_REDRAWS = 10;

const readScene = async (path: string): Promise<SavedScene | null> => {
  try {
    const response = await fetch(`/snapshots/${path}.scene.json`);
    const scene = (await response.json()) as Partial<SavedScene>;
    // (the server answers an unknown one with a JSON error)
    return response.ok && Array.isArray(scene.items) ? (scene as SavedScene) : null;
  } catch {
    return null;
  }
};

const redraw = (times: number, draw: () => void, onDone?: () => void): void => {
  let count = 0;
  const timer = setInterval(() => {
    draw();
    count += 1;
    if (count >= times) {
      clearInterval(timer);
      onDone?.();
    }
  }, REDRAW_MS);
};

const showShot = async (root: HTMLElement, path: string, parameters: URLSearchParams): Promise<void> => {
  const scene = await readScene(path);
  document.body.style.cssText = "margin:0;background:#000;overflow:hidden";
  root.style.cssText = "background:#000";
  if (!scene) {
    document.title = "missing";
    return;
  }
  const [cropX = 0, cropY = 0, cropWidth = scene.width, cropHeight = scene.height] = (
    parameters.get("crop") ?? `0,0,${scene.width},${scene.height}`
  )
    .split(",")
    .map(Number);
  const frame = document.createElement("div");
  frame.style.cssText = `position:relative;width:${cropWidth}px;height:${cropHeight}px;overflow:hidden;background:#000`;
  const place = `position:absolute;left:${-cropX}px;top:${-cropY}px`;
  const backdrop = parameters.get("backdrop");
  if (backdrop) {
    const picture = document.createElement("div");
    picture.style.cssText =
      `${place};width:${scene.width}px;height:${scene.height}px;` +
      `background:url("/art?p=${encodeURIComponent(backdrop)}") center/cover no-repeat;filter:brightness(0.8)`;
    frame.appendChild(picture);
  }
  if (parameters.get("renderer") === "gl") {
    // Drawn by the GPU's renderer, as the live screen is
    const canvas = document.createElement("canvas");
    canvas.style.cssText = place;
    frame.appendChild(canvas);
    root.appendChild(frame);
    let renderer: ReturnType<typeof createGlRenderer> = null;
    try {
      renderer = createGlRenderer(canvas, () => {});
    } catch (problem) {
      console.warn("AddonSim: no WebGL2", problem);
    }
    if (!renderer) {
      document.title = "no webgl2";
      return;
    }
    const gl = renderer;
    gl.resize(scene.width, scene.height, window.devicePixelRatio || 1);
    gl.draw(scene.items);
    redraw(
      SHOT_REDRAWS,
      () => gl.draw(scene.items),
      () => {
        document.title = "ready";
      },
    );
    return;
  }
  const layer = document.createElement("div");
  layer.className = "as-layer"; // drawn as the live screen's layer is
  layer.style.cssText = `${place};width:${scene.width}px;height:${scene.height}px`;
  frame.appendChild(layer);
  root.appendChild(frame);
  const renderer = createDomRenderer(layer);
  renderer.render(scene.items);
  redraw(
    SHOT_REDRAWS,
    () => renderer.render(scene.items),
    () => {
      document.title = "ready";
    },
  );
};

// Each drawn thing as the same text whatever order its fields came in, and without its id (ids differ by run)
const canonical = (item: SceneItem): string => {
  const fields = item as Record<string, unknown>;
  return JSON.stringify(
    Object.keys(fields)
      .filter((key) => key !== "i")
      .sort()
      .map((key) => [key, fields[key]]),
  );
};

const showComparison = async (root: HTMLElement, paths: readonly string[], parameters: URLSearchParams) => {
  const scenes = await Promise.all(paths.map(readScene));
  document.body.style.cssText = "margin:0;background:#111;color:#ddd;font:13px system-ui";
  root.style.cssText = "display:flex;gap:12px;padding:12px;flex-wrap:wrap;min-height:100vh;background:#111";
  const keys = scenes.map((scene) => new Set((scene ? scene.items : []).map(canonical)));
  // ?scale= draws it larger than the window, to look at small things
  const forcedScale = Number(parameters.get("scale"));
  scenes.forEach((scene, index) => {
    const column = document.createElement("div");
    const title = document.createElement("div");
    const label = paths.length === 1 ? "" : index === 0 ? "Reference: " : "Now: ";
    title.textContent = `${label}${paths[index]}${scene ? "" : " (missing)"}`;
    title.style.margin = "0 0 6px";
    column.appendChild(title);
    if (scene) {
      const frame = document.createElement("div");
      const fitScale = Math.min(paths.length === 1 ? 2 : 1, (window.innerWidth / paths.length - 30) / scene.width);
      const viewScale = forcedScale > 0 ? forcedScale : fitScale;
      frame.style.cssText =
        `position:relative;width:${scene.width * viewScale}px;height:${scene.height * viewScale}px;` +
        "overflow:hidden;background:#1d2a1d;outline:1px solid #444";
      const layer = document.createElement("div");
      layer.className = "as-layer"; // drawn as the live screen's layer is
      layer.style.cssText =
        `position:absolute;left:0;top:0;width:${scene.width}px;height:${scene.height}px;` +
        `transform-origin:0 0;transform:scale(${viewScale})`;
      frame.appendChild(layer);
      column.appendChild(frame);
      const renderer = createDomRenderer(layer);
      renderer.render(scene.items);
      redraw(COMPARE_REDRAWS, () => renderer.render(scene.items));
      // What is only in this one, outlined (over the drawn items, which the renderer keeps as the layer's own)
      const other = keys[1 - index];
      for (const item of scene.items) {
        if (!other || other.has(canonical(item)) || !("w" in item)) continue;
        const box = document.createElement("div");
        box.style.cssText =
          `position:absolute;left:${item.x}px;top:${item.y}px;width:${Math.max(item.w, 2)}px;` +
          `height:${Math.max(item.h, 2)}px;outline:2px solid ${index === 0 ? "#3fa7ff" : "#ff5a3c"};` +
          "z-index:100000;pointer-events:none";
        layer.appendChild(box);
      }
    }
    root.appendChild(column);
  });
};

/**
 * The picture page the address asks for (?shot= or ?compare=), drawn into root, which becomes the page's only content;
 * false when it asks for none (the live page)
 */
export const runPicturePage = (root: HTMLElement): boolean => {
  const parameters = new URLSearchParams(location.search);
  const shot = parameters.get("shot");
  const compare = parameters.get("compare");
  if (!shot && !compare) return false;
  document.body.replaceChildren(root);
  root.replaceChildren();
  root.removeAttribute("style");
  root.className = "as-engine";
  void loadFonts().then(() =>
    shot ? showShot(root, shot, parameters) : showComparison(root, (compare ?? "").split("|"), parameters),
  );
  return true;
};
