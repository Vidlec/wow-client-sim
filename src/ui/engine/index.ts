// The game screen: the simulator's scene drawn with the game's art (renderers/), kept up to date from the server's
// stream (stream.ts, scene.ts), and the mouse, keyboard and controller sent back (input.ts, gamepad.ts). The page's
// shell gives it an empty element and talks to it through GameScreen (types.ts) alone.
import "./engine.css";
import { onAtlasArrived } from "./atlas.ts";
import { loadFonts } from "./fonts.ts";
import { startGamepad } from "./gamepad.ts";
import { attachInput } from "./input.ts";
import { createInspector } from "./inspect.ts";
import type { SceneFrame } from "./items.ts";
import { createLayout } from "./layout.ts";
import { createDomRenderer } from "./renderers/dom.ts";
import { createGlRenderer, type GlRenderer } from "./renderers/gl.ts";
import { createScene } from "./scene.ts";
import { createStream } from "./stream.ts";
import type {
  ConnectedPad,
  DrawStats,
  GameScreen,
  GameScreenOptions,
  InputEvent,
  Listener,
  Renderer,
  StreamStatus,
  Unsubscribe,
} from "./types.ts";
import { createWorldBackdrop } from "./world.ts";

export { runPicturePage } from "./picture.ts";
export { fillInlineAtlases } from "./renderers/dom.ts";
export { lineToHtml } from "./text.ts";
export type * from "./types.ts";

const CURSOR_BLINK_MS = 500;
const DRAW_STATS_MS = 1000;
// A timer stands in for the browser's frames when it holds them back (a window behind others)
const DRAW_FALLBACK_MS = 100;

type PageStats = {
  received: number;
  drawn: number;
  drawMs: number;
  lastDrawAt: number;
  renderer: "webgl2" | "dom";
  gl: GlRenderer["stats"] | null;
  items: number;
};

declare global {
  interface Window {
    /** How the page keeps up, for the console and the audits */
    addonSimStats?: () => PageStats;
  }
}

const element = <K extends keyof HTMLElementTagNameMap>(tag: K, className: string): HTMLElementTagNameMap[K] => {
  const made = document.createElement(tag);
  made.className = className;
  return made;
};

/** The renderer asked for in the address (?renderer=dom|gl), which wins over the shell's */
const rendererInAddress = (): Renderer | null => {
  const asked = new URLSearchParams(location.search).get("renderer");
  return asked === "gl" || asked === "dom" ? asked : null;
};

/** Each listener of a set called with a value */
const tell = <T>(listeners: Set<Listener<T>>, value: T): void => {
  for (const listener of listeners) listener(value);
};
/** A subscription; with current, the listener is told the value as it is at once */
const subscribe =
  <T>(listeners: Set<Listener<T>>, current?: () => T) =>
  (listener: Listener<T>): Unsubscribe => {
    listeners.add(listener);
    if (current) listener(current());
    return () => listeners.delete(listener);
  };

