// The scene as the simulator exports it (lua/scene.lua): what is drawn, item by item, in screen points from the top
// left. Fields are short (each frame carries thousands of them); a field left out means the game's default.

/** r, g, b, a from 0 to 1; a part left out is 1 (Lua tables with holes) */
export type Color = readonly (number | null | undefined)[];

/** x, y, width, height */
export type Box = readonly number[];

type Placed = { x: number; y: number; w: number; h: number };

type ItemBase = {
  /** The id of the region (or frame) it is drawn for; the key is k .. i */
  i: number | string;
  /** The alpha it is drawn with (its own times its parents') */
  a?: number;
  /** The clipping frame's box it is cut to */
  cl?: Box;
};

export type Gradient = { orientation: string; from: Color; to: Color };

/** A texture: a file, an atlas or a colour, with the game's coordinates, tints, masks and blends */
export type TextureItem = ItemBase &
  Placed & {
    k: "t";
    /** A file id or a path */
    tex?: string | number | null;
    atlas?: string;
    /** Coordinates: left, right, top, bottom (or, turned a quarter, u at the top and bottom, v at the left and right) */
    tc?: readonly number[];
    tcTurned?: boolean;
    /** Tiled across and down */
    tile?: readonly boolean[];
    /** A plain colour (SetColorTexture) */
    c?: Color;
    /** The vertex colour */
    vc?: Color;
    gr?: Gradient;
    /** The scale of a sliced atlas's margins */
    sc?: number;
    mask?: string | number;
    maskAtlas?: string;
    /** Where the mask's own region is */
    maskBox?: Box;
    /** Turned about its middle, radians counter-clockwise */
    rot?: number;
    /** Corners moved (SetVertexOffset), fractions of the box: upper left, upper right, lower right, lower left */
    poly?: readonly number[];
    /** Greyed (SetDesaturated) */
    ds?: boolean;
    /** The blend mode: ADD, MOD or the usual */
    bl?: string;
    /** A map tile, drawn a hair larger so no seams show */
    seam?: boolean;
  };

/** A font string: its lines as Lua wrapped them, with the game's colour codes, links and inline icons */
export type FontStringItem = ItemBase &
  Placed & {
    k: "s";
    lines: readonly string[];
    /** The font's key (fonts.ts fontKey) */
    f: string;
    fs: number;
    /** Flags: OUTLINE, THICKOUTLINE, MONOCHROME */
    fl?: string;
    c?: Color;
    jh?: string;
    jv?: string;
    /** The line height and the spacing between lines */
    lh: number;
    sp?: number;
    /** The shadow's offset, y up */
    sh?: readonly number[];
    /** An edit box with the focus: the text cursor at its end */
    cursor?: boolean;
  };

export type Insets = { left?: number; right?: number; top?: number; bottom?: number };

/** A frame's backdrop: its background and the classic eight-piece edge */
export type BackdropItem = ItemBase &
  Placed & {
    k: "b";
    bg?: string | number;
    edge?: string | number;
    es?: number;
    ins?: Insets;
    tile?: boolean;
    ts?: number;
    c?: Color;
    bc?: Color;
  };

/** A line (CreateLine) */
export type LineItem = ItemBase & {
  k: "ln";
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  th: number;
  c?: Color;
  tex?: string | number;
  vc?: Color;
};

export type SceneItem = TextureItem | FontStringItem | BackdropItem | LineItem;

/** The scene in drawing order; a hole is an item the order named that never came (drawn as nothing) */
export type SceneItems = readonly (SceneItem | undefined)[];

/** What the server pushes: a whole scene, or what changed since the frame before, with the counts it keeps */
export type SceneFrame = {
  version?: number;
  /** (the poll's answer when nothing is newer) */
  unchanged?: boolean;
  generation?: number;
  errors?: number;
  chat?: number;
  width?: number;
  height?: number;
  error?: string;
  /** A whole scene */
  items?: SceneItem[];
  /** A frame of changes: the items new or changed, and the order (keys) when it changed */
  delta?: boolean;
  u?: SceneItem[];
  o?: string[];
};

/** A scene the runner saved (saveScene, snapshot): scenarios/…/name.scene.json */
export type SavedScene = { width: number; height: number; items: SceneItem[] };
