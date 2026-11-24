import { describe, expect, test } from "bun:test";
import { deflateSync } from "node:zlib";
import { decodeBlte, readArchiveIndex, readRoot, sortRecords } from "./tact.ts";

/** A BLTE file of the chunks given (each its mode byte and body) */
const makeBlte = (chunks: Uint8Array[]): Buffer => {
  const headerSize = 12 + chunks.length * 24;
  const header = Buffer.alloc(headerSize);
  header.write("BLTE", 0, "latin1");
  header.writeUInt32BE(headerSize, 4);
  header[8] = 0x0f;
  header.writeUIntBE(chunks.length, 9, 3);
  chunks.forEach((chunk, index) => {
    header.writeUInt32BE(chunk.length, 12 + index * 24);
  });
  return Buffer.concat([header, ...chunks]);
};

describe("decodeBlte", () => {
  test("joins raw and zlib chunks", () => {
    const raw = Buffer.concat([Buffer.from("N"), Buffer.from("hello ")]);
    const zipped = Buffer.concat([Buffer.from("Z"), deflateSync(Buffer.from("world"))]);
    expect(Buffer.from(decodeBlte(makeBlte([raw, zipped]))).toString()).toBe("hello world");
  });

  test("an encrypted chunk is refused", () => {
    expect(() => decodeBlte(makeBlte([Buffer.from("Esecret")]))).toThrow("encrypted");
  });
});

/** An MFST root (version 2) of blocks: their locale and content flags, and their files' ids and keys */
const makeRoot = (blocks: { locale: number; content: number; files: [number, number][] }[]): Buffer => {
  const parts: Buffer[] = [];
  const head = Buffer.alloc(24);
  head.write("TSFM", 0, "latin1");
  head.writeUInt32LE(24, 4);
  head.writeUInt32LE(2, 8);
  parts.push(head);
  for (const block of blocks) {
    const meta = Buffer.alloc(17);
    meta.writeUInt32LE(block.files.length, 0);
    meta.writeUInt32LE(block.locale, 4);
    meta.writeUInt32LE(block.content, 8);
    parts.push(meta);
    const ids = Buffer.alloc(block.files.length * 4);
    let previous = -1;
    block.files.forEach(([id], index) => {
      ids.writeInt32LE(id - previous - 1, index * 4);
      previous = id;
    });
    parts.push(
      ids,
      Buffer.concat(block.files.map(([, key]) => Buffer.alloc(16, key))),
      Buffer.alloc(block.files.length * 8),
    );
  }
  return Buffer.concat(parts);
};

describe("readRoot", () => {
  test("enUS files by id; of one listed twice, the one not for low violence", () => {
    const records = readRoot(
      makeRoot([
        { locale: 0x2, content: 0x80, files: [[5, 0xaa]] },
        {
          locale: 0x2,
          content: 0,
          files: [
            [3, 0x33],
            [5, 0x55],
          ],
        },
        { locale: 0x4, content: 0, files: [[4, 0x44]] },
      ]),
    );
    expect(records.length / 20).toBe(2);
    expect(records.readUInt32LE(0)).toBe(3);
    expect(records[4]).toBe(0x33);
    expect(records.readUInt32LE(20)).toBe(5);
    expect(records[24]).toBe(0x55);
  });
});

describe("readArchiveIndex", () => {
  test("its entries as records: the key's start, the archive, the offset, the size", () => {
    const block = Buffer.alloc(4096);
    const key = Buffer.alloc(16, 0x7e);
    key.copy(block, 0);
    block.writeUInt32BE(1234, 16);
    block.writeUInt32BE(98765, 20);
    const toc = Buffer.alloc(16 + 8);
    const footer = Buffer.alloc(28);
    footer[11] = 4;
    footer[12] = 4;
    footer[13] = 4;
    footer[14] = 16;
    footer[15] = 8;
    footer.writeUInt32LE(1, 16);
    const records = readArchiveIndex(Buffer.concat([block, toc, footer]), 7);
    expect(records.length).toBe(20);
    expect(records.subarray(0, 10).equals(key.subarray(0, 10))).toBe(true);
    expect(records.readUInt16BE(10)).toBe(7);
    expect(records.readUInt32BE(12)).toBe(98765);
    expect(records.readUInt32BE(16)).toBe(1234);
  });
});

describe("sortRecords", () => {
  test("orders by the key, ties on the first three bytes too", () => {
    const keys = ["0a0b0c09", "0a0b0c01", "00ffffff", "0a0b0c05", "ff000000"];
    const records = Buffer.concat(
      keys.map((hex, index) => {
        const record = Buffer.alloc(20);
        Buffer.from(hex, "hex").copy(record);
        record.writeUInt16BE(index, 10);
        return record;
      }),
    );
    const sorted = sortRecords(records, 10);
    const order = Array.from({ length: keys.length }, (_, index) =>
      sorted.subarray(index * 20, index * 20 + 4).toString("hex"),
    );
    expect(order).toEqual(["00ffffff", "0a0b0c01", "0a0b0c05", "0a0b0c09", "ff000000"]);
  });
});
