import { describe, expect, test } from "bun:test";
import type { LuaHost } from "./luaHost.ts";
import { type PageSocket, SceneStream, withGeneration } from "./sceneStream.ts";

/** A page's socket as the stream uses it: what it was sent, and how much it has not taken yet */
const createPage = (buffered = 0): PageSocket & { sent: string[] } => {
  const sent: string[] = [];
  const page = {
    data: { needsWhole: true },
    sent,
    send: (text: string) => {
      sent.push(text);
      return text.length;
    },
    getBufferedAmount: () => buffered,
  };
  return page as unknown as PageSocket & { sent: string[] };
};

/** The host as publish uses it: its run, and the whole scene when asked */
const createHost = (generation = 1): LuaHost =>
  ({ generation, requestRaw: async () => '{"version":9,"whole":true}' }) as unknown as LuaHost;

describe("withGeneration", () => {
  test("adds the run to the object as written", () => {
    expect(withGeneration('{"version":3}', 2)).toBe('{"version":3,"generation":2}');
    expect(withGeneration("{}", 1)).toBe('{"generation":1}');
    expect(withGeneration("not json", 1)).toBe("not json");
  });
});

describe("input", () => {
  test("moves after moves count once, the rest keep their order", () => {
    const stream = new SceneStream();
    stream.queueInput({ type: "move", x: 1 });
    stream.queueInput({ type: "move", x: 2 });
    stream.queueInput({ type: "down", x: 2 });
    stream.queueInput({ type: "move", x: 3 });
    expect(stream.takeInputs().map((event) => [event.type, event.x])).toEqual([
      ["move", 2],
      ["down", 2],
      ["move", 3],
    ]);
    expect(stream.takeInputs()).toEqual([]);
  });

  test("an input wakes the clock", async () => {
    const stream = new SceneStream();
    const started = performance.now();
    const sleeping = stream.sleep(5000);
    stream.queueInput({ type: "down" });
    await sleeping;
    expect(performance.now() - started).toBeLessThan(1000);
  });
});

describe("publish", () => {
  test("a new page gets the whole scene, then only the changes", async () => {
    const stream = new SceneStream();
    const page = createPage();
    stream.add(page);
    const host = createHost();
    await stream.publish(host, '{"delta":true,"version":1,"errors":0,"chat":0}');
    expect(page.sent).toEqual(['{"version":9,"whole":true,"generation":1}']);
    await stream.publish(host, '{"delta":true,"version":2,"errors":0,"chat":0}');
    expect(page.sent.at(-1)).toBe('{"delta":true,"version":2,"errors":0,"chat":0,"generation":1}');
  });

  test("a page behind is sent the whole scene again instead of more changes", async () => {
    const stream = new SceneStream();
    const page = createPage(10_000_000);
    stream.add(page);
    page.data.needsWhole = false;
    await stream.publish(createHost(), '{"delta":true,"version":3,"errors":0,"chat":0}');
    expect(page.sent).toEqual(['{"version":9,"whole":true,"generation":1}']);
    expect(page.data.needsWhole).toBe(false);
  });

  test("a new run of the host sends every page the whole scene", async () => {
    const stream = new SceneStream();
    const page = createPage();
    stream.add(page);
    await stream.publish(createHost(1), '{"delta":true,"version":1,"errors":0,"chat":0}');
    await stream.publish(createHost(2), '{"delta":true,"version":2,"errors":0,"chat":0}');
    expect(page.sent.at(-1)).toBe('{"version":9,"whole":true,"generation":2}');
  });
});
