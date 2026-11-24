// The fonts text is drawn in: the game's four main fonts loaded at once, and any other a string names (another of the
// game's, or an addon's own: EllesmereUI's Expressway...) loaded the first time it is seen. Each is measured per
// character, so Lua lays text out (wraps it, sizes it) exactly as it is drawn here (/api/metrics); until a font has
// arrived its strings are drawn in a stand-in, and drawn again when it comes.

const FONT_FILES = ["Fonts\\FRIZQT__.TTF", "Fonts\\ARIALN.TTF", "Fonts\\MORPHEUS.TTF", "Fonts\\skurri.ttf"];
const FALLBACK = "Georgia, serif";
const SAMPLE_SIZE = 100;
/** Fonts measured and sent together, a moment after the first of a batch arrived */
const SEND_DELAY_MS = 150;

/** The key the scene names a font by */
export const fontKey = (path: string): string => path.replace(/\//g, "\\").toLowerCase();

type FontTable = Record<string, number>;

// Known before the files arrive: what is drawn meanwhile falls back to Georgia, and is drawn again when they come
const families = new Map<string, string>(
  FONT_FILES.map((path, index) => [fontKey(path), `wowfont${index}, ${FALLBACK}`]),
);
/** Every font asked for: loading, loaded, or failed (then never asked again) */
const requested = new Map<string, "loading" | "loaded" | "failed">();
const metrics: Record<string, FontTable> = {};
const arrivedListeners = new Set<() => void>();
let nextFamily = FONT_FILES.length;

/** Each character's advance (32 to U+024F) at size 1, and the lower-case letters' average */
const measure = (context: CanvasRenderingContext2D, family: string): FontTable => {
  context.font = `${SAMPLE_SIZE}px ${family}`;
  const table: FontTable = {};
  let total = 0;
  let count = 0;
  for (let code = 32; code < 0x24f; code++) {
    const width = context.measureText(String.fromCodePoint(code)).width / SAMPLE_SIZE;
    table[code] = Math.round(width * 10000) / 10000;
    if (code >= 97 && code <= 122) {
      total += width;
      count++;
    }
  }
  table.avg = total / count;
  return table;
};

let measuringContext: CanvasRenderingContext2D | null | undefined;
const getContext = (): CanvasRenderingContext2D | null => {
  measuringContext ??= document.createElement("canvas").getContext("2d");
  return measuringContext;
};

// (every font's metrics each time: the simulator takes the table whole)
let sendTimer: ReturnType<typeof setTimeout> | null = null;
const sendMetrics = (): void => {
  if (sendTimer) return;
  sendTimer = setTimeout(() => {
    sendTimer = null;
    // (not waited on: what is drawn needs the fonts, not the simulator's answer; no server: it keeps what it had)
    fetch("/api/metrics", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(metrics),
    })
      .then((response) => response.body?.cancel())
      .catch(() => {});
  }, SEND_DELAY_MS);
};

/** Where a font's file is served: an addon's from its folder (/media), the game's from its files (/font) */
const fontUrl = (path: string): string =>
  /^interface[\\/]addons[\\/]/i.test(path)
    ? `/media?p=${encodeURIComponent(path)}`
    : `/font?p=${encodeURIComponent(path)}`;

const loadFace = async (key: string, family: string, url: string): Promise<boolean> => {
  try {
    const face = new FontFace(family, `url(${url})`);
    await face.load();
    document.fonts.add(face);
    return true;
  } catch (problem) {
    console.warn("AddonSim: font", key, problem);
    return false;
  }
};

/** A font a string names, loaded (once) if it is not yet: drawn in the stand-in until it arrives */
const requestFont = (key: string): void => {
  if (requested.has(key) || typeof FontFace === "undefined") return;
  requested.set(key, "loading");
  const family = `wowfont${nextFamily++}`;
  void loadFace(key, family, fontUrl(key)).then((isLoaded) => {
    requested.set(key, isLoaded ? "loaded" : "failed");
    if (!isLoaded) return;
    families.set(key, `${family}, ${FALLBACK}`);
    const context = getContext();
    if (context) {
      metrics[key] = measure(context, `${family}, ${FALLBACK}`);
      sendMetrics();
    }
    for (const listener of arrivedListeners) listener();
  });
};

/** The CSS font family of a font key: a font not loaded yet is asked for, and stands in meanwhile */
export const fontFamily = (key: string | undefined): string => {
  if (!key) return FALLBACK;
  const family = families.get(key);
  if (family) return family;
  requestFont(key);
  return FALLBACK;
};

/** Called each time a font arrives (another of the game's, an addon's): what is drawn in it is drawn again */
export const onFontArrived = (listener: () => void): (() => void) => {
  arrivedListeners.add(listener);
  return () => arrivedListeners.delete(listener);
};

const load = async (): Promise<void> => {
  for (const path of FONT_FILES) requested.set(fontKey(path), "loading");
  await Promise.all(
    FONT_FILES.map(async (path, index) => {
      const isLoaded = await loadFace(fontKey(path), `wowfont${index}`, `/font?p=${encodeURIComponent(path)}`);
      requested.set(fontKey(path), isLoaded ? "loaded" : "failed");
    }),
  );
  const context = getContext();
  if (!context) return;
  for (const path of FONT_FILES) {
    const key = fontKey(path);
    metrics[key] = measure(context, families.get(key) ?? FALLBACK);
  }
  sendMetrics();
};

let loading: Promise<void> | null = null;

/** The game's main fonts loaded (and their metrics sent to the simulator), once for the page */
export const loadFonts = (): Promise<void> => {
  loading ??= load();
  return loading;
};

/** No font asked for is still on its way (the picture pages wait for it: picture.ts) */
export const areFontsSettled = (): boolean => {
  for (const state of requested.values()) if (state === "loading") return false;
  return true;
};
