// The game's screen inside its viewport: fitted whole and centred, or magnified (drawn larger than the viewport, which
// then scrolls; clicks are mapped through the same scale, so they still land where they look)
import type { Magnify } from "./types.ts";

export type LayoutParts = { viewport: HTMLElement; sizer: HTMLElement; screen: HTMLElement };

export type Layout = {
  /** The screen's size in game points */
  setSize: (width: number, height: number) => boolean;
  setMagnify: (magnify: Magnify) => void;
  /** Fitted again; returns the scale (page pixels per game point) */
  fit: () => number;
  readonly scale: () => number;
  readonly magnify: () => Magnify;
  readonly width: () => number;
  readonly height: () => number;
};

export const createLayout = ({ viewport, sizer, screen }: LayoutParts, magnifyAtFirst: Magnify): Layout => {
  let width = 1366;
  let height = 768;
  let magnify: Magnify = magnifyAtFirst;
  let scale = 1;

  const fit = (): number => {
    const box = viewport.getBoundingClientRect();
    const fitScale = Math.min(box.width / width, box.height / height) || 1;
    scale = fitScale * magnify;
    screen.style.width = `${width}px`;
    screen.style.height = `${height}px`;
    viewport.classList.toggle("is-magnified", magnify > 1);
    if (magnify > 1) {
      sizer.style.width = `${width * scale}px`;
      sizer.style.height = `${height * scale}px`;
      screen.style.transform = `scale(${scale})`;
    } else {
      sizer.style.width = "0px";
      sizer.style.height = "0px";
      const left = (box.width - width * scale) / 2;
      const top = (box.height - height * scale) / 2;
      screen.style.transform = `translate(${left}px, ${top}px) scale(${scale})`;
    }
    return scale;
  };

  return {
    setSize: (newWidth, newHeight) => {
      if (newWidth === width && newHeight === height) return false;
      width = newWidth;
      height = newHeight;
      return true;
    },
    setMagnify: (newMagnify) => {
      magnify = newMagnify;
    },
    fit,
    scale: () => scale,
    magnify: () => magnify,
    width: () => width,
    height: () => height,
  };
};
