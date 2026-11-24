// The setup and the settings (src/shared/setup.ts): read once and kept for every part of the page that shows them, read
// again after each change, and once a second while the interface source downloads
import { useEffect, useSyncExternalStore } from "react";
import {
  type ArtInfo,
  type ClientBuilds,
  type FolderCheck,
  type FolderKind,
  type FolderListing,
  type ResetAnswer,
  type ResetChoice,
  SETUP_ROUTES,
  type SettingsChange,
  type SetupAnswer,
  type SetupState,
} from "../../shared/setup.ts";
import { getJson, postJson } from "./api.ts";
import { refreshState } from "./store.ts";

export type {
  ArtInfo,
  ClientBuilds,
  DetectedFolder,
  FlavourInfo,
  ResetChoice,
  Settings,
  SetupProblem,
  SetupState,
  StartProgress,
  StartStep,
} from "../../shared/setup.ts";

const DOWNLOAD_POLL_MS = 1000;

let setup: SetupState | null = null;
let readError: string | null = null;
const listeners = new Set<() => void>();

const publish = (next: SetupState | null, error: string | null = null): void => {
  setup = next;
  readError = error;
  for (const listener of listeners) listener();
};

// (read again while something is under way: the interface source downloading, or the simulator starting, which
// fetches the game's art and tables the first time; the page would show it under way forever otherwise)
const isUnderWay = (state: SetupState | null): boolean =>
  state?.interfaceDownload?.state === "downloading" ||
  state?.interfaceDownload?.state === "unpacking" ||
  state?.simulator.state === "starting" ||
  (state?.start?.steps.some((step) => step.state === "running") ?? false);

let pollTimer: ReturnType<typeof setTimeout> | null = null;
const followProgress = (): void => {
  if (pollTimer || !isUnderWay(setup)) return;
  pollTimer = setTimeout(() => {
    pollTimer = null;
    void readSetup().then(followProgress);
  }, DOWNLOAD_POLL_MS);
};

/** Reads the setup again (`refresh`: the server looks for folders and LuaJIT afresh) */
export const readSetup = async (refresh = false): Promise<SetupState | null> => {
  try {
    const state = await getJson<SetupState>(`${SETUP_ROUTES.setup}${refresh ? "?refresh=1" : ""}`);
    publish(state);
    followProgress();
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
  followProgress();
  void refreshState();
  return answer;
};

export const downloadInterface = async (): Promise<SetupState> => {
  const state = await postJson<SetupState>(SETUP_ROUTES.downloadInterface, {});
  publish(state);
  followProgress();
  return state;
};

// The setup screen asked for (after a reset): the page shows it until the user steps into the game again
let isSetupWanted = false;
const setupWantedListeners = new Set<() => void>();

/** Back to a fresh setup: every setting to its default, and what the choice says deleted; the setup screen shown */
export const resetSetup = async (choice: ResetChoice): Promise<ResetAnswer> => {
  const answer = await postJson<ResetAnswer>(SETUP_ROUTES.reset, choice);
  publish(answer);
  followProgress();
  void refreshState();
  isSetupWanted = true;
  for (const listener of setupWantedListeners) listener();
  return answer;
};

/** Whether the setup screen was asked for; taken (back to false) by whoever shows it */
export const useSetupWanted = (): { isWanted: boolean; take: () => void } => {
  const isWanted = useSyncExternalStore(
    (listener) => {
      setupWantedListeners.add(listener);
      return () => setupWantedListeners.delete(listener);
    },
    () => isSetupWanted,
    () => isSetupWanted,
  );
  return {
    isWanted,
    take: () => {
      isSetupWanted = false;
      for (const listener of setupWantedListeners) listener();
    },
  };
};

/** The client's builds: in use, the newest on Blizzard's servers, those wago.tools has, the interface source's */
export const readClientBuilds = (): Promise<ClientBuilds> => getJson<ClientBuilds>(SETUP_ROUTES.builds);

/** What the cache holds of the game's art and tables (reads the cache's folders: asked when the settings open) */
export const readArtInfo = (): Promise<ArtInfo> => getJson<ArtInfo>(SETUP_ROUTES.art);

export const checkFolder = (kind: FolderKind, path: string): Promise<FolderCheck> =>
  postJson(SETUP_ROUTES.checkFolder, { kind, path });

export const listFolder = (kind: FolderKind, path?: string): Promise<FolderListing> =>
  postJson(SETUP_ROUTES.listFolder, path ? { kind, path } : { kind });

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
