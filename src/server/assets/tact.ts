// The game's files straight from Blizzard's CDN (TACT): their only source (the same bytes wago.tools serves, without
// its rate limit). The game's tables come from wago.tools (their CSV), the listfile of paths from GitHub.
//
// A build is made ready once (prepare), its indexes kept in cache/tact/<build>/:
//   encoding.bin  Blizzard's encoding file, decoded: content key -> encoded key (looked up by its page table)
//   root.bin      fileDataID -> content key, enUS, sorted by id: 20-byte records (id u32 LE, content key)
//   archives.bin  encoded key -> where it lies: 20-byte records (the key's first 10 bytes, archive u16 BE, offset u32
//                 BE, size u32 BE), sorted by key; built from every archive's own index (the archive-group index the
//                 game's client builds is not on the CDN)
//   meta.json     the CDN's hosts and path, the archives, and that the rest is complete (written last)
// After that a file is three lookups on disk and one range request, its MD5 checked against its content key.
// Formats: wowdev.wiki (TACT, BLTE, Encoding, Root, CDN index); reference code: github.com/wowdev/TACTSharp.
import { createHash } from "node:crypto";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, readSync, rmSync } from "node:fs";
import { join } from "node:path";
import { inflateSync } from "node:zlib";
import { NotFoundError, USER_AGENT, WAGO_URL } from "./download.ts";
import { writeFileAtomic } from "./files.ts";

const PATCH_SERVER = "http://us.patch.battle.net:1119";
const LOCALE_EN_US = 0x2;
const NO_NAME_HASHES = 0x10000000;
/** A root block's files for the low-violence regions: a file there and elsewhere is taken from elsewhere */
const LOW_VIOLENCE = 0x80;
const INDEX_DOWNLOADS_AT_ONCE = 16;
const ARCHIVE_KEY_BYTES = 10;
const RECORD_BYTES = 20;
const TIMEOUT_MS = 60_000;
/** meta.json's shape: raised when the files beside it are made differently (they are made again) */
const META_VERSION = 1;
/** After a build could not be made ready (no network, the CDN down), how long its files are not asked of it */
const RETRY_PREPARE_MS = 10 * 60 * 1000;

/** A part of making a build ready, for the setup's view: what it is at, how far */
export type TactProgress = (stage: string, done: number, total: number) => void;

type Meta = { version: number; hosts: string[]; path: string; archives: string[]; buildConfig: string };

const toHex = (bytes: Uint8Array): string =>
  Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString("hex");
const fromHex = (hex: string): Buffer => Buffer.from(hex, "hex");
const md5 = (bytes: Uint8Array): string => createHash("md5").update(bytes).digest("hex");

/** Blizzard's "Name!TYPE:n|..." tables (versions, cdns) as rows of named fields */
const parseTable = (text: string): Record<string, string>[] => {
  const lines = text.split("\n").filter((line) => line.trim() !== "" && !line.startsWith("##"));
  const names = (lines[0] ?? "").split("|").map((field) => field.split("!")[0] ?? "");
  return lines.slice(1).map((line) => Object.fromEntries(line.split("|").map((value, index) => [names[index], value])));
};

/** A config file ("key = value value") as its keys' values */
const parseConfig = (text: string): Record<string, string[]> =>
  Object.fromEntries(
    text
      .split("\n")
      .filter((line) => line.includes(" = "))
      .map((line) => {
        const [key, value] = line.split(" = ");
        return [key?.trim() ?? "", (value ?? "").trim().split(" ")];
      }),
  );

// --- BLTE: the container of every file on the CDN (chunks: N raw, Z zlib, F nested, E encrypted)

const decodeChunk = (chunk: Uint8Array): Uint8Array => {
  const mode = String.fromCharCode(chunk[0] ?? 0);
  const body = chunk.subarray(1);
  if (mode === "N") return body;
  if (mode === "Z") return new Uint8Array(inflateSync(body));
  if (mode === "F") return decodeBlte(body);
  if (mode === "E") throw new Error("the file is encrypted (its key is not known here)");
  throw new Error(`a BLTE chunk of an unknown kind (${mode})`);
};

