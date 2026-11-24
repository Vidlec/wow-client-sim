// The inspector, as the game's /fstack: every frame under the mouse (the server's /api/inspect), top first, each with
// its box on the game; a row pointed at in the page's list shows its frame's box alone
import type { InspectedFrame, InspectOptions, Listener } from "./types.ts";

export type Inspector = {
  setOptions: (options: InspectOptions) => void;
  /** The mouse moved to a point of the game's screen (altKey: held, as Alt over the game holds the list) */
  follow: (point: { x: number; y: number }, isAltHeld: boolean) => void;
  highlight: (id: number | null) => void;
  listeners: Set<Listener<InspectedFrame[]>>;
};

export const createInspector = (boxes: HTMLElement): Inspector => {
  let options: InspectOptions = { isOn: false, isHeld: false, isDrawnOnly: true };
  let frames: InspectedFrame[] = [];
  let isBusy = false;
  let pendingPoint: { x: number; y: number } | null = null; // (the latest point asked for while busy)
  const listeners = new Set<Listener<InspectedFrame[]>>();

  const drawBoxes = (shown: readonly InspectedFrame[], pickedId: number | null): void => {
    const made: HTMLElement[] = [];
    for (const frame of shown) {
      const box = document.createElement("div");
      box.style.left = `${frame.x}px`;
      box.style.top = `${frame.y}px`;
      box.style.width = `${frame.w}px`;
      box.style.height = `${frame.h}px`;
      if (frame.id === pickedId) box.className = "picked";
      made.push(box);
    }
    boxes.replaceChildren(...made);
  };

  const inspectAt = async (point: { x: number; y: number }): Promise<void> => {
    if (isBusy) {
      pendingPoint = point;
      return;
    }
    isBusy = true;
    try {
      const response = await fetch("/api/inspect", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...point, drawnOnly: options.isDrawnOnly }),
      });
      const result = (await response.json()) as { frames?: InspectedFrame[] };
      frames = result.frames ?? [];
    } catch {
      frames = [];
    }
    isBusy = false;
    if (!options.isOn) return; // (switched off meanwhile)
    if (pendingPoint) {
      const next = pendingPoint;
      pendingPoint = null;
      void inspectAt(next);
      return;
    }
    drawBoxes(frames, null);
    for (const listener of listeners) listener(frames);
  };

  return {
    setOptions: (next) => {
      options = next;
      if (!options.isOn) boxes.replaceChildren();
    },
    follow: (point, isAltHeld) => {
      if (options.isOn && !options.isHeld && !isAltHeld) void inspectAt(point);
    },
    highlight: (id) => {
      if (!options.isOn) return;
      if (id === null) drawBoxes(frames, null);
      else
        drawBoxes(
          frames.filter((frame) => frame.id === id),
          id,
        );
    },
    listeners,
  };
};
