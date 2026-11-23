// The setup's download of a flavour's interface source: GitHub's archive of its branch (a gzipped tar, ~10 MB),
// unpacked into the data folder (interface/<flavour>/Interface). Only when the user asks (the setup's button); one at a
// time; its progress is read by GET /api/setup.
import { existsSync, mkdirSync, readdirSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import type { InterfaceDownload } from "../../shared/setup.ts";
import { USER_AGENT } from "../assets/download.ts";
import { type Flavour, interfaceArchiveUrl } from "../flavours/index.ts";
import { downloadedInterfaceRoot, interfaceDownloadDir } from "../paths.ts";

const IDLE_TIMEOUT_MS = 60_000;

const messageOf = (error: unknown): string => (error instanceof Error ? error.message : String(error));

export class InterfaceDownloader {
  status: InterfaceDownload = { state: "idle", receivedBytes: 0 };
  #running: Promise<void> | null = null;

  /** Starts the download (unless one runs); onDone is called once the source is in place */
  start(flavour: Flavour, onDone: (interfaceRoot: string) => void): void {
    if (this.#running) return;
    this.status = { state: "downloading", receivedBytes: 0 };
    this.#running = this.#download(flavour)
      .then((root) => {
        this.status = { ...this.status, state: "done", path: root };
        onDone(root);
      })
      .catch((error: unknown) => {
        this.status = { ...this.status, state: "failed", error: messageOf(error) };
      })
      .finally(() => {
        this.#running = null;
      });
  }

  async #download(flavour: Flavour): Promise<string> {
    const url = interfaceArchiveUrl(flavour);
    const controller = new AbortController();
    let timer = setTimeout(() => controller.abort(new Error("the download stopped")), IDLE_TIMEOUT_MS);
    const chunks: Uint8Array[] = [];
    try {
      const response = await fetch(url, { headers: { "User-Agent": USER_AGENT }, signal: controller.signal });
      if (!response.ok) throw new Error(`GitHub answered ${response.status} ${response.statusText} for ${url}`);
      const length = Number(response.headers.get("Content-Length"));
      if (length > 0) this.status.totalBytes = length;
      if (response.body) {
        for await (const chunk of response.body) {
          clearTimeout(timer);
          timer = setTimeout(() => controller.abort(new Error("the download stopped")), IDLE_TIMEOUT_MS);
          chunks.push(chunk);
          this.status.receivedBytes += chunk.byteLength;
        }
      }
    } finally {
      clearTimeout(timer);
    }
    this.status.state = "unpacking";
    const target = interfaceDownloadDir(flavour.id);
    // Unpacked beside the old one and moved over it: a failed unpack leaves the old source as it was
    const unpacking = `${target}.unpacking`;
    rmSync(unpacking, { recursive: true, force: true });
    mkdirSync(unpacking, { recursive: true });
    await new Bun.Archive(new Blob(chunks as BlobPart[])).extract(unpacking);
    // The archive holds one folder, "<repository>-<branch>", with Interface/ inside
    const top = readdirSync(unpacking).find((name) => existsSync(join(unpacking, name, "Interface")));
    if (!top) {
      rmSync(unpacking, { recursive: true, force: true });
      throw new Error("the archive has no Interface folder");
    }
    rmSync(target, { recursive: true, force: true });
    renameSync(join(unpacking, top), target);
    rmSync(unpacking, { recursive: true, force: true });
    return downloadedInterfaceRoot(flavour.id);
  }
}
