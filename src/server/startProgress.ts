// The simulator's start, part by part, for the setup to show while it runs (the first start fetches the game's file
// list, its tables and wowless's data, which takes minutes) and the settings to show afterwards. Each part is told
// when it begins, how far it got and how it ended; the file list builds in the background and is read as it stands.
import type { StartProgress, StartStep } from "../shared/setup.ts";
import { isRateLimited } from "./assets/download.ts";

type StepId = StartStep["id"];

const LABELS: Record<StepId, string> = {
  native: "AddonSim's native core",
  blizzard: "Blizzard's file indexes (once a build)",
  listfile: "The game's file list (GitHub)",
  wowless: "The client's API data (wowless)",
  tables: "The game's tables (DB2)",
  atlases: "The interface's atlases",
  highlights: "The map's highlights",
  boot: "The game booting",
};
const ORDER: readonly StepId[] = [
  "native",
  "blizzard",
  "listfile",
  "wowless",
  "tables",
  "atlases",
  "highlights",
  "boot",
];

/** How the background file list stands, read at each look (null: not known, the step as it was told) */
export type ListfileLook = () => Pick<StartStep, "state" | "detail"> | null;

/** What a part of the start tells (src/server/runtimeConfig.ts takes one, optionally) */
export type StartReporter = {
  begin: (id: StepId, detail?: string) => void;
  count: (id: StepId, done: number, total: number, detail?: string) => void;
  finish: (id: StepId, detail?: string) => void;
  fail: (id: StepId, detail: string) => void;
};

export class StartTracker implements StartReporter {
  #startedAt: Date | null = null;
  #steps = new Map<StepId, StartStep & { beganAt?: number; endedAt?: number }>();
  /** Parts that fetch from wago.tools (the game's tables, and the atlases read from them): only these say so while it
   * asks to slow down */
  readonly #fromWago = new Set<StepId>(["tables", "atlases"]);
  readonly #lookAtListfile: ListfileLook;

  constructor(lookAtListfile: ListfileLook) {
    this.#lookAtListfile = lookAtListfile;
  }

  /** No start yet (after a reset) */
  clear(): void {
    this.#startedAt = null;
    this.#steps = new Map();
  }

  /** A new start: every part waiting again */
  reset(): void {
    this.#startedAt = new Date();
    this.#steps = new Map(ORDER.map((id) => [id, { id, label: LABELS[id], state: "waiting" }]));
  }

  #update(id: StepId, change: Partial<StartStep>, now = performance.now()): void {
    if (!this.#startedAt) this.reset();
    const step = this.#steps.get(id);
    if (!step) return;
    if (change.state === "running" && step.state !== "running") step.beganAt = now;
    if (change.state === "done" || change.state === "failed") {
      step.beganAt ??= now;
      step.endedAt = now;
    }
    Object.assign(step, change);
  }

  begin(id: StepId, detail?: string): void {
    this.#update(id, { state: "running", detail, done: undefined, total: undefined });
  }

  count(id: StepId, done: number, total: number, detail?: string): void {
    this.#update(id, { state: "running", done, total, detail });
  }

  finish(id: StepId, detail?: string): void {
    this.#update(id, { state: "done", detail });
  }

  fail(id: StepId, detail: string): void {
    this.#update(id, { state: "failed", detail });
  }

  /** The start as it stands; null before the first */
  read(): StartProgress | null {
    if (!this.#startedAt) return null;
    const now = performance.now();
    const steps = ORDER.map((id): StartStep => {
      const stored = this.#steps.get(id) as StartStep & { beganAt?: number; endedAt?: number };
      const listfile = id === "listfile" ? this.#lookAtListfile() : null;
      // (the file list ends in the background: its end is when it is first seen ended)
      if (listfile && (listfile.state === "done" || listfile.state === "failed") && stored.endedAt === undefined) {
        stored.endedAt = now;
      }
      const { beganAt, endedAt, ...step } = stored;
      const shown = listfile ? { ...step, ...listfile } : step;
      if (beganAt !== undefined) shown.seconds = Math.round(((endedAt ?? now) - beganAt) / 100) / 10;
      // (a part fetching from wago.tools while it asks for less: said, so a slow start does not look stuck)
      if (shown.state === "running" && this.#fromWago.has(id) && isRateLimited()) {
        shown.detail = `${shown.detail ? `${shown.detail} · ` : ""}wago.tools asked to slow down, waiting`;
      }
      return shown;
    });
    return { startedAt: this.#startedAt.toISOString(), steps };
  }
}
