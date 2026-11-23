// The game screen's contract: what the page's React shell asks of the engine that draws the simulator's scene and
// sends the input back (engine/index.ts implements it). The shell never touches the screen's DOM; the engine never
// renders any of the page's controls.

export type Renderer = "gl" | "dom";
export type Magnify = 1 | 2 | 3 | 4;

/** What the server's socket says of each frame, besides the scene itself */
export type StreamStatus = {
  isConnected: boolean;
  /** The scene's version; a new one at each change */
  version: number | null;
  /** The host's run: changes at each reload */
  generation: number | null;
  /** Counts the simulator keeps; a change is the shell's cue to read the state again */
  errors: number;
  chat: number;
  /** What the server said went wrong with the frame (the simulator not running), or null */
  error: string | null;
};

/** How the page keeps up drawing (the server's own clock is in the state's perf) */
export type DrawStats = { drawsPerSecond: number; renderer: Renderer; drawMs: number };

/** A frame under the mouse, as the inspector lists it (the server's /api/inspect) */
export type InspectedFrame = {
  id: number;
  name: string;
  type: string;
  strata: string;
  level: number;
  mouse: boolean;
  creator?: string;
  x: number;
  y: number;
  w: number;
  h: number;
};

export type InspectOptions = {
  isOn: boolean;
  /** The list stays while the mouse moves on (Alt over the game does the same) */
  isHeld: boolean;
  /** Only frames that draw something or take the mouse */
  isDrawnOnly: boolean;
};

/** A press, a release or a move, in the game's terms (what /api/input and the socket's "input" take) */
export type InputEvent = { type: string; [key: string]: unknown };

/** A pad button by the client's key name (PAD1, PADDUP, PADLTRIGGER…) and the two sticks */
export type PadButton = string;
export type PadStick = "Movement" | "Camera";

export type ConnectedPad = { id: string; index: number };

export type Listener<T> = (value: T) => void;
export type Unsubscribe = () => void;

export type GameScreen = {
  /** Stops the socket, the drawing, the listeners; the container is left empty */
  destroy: () => void;
  /** Keys go to the game again (after a click on the page's controls) */
  focus: () => void;
  setMagnify: (magnify: Magnify) => void;
  setRenderer: (renderer: Renderer) => void;
  /** The loading screen of the continent the character is on, behind the interface, as the game draws its world */
  setWorldBackdrop: (uiMapId: number | null) => void;
  /** Called after the container changes size (the side panel folding); the screen fits itself again */
  fit: () => void;

  /** The page's scene dropped and a whole one asked for (after a reload, an addon switched on or off) */
  requestWholeScene: () => void;

  /** Called at once with the status as it is, then at each change (the version changes with every frame drawn) */
  onStatus: (listener: Listener<StreamStatus>) => Unsubscribe;
  /** Every second */
  onDrawStats: (listener: Listener<DrawStats>) => Unsubscribe;

  // The inspector (/fstack)
  setInspect: (options: InspectOptions) => void;
  onInspect: (listener: Listener<InspectedFrame[]>) => Unsubscribe;
  /** One frame's box alone (a row pointed at), or every inspected frame's again (null) */
  highlightFrame: (id: number | null) => void;

  // Input from the page's own controls
  sendInput: (event: InputEvent) => void;
  pressPad: (button: PadButton, isDown: boolean) => void;
  movePadStick: (stick: PadStick, x: number, y: number) => void;
  /** A controller plugged in (the browser's Gamepad API), or none; called at once with the one known */
  onPadConnected: (listener: Listener<ConnectedPad | null>) => Unsubscribe;
};

export type GameScreenOptions = {
  magnify?: Magnify;
  renderer?: Renderer;
};
