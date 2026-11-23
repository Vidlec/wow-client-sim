// Cache files: written whole or not at all, since the Python server may read the same cache at the same time.
import { randomBytes } from "node:crypto";
import { readFile, rename, rm, writeFile } from "node:fs/promises";

/** Write to a temporary file beside path, then move it over path */
export const writeFileAtomic = async (path: string, data: Uint8Array | string): Promise<void> => {
  const temporaryPath = `${path}.${process.pid}-${randomBytes(4).toString("hex")}.tmp`;
  try {
    await writeFile(temporaryPath, data);
    await rename(temporaryPath, path);
  } catch (error) {
    await rm(temporaryPath, { force: true });
    throw error;
  }
};

const isMissingFileError = (error: unknown): boolean =>
  error instanceof Error && "code" in error && (error.code === "ENOENT" || error.code === "ENOTDIR");

/** A file's bytes, or null when there is no such file */
export const readIfExists = async (path: string): Promise<Uint8Array | null> => {
  try {
    const data = await readFile(path);
    return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  } catch (error) {
    if (isMissingFileError(error)) return null;
    throw error;
  }
};
