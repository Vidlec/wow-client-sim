// Colours as the scene gives them (0 to 1, parts possibly left out) to CSS
import type { Color } from "./items.ts";

const byte = (value: number | null | undefined): number => Math.round((value ?? 1) * 255);

/** A CSS colour; no colour is transparent. A part left out is 1, as the game reads it */
export const rgba = (color: Color | null | undefined, alpha = 1): string => {
  if (!color) return "transparent";
  return `rgba(${byte(color[0])},${byte(color[1])},${byte(color[2])},${(color[3] ?? 1) * alpha})`;
};

/** No colour, or white: the art drawn as it is */
export const isWhite = (color: Color | null | undefined): boolean =>
  !color || ((color[0] ?? 0) >= 0.999 && (color[1] ?? 0) >= 0.999 && (color[2] ?? 0) >= 0.999);
