// Game textures converted for the browser, kept in cache/png/<build>/<fdid>.png (or .jpg when the source was a JPEG,
// passed through untouched).
import { join } from "node:path";
import type { CascStore } from "./casc.ts";
import { readIfExists, writeFileAtomic } from "./files.ts";
import { type FailureMemory, SingleFlight } from "./flight.ts";
import { CONTENT_TYPES, convertImage } from "./image.ts";
import type { Served } from "./types.ts";

const CACHED_EXTENSIONS = ["png", "jpg"] as const;

export class TextureStore {
  private readonly flights = new SingleFlight();

  constructor(
    readonly folder: string,
    private readonly casc: CascStore,
    private readonly failures: FailureMemory,
  ) {}

  /** The texture as PNG (or its JPEG), or null when the file cannot be had or is no image */
  get(fdid: number): Promise<Served | null> {
    const key = `image:${fdid}`;
    return this.flights.run(key, async () => {
      const base = join(this.folder, String(fdid));
      for (const extension of CACHED_EXTENSIONS) {
        const cached = await readIfExists(`${base}.${extension}`);
        if (cached) return { data: cached, contentType: CONTENT_TYPES[extension] ?? "image/png" };
      }
      if (this.failures.hasRecent(key)) return null;
      const raw = await this.casc.get(fdid);
      if (raw === null) return null;
      let converted: Served;
      try {
        converted = convertImage(raw);
      } catch {
        this.failures.add(key); // not an image we read (or a broken one): asked again after a while
        return null;
      }
      const extension = converted.contentType === "image/jpeg" ? "jpg" : "png";
      await writeFileAtomic(`${base}.${extension}`, converted.data);
      return converted;
    });
  }
}
