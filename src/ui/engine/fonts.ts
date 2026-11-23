// The game's fonts: loaded from the game's files once for the page and measured per character, so Lua lays text out
// (wraps it, sizes it) exactly as it is drawn here (/api/metrics)

const FONT_FILES = ["Fonts\\FRIZQT__.TTF", "Fonts\\ARIALN.TTF", "Fonts\\MORPHEUS.TTF", "Fonts\\skurri.ttf"];
const FALLBACK = "Georgia, serif";
const SAMPLE_SIZE = 100;

/** The key the scene names a font by */
export const fontKey = (path: string): string => path.replace(/\//g, "\\").toLowerCase();

// Known before the files arrive: what is drawn meanwhile falls back to Georgia, and is drawn again when they come
const families = new Map<string, string>(
  FONT_FILES.map((path, index) => [fontKey(path), `wowfont${index}, ${FALLBACK}`]),
);

/** The CSS font family of a font key */
export const fontFamily = (key: string | undefined): string => (key && families.get(key)) || FALLBACK;

type FontTable = Record<string, number>;

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

const load = async (): Promise<void> => {
  await Promise.all(
    FONT_FILES.map(async (path, index) => {
      try {
        const face = new FontFace(`wowfont${index}`, `url(/font?p=${encodeURIComponent(path)})`);
        await face.load();
        document.fonts.add(face);
      } catch (problem) {
        console.warn("AddonSim: font", path, problem);
      }
    }),
  );
  const context = document.createElement("canvas").getContext("2d");
  if (!context) return;
  const metrics: Record<string, FontTable> = {};
  for (const path of FONT_FILES) {
    const key = fontKey(path);
    metrics[key] = measure(context, fontFamily(key));
  }
  // (not waited on: what is drawn needs the fonts, not the simulator's answer; no server: it keeps the metrics it had)
  fetch("/api/metrics", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(metrics),
  })
    .then((response) => response.body?.cancel())
    .catch(() => {});
};

let loading: Promise<void> | null = null;

/** The fonts loaded (and their metrics sent to the simulator), once for the page */
export const loadFonts = (): Promise<void> => {
  loading ??= load();
  return loading;
};
