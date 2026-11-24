// One fetch per file however many requests want it, and a pause before trying a failed one again.

export const RETRY_SECONDS = 120;

/** Concurrent calls for the same key share one run of the task (one download or conversion of a file at a time) */
export class SingleFlight {
  private readonly running = new Map<string, Promise<unknown>>();

  run<T>(key: string, task: () => Promise<T>): Promise<T> {
    const current = this.running.get(key);
    if (current) return current as Promise<T>;
    const started = task().finally(() => this.running.delete(key));
    this.running.set(key, started);
    return started;
  }
}

/** Remembers what failed (network, a bad file) so it is not asked for again until RETRY_SECONDS have passed */
export class FailureMemory {
  private readonly failedAt = new Map<string, number>();

  hasRecent(key: string): boolean {
    const at = this.failedAt.get(key);
    return at !== undefined && Date.now() - at < RETRY_SECONDS * 1000;
  }

  add(key: string): void {
    this.failedAt.set(key, Date.now());
  }
}
