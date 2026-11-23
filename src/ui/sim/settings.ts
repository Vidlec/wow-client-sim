// The page's own choices, remembered in this browser (localStorage, "addonsim.<key>"): the panel shown, the zoom, the
// backdrop, where floating windows stand. A private window or blocked storage only forgets them.
import { useCallback, useState } from "react";

const PREFIX = "addonsim.";

export const readSetting = <T>(key: string, fallback: T, isValid: (value: unknown) => value is T): T => {
  try {
    const text = localStorage.getItem(PREFIX + key);
    if (text === null) return fallback;
    const value: unknown = JSON.parse(text);
    return isValid(value) ? value : fallback;
  } catch {
    return fallback;
  }
};

export const writeSetting = (key: string, value: unknown): void => {
  try {
    localStorage.setItem(PREFIX + key, JSON.stringify(value));
  } catch {
    // (storage refused: the choice lasts for this page only)
  }
};

export const isBoolean = (value: unknown): value is boolean => typeof value === "boolean";
export const isString = (value: unknown): value is string => typeof value === "string";
export const isNumber = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);
export const isOneOf =
  <T extends string | number>(choices: readonly T[]) =>
  (value: unknown): value is T =>
    choices.includes(value as T);

/** useState, remembered between visits */
export const usePersistentState = <T>(
  key: string,
  fallback: T,
  isValid: (value: unknown) => value is T,
): [T, (value: T) => void] => {
  const [value, setValue] = useState<T>(() => readSetting(key, fallback, isValid));
  const set = useCallback(
    (next: T) => {
      setValue(next);
      writeSetting(key, next);
    },
    [key],
  );
  return [value, set];
};
