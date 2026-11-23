// Fetching from wago.tools (and the listfile from GitHub). Endpoints (verified 2026-11):
//
//   https://wago.tools/db2/<Table>/csv?build=<build>[&locale=<locale>]   (400 for an unknown build)
//   https://wago.tools/api/casc/<fdid>?download&build=<build>
//       build is honoured: without it you get the retail file, whose atlas layouts differ; a missing file is
//       200 + {"error":"File not found"}, an unknown build is 400
//   https://github.com/wowdev/wow-listfile/releases/latest/download/community-listfile.csv

export const WAGO_URL = "https://wago.tools";
export const LISTFILE_URL = "https://github.com/wowdev/wow-listfile/releases/latest/download/community-listfile.csv";
export const USER_AGENT = "AddonSim/0.1";
export const MAX_PARALLEL_DOWNLOADS = 6;

export const cascUrl = (fdid: number, build: string): string => `${WAGO_URL}/api/casc/${fdid}?download&build=${build}`;

export const db2Url = (table: string, build: string, locale: string): string =>
  `${WAGO_URL}/db2/${table}/csv?build=${build}${locale === "enUS" ? "" : `&locale=${locale}`}`;

/** The remote server says the file does not exist */
export class NotFoundError extends Error {
  override name = "NotFoundError";
}

/** At most `size` holders at once; the rest wait in order */
class Semaphore {
  private free: number;
  private readonly waiting: (() => void)[] = [];

  constructor(size: number) {
    this.free = size;
  }

  async use<T>(task: () => Promise<T>): Promise<T> {
    if (this.free > 0) this.free--;
    else await new Promise<void>((resolve) => this.waiting.push(resolve));
    try {
      return await task();
    } finally {
      const next = this.waiting.shift();
      if (next) next();
      else this.free++;
    }
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

const slots = new Semaphore(MAX_PARALLEL_DOWNLOADS);

/** The whole body of url, at most MAX_PARALLEL_DOWNLOADS at once; NotFoundError for a 404 or wago's JSON error */
export const download = (url: string, idleTimeoutMs = 30_000): Promise<Uint8Array> =>
  slots.use(async () => {
    const chunks: Uint8Array[] = [];
    const { contentType } = await streamUrl(url, idleTimeoutMs, (chunk) => {
      chunks.push(chunk);
    });
    const body = Buffer.concat(chunks);
    if (contentType.startsWith("application/json") && body.subarray(0, 9).toString("latin1") === '{"error":') {
      throw new NotFoundError(body.toString("utf8"));
    }
    return new Uint8Array(body.buffer, body.byteOffset, body.byteLength);
  });
