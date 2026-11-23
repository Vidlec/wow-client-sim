// The page's own choices that several parts of it share (the panel shown, the zoom, the backdrop, the floating
// windows), each remembered in this browser (settings.ts). One small store: setPref changes one, usePref reads one.
import { useSyncExternalStore } from "react";
import type { Magnify, Renderer } from "../engine/types.ts";
import { isBoolean, isNumber, isOneOf, isString, readSetting, writeSetting } from "./settings.ts";

export type Place = { left: number; top: number; width?: number; height?: number };

const isPlace = (value: unknown): value is Place =>
  typeof value === "object" && value !== null && isNumber((value as Place).left) && isNumber((value as Place).top);

export type Prefs = {
  panel: string;
  isSideCollapsed: boolean;
  /** The side panel floats over the game, as a window of its own */
  isPanelFloating: boolean;
  floatingPlace: Place | null;
  magnify: Magnify;
  renderer: Renderer;
  worldBackdrop: boolean;
  isVirtualPadOpen: boolean;
  virtualPadPlace: Place | null;
  lootOnKill: boolean;
  inspectOn: boolean;
  inspectHeld: boolean;
  inspectDrawnOnly: boolean;
  sideWidth: number;
};

const isPlaceOrNull = (value: unknown): value is Place | null => value === null || isPlace(value);
const isMagnify = isOneOf<Magnify>([1, 2, 3, 4]);
const isRenderer = isOneOf<Renderer>(["gl", "dom"]);

const read = <K extends keyof Prefs>(key: K, fallback: Prefs[K], isValid: (value: unknown) => value is Prefs[K]) =>
  readSetting(key, fallback, isValid);

// (the keys of the first page where they existed: "panel", "magnify", "worldBackdrop", "isSideCollapsed")
let prefs: Prefs = {
  panel: read("panel", "character", isString),
  isSideCollapsed: read("isSideCollapsed", false, isBoolean),
  isPanelFloating: read("isPanelFloating", false, isBoolean),
  floatingPlace: read("floatingPlace", null, isPlaceOrNull),
  magnify: read("magnify", 1, isMagnify),
  renderer: read("renderer", "gl", isRenderer),
  worldBackdrop: read("worldBackdrop", true, isBoolean),
  isVirtualPadOpen: read("isVirtualPadOpen", false, isBoolean),
  virtualPadPlace: read("virtualPadPlace", null, isPlaceOrNull),
  lootOnKill: read("lootOnKill", true, isBoolean),
  inspectOn: false, // (not remembered: the boxes over the game would surprise on the next visit)
  inspectHeld: false,
  inspectDrawnOnly: read("inspectDrawnOnly", true, isBoolean),
  sideWidth: read("sideWidth", 380, isNumber),
};

const NOT_REMEMBERED: ReadonlySet<keyof Prefs> = new Set(["inspectOn", "inspectHeld"]);
const listeners = new Set<() => void>();

export const getPrefs = (): Prefs => prefs;

export const setPref = <K extends keyof Prefs>(key: K, value: Prefs[K]): void => {
  if (Object.is(prefs[key], value)) return;
  prefs = { ...prefs, [key]: value };
  if (!NOT_REMEMBERED.has(key)) writeSetting(key, value);
  for (const listener of listeners) listener();
};

const subscribe = (listener: () => void): (() => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

export const usePref = <K extends keyof Prefs>(key: K): Prefs[K] =>
  useSyncExternalStore(
    subscribe,
    () => prefs[key],
    () => prefs[key],
  );
