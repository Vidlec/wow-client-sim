// The game's resolutions the View panel offers, by shape (the game's own list, from 1024x768 to 5120x1440), and its
// UI Scale setting's range
export const SCREEN_GROUPS: readonly { shape: string; sizes: readonly string[] }[] = [
  { shape: "16:9", sizes: ["1280x720", "1366x768", "1600x900", "1920x1080", "2560x1440", "3840x2160"] },
  { shape: "16:10", sizes: ["1280x800", "1440x900", "1680x1050", "1920x1200", "2560x1600"] },
  { shape: "21:9", sizes: ["2560x1080", "3440x1440"] },
  { shape: "32:9", sizes: ["5120x1440"] },
  { shape: "4:3 and 5:4", sizes: ["1024x768", "1280x960", "1600x1200", "1280x1024"] },
];

export const UI_SCALE_MIN = 0.64;
export const UI_SCALE_MAX = 1.15;
export const UI_SCALE_MARKS = [0.64, 0.8, 1, 1.15] as const;

export const formatSize = (size: string): string => size.replace("x", "×");
