// Fetching from wago.tools (and the listfile from GitHub). Endpoints (verified 2026-11):
//
//   https://wago.tools/db2/<Table>/csv?build=<build>[&locale=<locale>]   (400 for an unknown build)
//   https://github.com/wowdev/wow-listfile/releases/latest/download/community-listfile.csv
//
// The game's files come from Blizzard's CDN (tact.ts); from wago.tools only the game's tables. wago.tools limits how
// fast one client may ask: a 429 (or 503) waits as the server says (Retry-After) or longer each time, every download
// pausing with it and fewer at once after, and is asked again.
import { APP_VERSION } from "../paths.ts";

export const WAGO_URL = "https://wago.tools";
export const LISTFILE_URL = "https://github.com/wowdev/wow-listfile/releases/latest/download/community-listfile.csv";
export const USER_AGENT = `AddonSim/${APP_VERSION}`;
/** Downloads at once: at most, at first, and how many must go through before one more is allowed */
export const MAX_PARALLEL_DOWNLOADS = 6;
const START_PARALLEL_DOWNLOADS = 4;
const RAISE_AFTER_SUCCESSES = 20;

export const db2Url = (table: string, build: string, locale: string): string =>
  `${WAGO_URL}/db2/${table}/csv?build=${build}${locale === "enUS" ? "" : `&locale=${locale}`}`;

/** The remote server says the file does not exist */
export class NotFoundError extends Error {
  override name = "NotFoundError";
}

/** The remote server asks to be asked less often (429, or 503 while busy): how long it said to wait, if it did */
export class RateLimitError extends Error {
  override name = "RateLimitError";
  constructor(
    message: string,
    readonly retryAfterMs: number | null,
  ) {
    super(message);
  }
}

/** How many times a rate-limited download is asked again, and the longest wait between */
const RATE_LIMIT_TRIES = 6;
const MAX_RATE_LIMIT_WAIT_MS = 30_000;
/** Until when every download waits (performance.now()), after a server asked for less */
let pausedUntil = 0;

/** Whether the downloads are waiting now because a server asked for less (the setup says so) */
export const isRateLimited = (): boolean => pausedUntil > performance.now();

/** Retry-After as milliseconds: seconds, or an HTTP date; null when absent or unreadable */
const readRetryAfter = (value: string | null): number | null => {
  if (!value) return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000);
  const at = Date.parse(value);
  return Number.isNaN(at) ? null : Math.max(0, at - Date.now());
};

/**
 * At most `limit` holders at once, the rest waiting in order; the limit halves when the server asks for less and grows
 * back by one after a run of downloads that went through (as TCP paces itself): fewer requests turned away, and none
 * wasted on retries while wago.tools is busy
 */
class AdaptiveLimit {
  #limit: number;
  #active = 0;
  #successes = 0;
  readonly #waiting: (() => void)[] = [];

  constructor(
    start: number,
    readonly max: number,
    readonly raiseAfter: number,
  ) {
    this.#limit = start;
  }

  get limit(): number {
    return this.#limit;
  }

  async use<T>(task: () => Promise<T>): Promise<T> {
    while (this.#active >= this.#limit) await new Promise<void>((resolve) => this.#waiting.push(resolve));
    this.#active++;
    try {
      return await task();
    } finally {
      this.#active--;
      this.#wake();
    }
  }

  /** The server asked for less: half as many at once (one at least) */
  slowDown(): void {
    this.#limit = Math.max(1, Math.floor(this.#limit / 2));
    this.#successes = 0;
  }

  /** One went through: after a run of them, one more at once */
  succeeded(): void {
    this.#successes++;
    if (this.#successes < this.raiseAfter || this.#limit >= this.max) return;
    this.#limit++;
    this.#successes = 0;
    this.#wake();
  }

  #wake(): void {
    for (let free = this.#limit - this.#active; free > 0 && this.#waiting.length > 0; free--) this.#waiting.shift()?.();
  }
}

/**
 * GET url and hand each chunk of the body to onChunk. The timeout is for silence, not the whole transfer (as a
 * socket timeout is): the listfile is 150 MB and may take minutes on a slow line.
 */
export const streamUrl = async (
  url: string,
  idleTimeoutMs: number,
  onChunk: (chunk: Uint8Array) => void | Promise<void>,
): Promise<{ contentType: string }> => {
  const controller = new AbortController();
  let timer = setTimeout(() => controller.abort(new Error(`timed out after ${idleTimeoutMs} ms`)), idleTimeoutMs);
  const touch = (): void => {
    clearTimeout(timer);
    timer = setTimeout(() => controller.abort(new Error(`timed out after ${idleTimeoutMs} ms`)), idleTimeoutMs);
  };
  try {
    const response = await fetch(url, { headers: { "User-Agent": USER_AGENT }, signal: controller.signal });
    if (response.status === 404) throw new NotFoundError(url);
    if (response.status === 429 || response.status === 503) {
      await response.body?.cancel();
      throw new RateLimitError(
        `HTTP Error ${response.status}: ${response.statusText} (${url})`,
        readRetryAfter(response.headers.get("Retry-After")),
      );
    }
    if (!response.ok) throw new Error(`HTTP Error ${response.status}: ${response.statusText} (${url})`);
    const contentType = response.headers.get("Content-Type") ?? "";
    if (response.body) {
      for await (const chunk of response.body) {
        touch();
        await onChunk(chunk);
      }
    }
    return { contentType };
  } finally {
    clearTimeout(timer);
  }
};

const slots = new AdaptiveLimit(START_PARALLEL_DOWNLOADS, MAX_PARALLEL_DOWNLOADS, RAISE_AFTER_SUCCESSES);

/** How many downloads may run at once now (it falls when a server asks for less, and grows back) */
export const getParallelDownloads = (): number => slots.limit;

/** The whole body of url, a few at once (getParallelDownloads); NotFoundError for a 404 or wago's JSON error */
export const download = (url: string, idleTimeoutMs = 30_000): Promise<Uint8Array> =>
  slots.use(async () => {
    let chunks: Uint8Array[] = [];
    let contentType = "";
    for (let attempt = 1; ; attempt++) {
      const waitMs = pausedUntil - performance.now();
      if (waitMs > 0) await Bun.sleep(waitMs);
      chunks = [];
      try {
        ({ contentType } = await streamUrl(url, idleTimeoutMs, (chunk) => {
          chunks.push(chunk);
        }));
        slots.succeeded();
        break;
      } catch (error) {
        if (!(error instanceof RateLimitError) || attempt >= RATE_LIMIT_TRIES) throw error;
        // (as long as the server said, else twice as long each time, with a little spread so they do not return
        // together; every download waits as long)
        const backoffMs = Math.min(MAX_RATE_LIMIT_WAIT_MS, 1000 * 2 ** (attempt - 1));
        const delayMs = Math.min(MAX_RATE_LIMIT_WAIT_MS, error.retryAfterMs ?? backoffMs) + Math.random() * 250;
        if (pausedUntil <= performance.now()) {
          // (once a pause, not for every download waiting in it: fewer at once from now on)
          slots.slowDown();
          process.stderr.write(
            `${error.message}: downloads wait ${(delayMs / 1000).toFixed(1)} s, then go on ${slots.limit} at once\n`,
          );
        }
        pausedUntil = Math.max(pausedUntil, performance.now() + delayMs);
      }
    }
    const body = Buffer.concat(chunks);
    if (contentType.startsWith("application/json") && body.subarray(0, 9).toString("latin1") === '{"error":') {
      throw new NotFoundError(body.toString("utf8"));
    }
    return new Uint8Array(body.buffer, body.byteOffset, body.byteLength);
  });
