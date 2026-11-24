// The scene as the page holds it: the items in drawing order, and each by its key (k .. i). The server sends a whole
// scene, then frames of what changed: the items new or changed, and the order when it changed. An item that did not
// change stays the same object from frame to frame (the renderers' caches go by it).
import type { SceneFrame, SceneItem, SceneItems, SceneMove } from "./items.ts";

export const itemKey = (item: SceneItem): string => item.k + item.i;

export type Scene = {
  /** The items in drawing order */
  readonly items: () => SceneItems;
  /** A frame put in; false when it carried no scene (only the counts) */
  apply: (frame: SceneFrame) => boolean;
};

export const createScene = (): Scene => {
  let items: (SceneItem | undefined)[] = [];
  const byKey = new Map<string, SceneItem>();
  const indexByKey = new Map<string, number>();

  const applyWhole = (whole: SceneItem[]): void => {
    items = whole;
    byKey.clear();
    indexByKey.clear();
    for (let index = 0; index < whole.length; index++) {
      const item = whole[index] as SceneItem;
      const key = itemKey(item);
      byKey.set(key, item);
      indexByKey.set(key, index);
    }
  };

  // A moved item: a new object with its new boxes (the renderers' caches go by the object), in its place
  const applyMoves = (moves: readonly SceneMove[]): void => {
    for (const [key, x, y, w, h, clip, masks] of moves) {
      const held = byKey.get(key);
      if (!held || !("w" in held)) continue;
      const moved = { ...held, x, y, w, h } as SceneItem & { cl?: unknown; mk?: readonly { b: unknown }[] };
      if (clip === 0) delete moved.cl;
      else moved.cl = clip;
      if (masks !== 0 && moved.mk) moved.mk = moved.mk.map((mask, index) => ({ ...mask, b: masks[index] ?? mask.b }));
      byKey.set(key, moved);
      const index = indexByKey.get(key);
      if (index !== undefined) items[index] = moved;
    }
  };

  const applyDelta = (changed: readonly SceneItem[], order: readonly string[] | undefined): void => {
    for (const item of changed) byKey.set(itemKey(item), item);
    if (order) {
      items = order.map((key) => byKey.get(key));
      indexByKey.clear();
      for (let index = 0; index < order.length; index++) indexByKey.set(order[index] as string, index);
      // Those no longer in the order are gone
      if (byKey.size !== order.length) {
        for (const key of [...byKey.keys()]) if (!indexByKey.has(key)) byKey.delete(key);
      }
      return;
    }
    for (const item of changed) {
      const index = indexByKey.get(itemKey(item));
      if (index !== undefined) items[index] = item;
    }
  };

  return {
    items: () => items,
    apply: (frame) => {
      if (frame.items && !frame.delta) {
        applyWhole(frame.items);
        return true;
      }
      if (!frame.delta) return false;
      if (frame.mv) applyMoves(frame.mv);
      applyDelta(frame.u ?? [], frame.o);
      return true;
    },
  };
};
