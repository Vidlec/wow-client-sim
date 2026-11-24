// The community listfile (every game file's path and fileDataID, ~150 MB of "id;path" lines) indexed into
// cache/listfile.sqlite, keeping only what the simulator asks for: interface/, fonts/ and the minimap tiles.
//
//   files (stem TEXT, ext TEXT, fdid INTEGER), indexed on stem: "interface/icons/x.blp" is ("interface/icons/x", "blp")
//   meta (key TEXT PRIMARY KEY, value): source, downloadedBytes, rows, buildSeconds, builtAt
//
// Built once, in the background, as the body streams in: the server answers meanwhile (art says "not ready").
import { Database, type Statement } from "bun:sqlite";
import { existsSync } from "node:fs";
import { rename, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { LISTFILE_URL, streamUrl } from "./download.ts";
import { writeFileAtomic } from "./files.ts";
import { RETRY_SECONDS } from "./flight.ts";
import { getExtensionRank, splitExtension } from "./paths.ts";

const PREFIXES = ["interface/", "fonts/", "world/minimaps/", "textures/minimap/"];
const BATCH_SIZE = 50_000;
const IDLE_TIMEOUT_MS = 60_000;

export type ListfileRow = { stem: string; ext: string; fdid: number };
export type ListfileMeta = Record<string, string | number | null>;

/** Python's bytes.strip(): ASCII whitespace only */
const stripAscii = (text: string): string => text.replace(/^[ \t\n\r\v\f]+|[ \t\n\r\v\f]+$/g, "");

/** Python's bytes.lower(): ASCII letters only, so a non-ASCII path keeps its other letters as they are */
const lowerAscii = (text: string): string =>
  /[^\0-\x7f]/.test(text) ? text.replace(/[A-Z]+/g, (letters) => letters.toLowerCase()) : text.toLowerCase();

/** Python's int() on the id column: optional sign, digits (underscores between them), whitespace around */
const parseId = (text: string): number | null => {
  const match = /^\s*([+-]?\d+(?:_\d+)*)\s*$/.exec(text);
  return match?.[1] === undefined ? null : Number(match[1].replaceAll("_", ""));
};

const pad = (value: number): string => String(value).padStart(2, "0");

/** Local time as time.strftime("%Y-%m-%dT%H:%M:%S") writes it */
const formatLocalTime = (date: Date): string =>
  `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;

const describeError = (error: unknown): string =>
  error instanceof Error ? `${error.name}: ${error.message}` : `Error: ${String(error)}`;

export class Listfile {
  readonly path: string;
  private ready: boolean;
  private building: Promise<void> | null = null;
  private failedAt = 0;
  private connection: Database | null = null;
  private lookupQuery: Statement<ListfileRow, [string, string]> | null = null;
  /** Wakes waitReady callers when a build ends, well or not */
  private readonly listeners = new Set<() => void>();
  error: string | null = null;
  /** While it builds: how much of the list has come, and the paths indexed so far */
  progress: { downloadedBytes: number; rows: number } | null = null;

  constructor(cacheDir: string) {
    this.path = join(cacheDir, "listfile.sqlite");
    this.ready = existsSync(this.path);
  }

  /** True once the index exists; starts building it otherwise */
  isReady(): boolean {
    if (this.ready) return true;
    this.startBuild();
    return false;
  }

  /** True once the index exists, without starting a build */
  get isBuilt(): boolean {
    return this.ready;
  }

  /** Waits until the index is ready, the build fails, or timeoutMs passes; true when ready */
  async waitReady(timeoutMs: number): Promise<boolean> {
    if (this.isReady()) return true;
    if (!this.building) return false; // failed a moment ago: no build to wait for until RETRY_SECONDS pass
    await new Promise<void>((resolve) => {
      const done = (): void => {
        clearTimeout(timer);
        this.listeners.delete(done);
        resolve();
      };
      const timer = setTimeout(done, timeoutMs);
      this.listeners.add(done);
    });
    return this.ready;
  }

  /** The meta table's rows (throws when the database cannot be read) */
  getMeta(): ListfileMeta {
    const rows = this.getConnection().query<{ key: string; value: string | number | null }, []>(
      "SELECT key, value FROM meta",
    );
    return Object.fromEntries(rows.all().map((row) => [row.key, row.value]));
  }

  /** Rows whose stem is either of the two (a path as given, and without its extension) */
  lookup(full: string, stem: string): ListfileRow[] {
    this.lookupQuery ??= this.getConnection().query<ListfileRow, [string, string]>(
      "SELECT stem, ext, fdid FROM files WHERE stem IN (?, ?)",
    );
    return this.lookupQuery.all(full, stem);
  }

  /** Lets go of the index's file (before the cache is deleted: an open file cannot be on Windows) */
  close(): void {
    this.lookupQuery?.finalize();
    this.lookupQuery = null;
    this.connection?.close();
    this.connection = null;
  }

  private getConnection(): Database {
    this.connection ??= new Database(this.path, { readonly: true });
    return this.connection;
  }

  private startBuild(): void {
    if (this.ready || this.building) return;
    if (this.error && Date.now() - this.failedAt < RETRY_SECONDS * 1000) return;
    this.building = this.build().finally(() => {
      this.building = null;
      this.progress = null;
      for (const listener of [...this.listeners]) listener();
    });
  }

  private async build(): Promise<void> {
    const temporaryPath = `${this.path}.tmp`;
    const startedAt = Date.now();
    let database: Database | null = null;
    let insert: Statement<void, [string, string, number]> | null = null;
    try {
      await rm(temporaryPath, { force: true });
      database = new Database(temporaryPath, { create: true });
      database.run("PRAGMA journal_mode=OFF");
      database.run("PRAGMA synchronous=OFF");
      database.run("CREATE TABLE files (stem TEXT NOT NULL, ext TEXT NOT NULL, fdid INTEGER NOT NULL)");
      database.run("CREATE TABLE meta (key TEXT PRIMARY KEY, value)");
      // Statements are finalized before the file is closed and moved: an open one keeps the file locked on Windows
      insert = database.prepare<void, [string, string, number]>("INSERT INTO files VALUES (?, ?, ?)");
      const statement = insert;
      const insertBatch = database.transaction((rows: ListfileRow[]) => {
        for (const row of rows) statement.run(row.stem, row.ext, row.fdid);
      });

      let batch: ListfileRow[] = [];
      let rowCount = 0;
      let downloadedBytes = 0;
      let pending = ""; // the start of a line whose end is in the next chunk
      this.progress = { downloadedBytes: 0, rows: 0 };
      const decoder = new TextDecoder("utf-8"); // invalid bytes become U+FFFD, as Python's "replace"
      const addLine = (line: string): void => {
        const separator = line.indexOf(";");
        if (separator < 0) return;
        const path = lowerAscii(stripAscii(line.slice(separator + 1)));
        if (!PREFIXES.some((prefix) => path.startsWith(prefix))) return;
        const fdid = parseId(line.slice(0, separator));
        if (fdid === null) return;
        const [stem, ext] = splitExtension(path);
        batch.push({ stem, ext, fdid });
      };
      const flush = (): void => {
        insertBatch(batch);
        rowCount += batch.length;
        batch = [];
        if (this.progress) this.progress.rows = rowCount;
      };
      await streamUrl(LISTFILE_URL, IDLE_TIMEOUT_MS, (chunk) => {
        downloadedBytes += chunk.length;
        if (this.progress) this.progress.downloadedBytes = downloadedBytes;
        const lines = (pending + decoder.decode(chunk, { stream: true })).split("\n");
        pending = lines.pop() ?? "";
        for (const line of lines) addLine(line);
        if (batch.length >= BATCH_SIZE) flush();
      });
      addLine(pending + decoder.decode());
      flush();
      if (rowCount === 0) throw new Error("listfile contained no interface/ or fonts/ paths");
      insert.finalize();
      insert = null;
      database.run("CREATE INDEX files_stem ON files (stem)");
      const addMeta = (key: string, value: string | number): void => {
        database?.run("INSERT INTO meta VALUES (?, ?)", [key, value]);
      };
      addMeta("source", LISTFILE_URL);
      addMeta("downloadedBytes", downloadedBytes);
      addMeta("rows", rowCount);
      // Stored as REAL even when whole, as Python's round(x, 1) gives a float
      database.run("INSERT INTO meta VALUES (?, CAST(? AS REAL))", [
        "buildSeconds",
        Math.round((Date.now() - startedAt) / 100) / 10,
      ]);
      addMeta("builtAt", formatLocalTime(new Date()));
      database.close(true);
      database = null;
      await rename(temporaryPath, this.path);
      this.error = null;
      this.ready = true;
    } catch (error) {
      // Network, disk or parse failure: tried again after RETRY_SECONDS
      this.error = describeError(error);
      this.failedAt = Date.now();
      insert?.finalize();
      database?.close();
      await rm(temporaryPath, { force: true }).catch(() => undefined);
    }
  }

  /**
   * Writes every path of the index with its file ID, sorted by bytes, one "path<TAB>id" a line: each path both as
   * written ("interface/icons/x.blp") and without its extension (the best file by EXTENSION_RANK), for the
   * simulator's GetFileIDFromPath, which looks a path up by binary search without loading the file. Done again when
   * the index is newer; never starts a download (null when there is no index).
   */
  async exportFileIds(outPath: string): Promise<string | null> {
    if (!existsSync(this.path)) return null;
    const outStat = await stat(outPath).catch(() => null);
    if (outStat && outStat.mtimeMs >= (await stat(this.path)).mtimeMs) return outPath;

    const keys: string[] = [];
    const ids: number[] = [];
    const best = new Map<string, { rank: number; fdid: number }>();
    const connection = new Database(this.path, { readonly: true });
    try {
      const rows = connection.query<ListfileRow, []>("SELECT stem, ext, fdid FROM files").iterate();
      for (const { stem, ext, fdid } of rows) {
        if (ext === "meta") continue;
        keys.push(`${stem}.${ext}`);
        ids.push(fdid);
        const rank = getExtensionRank(ext);
        const current = best.get(stem);
        if (!current || rank < current.rank || (rank === current.rank && fdid < current.fdid)) {
          best.set(stem, { rank, fdid });
        }
      }
    } finally {
      connection.close();
    }
    for (const [stem, entry] of best) {
      keys.push(stem);
      ids.push(entry.fdid);
    }
    await writeFileAtomic(outPath, formatFileIds(keys, ids));
    return outPath;
  }
}

/**
 * The lines sorted by (UTF-8 bytes of the path, id) and without repeated paths (the first, lowest id, stays), as the
 * Python sorted its (bytes, id) tuples. Sorting "path\0" + a fixed-width id with the engine's own string sort gives
 * the same order, as long as no path holds a NUL (which would sort before the separator) or a surrogate pair (UTF-16
 * order differs from UTF-8's there); those rare cases take a slower comparison.
 */
const formatFileIds = (keys: string[], ids: number[]): string => {
  const isPlain = keys.every((key) => !/[\0\uD800-\uDFFF]/.test(key));
  let order: { key: string; fdid: number }[];
  if (isPlain) {
    const sortable = keys.map((key, i) => `${key}\0${String(ids[i] ?? 0).padStart(16, "0")}`);
    sortable.sort();
    order = sortable.map((entry) => {
      const separator = entry.lastIndexOf("\0");
      return { key: entry.slice(0, separator), fdid: Number(entry.slice(separator + 1)) };
    });
  } else {
    const encoder = new TextEncoder();
    const entries = keys.map((key, i) => ({ key, fdid: ids[i] ?? 0, bytes: Buffer.from(encoder.encode(key)) }));
    entries.sort((a, b) => Buffer.compare(a.bytes, b.bytes) || a.fdid - b.fdid);
    order = entries;
  }
  const lines: string[] = [];
  let previous: string | null = null;
  for (const { key, fdid } of order) {
    if (key !== previous && !key.includes("\t") && !key.includes("\n")) lines.push(`${key}\t${fdid}\n`);
    previous = key;
  }
  return lines.join("");
};
