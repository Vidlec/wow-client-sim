import { describe, expect, test } from "bun:test";
import { createFrameReader } from "./frameReader.ts";

const streamOf = (chunks: Uint8Array[]): ReadableStream<Uint8Array> =>
  new ReadableStream({
    start: (controller) => {
      for (const chunk of chunks) controller.enqueue(chunk);
      controller.close();
    },
  });

const bytes = (text: string): Uint8Array => new TextEncoder().encode(text);

describe("createFrameReader", () => {
  test("reads lines, and the binary part a line's end announces, across chunks", async () => {
    const binary = new Uint8Array([1, 10, 0, 255, 10, 7]); // (newlines inside the binary part)
    const whole = new Uint8Array([
      ...bytes('{"ready":true}\n{"delta":true,"bin":6,"id":1}\n'),
      ...binary,
      ...bytes('{"text":"a \\"bin\\":3,\\"id\\":1}","id":2}\n'),
    ]);
    // cut into small pieces, so lines and the binary part span chunks
    const chunks: Uint8Array[] = [];
    for (let at = 0; at < whole.length; at += 5) chunks.push(whole.slice(at, at + 5));
    const reader = createFrameReader(streamOf(chunks));
    expect(await reader.next()).toEqual({ text: '{"ready":true}' });
    const framed = await reader.next();
    expect(framed?.text).toBe('{"delta":true,"bin":6,"id":1}');
    expect([...(framed?.bin ?? [])]).toEqual([...binary]);
    // a string that only looks like the mark is text
    expect((await reader.next())?.bin).toBeUndefined();
    expect(await reader.next()).toBeNull();
  });
});
