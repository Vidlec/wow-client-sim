import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { createBinaryState, FIELDS, readBinaryFrame } from "./binaryFrame.ts";

/** A binary message as the server sends it: the header's length, the header, then the scene's bytes */
const message = (header: object, scene: number[]): ArrayBuffer => {
  const head = new TextEncoder().encode(JSON.stringify(header));
  const out = new Uint8Array(4 + head.length + scene.length);
  new DataView(out.buffer).setUint32(0, head.length, true);
  out.set(head, 4);
  out.set(scene, 4 + head.length);
  return out.buffer;
};
const u16 = (value: number): number[] => [value & 255, value >> 8];
const u32 = (value: number): number[] => [value & 255, (value >> 8) & 255, (value >> 16) & 255, value >>> 24];
const f64 = (value: number): number[] => {
  const view = new DataView(new ArrayBuffer(8));
  view.setFloat64(0, value, true);
  return [...new Uint8Array(view.buffer)];
};
const text = (value: string): number[] => [...new TextEncoder().encode(value)];
// packed values, as lua/pack.lua writes them (field numbers: k 0, i 1, x 2, y 3, w 4, h 5, a 6)
const int = (value: number): number[] => [3, ...u32(value)];
const num = (value: number): number[] => [4, ...f64(value)];
const str = (value: string): number[] => [5, ...u32(value.length), ...text(value)];
const field = (number: number, value: number[]): number[] => [8, number, ...value];
const item = (id: number, x: number): number[] => {
  const packed = [7, ...u32(6), ...field(0, str("t")), ...field(1, int(id)), ...field(2, num(x))];
  packed.push(...field(3, int(5)), ...field(4, int(10)), ...field(5, int(10)));
  return packed;
};

describe("readBinaryFrame", () => {
  test("a whole scene, then changes: keys by id, the order, items, moves", () => {
    const state = createBinaryState();
    const first = item(7, 1.5);
    const whole = readBinaryFrame(
      message({ version: 1 }, [
        2,
        ...u32(1),
        ...u32(0),
        ...u16(2),
        ...text("t7"),
        1,
        ...u32(1),
        ...u32(0),
        ...u32(1),
        ...u32(0),
        ...u32(first.length),
        ...first,
        ...u32(0),
      ]),
      state,
    );
    expect(whole.items).toEqual([{ k: "t", i: 7, x: 1.5, y: 5, w: 10, h: 10 }]);
    // changes: a new key (t8) and item, the order, and t7 moved with a clip
    const second = item(8, 3);
    const changes = readBinaryFrame(
      message({ version: 2 }, [
        1,
        ...u32(1),
        ...u32(1),
        ...u16(2),
        ...text("t8"),
        1,
        ...u32(2),
        ...u32(0),
        ...u32(1),
        ...u32(1),
        ...u32(1),
        ...u32(second.length),
        ...second,
        ...u32(1),
        ...u32(0),
        ...f64(20),
        ...f64(30),
        ...f64(10),
        ...f64(10),
        1,
        ...f64(0),
        ...f64(0),
        ...f64(50),
        ...f64(50),
        0,
      ]),
      state,
    );
    expect(changes.delta).toBe(true);
    expect(changes.o).toEqual(["t7", "t8"]);
    expect(changes.u).toEqual([{ k: "t", i: 8, x: 3, y: 5, w: 10, h: 10 }]);
    expect(changes.mv).toEqual([["t7", 20, 30, 10, 10, [0, 0, 50, 50], 0]]);
  });
});

describe("the field names", () => {
  test("are the same list, in the same order, as the simulator packs them (lua/pack.lua)", async () => {
    const lua = await Bun.file(join(import.meta.dir, "..", "..", "..", "lua", "pack.lua")).text();
    const list = /pack\.FIELDS = \{([^}]*)\}/.exec(lua)?.[1] ?? "";
    expect([...list.matchAll(/"([^"]*)"/g)].map((match) => match[1])).toEqual([...FIELDS]);
  });
});
