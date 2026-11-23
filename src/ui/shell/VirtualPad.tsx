// The virtual gamepad: a controller drawn on the page that sends what a real one sends. A button is down while
// pressed; Shift-click or right-click holds it down (a trigger held for the crossbar while another is pressed) until
// pressed again. A stick follows the mouse while dragged and springs back when let go. Dragged by its title; where it
// stands is kept in this browser. It never takes the keyboard from the game.
import { Xmark } from "@gravity-ui/icons";
import { Button, Kbd } from "@heroui/react";
import { type PointerEvent as ReactPointerEvent, useCallback, useEffect, useRef, useState } from "react";
import { GamepadIcon } from "../components/bits.tsx";
import type { PadButton, PadStick } from "../engine/types.ts";
import { getPrefs, setPref, usePref } from "../sim/prefs.ts";
import { useInputStyle } from "./header/InputSwitch.tsx";
import { getGameScreen } from "./screen.ts";

const WIDTH = 340;
const HEIGHT = 340;
const STICK_REACH = 25; // how far the knob goes from the middle, in pixels

type ButtonProps = {
  name: PadButton;
  label: string;
  className: string;
  title?: string;
  held: Set<string>;
  onHold: () => void;
};

const PadKey = ({ name, label, className, title, held, onHold }: ButtonProps) => {
  const [isDown, setDown] = useState(false);
  const isHeld = held.has(name);
  const press = (down: boolean): void => {
    setDown(down);
    getGameScreen()?.pressPad(name, down);
  };
  return (
    <button
      type="button"
      tabIndex={-1}
      title={title}
      aria-label={title ?? label}
      className={`vpad-btn ${className} ${isDown || isHeld ? "is-down" : ""} ${isHeld ? "is-held" : ""}`}
      onPointerDown={(event) => {
        if (event.shiftKey || event.button === 2) {
          onHold();
          return;
        }
        if (event.button !== 0 || isHeld) return;
        event.currentTarget.setPointerCapture(event.pointerId);
        press(true);
      }}
      onPointerUp={() => {
        if (isDown && !isHeld) press(false);
      }}
      onPointerCancel={() => {
        if (isDown && !isHeld) press(false);
      }}
    >
      {label}
    </button>
  );
};

const Stick = ({ stick, title }: { stick: PadStick; title: string }) => {
  const [offset, setOffset] = useState<[number, number]>([0, 0]);
  const [isDragging, setDragging] = useState(false);
  const last = useRef<[number, number]>([0, 0]);
  const send = (x: number, y: number): void => {
    setOffset([x, y]);
    const rounded: [number, number] = [Math.round(x * 20) / 20, Math.round(y * 20) / 20];
    if (rounded[0] === last.current[0] && rounded[1] === last.current[1]) return;
    last.current = rounded;
    getGameScreen()?.movePadStick(stick, rounded[0], rounded[1]);
  };
  const follow = (event: ReactPointerEvent<HTMLDivElement>): void => {
    const rect = event.currentTarget.getBoundingClientRect();
    const reach = rect.width / 2 - 17;
    let x = (event.clientX - (rect.left + rect.width / 2)) / reach;
    let y = -(event.clientY - (rect.top + rect.height / 2)) / reach; // (up, as the game counts)
    const length = Math.hypot(x, y);
    if (length > 1) {
      x /= length;
      y /= length;
    }
    send(x, y);
  };
  const letGo = (): void => {
    setDragging(false);
    send(0, 0);
  };
  return (
    <div
      className={`vpad-stick ${isDragging ? "is-dragging" : ""}`}
      title={title}
      onPointerDown={(event) => {
        if (event.button !== 0) return;
        event.currentTarget.setPointerCapture(event.pointerId);
        setDragging(true);
        follow(event);
      }}
      onPointerMove={(event) => {
        if (isDragging) follow(event);
      }}
      onPointerUp={letGo}
      onPointerCancel={letGo}
    >
      <div
        className="vpad-knob"
        style={{ transform: `translate(${offset[0] * STICK_REACH}px, ${-offset[1] * STICK_REACH}px)` }}
      />
    </div>
  );
};

const placeInside = (left: number, top: number): { left: number; top: number } => ({
  left: Math.max(0, Math.min(window.innerWidth - WIDTH, left)),
  top: Math.max(0, Math.min(window.innerHeight - HEIGHT, top)),
});

