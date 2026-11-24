// The game screen: the simulator's scene drawn with the game's art (renderers/), kept up to date from the server's
// stream (stream.ts, scene.ts), and the mouse, keyboard and controller sent back (input.ts, gamepad.ts). The page's
// shell gives it an empty element and talks to it through GameScreen (types.ts) alone.
import "./engine.css";
import { countAtlasesLoading, onAtlasArrived } from "./atlas.ts";
import { createAudioPlayer } from "./audio.ts";
import { countFontsLoading, loadFonts, onFontArrived } from "./fonts.ts";
import { startGamepad } from "./gamepad.ts";
import { attachInput } from "./input.ts";
import { createInspector } from "./inspect.ts";
import type { SceneFrame } from "./items.ts";
import { createLayout } from "./layout.ts";
import { createRenderer, type Renderer as GpuRenderer } from "./renderers/renderer.ts";
import { createScene } from "./scene.ts";
import { createStream } from "./stream.ts";
import { textureUrl } from "./textures.ts";
import type {
  ConnectedPad,
  DrawStats,
  GameScreen,
  GameScreenOptions,
  InputEvent,
  Listener,
  StreamStatus,
  Unsubscribe,
} from "./types.ts";
import { createWorldBackdrop } from "./world.ts";

const DEFAULT_CURSOR = "Interface/Cursor/Point";

