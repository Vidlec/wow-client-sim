// The picture pages: a saved scene drawn once, nothing live (no socket, no controller), by the same renderer as the
// live screen (renderers/renderer.ts). src/sdk/shots.ts and src/cli/shots.ts load them in headless Chrome and take the
// picture once the title says "ready"; the scenario runner's links open them too.
//
//   ?shot=path            one saved scene alone, at its own size and nothing round it. &backdrop=<texture> puts a
//                         picture of the game's behind it, as the world would be (a loading screen:
//                         "Interface\Glues\LoadingScreens\LoadScreenBarrens"); &crop=x,y,w,h shows only that part of
//                         the screen. The title says "ready" once its art has arrived and the GPU has drawn it
//                         ("missing": no scene; "no gpu": the browser has no WebGPU).
//   ?compare=a|b          two saved scenes side by side (the reference and now), each with what differs outlined;
//                         one alone with ?compare=a. &scale= draws them larger, to look at small things.
import "./engine.css";
import { areAtlasesSettled, onAtlasArrived } from "./atlas.ts";
import { areFontsSettled, loadFonts, onFontArrived } from "./fonts.ts";
import type { SavedScene, SceneItem } from "./items.ts";
import { createRenderer, type Renderer } from "./renderers/renderer.ts";

// A shot waits for its art: drawn again until every atlas, picture and font asked for has arrived
const SETTLE_STEPS = 150;
const SETTLE_STEP_MS = 50;

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

const wait = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** A renderer on a new canvas placed as style says, drawing again whenever art or a font arrives */
const makeRenderer = async (
  parent: HTMLElement,
  style: string,
  redraw: () => void,
): Promise<{ renderer: Renderer; canvas: HTMLCanvasElement } | null> => {
  const canvas = document.createElement("canvas");
  canvas.style.cssText = style;
  parent.appendChild(canvas);
  const renderer = await createRenderer(canvas, redraw);
  if (!renderer) return null;
  onAtlasArrived(redraw);
  onFontArrived(() => {
    renderer.resetText();
    redraw();
  });
  return { renderer, canvas };
};

/** Drawn until its art has all arrived, then once more; the title says "ready" when the GPU has done it */
const drawWhenSettled = async (renderer: Renderer, draw: () => void): Promise<void> => {
  for (let step = 0; step < SETTLE_STEPS; step++) {
    draw();
    if (step >= 2 && areAtlasesSettled() && renderer.isSettled() && areFontsSettled()) break;
    await wait(SETTLE_STEP_MS);
  }
  renderer.resetText(); // (the fonts are all in now: every string laid out in them)
  draw();
  await renderer.finished();
  // (a frame for the canvas to be shown with what was drawn)
  await new Promise((resolve) => requestAnimationFrame(resolve));
  document.title = "ready";
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
  root.appendChild(frame);
  let draw = (): void => {};
  const made = await makeRenderer(frame, place, () => draw());
  if (!made) {
    document.title = "no gpu";
    return;
  }
  const { renderer } = made;
  renderer.resize(scene.width, scene.height, window.devicePixelRatio || 1);
  draw = () => renderer.draw(scene.items);
  await drawWhenSettled(renderer, draw);
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
  const drawn = scenes.map(async (scene, index) => {
    const column = document.createElement("div");
    const title = document.createElement("div");
    const label = paths.length === 1 ? "" : index === 0 ? "Reference: " : "Now: ";
    title.textContent = `${label}${paths[index]}${scene ? "" : " (missing)"}`;
    title.style.margin = "0 0 6px";
    column.appendChild(title);
    root.appendChild(column);
    if (!scene) return;
    const fitScale = Math.min(paths.length === 1 ? 2 : 1, (window.innerWidth / paths.length - 30) / scene.width);
    const viewScale = forcedScale > 0 ? forcedScale : fitScale;
    const frame = document.createElement("div");
    frame.style.cssText =
      `position:relative;width:${scene.width * viewScale}px;height:${scene.height * viewScale}px;` +
      "overflow:hidden;background:#1d2a1d;outline:1px solid #444";
    column.appendChild(frame);
    // The scene drawn at the view's scale (its canvas's pixels as many as shown), the outlines over it
    const layer = document.createElement("div");
    layer.style.cssText =
      `position:absolute;left:0;top:0;width:${scene.width}px;height:${scene.height}px;` +
      `transform-origin:0 0;transform:scale(${viewScale})`;
    frame.appendChild(layer);
    let draw = (): void => {};
    const made = await makeRenderer(layer, "position:absolute;left:0;top:0", () => draw());
    if (!made) {
      title.textContent += " (this browser has no WebGPU to draw it with)";
      return;
    }
    const { renderer } = made;
    renderer.resize(scene.width, scene.height, viewScale * (window.devicePixelRatio || 1));
    draw = () => renderer.draw(scene.items);
    // What is only in this one, outlined
    const other = keys[1 - index];
    for (const item of scene.items) {
      if (!other || other.has(canonical(item)) || !("w" in item)) continue;
      const box = document.createElement("div");
      box.style.cssText =
        `position:absolute;left:${item.x}px;top:${item.y}px;width:${Math.max(item.w, 2)}px;` +
        `height:${Math.max(item.h, 2)}px;outline:2px solid ${index === 0 ? "#3fa7ff" : "#ff5a3c"};` +
        "pointer-events:none";
      layer.appendChild(box);
    }
    await drawWhenSettled(renderer, draw);
  });
  await Promise.all(drawn);
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
