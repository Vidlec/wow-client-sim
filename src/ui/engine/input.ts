// The mouse and the keyboard on the game screen, sent to the game in its terms: points on the game's screen (clicks
// mapped through the screen's scale, so they land where they look), its button and key names, the modifiers held.
import type { InputEvent } from "./types.ts";

export type Point = { x: number; y: number };

export type InputOptions = {
  /** The game's screen point under a page point */
  toScreen: (clientX: number, clientY: number) => Point;
  send: (event: InputEvent) => Promise<void>;
  /** The scene asked for after an input (its effect drawn at once) */
  poll: () => void;
  /** Magnified: Alt + wheel scrolls the view instead of reaching the game */
  isMagnified: () => boolean;
  /** The mouse moved over the game (the inspector follows it) */
  onMove: (point: Point, event: MouseEvent) => void;
};

const BUTTONS = ["LeftButton", "MiddleButton", "RightButton", "Button4", "Button5"];
const KEY_NAMES: Record<string, string> = {
  Escape: "ESCAPE",
  Enter: "ENTER",
  Tab: "TAB",
  Backspace: "BACKSPACE",
  " ": "SPACE",
  ArrowUp: "UP",
  ArrowDown: "DOWN",
  ArrowLeft: "LEFT",
  ArrowRight: "RIGHT",
  Delete: "DELETE",
  Home: "HOME",
  End: "END",
  PageUp: "PAGEUP",
  PageDown: "PAGEDOWN",
};
// Keys by where they sit when the character does not care what they print (numpad keys)
const CODE_NAMES: Record<string, string> = { NumpadDivide: "NUMPADDIVIDE", NumLock: "NUMLOCK" };
const keyName = (event: KeyboardEvent): string =>
  CODE_NAMES[event.code] ?? KEY_NAMES[event.key] ?? event.key.toUpperCase();
const modifiers = (event: MouseEvent | KeyboardEvent): Record<string, boolean> => ({
  shift: event.shiftKey,
  ctrl: event.ctrlKey || event.metaKey,
  alt: event.altKey,
});

/** The listeners on the screen element; returns what takes them off */
export const attachInput = (screen: HTMLElement, options: InputOptions): (() => void) => {
  const { toScreen, send, poll } = options;
  let pendingMove: InputEvent | null = null;
  let isMoving = false;

  // Moves are coalesced: while one is on its way, only the latest waits
  const sendMove = async (): Promise<void> => {
    if (isMoving || !pendingMove) return;
    isMoving = true;
    const move = pendingMove;
    pendingMove = null;
    await send(move);
    isMoving = false;
    if (pendingMove) void sendMove();
    poll();
  };
  const sendThenPoll = async (event: InputEvent): Promise<void> => {
    await send(event);
    poll();
  };

  const onMouseMove = (event: MouseEvent): void => {
    const point = toScreen(event.clientX, event.clientY);
    pendingMove = { type: "move", ...point, mods: modifiers(event) };
    void sendMove();
    options.onMove(point, event);
  };
  // The buttons pressed on the screen: their release and the moves between are followed off it too (a drag let go
  // outside the screen still ends in the game)
  const buttonsDown = new Set<number>();
  const onMouseDown = (event: MouseEvent): void => {
    screen.focus({ preventScroll: true });
    event.preventDefault();
    if (buttonsDown.size === 0) {
      window.addEventListener("mousemove", onWindowMouseMove);
      window.addEventListener("mouseup", onMouseUp);
    }
    buttonsDown.add(event.button);
    const point = toScreen(event.clientX, event.clientY);
    void sendThenPoll({ type: "down", ...point, button: BUTTONS[event.button], mods: modifiers(event) });
  };
  const onWindowMouseMove = (event: MouseEvent): void => {
    if (event.target !== screen && !screen.contains(event.target as Node)) onMouseMove(event);
  };
  const onMouseUp = (event: MouseEvent): void => {
    if (!buttonsDown.delete(event.button)) return;
    if (buttonsDown.size === 0) {
      window.removeEventListener("mousemove", onWindowMouseMove);
      window.removeEventListener("mouseup", onMouseUp);
    }
    // A move still waiting goes first: the release must come where the cursor ended (a drag across the map pans it)
    if (pendingMove) {
      const move = pendingMove;
      pendingMove = null;
      void send(move);
    }
    const point = toScreen(event.clientX, event.clientY);
    void sendThenPoll({ type: "up", ...point, button: BUTTONS[event.button], mods: modifiers(event) });
  };
  const onContextMenu = (event: Event): void => event.preventDefault();
  const onWheel = (event: WheelEvent): void => {
    if (options.isMagnified() && event.altKey) return; // Option/Alt + wheel moves the magnified view instead
    event.preventDefault();
    if (event.deltaY === 0) return; // (a sideways swipe: the game's wheel is up and down only)
    const point = toScreen(event.clientX, event.clientY);
    void sendThenPoll({ type: "wheel", ...point, delta: event.deltaY < 0 ? 1 : -1, mods: modifiers(event) });
  };
  const onKeyDown = (event: KeyboardEvent): void => {
    if (event.metaKey) return;
    event.preventDefault();
    if (event.repeat) return; // held: the game moves on its own clock until the key comes up
    const text = event.key.length === 1 ? event.key : null;
    void sendThenPoll({ type: "key", key: keyName(event), isHeld: true, text, mods: modifiers(event) });
  };
  const onKeyUp = (event: KeyboardEvent): void => {
    void send({ type: "keyup", key: keyName(event) });
  };
  // Leaving the game screen lets go of every key, as alt-tabbing out of the game does
  const onBlur = (): void => {
    void send({ type: "releaseAll" });
  };

  screen.addEventListener("mousemove", onMouseMove);
  screen.addEventListener("mousedown", onMouseDown);
  screen.addEventListener("contextmenu", onContextMenu);
  screen.addEventListener("wheel", onWheel, { passive: false });
  screen.addEventListener("keydown", onKeyDown);
  screen.addEventListener("keyup", onKeyUp);
  screen.addEventListener("blur", onBlur);
  return () => {
    screen.removeEventListener("mousemove", onMouseMove);
    screen.removeEventListener("mousedown", onMouseDown);
    window.removeEventListener("mousemove", onWindowMouseMove);
    window.removeEventListener("mouseup", onMouseUp);
    screen.removeEventListener("contextmenu", onContextMenu);
    screen.removeEventListener("wheel", onWheel);
    screen.removeEventListener("keydown", onKeyDown);
    screen.removeEventListener("keyup", onKeyUp);
    screen.removeEventListener("blur", onBlur);
  };
};
