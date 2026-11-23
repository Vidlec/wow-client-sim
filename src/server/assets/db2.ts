// The game's DB2 tables for one build and language, as wago.tools' CSVs, kept in cache/db2/<build>[-<locale>]/.
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { parseCsv } from "./csv.ts";
import { db2Url, download } from "./download.ts";
import { writeFileAtomic } from "./files.ts";
import { type FailureMemory, SingleFlight } from "./flight.ts";

const DB2_IDLE_TIMEOUT_MS = 60_000;

/** wago answers some failures with a page instead of a table: a table's first line has columns */
const looksLikeCsv = (data: Uint8Array): boolean => {
  const firstLineEnd = data.indexOf(10);
  const firstLine = data.subarray(0, firstLineEnd < 0 ? data.length : firstLineEnd);
  const startsWithId = data[0] === 0x49 && data[1] === 0x44 && data[2] === 0x2c; // "ID,"
  return startsWithId || firstLine.includes(0x2c);
};

export class Db2Store {
  private readonly flights = new SingleFlight();

  constructor(
    readonly folder: string,
    private readonly build: string,
    private readonly locale: string,
    private readonly failures: FailureMemory,
  ) {}

  getPath(table: string): string {
    return join(this.folder, `${table}.csv`);
  }

  /** Downloads the table's CSV unless it is cached; false when it cannot be had now */
  private ensure(table: string): Promise<boolean> {
    const key = `db2:${table}`;
    return this.flights.run(key, async () => {
      const path = this.getPath(table);
      if (await Bun.file(path).exists()) return true;
      if (this.failures.hasRecent(key)) return false;
      let data: Uint8Array;
      try {
        data = await download(db2Url(table, this.build, this.locale), DB2_IDLE_TIMEOUT_MS);
      } catch {
        this.failures.add(key);
        return false;
      }
      if (!looksLikeCsv(data)) {
        this.failures.add(key);
        return false;
      }
      await writeFileAtomic(path, data);
      return true;
    });
  }

  /** The table's rows keyed by column name (parsed afresh each call), or null when it cannot be had */
  async getRows(table: string): Promise<Record<string, string>[] | null> {
    if (!(await this.ensure(table))) return null;
    return parseCsv(await readFile(this.getPath(table), "utf8"));
  }

  /** The local CSV of a table, downloaded on first use; null when it cannot be had */
  async getLocalPath(table: string): Promise<string | null> {
    return (await this.ensure(table)) ? this.getPath(table) : null;
  }
}