export const createGameScreen = (container: HTMLElement, options: GameScreenOptions = {}): GameScreen => {
  // The screen's parts: the viewport (scrolls when magnified) round the screen, which holds the world behind, the
  // GPU's canvas, the elements' layer and the inspector's boxes
  container.classList.add("as-engine");
  if (getComputedStyle(container).position === "static") container.style.position = "relative";
  const viewport = element("div", "as-viewport");
  const sizer = element("div", "as-sizer");
  const screen = element("div", "as-screen");
  screen.tabIndex = 0;
  screen.setAttribute("role", "application");
  screen.setAttribute("aria-label", "The game");
  const world = element("div", "as-world");
  const canvas = element("canvas", "as-gl");
  const layer = element("div", "as-layer");
  const boxes = element("div", "as-inspect");
  screen.append(world, canvas, layer, boxes);
  viewport.append(sizer, screen);
  container.replaceChildren(viewport);

  const scene = createScene();
  const layout = createLayout({ viewport, sizer, screen }, options.magnify ?? 1);
  const dom = createDomRenderer(layer);
  const inspector = createInspector(boxes);
  const setWorldBackdrop = createWorldBackdrop(world);
  const statusListeners = new Set<Listener<StreamStatus>>();
  const drawStatsListeners = new Set<Listener<DrawStats>>();
  const padListeners = new Set<Listener<ConnectedPad | null>>();
  let connectedPad: ConnectedPad | null = null;
  const pageStats = { received: 0, drawn: 0, drawMs: 0, lastDrawAt: 0 };
  let isDestroyed = false;

  // The renderer: the GPU's (WebGL2) by default; the page's own elements with ?renderer=dom, or when the browser has
  // no WebGL2. The GPU's, once made, is kept while the elements draw (a canvas keeps its context for good).
  let wanted: Renderer = rendererInAddress() ?? options.renderer ?? "gl";
  let glMade: GlRenderer | null = null;
  let gl: GlRenderer | null = null;

  // Drawing: at the browser's next frame after anything changed (the scene, art arriving, the size), once however
  // many changes came
  let isDrawPending = false;
  const present = (): void => {
    if (!isDrawPending || isDestroyed) return;
    isDrawPending = false;
    const started = performance.now();
    if (gl) gl.draw(scene.items());
    else dom.render(scene.items());
    pageStats.drawn += 1;
    pageStats.drawMs = performance.now() - started;
    pageStats.lastDrawAt = started;
  };
  const requestDraw = (): void => {
    if (isDrawPending || isDestroyed) return;
    isDrawPending = true;
    requestAnimationFrame(present);
    setTimeout(present, DRAW_FALLBACK_MS);
  };

  const makeGl = (): GlRenderer | null => {
    try {
      return createGlRenderer(canvas, requestDraw);
    } catch (problem) {
      console.warn("AddonSim: no WebGL2, drawing with the page's elements", problem);
      return null;
    }
  };

  const fit = (): void => {
    const scale = layout.fit();
    // The canvas's pixels are the screen's: as many as the game is drawn at on this display, so nothing is blurred
    if (gl) {
      gl.resize(layout.width(), layout.height(), scale * (window.devicePixelRatio || 1));
      requestDraw();
    }
  };

  const switchRenderer = (renderer: Renderer): void => {
    wanted = renderer;
    if (renderer === "gl") {
      glMade ??= makeGl();
      if (glMade && gl !== glMade) {
        gl = glMade;
        dom.render([]); // (the elements drawn meanwhile taken away)
      }
    } else if (gl) {
      gl.clear();
      gl = null;
      dom.invalidate();
    }
    fit();
    requestDraw();
  };

  // The GPU's context lost (a driver reset, the GPU switched): drawn with the page's elements until it is back
  const onContextLost = (event: Event): void => {
    event.preventDefault();
    glMade = null;
    if (!gl) return;
    gl = null;
    dom.invalidate();
    requestDraw();
  };
  const onContextRestored = (): void => {
    if (wanted === "gl") switchRenderer("gl");
  };
  canvas.addEventListener("webglcontextlost", onContextLost);
  canvas.addEventListener("webglcontextrestored", onContextRestored);
  switchRenderer(wanted);

  // The stream, and what each frame says besides the scene
  const status: StreamStatus = { isConnected: false, version: null, generation: null, errors: 0, chat: 0, error: null };
  const tellStatus = (): void => tell(statusListeners, { ...status });
  const onFrame = (frame: SceneFrame): void => {
    pageStats.received += 1;
    let isChanged = false;
    const error = frame.error ?? null;
    if (error !== status.error) {
      status.error = error;
      isChanged = true;
    }
    if (frame.generation !== undefined && frame.generation !== status.generation) {
      status.generation = frame.generation;
      isChanged = true;
    }
    if (frame.width && frame.height && layout.setSize(frame.width, frame.height)) fit();
    if (scene.apply(frame)) requestDraw();
    if (frame.version !== undefined && !frame.unchanged && frame.version !== status.version) {
      status.version = frame.version;
      isChanged = true;
    }
    if (frame.errors !== undefined && frame.errors !== status.errors) {
      status.errors = frame.errors;
      isChanged = true;
    }
    if (frame.chat !== undefined && frame.chat !== status.chat) {
      status.chat = frame.chat;
      isChanged = true;
    }
    if (isChanged) tellStatus();
  };
  const stream = createStream({
    onFrame,
    onConnection: (isConnected) => {
      if (isConnected === status.isConnected) return;
      status.isConnected = isConnected;
      tellStatus();
    },
  });
  const sendInput = (event: InputEvent): void => {
    void stream.send(event).then(stream.poll);
  };

  // Input
  const detachInput = attachInput(screen, {
    toScreen: (clientX, clientY) => {
      const rect = screen.getBoundingClientRect();
      const scale = layout.scale();
      return { x: (clientX - rect.left) / scale, y: (clientY - rect.top) / scale };
    },
    send: stream.send,
    poll: stream.poll,
    isMagnified: () => layout.magnify() > 1,
    onMove: (point, event) => inspector.follow(point, event.altKey),
  });
  const stopGamepad = startGamepad({
    send: (event) => void stream.send(event),
    onPad: (pad) => {
      connectedPad = pad;
      tell(padListeners, pad);
    },
  });

  // The game keeps its fit as the panels round it open or fold, and as the window changes
  const resizeObserver = new ResizeObserver(() => fit());
  resizeObserver.observe(viewport);
  window.addEventListener("resize", fit);

  // Art the drawn items wait on arrived; the game's fonts arrived (strings drawn before were in a stand-in)
  const stopAtlases = onAtlasArrived(requestDraw);
  void loadFonts().then(() => {
    if (isDestroyed) return;
    glMade?.resetText();
    requestDraw();
  });
  // The text cursor blinks (the elements' blinks by itself, in CSS)
  const blinkTimer = setInterval(() => {
    if (gl?.hasCursor()) {
      gl.blink();
      requestDraw();
    }
  }, CURSOR_BLINK_MS);
  let drawnBefore = 0;
  let measuredAt = performance.now();
  const drawStatsTimer = setInterval(() => {
    const now = performance.now();
    const drawsPerSecond = (pageStats.drawn - drawnBefore) / Math.max(0.001, (now - measuredAt) / 1000);
    drawnBefore = pageStats.drawn;
    measuredAt = now;
    tell(drawStatsListeners, { drawsPerSecond, renderer: gl ? "gl" : "dom", drawMs: pageStats.drawMs });
  }, DRAW_STATS_MS);
  window.addonSimStats = () => ({
    ...pageStats,
    renderer: gl ? "webgl2" : "dom",
    gl: gl ? { ...gl.stats } : null,
    items: scene.items().length,
  });

  fit();
  screen.focus({ preventScroll: true });

  return {
    destroy: () => {
      if (isDestroyed) return;
      isDestroyed = true;
      stream.close();
      detachInput();
      stopGamepad();
      stopAtlases();
      resizeObserver.disconnect();
      window.removeEventListener("resize", fit);
      clearInterval(blinkTimer);
      clearInterval(drawStatsTimer);
      canvas.removeEventListener("webglcontextlost", onContextLost);
      canvas.removeEventListener("webglcontextrestored", onContextRestored);
      glMade?.dispose();
      dom.dispose();
      statusListeners.clear();
      drawStatsListeners.clear();
      padListeners.clear();
      inspector.listeners.clear();
      delete window.addonSimStats;
      container.replaceChildren();
      container.classList.remove("as-engine");
    },
    focus: () => screen.focus({ preventScroll: true }),
    setMagnify: (magnify) => {
      layout.setMagnify(magnify);
      fit();
    },
    setRenderer: switchRenderer,
    setWorldBackdrop,
    fit,
    requestWholeScene: stream.forgetScene,
    onStatus: subscribe(statusListeners, () => ({ ...status })),
    onDrawStats: subscribe(drawStatsListeners),
    setInspect: inspector.setOptions,
    onInspect: subscribe(inspector.listeners),
    highlightFrame: inspector.highlight,
    sendInput,
    pressPad: (button, isDown) => sendInput({ type: "pad", button, isDown }),
    movePadStick: (stick, x, y) => sendInput({ type: "padStick", stick, x, y }),
    onPadConnected: subscribe(padListeners, () => connectedPad),
  };
};
