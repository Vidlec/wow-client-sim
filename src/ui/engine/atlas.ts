// The game's atlases (UiTextureAtlasMember), asked of the server by name once and kept for the page: where each sits
// on its sheet, its size and its nine-slice margins. Every screen on the page shares them.

export type AtlasInfo = {
  /** The sheet's file id */
  fdid: number;
  /** The element's size in its pixels */
  width: number;
  height: number;
  /** Its place on the sheet, 0 to 1 */
  left: number;
  right: number;
  top: number;
  bottom: number;
  /** Nine-slice margins in the element's pixels: left, top, right, bottom */
  slice?: readonly number[];
};

type Entry = AtlasInfo | null | Promise<void>;

const cache = new Map<string, Entry>();
const listeners = new Set<() => void>();

/** Called whenever an atlas asked for has arrived (what waited on it is drawn again) */
export const onAtlasArrived = (listener: () => void): (() => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

const fetchAtlas = async (key: string): Promise<void> => {
  let info: AtlasInfo | null = null;
  try {
    const answer = (await (await fetch(`/atlas?n=${encodeURIComponent(key)}`)).json()) as Partial<AtlasInfo>;
    info = answer?.fdid ? (answer as AtlasInfo) : null;
  } catch {
    info = null; // (no server: drawn as an unknown atlas, nothing)
  }
  cache.set(key, info);
  for (const listener of listeners) listener();
};

/** The atlas by name: its info, null when there is none, undefined while it is asked for */
export const getAtlas = (name: string): AtlasInfo | null | undefined => {
  const key = name.toLowerCase();
  const cached = cache.get(key);
  if (cached === undefined) {
    cache.set(key, fetchAtlas(key));
    return undefined;
  }
  return cached instanceof Promise ? undefined : cached;
};