export const VirtualPad = () => {
  const isOpen = usePref("isVirtualPadOpen");
  const saved = usePref("virtualPadPlace");
  const { style, setStyle } = useInputStyle();
  const [held, setHeld] = useState<Set<string>>(() => new Set());
  const [place, setPlace] = useState(() =>
    saved
      ? placeInside(saved.left, saved.top)
      : placeInside(window.innerWidth - WIDTH - 24, window.innerHeight - HEIGHT - 48),
  );

  const heldRef = useRef(held);
  heldRef.current = held;

  // Open: the game is told a pad is there. Closed: everything let go, the sticks back in the middle.
  useEffect(() => {
    if (!isOpen) return;
    getGameScreen()?.sendInput({ type: "padConnected", isConnected: true, name: "Virtual gamepad" });
    return () => {
      const screen = getGameScreen();
      for (const name of heldRef.current) screen?.pressPad(name, false);
      screen?.movePadStick("Movement", 0, 0);
      screen?.movePadStick("Camera", 0, 0);
      setHeld(new Set());
    };
  }, [isOpen]);

  const toggleHold = useCallback((name: string): void => {
    setHeld((before) => {
      const next = new Set(before);
      const isHeld = !next.has(name);
      if (isHeld) next.add(name);
      else next.delete(name);
      getGameScreen()?.pressPad(name, isHeld);
      return next;
    });
  }, []);

  const startDrag = (event: ReactPointerEvent<HTMLDivElement>): void => {
    if ((event.target as HTMLElement).closest("button")) return;
    const offsetX = event.clientX - place.left;
    const offsetY = event.clientY - place.top;
    const target = event.currentTarget;
    target.setPointerCapture(event.pointerId);
    let latest = place;
    const move = (moveEvent: PointerEvent): void => {
      latest = placeInside(moveEvent.clientX - offsetX, moveEvent.clientY - offsetY);
      setPlace(latest);
    };
    const stop = (): void => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", stop);
      setPref("virtualPadPlace", { ...(getPrefs().virtualPadPlace ?? {}), ...latest });
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", stop);
  };

  if (!isOpen) return null;
  const key = (name: PadButton, label: string, className: string, title?: string) => (
    <PadKey
      key={name}
      name={name}
      label={label}
      className={className}
      held={held}
      onHold={() => toggleHold(name)}
      {...(title ? { title } : {})}
    />
  );

  return (
    <section
      className="vpad fixed z-40"
      style={{ left: place.left, top: place.top, width: WIDTH }}
      aria-label="Virtual gamepad"
      onMouseDown={(event) => event.preventDefault()}
      onContextMenu={(event) => event.preventDefault()}
    >
      <div className="vpad-head" onPointerDown={startDrag}>
        <GamepadIcon className="text-accent" />
        <span className="grow">Virtual gamepad</span>
        <span className="vpad-hint">
          <Kbd className="text-[10px]">
            <Kbd.Content>Shift</Kbd.Content>
          </Kbd>{" "}
          or right-click holds
        </span>
        <Button
          isIconOnly
          size="sm"
          variant="ghost"
          aria-label="Close (held buttons are let go)"
          onPress={() => setPref("isVirtualPadOpen", false)}
        >
          <Xmark />
        </Button>
      </div>
      {style !== 1 && (
        <div className="vpad-notice">
          <span>With mouse and keyboard the game binds no pad buttons: only the sticks walk and turn.</span>
          <Button size="sm" onPress={() => void setStyle(1)}>
            Use the gamepad interface
          </Button>
        </div>
      )}
      <div className="vpad-body">
        <div className="vpad-row">
          <div className="vpad-pair">
            {key("PADLTRIGGER", "LT", "vpad-trigger")}
            {key("PADLSHOULDER", "LB", "vpad-shoulder")}
          </div>
          <div className="vpad-pair">
            {key("PADRSHOULDER", "RB", "vpad-shoulder")}
            {key("PADRTRIGGER", "RT", "vpad-trigger")}
          </div>
        </div>
        <div className="vpad-row">
          {/* biome-ignore lint/a11y/useSemanticElements: a fieldset would change the pad's layout; a group of buttons */}
          <div className="vpad-cross" role="group" aria-label="D-pad">
            {key("PADDUP", "▲", "vpad-dir up", "D-pad up")}
            {key("PADDLEFT", "◀", "vpad-dir left", "D-pad left")}
            {key("PADDRIGHT", "▶", "vpad-dir right", "D-pad right")}
            {key("PADDDOWN", "▼", "vpad-dir down", "D-pad down")}
          </div>
          <div className="vpad-menu">
            {key("PADBACK", "Back", "vpad-small", "Back (View)")}
            {key("PADFORWARD", "Start", "vpad-small", "Start (Menu): the radial menu in the gamepad interface")}
          </div>
          {/* biome-ignore lint/a11y/useSemanticElements: a fieldset would change the pad's layout; a group of buttons */}
          <div className="vpad-face" role="group" aria-label="Face buttons">
            {key("PAD4", "Y", "vpad-round y")}
            {key("PAD3", "X", "vpad-round x")}
            {key("PAD2", "B", "vpad-round b")}
            {key("PAD1", "A", "vpad-round a")}
          </div>
        </div>
        <div className="vpad-row vpad-sticks">
          <div className="vpad-stickbox">
            <Stick stick="Movement" title="Left stick: walks the character (drag it)" />
            {key("PADLSTICK", "L3", "vpad-small", "Left stick press")}
          </div>
          <div className="vpad-stickbox">
            <Stick stick="Camera" title="Right stick: turns, and picks in the radial menu (drag it)" />
            {key("PADRSTICK", "R3", "vpad-small", "Right stick press")}
          </div>
        </div>
      </div>
    </section>
  );
};
