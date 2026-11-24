import { afterAll, describe, expect, test } from "bun:test";
import { download, getParallelDownloads, MAX_PARALLEL_DOWNLOADS, NotFoundError } from "./download.ts";

// A server that asks for less first: 429 (with Retry-After) the first time a path is asked for, then the file
const asked = new Map<string, number>();
let open = 0;
let mostOpen = 0;
const server = Bun.serve({
  port: 0,
  fetch: async (request) => {
    const path = new URL(request.url).pathname;
    if (path.startsWith("/ok-")) {
      // (a file that takes a moment, counting how many are asked for at once)
      open++;
      mostOpen = Math.max(mostOpen, open);
      await Bun.sleep(5);
      open--;
      return new Response("ok");
    }
    const count = (asked.get(path) ?? 0) + 1;
    asked.set(path, count);
    if (path === "/missing") return new Response("no", { status: 404 });
    if (path === "/always-busy") return new Response("busy", { status: 429, headers: { "Retry-After": "0" } });
    if (count === 1) return new Response("slow down", { status: 429, headers: { "Retry-After": "0" } });
    return new Response(`file ${path}`);
  },
});
afterAll(() => server.stop(true));
const at = (path: string): string => `http://localhost:${server.port}${path}`;

describe("download", () => {
  test("a rate-limited file is asked for again and comes", async () => {
    const body = await download(at("/texture"));
    expect(new TextDecoder().decode(body)).toBe("file /texture");
    expect(asked.get("/texture")).toBe(2);
  });

  test("many at once, each limited first, all come", async () => {
    const paths = Array.from({ length: 12 }, (_, index) => `/burst-${index}`);
    const bodies = await Promise.all(paths.map((path) => download(at(path))));
    expect(bodies.map((body) => new TextDecoder().decode(body))).toEqual(paths.map((path) => `file ${path}`));
  });

  test("a server that stays busy fails in the end; a missing file fails at once", async () => {
    await expect(download(at("/always-busy"))).rejects.toThrow("429");
    expect(asked.get("/always-busy")).toBe(6);
    await expect(download(at("/missing"))).rejects.toBeInstanceOf(NotFoundError);
    expect(asked.get("/missing")).toBe(1);
  });

  test("a 429 halves how many go at once; a run that goes through raises it back, never past the most", async () => {
    const before = getParallelDownloads();
    await download(at("/slow-down-once"));
    const after = getParallelDownloads();
    expect(after).toBeLessThan(before === 1 ? 2 : before);
    expect(after).toBe(Math.max(1, Math.floor(before / 2)));
    mostOpen = 0;
    await Promise.all(Array.from({ length: 200 }, (_, index) => download(at(`/ok-${index}`))));
    expect(getParallelDownloads()).toBeGreaterThan(after);
    expect(getParallelDownloads()).toBeLessThanOrEqual(MAX_PARALLEL_DOWNLOADS);
    expect(mostOpen).toBeLessThanOrEqual(MAX_PARALLEL_DOWNLOADS);
  });
});
