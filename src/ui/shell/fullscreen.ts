// The page on the whole screen (the browser's fullscreen; its Esc leaves): the game takes it all and the side panel
// floats over it, as a window
import { useSyncExternalStore } from "react";

const subscribe = (listener: () => void): (() => void) => {
  document.addEventListener("fullscreenchange", listener);
  return () => document.removeEventListener("fullscreenchange", listener);
};

export const useIsFullscreen = (): boolean =>
  useSyncExternalStore(
    subscribe,
    () => document.fullscreenElement !== null,
    () => false,
  );

/** In or out; false when the browser refused */
export const toggleFullscreen = async (): Promise<boolean> => {
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await document.documentElement.requestFullscreen();
    return true;
  } catch {
    return false;
  }
};
