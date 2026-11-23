// A controller, read through the browser's Gamepad API while the page is open: its buttons go to the game by the
// client's key names, its sticks as the game's Movement and Camera sticks (y up, as the game counts). Away from the
// page (no focus) everything is let go, as the game does when it loses the focus.
import type { ConnectedPad, InputEvent, PadStick } from "./types.ts";

// The standard mapping's buttons, in its order
const PAD_BUTTONS = [
  "PAD1",
  "PAD2",
  "PAD3",
  "PAD4",
  "PADLSHOULDER",
  "PADRSHOULDER",
  "PADLTRIGGER",
  "PADRTRIGGER",
  "PADBACK",
  "PADFORWARD",
  "PADLSTICK",
  "PADRSTICK",
  "PADDUP",
  "PADDDOWN",
  "PADDLEFT",
  "PADDRIGHT",
  "PADSYSTEM",
];
const STICK_DEAD_ZONE = 0.15;
const STICKS: readonly (readonly [PadStick, number, number])[] = [
  ["Movement", 0, 1],
  ["Camera", 2, 3],
];

/** A stick's place, y up as the game counts; rounded, so a stick held still sends nothing more */
const readStick = (x: number, y: number): [number, number] => {
  if (Math.hypot(x, y) < STICK_DEAD_ZONE) return [0, 0];
  return [Math.round(x * 20) / 20, Math.round(-y * 20) / 20];
};

export type GamepadOptions = {
  send: (event: InputEvent) => void;
  onPad: (pad: ConnectedPad | null) => void;
};

/** Reads the controller at each of the browser's frames; returns what stops it */
export const startGamepad = ({ send, onPad }: GamepadOptions): (() => void) => {
  let padIndex: number | null = null;
  let buttons: boolean[] = [];
  const sticks: Record<PadStick, [number, number]> = { Movement: [0, 0], Camera: [0, 0] };
  let frame = 0;

  const letGo = (): void => {
    for (let index = 0; index < buttons.length; index++) {
      if (buttons[index]) send({ type: "pad", button: PAD_BUTTONS[index], isDown: false });
    }
    buttons = [];
    for (const [stick] of STICKS) {
      const [x, y] = sticks[stick];
      if (x || y) send({ type: "padStick", stick, x: 0, y: 0 });
      sticks[stick] = [0, 0];
    }
  };

  const read = (pad: Gamepad): void => {
    if (padIndex !== pad.index) {
      padIndex = pad.index;
      onPad({ id: pad.id, index: pad.index });
      send({ type: "padConnected", isConnected: true, name: pad.id });
    }
    for (let index = 0; index < pad.buttons.length; index++) {
      const name = PAD_BUTTONS[index];
      const button = pad.buttons[index];
      if (!name || !button) continue;
      const isDown = button.pressed || button.value > 0.5;
      if (Boolean(buttons[index]) === isDown) continue;
      buttons[index] = isDown;
      send({ type: "pad", button: name, isDown });
    }
    for (const [stick, xAxis, yAxis] of STICKS) {
      const [x, y] = readStick(pad.axes[xAxis] ?? 0, pad.axes[yAxis] ?? 0);
      const [lastX, lastY] = sticks[stick];
      if (x === lastX && y === lastY) continue;
      sticks[stick] = [x, y];
      send({ type: "padStick", stick, x, y });
    }
  };

  const poll = (): void => {
    const pads = navigator.getGamepads ? navigator.getGamepads() : [];
    let pad: Gamepad | null = null;
    for (const each of pads) {
      if (!each) continue;
      if (each.index === padIndex) {
        pad = each;
        break;
      }
      pad ??= each;
    }
    if (pad && document.hasFocus()) read(pad);
    else if (pad) letGo();
    frame = requestAnimationFrame(poll);
  };
  frame = requestAnimationFrame(poll);

  const onConnected = (event: GamepadEvent): void => onPad({ id: event.gamepad.id, index: event.gamepad.index });
  const onDisconnected = (event: GamepadEvent): void => {
    if (event.gamepad.index !== padIndex) return;
    padIndex = null;
    buttons = [];
    onPad(null);
    send({ type: "padConnected", isConnected: false });
  };
  window.addEventListener("gamepadconnected", onConnected);
  window.addEventListener("gamepaddisconnected", onDisconnected);
  return () => {
    cancelAnimationFrame(frame);
    window.removeEventListener("gamepadconnected", onConnected);
    window.removeEventListener("gamepaddisconnected", onDisconnected);
  };
};
