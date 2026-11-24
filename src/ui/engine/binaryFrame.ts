// A binary frame of the scene stream, read into the frame the page applies (scene.ts), as the JSON one would be: the
// server sends one binary message, the header's length (u32), the header's JSON, then the scene as the simulator's
// native store wrote it (native/src/lib.rs). Items come packed (lua/pack.lua) and are read into the same objects the
// JSON stream carries, so nothing after this knows which stream it came from.
import type { Box, SceneFrame, SceneItem, SceneMove } from "./items.ts";

// The names of the items' fields, numbered from 0 in this order: the same list as lua/pack.lua's FIELDS
export const FIELDS = [
  "k",
  "i",
  "x",
  "y",
  "w",
  "h",
  "a",
  "c",
  "vc",
  "tc",
  "tcTurned",
  "tex",
  "atlas",
  "sc",
  "sl",
  "slm",
  "wr",
  "bl",
  "ds",
  "rot",
  "gr",
  "tile",
  "mk",
  "b",
  "poly",
  "pie",
  "seam",
  "cl",
  "fg",
  "fa",
  "lines",
  "f",
  "fs",
  "fl",
  "jh",
  "jv",
  "lh",
  "sp",
  "sh",
  "shc",
  "ag",
  "cursor",
  "bg",
  "edge",
  "es",
  "ins",
  "ts",
  "bc",
  "x1",
  "y1",
  "x2",
  "y2",
  "th",
  "unit",
  "orientation",
  "from",
  "to",
  "left",
  "right",
  "top",
  "bottom",
] as const;

/** What a page's stream keeps between binary frames: the keys' ids */
export type BinaryState = { keys: Map<number, string> };

export const createBinaryState = (): BinaryState => ({ keys: new Map() });

const decoder = new TextDecoder();

/** Reads the values lua/pack.lua writes */
class Reader {
  at = 0;
  constructor(
    readonly view: DataView,
    readonly bytes: Uint8Array,
  ) {}

  u8(): number {
    const value = this.view.getUint8(this.at);
    this.at += 1;
    return value;
  }
  u16(): number {
    const value = this.view.getUint16(this.at, true);
    this.at += 2;
    return value;
  }
  u32(): number {
    const value = this.view.getUint32(this.at, true);
    this.at += 4;
    return value;
  }
  f64(): number {
    const value = this.view.getFloat64(this.at, true);
    this.at += 8;
    return value;
  }
  text(length: number): string {
    const value = decoder.decode(this.bytes.subarray(this.at, this.at + length));
    this.at += length;
    return value;
  }
  box(): Box {
    return [this.f64(), this.f64(), this.f64(), this.f64()];
  }

  value(): unknown {
    const tag = this.u8();
    switch (tag) {
      case 0:
        return null;
      case 1:
        return false;
      case 2:
        return true;
      case 3: {
        const value = this.view.getInt32(this.at, true);
        this.at += 4;
        return value;
      }
      case 4:
        return this.f64();
      case 5:
        return this.text(this.u32());
      case 6: {
        const count = this.u32();
        const list: unknown[] = new Array(count);
        for (let index = 0; index < count; index++) list[index] = this.value();
        return list;
      }
      case 7: {
        const count = this.u32();
        const map: Record<string, unknown> = {};
        for (let index = 0; index < count; index++) {
          const keyTag = this.u8();
          const key = keyTag === 8 ? (FIELDS[this.u8()] ?? "?") : this.text(this.u32());
          map[key] = this.value();
        }
        return map;
      }
      default:
        throw new Error(`a packed value of unknown kind ${tag}`);
    }
  }
}

const KIND_CHANGES = 1;

/**
 * A binary message read: the header's fields with the scene's (a frame of changes: u, o, mv; a whole scene: items),
 * the keys' ids kept in the state for the frames after
 */
export const readBinaryFrame = (message: ArrayBuffer, state: BinaryState): SceneFrame => {
  const view = new DataView(message);
  const bytes = new Uint8Array(message);
  const headerLength = view.getUint32(0, true);
  const header = JSON.parse(decoder.decode(bytes.subarray(4, 4 + headerLength))) as SceneFrame;
  const reader = new Reader(view, bytes);
  reader.at = 4 + headerLength;
  const kind = reader.u8();
  if (kind !== KIND_CHANGES) state.keys.clear();
  const keyCount = reader.u32();
  for (let index = 0; index < keyCount; index++) {
    const id = reader.u32();
    state.keys.set(id, reader.text(reader.u16()));
  }
  const keyOf = (id: number): string => state.keys.get(id) ?? `?${id}`;
  let order: string[] | undefined;
  if (reader.u8() === 1) {
    const count = reader.u32();
    order = new Array(count);
    for (let index = 0; index < count; index++) order[index] = keyOf(reader.u32());
  }
  const itemCount = reader.u32();
  const items: SceneItem[] = [];
  const itemByKey = new Map<string, SceneItem>();
  for (let index = 0; index < itemCount; index++) {
    const id = reader.u32();
    const length = reader.u32();
    const end = length + reader.at;
    // (an item with no bytes: none to read, the rest of the frame still is)
    if (length === 0) continue;
    const item = reader.value() as SceneItem;
    reader.at = end;
    items.push(item);
    itemByKey.set(keyOf(id), item);
  }
  const moveCount = reader.u32();
  const moves: SceneMove[] = new Array(moveCount);
  for (let index = 0; index < moveCount; index++) {
    const key = keyOf(reader.u32());
    const [x, y, w, h] = reader.box();
    const clip = reader.u8() === 1 ? reader.box() : 0;
    const maskCount = reader.u8();
    const masks: Box[] = [];
    for (let mask = 0; mask < maskCount; mask++) masks.push(reader.box());
    moves[index] = [key, x as number, y as number, w as number, h as number, clip, maskCount > 0 ? masks : 0];
  }
  if (kind === KIND_CHANGES) {
    const frame: SceneFrame = { ...header, delta: true, u: items };
    if (order) frame.o = order;
    if (moveCount > 0) frame.mv = moves;
    return frame;
  }
  // A whole scene: the items in order, given the boxes of those moved since they were made
  for (const [key, x, y, w, h, clip, masks] of moves) {
    const item = itemByKey.get(key) as (SceneItem & { cl?: Box; mk?: { b: Box }[] }) | undefined;
    if (!item || !("w" in item)) continue;
    Object.assign(item, { x, y, w, h });
    if (clip === 0) delete item.cl;
    else item.cl = clip;
    if (masks !== 0 && item.mk) item.mk = item.mk.map((mask, index) => ({ ...mask, b: masks[index] ?? mask.b }));
  }
  const whole = (order ?? []).map((key) => itemByKey.get(key)).filter((item): item is SceneItem => !!item);
  return { ...header, items: whole };
};
