// The setup and the settings (src/shared/setup.ts): read once and kept for every part of the page that shows them, read
// again after each change, and once a second while the interface source downloads
import { useEffect, useSyncExternalStore } from "react";
import {
  type FolderCheck,
  type FolderKind,
  type FolderPick,
  SETUP_ROUTES,
  type SettingsChange,
  type SetupAnswer,
  type SetupState,
} from "../../shared/setup.ts";
import { getJson, postJson } from "./api.ts";
import { refreshState } from "./store.ts";

export type { DetectedFolder, FlavourInfo, Settings, SetupProblem, SetupState } from "../../shared/setup.ts";

const DOWNLOAD_POLL_MS = 1000;

let setup: SetupState | null = null;
let readError: string | null = null;
const listeners = new Set<() => void>();

const publish = (next: SetupState | null, error: string | null = null): void => {
  setup = next;
  readError = error;
  for (const listener of listeners) listener();
};

const isDownloading = (state: SetupState | null): boolean =>
  state?.interfaceDownload?.state === "downloading" || state?.interfaceDownload?.state === "unpacking";

let pollTimer: ReturnType<typeof setTimeout> | null = null;
const followDownload = (): void => {
  if (pollTimer || !isDownloading(setup)) return;
  pollTimer = setTimeout(() => {
    pollTimer = null;
    void readSetup().then(followDownload);
  }, DOWNLOAD_POLL_MS);
};

/** Reads the setup again (`refresh`: the server looks for folders and LuaJIT afresh) */
export const readSetup = async (refresh = false): Promise<SetupState | null> => {
  try {
    const state = await getJson<SetupState>(`${SETUP_ROUTES.setup}${refresh ? "?refresh=1" : ""}`);
    publish(state);
    followDownload();
    return state;
  } catch (error) {
    publish(setup, error instanceof Error ? error.message : String(error));
    return null;
  }
};

/** Changes settings: the server checks and saves them, and starts the simulator again when it needs to */
export const changeSettings = async (change: SettingsChange): Promise<SetupAnswer> => {
  const answer = await postJson<SetupAnswer>(SETUP_ROUTES.setup, change);
  publish(answer);
  void refreshState();
  return answer;
};

export const downloadInterface = async (): Promise<SetupState> => {
  const state = await postJson<SetupState>(SETUP_ROUTES.downloadInterface, {});
  publish(state);
  followDownload();
  return state;
};

export const checkFolder = (kind: FolderKind, path: string): Promise<FolderCheck> =>
  postJson(SETUP_ROUTES.checkFolder, { kind, path });

export const pickFolder = (kind: FolderKind, startPath?: string): Promise<FolderPick> =>
  postJson(SETUP_ROUTES.pickFolder, startPath ? { kind, startPath } : { kind });

const subscribe = (listener: () => void): (() => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

/** The setup as last read (read on first use); null until it has come */
export const useSetup = (): { setup: SetupState | null; error: string | null } => {
  const state = useSyncExternalStore(
    subscribe,
    () => setup,
    () => setup,
  );
  const error = useSyncExternalStore(
    subscribe,
    () => readError,
    () => readError,
  );
  useEffect(() => {
    if (!setup) void readSetup();
  }, []);
  return { setup: state, error };
};
