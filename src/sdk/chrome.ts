// Headless Chrome (or Edge) taking a picture of one of the sim's picture pages (src/ui/engine/picture.ts), driven over
// its DevTools protocol: the page opened at the picture's size, waited on till its title says "ready" (its art in and
// the GPU done), then the picture taken. On the real clock, not Chrome's virtual one: the GPU (WebGPU) answers in its
// own time, which a virtual clock does not wait for. Where the machine's GPU gives Chrome no WebGPU (a server, a CI
// runner), the picture is taken again with Chrome's own software one (SwiftShader).
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const START_TIMEOUT_MS = 20_000;
const POLL_MS = 50;

/** Chrome or Edge where they are usually installed (ADDONSIM_CHROME names another); null with neither */
export const findChrome = (): string | null => {
  const places =
    process.platform === "win32"
      ? [
          "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
          "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
          "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
          "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
        ]
      : [
          "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
          "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
          "/usr/bin/google-chrome",
          "/usr/bin/chromium",
          "/usr/bin/chromium-browser",
        ];
  return process.env.ADDONSIM_CHROME ?? places.find((path) => existsSync(path)) ?? null;
};

export type PictureRequest = {
  chrome: string;
  /** The picture page's address (…/?shot=…) */
  url: string;
  /** The page's size in CSS pixels, and the pixels per one (2: as on a sharp display) */
  width: number;
  height: number;
  scale: number;
  /** Where the PNG goes */
  target: string;
  timeoutMs: number;
};

/** What the page said when the picture was taken: "ready", or why not ("missing", "no gpu", "timeout") */
export type PictureOutcome = { title: string; isSaved: boolean };

type Message = { id?: number; result?: Record<string, unknown>; error?: { message: string } };

const wait = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** The page drawn by Chrome and saved as a PNG at target: with the machine's GPU, else Chrome's software one */
export const takePicture = async (request: PictureRequest): Promise<PictureOutcome> => {
  const outcome = await takePictureWith(request, false);
  return outcome.title === "no gpu" ? takePictureWith(request, true) : outcome;
};

const takePictureWith = async (request: PictureRequest, isSoftwareGpu: boolean): Promise<PictureOutcome> => {
  // A fresh profile each time: one left behind by another Chrome holds it, and the next waits on it for good
  const profile = mkdtempSync(join(tmpdir(), "addonsim-chrome-"));
  const child = Bun.spawn(
    [
      request.chrome,
      "--headless=new",
      "--hide-scrollbars",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-extensions",
      "--mute-audio",
      // (no crash reporter: on Windows its process outlived Chrome's and held the profile, which then could not go)
      "--disable-breakpad",
      "--disable-crash-reporter",
      ...(isSoftwareGpu ? ["--enable-unsafe-webgpu", "--use-webgpu-adapter=swiftshader"] : []),
      "--remote-debugging-port=0",
      `--user-data-dir=${profile}`,
      `--window-size=${Math.max(1, Math.round(request.width))},${Math.max(1, Math.round(request.height))}`,
      "about:blank",
    ],
    { stdin: "ignore", stdout: "ignore", stderr: "ignore", windowsHide: true },
  );
  let socket: WebSocket | null = null;
  try {
    const deadline = Date.now() + request.timeoutMs;
    // Its port, which Chrome writes into the profile once it listens
    const portFile = join(profile, "DevToolsActivePort");
    let port = 0;
    const startBy = Date.now() + START_TIMEOUT_MS;
    while (!port && Date.now() < startBy) {
      if (existsSync(portFile)) port = Number(readFileSync(portFile, "utf8").split("\n")[0]) || 0;
      if (!port) await wait(POLL_MS);
    }
    if (!port) throw new Error("Chrome did not start");
    let pageUrl: string | null = null;
    while (!pageUrl && Date.now() < startBy) {
      try {
        const targets = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()) as {
          type: string;
          webSocketDebuggerUrl: string;
        }[];
        pageUrl = targets.find((target) => target.type === "page")?.webSocketDebuggerUrl ?? null;
      } catch {
        // (not answering yet)
      }
      if (!pageUrl) await wait(POLL_MS);
    }
    if (!pageUrl) throw new Error("Chrome opened no page");
    const open = new WebSocket(pageUrl);
    socket = open;
    await new Promise<void>((resolve, reject) => {
      open.addEventListener("open", () => resolve());
      open.addEventListener("error", () => reject(new Error("no DevTools connection")));
    });
    let nextId = 0;
    const pending = new Map<number, { resolve: (message: Message) => void; reject: (problem: Error) => void }>();
    open.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data)) as Message;
      if (message.id !== undefined) {
        pending.get(message.id)?.resolve(message);
        pending.delete(message.id);
      }
    });
    // (Chrome gone mid-shot: every question still open fails, rather than waiting for good)
    open.addEventListener("close", () => {
      for (const { reject } of pending.values()) reject(new Error("the DevTools connection closed"));
      pending.clear();
    });
    const send = (method: string, params: Record<string, unknown> = {}): Promise<Message> =>
      new Promise((resolve, reject) => {
        nextId += 1;
        const id = nextId;
        pending.set(id, { resolve, reject });
        open.send(JSON.stringify({ id, method, params }));
        // (and none waits past the shot's deadline)
        const timer = setTimeout(
          () => {
            if (pending.delete(id)) reject(new Error(`no answer to ${method} from Chrome`));
          },
          Math.max(1000, deadline - Date.now()),
        );
        timer.unref?.();
      });
    await send("Emulation.setDeviceMetricsOverride", {
      width: Math.max(1, Math.round(request.width)),
      height: Math.max(1, Math.round(request.height)),
      deviceScaleFactor: request.scale,
      mobile: false,
    });
    await send("Page.navigate", { url: request.url });
    let title = "";
    while (Date.now() < deadline) {
      const answer = await send("Runtime.evaluate", { expression: "document.title", returnByValue: true });
      title = String((answer.result?.result as { value?: unknown } | undefined)?.value ?? "");
      if (title === "ready" || title === "missing" || title === "no gpu") break;
      await wait(POLL_MS);
    }
    if (title !== "ready")
      return { title: title === "missing" || title === "no gpu" ? title : "timeout", isSaved: false };
    const shot = await send("Page.captureScreenshot", { format: "png" });
    const data = shot.result?.data;
    if (typeof data !== "string") return { title, isSaved: false };
    await Bun.write(request.target, Buffer.from(data, "base64"));
    return { title, isSaved: true };
  } finally {
    socket?.close();
    child.kill();
    await child.exited;
    removeProfile(profile);
  }
};

/** Chrome's profile taken away: at once, or a little later while a process of Chrome's still holds a file in it */
const removeProfile = (profile: string, triesLeft = 10): void => {
  try {
    rmSync(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
  } catch {
    // (the picture is taken: the folder is only left over, and is tried again)
    if (triesLeft > 0) setTimeout(() => removeProfile(profile, triesLeft - 1), 1000).unref?.();
  }
};
