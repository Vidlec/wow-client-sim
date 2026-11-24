// The game's clock: a frame each 1/fps seconds (the work of the last one counted in, not a full frame's wait after
// it), or at once after an input, at most twice as often. While a page watches, each frame is one request to the
// simulator, the tick and what changed in the scene together, and what changed goes out to the pages.
import { type Config, DEFAULT_FPS } from "./config.ts";
import type { LuaHost } from "./luaHost.ts";
import type { SceneStream } from "./sceneStream.ts";

const MIN_FPS = 10;
const MAX_FPS = 240;
const RETRY_MS = 1000;

const runFrame = async (host: LuaHost, stream: SceneStream, elapsedSeconds: number): Promise<void> => {
  if (!host.isRunning) return; // (not set up yet, starting, or stopped: the page shows why)
  if (!stream.isWatched()) {
    if (host.isPaused) return;
    const result = await host.request({ op: "tick", dt: elapsedSeconds * host.speed });
    if (result.reload) await host.start();
    return;
  }
  // (what changed in the scene comes as a binary frame after the header: lua/stream.lua)
  const request: Record<string, unknown> & { op: string } = { op: "frame" };
  const inputs = stream.takeInputs();
  if (inputs.length > 0) request.inputs = inputs;
  if (!host.isPaused) request.dt = elapsedSeconds * host.speed;
  const started = performance.now();
  const { text, bin } = await host.requestWithBinary(request);
  if (text.includes('"reload":true')) {
    await host.start();
    return;
  }
  stream.noteFrame(performance.now() - started, text.includes('"delta":true'), host.lastLockWait * 1000);
  await stream.publish(host, text, bin);
};

export const runClock = async (host: LuaHost, stream: SceneStream, config: Config): Promise<never> => {
  // (Read at each frame: the setup may change it while the clock runs)
  const frameMsNow = (): number => 1000 / Math.max(MIN_FPS, Math.min(MAX_FPS, Number(config.fps) || DEFAULT_FPS));
  let frameMs = frameMsNow();
  let last = performance.now();
  let nextTick = last + frameMs;
  for (;;) {
    const left = nextTick - performance.now();
    if (left > 0) await stream.sleep(left);
    let now = performance.now();
    if (now - last < frameMs / 2) {
      await Bun.sleep(frameMs / 2 - (now - last));
      now = performance.now();
    }
    frameMs = frameMsNow();
    nextTick = Math.max(nextTick + frameMs, now);
    const elapsedSeconds = (now - last) / 1000;
    last = now;
    try {
      await runFrame(host, stream, elapsedSeconds);
    } catch (error) {
      // The host died: the page shows it, a reload starts it again
      process.stderr.write(`tick: ${error instanceof Error ? error.message : String(error)}\n`);
      await Bun.sleep(RETRY_MS);
    }
  }
};
