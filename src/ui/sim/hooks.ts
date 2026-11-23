// The store in React: a part of the state chosen by a selector, drawn again only when that part changes; and the
// changes started from buttons, with their pending and problem states
import { useCallback, useRef, useState, useSyncExternalStore } from "react";
import { api, type GameAction } from "./api.ts";
import { shallowEqual } from "./equality.ts";
import { getSnapshot, refreshState, type StoreSnapshot, subscribe } from "./store.ts";
import type { GameAnswer, SimState } from "./types.ts";

type Cached<T> = { source: unknown; select: unknown; value: T };

/** A part of the snapshot; equal parts (shallowly, by default) keep the value from before */
const useSelected = <T>(
  read: (snapshot: StoreSnapshot) => T,
  isEqual: (first: T, second: T) => boolean = shallowEqual,
): T => {
  const cache = useRef<Cached<T> | null>(null);
  const getValue = (): T => {
    const current = getSnapshot();
    const kept = cache.current;
    if (kept && kept.source === current && kept.select === read) return kept.value;
    const value = read(current);
    if (kept && isEqual(kept.value, value)) {
      cache.current = { source: current, select: read, value: kept.value };
      return kept.value;
    }
    cache.current = { source: current, select: read, value };
    return value;
  };
  return useSyncExternalStore(subscribe, getValue, getValue);
};

/** A part of the simulator's state (the fallback until the first state has come) */
export const useSimState = <T>(
  select: (state: SimState) => T,
  fallback: T,
  isEqual?: (first: T, second: T) => boolean,
): T => useSelected((snapshot) => (snapshot.state ? select(snapshot.state) : fallback), isEqual);

export const useStoreStatus = (): Pick<StoreSnapshot, "problem" | "isOffline"> & { hasState: boolean } =>
  useSelected((snapshot) => ({
    problem: snapshot.problem,
    isOffline: snapshot.isOffline,
    hasState: snapshot.state !== null,
  }));

export const useEventHistory = (): StoreSnapshot["history"] => useSelected((snapshot) => snapshot.history, Object.is);

export type Task<A extends unknown[], R> = {
  run: (...args: A) => Promise<R | null>;
  isPending: boolean;
  problem: string | null;
  clearProblem: () => void;
};

const messageOf = (error: unknown): string => (error instanceof Error ? error.message : String(error));

/**
 * Any call to the server from a button: pending while it runs, its problem kept (an answer's `problem` or `error`,
 * or a failed request), the state read again after it
 */
export const useTask = <A extends unknown[], R>(call: (...args: A) => Promise<R>): Task<A, R> => {
  const [isPending, setPending] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const callRef = useRef(call);
  callRef.current = call;
  const run = useCallback(async (...args: A): Promise<R | null> => {
    setPending(true);
    setProblem(null);
    try {
      const answer = await callRef.current(...args);
      const reported =
        answer && typeof answer === "object"
          ? ((answer as { problem?: unknown; error?: unknown }).problem ?? (answer as { error?: unknown }).error)
          : undefined;
      if (typeof reported === "string" && reported) setProblem(reported);
      return answer;
    } catch (error) {
      setProblem(messageOf(error));
      return null;
    } finally {
      setPending(false);
      void refreshState();
    }
  }, []);
  const clearProblem = useCallback(() => setProblem(null), []);
  return { run, isPending, problem, clearProblem };
};

/** A change to the game (one of lua/boot.lua's game actions) */
export const useGameAction = (): Task<[GameAction], GameAnswer> => useTask((action: GameAction) => api.game(action));