/** A BLTE file decoded: its chunks, joined */
export const decodeBlte = (bytes: Uint8Array): Uint8Array => {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes[0] !== 0x42 || bytes[1] !== 0x4c || bytes[2] !== 0x54 || bytes[3] !== 0x45) throw new Error("not BLTE");
  const headerSize = view.getUint32(4);
  if (headerSize === 0) return decodeChunk(bytes.subarray(8));
  const chunkCount = ((bytes[9] ?? 0) << 16) | ((bytes[10] ?? 0) << 8) | (bytes[11] ?? 0);
  const parts: Uint8Array[] = [];
  let offset = headerSize;
  for (let index = 0; index < chunkCount; index++) {
    const size = view.getUint32(12 + index * 24);
    parts.push(decodeChunk(bytes.subarray(offset, offset + size)));
    offset += size;
  }
  return parts.length === 1 ? (parts[0] as Uint8Array) : Buffer.concat(parts);
};

// --- sorting millions of 20-byte records by their first bytes without a comparison per pair

/** Records sorted by their first `keyBytes` bytes: a counting sort on the first three, the few ties put in order */
export const sortRecords = (records: Buffer, keyBytes: number): Buffer => {
  const count = records.length / RECORD_BYTES;
  const bucketOf = (index: number): number => {
    const at = index * RECORD_BYTES;
    return ((records[at] ?? 0) << 16) | ((records[at + 1] ?? 0) << 8) | (records[at + 2] ?? 0);
  };
  const starts = new Uint32Array((1 << 24) + 1);
  for (let index = 0; index < count; index++) {
    const bucket = bucketOf(index) + 1;
    starts[bucket] = (starts[bucket] ?? 0) + 1;
  }
  for (let bucket = 1; bucket <= 1 << 24; bucket++) starts[bucket] = (starts[bucket] ?? 0) + (starts[bucket - 1] ?? 0);
  const sorted = Buffer.alloc(records.length);
  const next = starts.slice(0, 1 << 24);
  for (let index = 0; index < count; index++) {
    const bucket = bucketOf(index);
    const to = next[bucket] ?? 0;
    next[bucket] = to + 1;
    records.copy(sorted, to * RECORD_BYTES, index * RECORD_BYTES, (index + 1) * RECORD_BYTES);
  }
  // (records sharing their first three bytes: few, and next to each other; put in order by the rest of the key)
  const swap = Buffer.alloc(RECORD_BYTES);
  for (let bucket = 0; bucket < 1 << 24; bucket++) {
    const from = starts[bucket] ?? 0;
    const to = starts[bucket + 1] ?? 0;
    for (let index = from + 1; index < to; index++) {
      for (let at = index; at > from; at--) {
        const left = (at - 1) * RECORD_BYTES;
        const right = at * RECORD_BYTES;
        // (in order already when the left one's key is at or below the right one's)
        if (sorted.compare(sorted, right + 3, right + keyBytes, left + 3, left + keyBytes) <= 0) break;
        sorted.copy(swap, 0, left, left + RECORD_BYTES);
        sorted.copy(sorted, left, right, right + RECORD_BYTES);
        swap.copy(sorted, right);
      }
    }
  }
  return sorted;
};

/**
 * Binary search in a file of sorted 20-byte records: the one compareAt says is it (0), or null; compareAt gives the
 * record's order against what is looked for (below 0: the record comes first)
 */
const findRecord = (fd: number, recordCount: number, compareAt: (record: Buffer) => number): Buffer | null => {
  const record = Buffer.alloc(RECORD_BYTES);
  let low = 0;
  let high = recordCount - 1;
  while (low <= high) {
    const middle = (low + high) >>> 1;
    readSync(fd, record, 0, RECORD_BYTES, middle * RECORD_BYTES);
    const order = compareAt(record);
    if (order === 0) return record;
    if (order < 0) low = middle + 1;
    else high = middle - 1;
  }
  return null;
};

