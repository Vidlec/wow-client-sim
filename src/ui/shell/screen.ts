// The game screen the shell mounted (GameView), for the panels that talk to it: the inspector, the view's zoom, the
// virtual pad, the status strip's drawing figures
import { useEffect, useState, useSyncExternalStore } from "react";
import type { ConnectedPad, DrawStats, GameScreen, InspectedFrame, Listener, Unsubscribe } from "../engine/types.ts";

let current: GameScreen | null = null;
const listeners = new Set<() => void>();

export const setGameScreen = (screen: GameScreen | null): void => {
  current = screen;
  for (const listener of listeners) listener();
};

export const getGameScreen = (): GameScreen | null => current;

const subscribe = (listener: () => void): (() => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

export const useGameScreen = (): GameScreen | null =>
  useSyncExternalStore(
    subscribe,
    () => current,
    () => current,
  );

/** The latest value a screen's listener gave (null until it has given one) */
const useScreenFeed = <T>(pick: (screen: GameScreen, listener: Listener<T>) => Unsubscribe): T | null => {
  const screen = useGameScreen();
  const [value, setValue] = useState<T | null>(null);
  useEffect(() => {
    if (!screen) return;
    return pick(screen, setValue);
  }, [screen, pick]);
  return value;
};

const pickDrawStats = (screen: GameScreen, listener: Listener<DrawStats>): Unsubscribe => screen.onDrawStats(listener);
const pickPad = (screen: GameScreen, listener: Listener<ConnectedPad | null>): Unsubscribe =>
  screen.onPadConnected(listener);
const pickInspect = (screen: GameScreen, listener: Listener<InspectedFrame[]>): Unsubscribe =>
  screen.onInspect(listener);

export const useDrawStats = (): DrawStats | null => useScreenFeed(pickDrawStats);
export const useConnectedPad = (): ConnectedPad | null => useScreenFeed(pickPad);
export const useInspectedFrames = (): InspectedFrame[] | null => useScreenFeed(pickInspect);

/** Keys go back to the game (after a control of the page took them) */
export const focusGame = (): void => current?.focus();

/** The page's scene dropped and a whole one asked for (after a reload, an addon switched on or off) */
export const requestWholeScene = (): void => current?.requestWholeScene();

/** What the socket says that the page shows: connected or not, and the server's frame error (the simulator down) */
export type StreamHealth = { isConnected: boolean; error: string | null };

let health: StreamHealth = { isConnected: true, error: null };
const healthListeners = new Set<() => void>();

export const setStreamHealth = (next: StreamHealth): void => {
  if (next.isConnected === health.isConnected && next.error === health.error) return;
  health = next;
  for (const listener of healthListeners) listener();
};

export const useStreamHealth = (): StreamHealth =>
  useSyncExternalStore(
    (listener) => {
      healthListeners.add(listener);
      return () => healthListeners.delete(listener);
    },
    () => health,
    () => health,
  );
