// The simulator's state for the whole page: one poller of /api/state (twice a second while the tab is shown, at once
// after each change), its parts kept as the same objects while they do not change (equality.ts), and the events
// gathered into a longer history than the state's last sixty.
import { api } from "./api.ts";
import { replaceEqualDeep } from "./equality.ts";
import type { SimEvent, SimState, StateProblem } from "./types.ts";

const POLL_MS = 500;
const HIDDEN_POLL_MS = 5000; // (a hidden tab still notices the server going away, slowly)
const HISTORY_LIMIT = 5000;

export type StoreSnapshot = {
  state: SimState | null;
  /** The server's answer when there is no state: the simulator down, or the first setup needed */
  problem: StateProblem | null;
  /** The server did not answer at all */
  isOffline: boolean;
  /** Every event seen since the page opened (or the last reload), oldest first */
  history: readonly SimEvent[];
};

type Listener = () => void;

let snapshot: StoreSnapshot = { state: null, problem: null, isOffline: false, history: [] };
const listeners = new Set<Listener>();

const publish = (next: StoreSnapshot): void => {
  snapshot = next;
  for (const listener of listeners) listener();
};

const sameEvent = (first: SimEvent | undefined, second: SimEvent | undefined): boolean =>
  first !== undefined &&
  second !== undefined &&
  first.time === second.time &&
  first.event === second.event &&
  first.args.join("\u0001") === second.args.join("\u0001");

/** The state's last events added to the history: those after the newest the history already has */
const mergeEvents = (history: readonly SimEvent[], latest: readonly SimEvent[]): readonly SimEvent[] => {
  if (latest.length === 0) return history;
  const tail = history[history.length - 1];
  let start = 0;
  if (tail) {
    // (the newest match: two events alike in the same hundredth of a second are rare, and harmless here)
    for (let index = latest.length - 1; index >= 0; index--) {
      if (sameEvent(latest[index], tail)) {
        start = index + 1;
        break;
      }
      if ((latest[index]?.time ?? 0) < tail.time) {
        start = index + 1;
        break;
      }
    }
  }
  if (start >= latest.length) return history;
  const merged = history.concat(latest.slice(start));
  return merged.length > HISTORY_LIMIT ? merged.slice(merged.length - HISTORY_LIMIT) : merged;
};

const isState = (answer: SimState | StateProblem): answer is SimState =>
  !("error" in answer && answer.error) && !("setupNeeded" in answer && answer.setupNeeded) && "profile" in answer;

let inFlight: Promise<void> | null = null;
let isAgainWanted = false;

const readState = async (): Promise<void> => {
  let answer: SimState | StateProblem;
  try {
    answer = await api.state();
  } catch {
    if (!snapshot.isOffline) publish({ ...snapshot, isOffline: true });
    return;
  }
  if (!isState(answer)) {
    // (the same problem polled again is not news: the page would draw again twice a second while it lasts)
    const problem = replaceEqualDeep(snapshot.problem, answer);
    if (problem !== snapshot.problem || snapshot.isOffline) publish({ ...snapshot, problem, isOffline: false });
    return;
  }
  const previous = snapshot.state;
  const isNewRun = previous !== null && previous.generation !== answer.generation;
  const state = replaceEqualDeep(isNewRun ? null : previous, answer);
  const history = mergeEvents(isNewRun ? [] : snapshot.history, state.events ?? []);
  if (state === previous && history === snapshot.history && snapshot.problem === null && !snapshot.isOffline) return;
  publish({ state, problem: null, isOffline: false, history });
};

/** Reads the state now (after a change); a read already under way is followed by one more */
export const refreshState = (): Promise<void> => {
  if (inFlight) {
    isAgainWanted = true;
    return inFlight;
  }
  inFlight = readState().finally(() => {
    inFlight = null;
    if (isAgainWanted) {
      isAgainWanted = false;
      void refreshState();
    }
  });
  return inFlight;
};

export const clearHistory = (): void => publish({ ...snapshot, history: [] });

export const getSnapshot = (): StoreSnapshot => snapshot;

export const subscribe = (listener: Listener): (() => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

// The poller: started once, slowed while the tab is hidden, at once again when it is shown
let timer: ReturnType<typeof setTimeout> | null = null;
const schedule = (): void => {
  if (timer) clearTimeout(timer);
  timer = setTimeout(
    () => {
      void refreshState().finally(schedule);
    },
    document.hidden ? HIDDEN_POLL_MS : POLL_MS,
  );
};

let isStarted = false;
export const startPolling = (): void => {
  if (isStarted) return;
  isStarted = true;
  void refreshState().finally(schedule);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) void refreshState();
    schedule();
  });
};