/** One build's files from Blizzard's CDN */
export class TactStore {
  #meta: Meta | null = null;
  #preparing: Promise<void> | null = null;
  /** The last failure to make the build ready, and when: until RETRY_PREPARE_MS pass, files fail at once */
  #failed: { at: number; error: Error } | null = null;
  #encoding: { fd: number; pageSize: number; pageCount: number; pagesStart: number; table: Buffer } | null = null;
  #root: { fd: number; count: number } | null = null;
  #archives: { fd: number; count: number } | null = null;

  constructor(
    readonly folder: string,
    readonly build: string,
    readonly product: string,
  ) {}

  /** Whether the build was made ready before (its indexes are on disk) */
  get isReady(): boolean {
    return this.#meta !== null || this.#readMeta() !== null;
  }

  #readMeta(): Meta | null {
    try {
      const meta = JSON.parse(readFileSync(join(this.folder, "meta.json"), "utf8")) as Meta;
      return meta.version === META_VERSION ? meta : null;
    } catch {
      return null;
    }
  }

  /** The build made ready: its indexes fetched and built once (a few hundred MB), then only opened */
  prepare(onProgress?: TactProgress): Promise<void> {
    const failed = this.#failed;
    if (failed && Date.now() - failed.at < RETRY_PREPARE_MS) return Promise.reject(failed.error);
    this.#preparing ??= this.#prepare(onProgress).then(
      () => {
        this.#failed = null;
      },
      (error: unknown) => {
        this.#preparing = null;
        this.#failed = { at: Date.now(), error: error instanceof Error ? error : new Error(String(error)) };
        throw this.#failed.error;
      },
    );
    return this.#preparing;
  }

  async #fetch(url: string, range?: [number, number]): Promise<Buffer> {
    const headers: Record<string, string> = { "User-Agent": USER_AGENT };
    if (range) headers.Range = `bytes=${range[0]}-${range[1]}`;
    const response = await fetch(url, { headers, signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (response.status === 404) throw new NotFoundError(url);
    if (!response.ok) throw new Error(`HTTP ${response.status} for ${url}`);
    return Buffer.from(await response.arrayBuffer());
  }

  /** A file of the CDN ("config" or "data"), from the first of its hosts that has it */
  async #fetchCdn(kind: "config" | "data", key: string, suffix = "", range?: [number, number]): Promise<Buffer> {
    const meta = this.#meta;
    if (!meta) throw new Error("the build is not ready");
    let lastError: unknown = null;
    for (const host of meta.hosts) {
      try {
        return await this.#fetch(
          `http://${host}/${meta.path}/${kind}/${key.slice(0, 2)}/${key.slice(2, 4)}/${key}${suffix}`,
          range,
        );
      } catch (error) {
        if (error instanceof NotFoundError) throw error;
        lastError = error;
      }
    }
    throw lastError instanceof Error ? lastError : new Error(String(lastError));
  }

  async #prepare(onProgress?: TactProgress): Promise<void> {
    const kept = this.#readMeta();
    if (kept && ["encoding.bin", "root.bin", "archives.bin"].every((name) => existsSync(join(this.folder, name)))) {
      this.#meta = kept;
      this.#open();
      return;
    }
    mkdirSync(this.folder, { recursive: true });
    onProgress?.("the build's configs", 0, 1);
    // The build's configs: from the patch server when a region runs it, else from wago.tools' list of builds
    const versions = parseTable(await (await this.#fetch(`${PATCH_SERVER}/${this.product}/versions`)).toString("utf8"));
    const cdns = parseTable(await (await this.#fetch(`${PATCH_SERVER}/${this.product}/cdns`)).toString("utf8"));
    let buildConfig = versions.find((row) => row.VersionsName === this.build)?.BuildConfig ?? "";
    let cdnConfig = versions.find((row) => row.VersionsName === this.build)?.CDNConfig ?? "";
    if (!buildConfig) {
      const all = JSON.parse((await this.#fetch(`${WAGO_URL}/api/builds`)).toString("utf8")) as Record<
        string,
        { version?: string; build_config?: string; cdn_config?: string }[]
      >;
      const listed = (all[this.product] ?? []).find((entry) => entry.version === this.build);
      buildConfig = listed?.build_config ?? "";
      cdnConfig = listed?.cdn_config ?? "";
    }
    if (!buildConfig || !cdnConfig) throw new Error(`Blizzard's CDN does not know the build ${this.build}`);
    const hosts = [...new Set(cdns.flatMap((row) => (row.Hosts ?? "").split(" ").filter(Boolean)))];
    const path = cdns[0]?.Path ?? "tpr/wow";
    this.#meta = { version: META_VERSION, hosts, path, archives: [], buildConfig };
    const build = parseConfig((await this.#fetchCdn("config", buildConfig)).toString("utf8"));
    const cdn = parseConfig((await this.#fetchCdn("config", cdnConfig)).toString("utf8"));
    const archives = cdn.archives ?? [];
    this.#meta.archives = archives;
    onProgress?.("the build's configs", 1, 1);

    // The encoding file, whole, decoded (content key -> encoded key)
    const encodingPath = join(this.folder, "encoding.bin");
    onProgress?.("the encoding file (~140 MB)", 0, 1);
    await writeFileAtomic(encodingPath, decodeBlte(await this.#fetchCdn("data", build.encoding?.[1] ?? "")));
    onProgress?.("the encoding file (~140 MB)", 1, 1);
    this.#openEncoding();

    // The root: fileDataID -> content key (enUS), sorted by id
    onProgress?.("the root (~40 MB)", 0, 1);
    const rootEncodedKey = this.#findEncodedKey(build.root?.[0] ?? "");
    if (!rootEncodedKey) throw new Error("the root is not in the encoding file");
    await writeFileAtomic(
      join(this.folder, "root.bin"),
      readRoot(decodeBlte(await this.#fetchCdn("data", rootEncodedKey))),
    );
    onProgress?.("the root (~40 MB)", 1, 1);

    // Every archive's index, into one sorted table (encoded key -> archive, offset, size)
    const parts: Buffer[] = new Array(archives.length);
    let done = 0;
    let next = 0;
    onProgress?.("the archives' indexes", 0, archives.length);
    await Promise.all(
      Array.from({ length: INDEX_DOWNLOADS_AT_ONCE }, async () => {
        while (next < archives.length) {
          const archive = next++;
          parts[archive] = readArchiveIndex(await this.#fetchCdn("data", archives[archive] ?? "", ".index"), archive);
          done++;
          onProgress?.("the archives' indexes", done, archives.length);
        }
      }),
    );
    onProgress?.("sorting the archives' indexes", 0, 1);
    await writeFileAtomic(join(this.folder, "archives.bin"), sortRecords(Buffer.concat(parts), ARCHIVE_KEY_BYTES));
    await writeFileAtomic(join(this.folder, "meta.json"), JSON.stringify(this.#meta));
    onProgress?.("sorting the archives' indexes", 1, 1);
    this.#open();
  }

  #openEncoding(): void {
    if (this.#encoding) closeSync(this.#encoding.fd);
    const fd = openSync(join(this.folder, "encoding.bin"), "r");
    const head = Buffer.alloc(22);
    readSync(fd, head, 0, 22, 0);
    const pageSize = head.readUInt16BE(5) * 1024;
    const pageCount = head.readUInt32BE(9);
    const tableStart = 22 + head.readUInt32BE(18);
    const table = Buffer.alloc(pageCount * 32);
    readSync(fd, table, 0, table.length, tableStart);
    this.#encoding = { fd, pageSize, pageCount, pagesStart: tableStart + table.length, table };
  }

  #open(): void {
    this.#openEncoding();
    for (const name of ["root", "archives"] as const) {
      const path = join(this.folder, `${name}.bin`);
      const fd = openSync(path, "r");
      const size = Bun.file(path).size;
      const opened = { fd, count: Math.floor(size / RECORD_BYTES) };
      if (name === "root") this.#root = opened;
      else this.#archives = opened;
    }
  }

  /** A content key's encoded key: the page whose first key is the last at or below it, scanned */
  #findEncodedKey(contentKeyHex: string): string | null {
    const encoding = this.#encoding;
    if (!encoding || !contentKeyHex) return null;
    const contentKey = fromHex(contentKeyHex);
    let low = 0;
    let high = encoding.pageCount - 1;
    while (low < high) {
      const middle = Math.ceil((low + high) / 2);
      if (encoding.table.compare(contentKey, 0, 16, middle * 32, middle * 32 + 16) <= 0) low = middle;
      else high = middle - 1;
    }
    const page = Buffer.alloc(encoding.pageSize);
    readSync(encoding.fd, page, 0, page.length, encoding.pagesStart + low * encoding.pageSize);
    for (let at = 0; at + 22 <= page.length; ) {
      const keyCount = page[at] ?? 0;
      if (keyCount === 0) break;
      if (page.compare(contentKey, 0, 16, at + 6, at + 22) === 0) return toHex(page.subarray(at + 22, at + 38));
      at += 22 + keyCount * 16;
    }
    return null;
  }

  /** A file by its fileDataID: its bytes (MD5-checked); NotFoundError when the build has no such file */
  async get(fileDataId: number): Promise<Uint8Array> {
    await this.prepare();
    const root = this.#root;
    const archives = this.#archives;
    const meta = this.#meta;
    if (!root || !archives || !meta) throw new Error("the build is not ready");
    const rootRecord = findRecord(root.fd, root.count, (record) => record.readUInt32LE(0) - fileDataId);
    if (!rootRecord) throw new NotFoundError(`fileDataID ${fileDataId}`);
    const contentKey = toHex(rootRecord.subarray(4, 20));
    const encodedKey = this.#findEncodedKey(contentKey);
    if (!encodedKey) throw new NotFoundError(`fileDataID ${fileDataId} (content key ${contentKey})`);
    const wanted = fromHex(encodedKey).subarray(0, ARCHIVE_KEY_BYTES);
    const location = findRecord(archives.fd, archives.count, (record) =>
      record.compare(wanted, 0, ARCHIVE_KEY_BYTES, 0, ARCHIVE_KEY_BYTES),
    );
    let encoded: Buffer;
    if (location) {
      const archive = meta.archives[location.readUInt16BE(10)] ?? "";
      const offset = location.readUInt32BE(12);
      const size = location.readUInt32BE(16);
      encoded = await this.#fetchCdn("data", archive, "", [offset, offset + size - 1]);
    } else {
      // (not in an archive: a loose file, by its encoded key)
      encoded = await this.#fetchCdn("data", encodedKey);
    }
    const file = decodeBlte(encoded);
    if (md5(file) !== contentKey) throw new Error(`fileDataID ${fileDataId} came damaged (its MD5 is not its key)`);
    return file;
  }

  /** The files it keeps open let go (before the cache is deleted) */
  close(): void {
    for (const opened of [this.#encoding, this.#root, this.#archives]) if (opened) closeSync(opened.fd);
    this.#encoding = null;
    this.#root = null;
    this.#archives = null;
    this.#preparing = null;
  }

  /** Its indexes deleted (made again at the next use) */
  forget(): void {
    this.close();
    rmSync(this.folder, { recursive: true, force: true });
    this.#meta = null;
  }
}

/**
 * An MFST root: every enUS file's fileDataID and content key, as 20-byte records sorted by id; of an id listed more
 * than once, the one not for the low-violence regions (as wago.tools and the game in other regions take it), else
 * the first
 */
export const readRoot = (root: Uint8Array): Buffer => {
  const view = new DataView(root.buffer, root.byteOffset, root.byteLength);
  if (root[0] !== 0x54 || root[1] !== 0x53 || root[2] !== 0x46 || root[3] !== 0x4d) throw new Error("not an MFST root");
  // (newer roots: a header size and a version after the magic; older ones: the counts straight away)
  let at = 12;
  let version = 0;
  if (view.getUint32(4, true) === 24) {
    version = view.getUint32(8, true);
    at = 24;
  }
  const ids: number[] = [];
  const keyAt: number[] = [];
  const isLowViolence: boolean[] = [];
  while (at + 12 <= root.length) {
    const count = view.getUint32(at, true);
    let contentFlags: number;
    let localeFlags: number;
    if (version >= 2) {
      localeFlags = view.getUint32(at + 4, true);
      contentFlags = view.getUint32(at + 8, true) | view.getUint32(at + 12, true) | ((root[at + 16] ?? 0) << 17);
      at += 17;
    } else {
      contentFlags = view.getUint32(at + 4, true);
      localeFlags = view.getUint32(at + 8, true);
      at += 12;
    }
    const idsAt = at;
    const keysAt = idsAt + count * 4;
    at = keysAt + count * 16 + ((contentFlags & NO_NAME_HASHES) === 0 ? count * 8 : 0);
    if ((localeFlags & LOCALE_EN_US) === 0) continue;
    let id = -1;
    const isBlockLowViolence = (contentFlags & LOW_VIOLENCE) !== 0;
    for (let index = 0; index < count; index++) {
      id += 1 + view.getInt32(idsAt + index * 4, true);
      ids.push(id);
      keyAt.push(keysAt + index * 16);
      isLowViolence.push(isBlockLowViolence);
    }
  }
  // Sorted by id; of one id, the one not for low violence first, then the root's order; the first kept
  const order = new Uint32Array(ids.length);
  for (let index = 0; index < ids.length; index++) order[index] = index;
  order.sort(
    (a, b) =>
      (ids[a] ?? 0) - (ids[b] ?? 0) || Number(isLowViolence[a] ?? false) - Number(isLowViolence[b] ?? false) || a - b,
  );
  const source = Buffer.from(root.buffer, root.byteOffset, root.byteLength);
  const records = Buffer.alloc(ids.length * RECORD_BYTES);
  let written = 0;
  let lastId = -1;
  for (const index of order) {
    const id = ids[index] ?? 0;
    if (id === lastId) continue;
    lastId = id;
    records.writeUInt32LE(id, written * RECORD_BYTES);
    const from = keyAt[index] ?? 0;
    source.copy(records, written * RECORD_BYTES + 4, from, from + 16);
    written++;
  }
  return records.subarray(0, written * RECORD_BYTES);
};

/** An archive's index (the CDN's .index): its entries as 20-byte records (key's first 10 bytes, archive, offset, size) */
export const readArchiveIndex = (bytes: Uint8Array, archive: number): Buffer => {
  const footerAt = bytes.length - 28;
  const blockSize = (bytes[footerAt + 11] ?? 4) * 1024;
  const offsetBytes = bytes[footerAt + 12] ?? 4;
  const sizeBytes = bytes[footerAt + 13] ?? 4;
  const keyBytes = bytes[footerAt + 14] ?? 16;
  const checksumBytes = bytes[footerAt + 15] ?? 8;
  const entryBytes = keyBytes + sizeBytes + offsetBytes;
  const blockCount = Math.floor(footerAt / (blockSize + keyBytes + checksumBytes));
  const source = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const records = Buffer.alloc(Math.floor((blockCount * blockSize) / entryBytes) * RECORD_BYTES);
  let written = 0;
  for (let block = 0; block < blockCount; block++) {
    for (let at = block * blockSize; at + entryBytes <= (block + 1) * blockSize; at += entryBytes) {
      if (source[at] === 0 && source[at + 1] === 0 && source[at + 2] === 0 && source[at + 3] === 0) break;
      const out = written * RECORD_BYTES;
      source.copy(records, out, at, at + ARCHIVE_KEY_BYTES);
      records.writeUInt16BE(archive, out + 10);
      // (an entry: the key, its size, its offset in the archive, each big-endian; the offset's last 4 bytes)
      records.writeUInt32BE(source.readUInt32BE(at + keyBytes + sizeBytes + offsetBytes - 4), out + 12);
      records.writeUInt32BE(source.readUIntBE(at + keyBytes, Math.min(sizeBytes, 6)), out + 16);
      written++;
    }
  }
  return records.subarray(0, written * RECORD_BYTES);
};
