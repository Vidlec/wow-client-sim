// Raw game files by fileDataID, from wago.tools' CASC mirror, kept in cache/casc/<build>/<fdid>.
// An empty <fdid>.missing beside them marks "not in this build" for good; other failures are retried later.
import { join } from "node:path";
import { cascUrl, download, NotFoundError } from "./download.ts";
import { readIfExists, writeFileAtomic } from "./files.ts";
import { type FailureMemory, SingleFlight } from "./flight.ts";

export class CascStore {
  private readonly flights = new SingleFlight();

  constructor(
    readonly folder: string,
    private readonly build: string,
    private readonly failures: FailureMemory,
  ) {}

  /** The file's bytes (downloaded once, then cached), or null when it does not exist or cannot be had now */
  get(fdid: number): Promise<Uint8Array | null> {
    const key = `raw:${fdid}`;
    return this.flights.run(key, async () => {
      const path = join(this.folder, String(fdid));
      const missingPath = `${path}.missing`;
      const cached = await readIfExists(path);
      if (cached) return cached;
      if (this.failures.hasRecent(key) || (await Bun.file(missingPath).exists())) return null;
      let data: Uint8Array;
      try {
        data = await download(cascUrl(fdid, this.build));
      } catch (error) {
        if (error instanceof NotFoundError) await writeFileAtomic(missingPath, new Uint8Array(0));
        else this.failures.add(key);
        return null;
      }
      await writeFileAtomic(path, data);
      return data;
    });
  }
}
