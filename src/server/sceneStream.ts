// The scene pushed to the pages as it changes: a WebSocket per page, the frames the simulator writes (lua/stream.lua:
// a whole scene, then only what changed) sent to each, the pages' input taken with the next frame.
//
// A page joins with the whole scene the stream stands at; every frame after is a change to it. A page that falls
// behind (more unsent than a few frames: a tab in the background) is sent the whole scene again instead of the frames
// it missed. A frame's items and order are absolute, so a frame applied over a newer whole scene changes nothing.
import type { ServerWebSocket } from "bun";
import type { LuaHost } from "./luaHost.ts";

/** Bytes a page may have waiting before it is dropped back to a whole scene (half a second of busy frames) */
const MAX_BUFFERED_BYTES = 2_000_000;
/** A page polling /api/scene this recently keeps the frames coming */
const LEGACY_SECONDS = 2;
const POLL_WAIT_MS = 500;
const TIMING_WINDOW_MS = 1000;

export type PageSocket = ServerWebSocket<{ needsWhole: boolean }>;
export type InputEvent = { type?: string; [key: string]: unknown };
type Timing = { at: number; ms: number; isSent: boolean; waitedMs: number };

export type StreamPerf = {
  fps: number;
  sentPerSecond: number;
  frameMs: number;
  worstMs: number;
  pages: number;
  worstWaitMs?: number;
};

/** The host's run added to the object as written: "{...}" -> "{..., "generation": N}" */
export const withGeneration = (text: string, generation: number): string => {
  if (!text.endsWith("}")) return text;
  const body = text.slice(0, -1).trimEnd();
  return `${body}${body.endsWith("{") ? "" : ","}"generation":${generation}}`;
};

const round = (value: number, places: number): number => Math.round(value * 10 ** places) / 10 ** places;

export class SceneStream {
  readonly #pages = new Set<PageSocket>();
  #inputs: InputEvent[] = [];
  #timings: Timing[] = [];
  #version: number | null = null;
  #generation: number | null = null;
  #lastStatus: string | null = null;
  #legacyAskedAt = 0;
  #versionWaiters: (() => void)[] = [];
  #wakeClock: (() => void) | null = null;

  // The clock's wait: an input or a page joining ends it early, so its effect is drawn at once

  /** Resolves after ms, or sooner when woken */
  sleep(ms: number): Promise<void> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.#wakeClock = null;
        resolve();
      }, ms);
      this.#wakeClock = () => {
        clearTimeout(timer);
        this.#wakeClock = null;
        resolve();
      };
    });
  }

  wake(): void {
    this.#wakeClock?.();
  }

  // Input

  queueInput(event: InputEvent): void {
    // A move after a move: only where the mouse got to counts (the page sends one each of its frames)
    const last = this.#inputs.at(-1);
    if (event.type === "move" && last?.type === "move") this.#inputs[this.#inputs.length - 1] = event;
    else this.#inputs.push(event);
    this.wake();
  }

  takeInputs(): InputEvent[] {
    const inputs = this.#inputs;
    this.#inputs = [];
    return inputs;
  }

  // Pages

  add(page: PageSocket): void {
    page.data.needsWhole = true;
    this.#pages.add(page);
    this.wake();
  }

  remove(page: PageSocket): void {
    this.#pages.delete(page);
  }

  requestWhole(page: PageSocket): void {
    page.data.needsWhole = true;
    this.wake();
  }

  isWatched(): boolean {
    return this.#pages.size > 0 || performance.now() - this.#legacyAskedAt < LEGACY_SECONDS * 1000;
  }

  // How the clock keeps up, over the last second

  noteFrame(ms: number, isSent: boolean, waitedMs: number): void {
    const at = performance.now();
    this.#timings.push({ at, ms, isSent, waitedMs });
    const firstKept = this.#timings.findIndex((timing) => at - timing.at <= TIMING_WINDOW_MS);
    if (firstKept > 0) this.#timings.splice(0, firstKept);
  }

  perf(): StreamPerf {
    const timings = this.#timings;
    const pages = this.#pages.size;
    if (timings.length === 0) return { fps: 0, sentPerSecond: 0, frameMs: 0, worstMs: 0, pages };
    const spent = timings.map((timing) => timing.ms);
    return {
      fps: timings.length,
      sentPerSecond: timings.filter((timing) => timing.isSent).length,
      frameMs: round(spent.reduce((sum, ms) => sum + ms, 0) / spent.length, 2),
      worstMs: round(Math.max(...spent), 1),
      pages,
      worstWaitMs: round(Math.max(...timings.map((timing) => timing.waitedMs)), 1),
    };
  }

  /**
   * After each tick: the frame the simulator wrote (a change, or only its counts) to the pages, and the whole scene
   * to those that need it
   */
  async publish(host: LuaHost, text: string): Promise<void> {
    const generation = host.generation;
    if (generation !== this.#generation) {
      this.#generation = generation;
      for (const page of this.#pages) page.data.needsWhole = true;
    }
    const version = Number(/"version":(-?\d+)/.exec(text)?.[1] ?? Number.NaN);
    const status = /"errors":\d+,"chat":\d+/.exec(text)?.[0] ?? null;
    const isDelta = text.includes('"delta":true');
    if (isDelta || status !== this.#lastStatus) {
      const framed = withGeneration(text, generation);
      for (const page of this.#pages) {
        if (page.data.needsWhole) continue;
        // Behind: what it has not drawn is dropped, and it starts again from a whole scene
        if (page.getBufferedAmount() > MAX_BUFFERED_BYTES) page.data.needsWhole = true;
        else page.send(framed);
      }
    }
    this.#lastStatus = status;
    const waiting = [...this.#pages].filter((page) => page.data.needsWhole);
    if (waiting.length > 0) {
      const whole = withGeneration(await host.requestRaw({ op: "sceneWhole" }), generation);
      for (const page of waiting) {
        page.data.needsWhole = false;
        page.send(whole);
      }
    }
    const newVersion = Number.isNaN(version) ? null : version;
    if (newVersion !== this.#version) {
      this.#version = newVersion;
      for (const resolve of this.#versionWaiters.splice(0)) resolve();
    }
  }

  /** The old poll (/api/scene, a page without WebSockets): the whole scene when it is newer than the page's */
  async waitWhole(host: LuaHost, since: number | null): Promise<string | null> {
    this.#legacyAskedAt = performance.now();
    if (since !== null && this.#version === since && host.generation === this.#generation) {
      const changed = await Promise.race([
        new Promise<boolean>((resolve) => this.#versionWaiters.push(() => resolve(true))),
        Bun.sleep(POLL_WAIT_MS).then(() => false),
      ]);
      if (!changed) return null;
    }
    return withGeneration(await host.requestRaw({ op: "sceneWhole" }), host.generation);
  }
}
