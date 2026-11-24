// Raw game files by fileDataID, from Blizzard's CDN (a TactStore: src/server/assets/tact.ts), kept in
// cache/casc/<build>/<fdid>. An empty <fdid>.missing beside them marks "not in this build" for good; other failures
// are retried later.
import { join } from "node:path";
import { NotFoundError } from "./download.ts";
import { readIfExists, writeFileAtomic } from "./files.ts";
import { type FailureMemory, SingleFlight } from "./flight.ts";

/** Where a file comes from when the cache has none: its bytes, or NotFoundError when the build has no such file */
export type FileSource = { get: (fdid: number) => Promise<Uint8Array> };

export class CascStore {
  private readonly flights = new SingleFlight();

  constructor(
    readonly folder: string,
    private readonly failures: FailureMemory,
    /** Blizzard's CDN, for the build */
    private readonly source: FileSource,
  ) {}

  /** The file's bytes (fetched once, then cached), or null when it does not exist or cannot be had now */
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
        data = await this.source.get(fdid);
      } catch (error) {
        if (error instanceof NotFoundError) await writeFileAtomic(missingPath, new Uint8Array(0));
        else {
          // (said once until it is tried again: a game file that cannot be had shows as missing art in the page)
          process.stderr.write(`game file ${fdid}: ${error instanceof Error ? error.message : String(error)}\n`);
          this.failures.add(key);
        }
        return null;
      }
      await writeFileAtomic(path, data);
      return data;
    });
  }
}