export { runPicturePage } from "./picture.ts";
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
  hasGpu: boolean;
  gpu: GpuRenderer["stats"] | null;
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
  // GPU's canvas and the inspector's boxes
  container.classList.add("as-engine");
  if (getComputedStyle(container).position === "static") container.style.position = "relative";
  const viewport = element("div", "as-viewport");
  const sizer = element("div", "as-sizer");
  const screen = element("div", "as-screen");
  screen.tabIndex = 0;
  screen.setAttribute("role", "application");
  screen.setAttribute("aria-label", "The game");
  const world = element("div", "as-world");
  let canvas = element("canvas", "as-gl");
  const boxes = element("div", "as-inspect");
  screen.append(world, canvas, boxes);
  viewport.append(sizer, screen);
  container.replaceChildren(viewport);

  const scene = createScene();
  const layout = createLayout({ viewport, sizer, screen }, options.magnify ?? 1);
  const inspector = createInspector(boxes);
  const setWorldBackdrop = createWorldBackdrop(world);
  const statusListeners = new Set<Listener<StreamStatus>>();
  const drawStatsListeners = new Set<Listener<DrawStats>>();
  const padListeners = new Set<Listener<ConnectedPad | null>>();
  let connectedPad: ConnectedPad | null = null;
  const pageStats = { received: 0, drawn: 0, drawMs: 0, lastDrawAt: 0 };
  let isDestroyed = false;

  // The renderer (WebGPU): made a moment after the screen (the GPU is asked for), again on a new canvas if the GPU is
  // lost (a canvas keeps the context it was first given)
  let gpu: GpuRenderer | null = null;
  let making = 0;

  // Drawing: at the browser's next frame after anything changed (the scene, art arriving, the size), once however
  // many changes came
  let isDrawPending = false;
  const present = (): void => {
    if (!isDrawPending || isDestroyed) return;
    isDrawPending = false;
    if (!gpu) return;
    const started = performance.now();
    gpu.draw(scene.items());
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

  const fit = (): void => {
    const scale = layout.fit();
    // The canvas's pixels are the screen's: as many as the game is drawn at on this display, so nothing is blurred
    if (gpu) {
      gpu.resize(layout.width(), layout.height(), scale * (window.devicePixelRatio || 1));
      requestDraw();
    }
  };

  /** A renderer made (again) on a new canvas: at the start, after the GPU was lost */
  const makeRenderer = async (): Promise<void> => {
    making += 1;
    const ticket = making;
    gpu?.dispose();
    gpu = null;
    const fresh = element("canvas", "as-gl");
    canvas.replaceWith(fresh);
    canvas = fresh;
    // (a backend that throws rather than answering none is no WebGPU too: the notice below says so)
    const made = await createRenderer(fresh, requestDraw).catch((problem: unknown) => {
      console.warn("AddonSim renderer", problem);
      return null;
    });
    // (another asked for meanwhile, or the screen gone: this one is not wanted)
    if (ticket !== making || isDestroyed) {
      made?.dispose();
      return;
    }
    if (!made) {
      // (said on the screen itself: nothing else would show why it stays empty)
      const notice = element("div", "as-no-gpu");
      notice.textContent =
        "This browser has no WebGPU, which the game is drawn with: open the page in a current Chrome, Edge, Firefox or Safari (with hardware acceleration on).";
      screen.append(notice);
      console.warn("AddonSim: no WebGPU: the game cannot be drawn in this browser");
      return;
    }
    gpu = made;
    made.onLost(() => {
      if (gpu === made && !isDestroyed) void makeRenderer();
    });
    fit();
    requestDraw();
  };
  void makeRenderer();

  // The stream, and what each frame says besides the scene
  // The game's sounds: played here, each one's end told back to the game (it waits on it: C_Sound.IsPlaying)
  let sendToGame: (event: InputEvent) => void = () => {};
  const audio = createAudioPlayer((handle) => sendToGame({ type: "soundEnded", h: handle }));
  const status: StreamStatus = { isConnected: false, version: null, generation: null, errors: 0, chat: 0, error: null };
  const tellStatus = (): void => tell(statusListeners, { ...status });
  // The game's pointer over its screen, as the client draws it: its own arrow, or the one the game or an addon set
  // (SetCursor: a sword over an enemy, an addon's own)
  let shownCursor: string | number | null = null;
  const showCursor = (cursor: string | number | undefined): void => {
    const wanted = cursor ?? DEFAULT_CURSOR;
    if (wanted === shownCursor) return;
    shownCursor = wanted;
    screen.style.cursor = `url("${textureUrl(wanted)}") 1 1, default`;
  };
  showCursor(undefined);
  const onFrame = (frame: SceneFrame): void => {
    pageStats.received += 1;
    // (every frame of the stream carries the pointer)
    if (frame.version !== undefined) showCursor(frame.cursor);
    let isChanged = false;
    const error = frame.error ?? null;
    if (error !== status.error) {
      status.error = error;
      isChanged = true;
    }
    if (frame.generation !== undefined && frame.generation !== status.generation) {
      status.generation = frame.generation;
      audio.stopAll(); // (another game: its sounds and their handles start again)
      isChanged = true;
    }
    if (frame.width && frame.height && layout.setSize(frame.width, frame.height)) fit();
    if (scene.apply(frame)) requestDraw();
    if (frame.sounds) audio.apply(frame.sounds);
    if (frame.version !== undefined && frame.version !== status.version) {
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
  sendToGame = (event) => void stream.send(event);

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
    gpu?.resetText();
    requestDraw();
  });
  // Another font arrived (one a string names: the game's, an addon's): its strings are drawn in it now
  const stopFonts = onFontArrived(() => {
    if (isDestroyed) return;
    gpu?.resetText();
    requestDraw();
  });
  // The text cursor blinks
  const blinkTimer = setInterval(() => {
    if (gpu?.hasCursor()) {
      gpu.blink();
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
    const artLoading = (gpu?.countLoading() ?? 0) + countAtlasesLoading() + countFontsLoading();
    tell(drawStatsListeners, { drawsPerSecond, hasGpu: gpu !== null, drawMs: pageStats.drawMs, artLoading });
  }, DRAW_STATS_MS);
  window.addonSimStats = () => ({
    ...pageStats,
    hasGpu: gpu !== null,
    gpu: gpu ? { ...gpu.stats } : null,
    items: scene.items().length,
  });

  fit();
  screen.focus({ preventScroll: true });

  return {
    destroy: () => {
      audio.close();
      if (isDestroyed) return;
      isDestroyed = true;
      stream.close();
      detachInput();
      stopGamepad();
      stopAtlases();
      stopFonts();
      resizeObserver.disconnect();
      window.removeEventListener("resize", fit);
      clearInterval(blinkTimer);
      clearInterval(drawStatsTimer);
      gpu?.dispose();
      gpu = null;
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
