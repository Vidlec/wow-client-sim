// The page's own elements as the renderer: an absolutely placed element per item, styled with CSS backgrounds, masks,
// filters and transforms. The picture pages draw so (one draw, every browser alike), and the live screen does with
// ?renderer=dom or when the browser has no WebGL2.
import { getAtlas, onAtlasArrived } from "../atlas.ts";
import { isWhite, rgba } from "../color.ts";
import { fontFamily } from "../fonts.ts";
import type { BackdropItem, Color, FontStringItem, LineItem, SceneItem, SceneItems, TextureItem } from "../items.ts";
import { itemKey } from "../scene.ts";
import { lineToHtml } from "../text.ts";
import { artUrl, textureUrl } from "../textures.ts";

/** An item's element, with what it was last drawn as (expandos: cheaper than attributes) */
type ItemElement = HTMLDivElement & {
  kind?: string;
  drawnItem?: SceneItem;
  drawnAs?: string;
  drawnEpoch?: number;
  drawnIndex?: number;
  seenAt?: number;
  html?: string;
  turned?: HTMLDivElement | null;
  slices?: HTMLDivElement | null;
};

export type DomRenderer = {
  render: (items: SceneItems) => void;
  /** Everything drawn again at the next render (art it waited on arrived, or the elements were away) */
  invalidate: () => void;
  /** The elements taken away, the listeners stopped */
  dispose: () => void;
};

type Corners = readonly number[];

const setMaskImage = (style: CSSStyleDeclaration, value: string): void => {
  style.maskImage = value;
  style.webkitMaskImage = value;
};
const setMaskSize = (style: CSSStyleDeclaration, value: string): void => {
  style.maskSize = value;
  style.webkitMaskSize = value;
};
const setMaskPosition = (style: CSSStyleDeclaration, value: string): void => {
  style.maskPosition = value;
  style.webkitMaskPosition = value;
};
const setMaskRepeat = (style: CSSStyleDeclaration, value: string): void => {
  style.maskRepeat = value;
  style.webkitMaskRepeat = value;
};
const clearPaint = (style: CSSStyleDeclaration): void => {
  style.backgroundImage = "";
  style.backgroundColor = "";
  setMaskImage(style, "");
};

/**
 * A picture as an element's background: coords (left, right, top, bottom) pick its piece, a tint multiplies it (the
 * art's alpha cutting the shape). Returns the flip it needs as a transform ("" for none).
 */
const setImage = (
  style: CSSStyleDeclaration,
  url: string | null,
  coords: Corners | null | undefined,
  tint: Color | null | undefined,
  isTiledAsked: boolean,
  box?: { w: number; h: number },
): string => {
  const left = coords?.[0] ?? 0;
  const right = coords?.[1] ?? 1;
  const top = coords?.[2] ?? 0;
  const bottom = coords?.[3] ?? 1;
  const width = right - left;
  const height = bottom - top;
  let isTiled = isTiledAsked;
  // Coordinates past the texture's edge repeat it, as the game's backdrops tile their background and edges
  const isRepeating = box && Math.max(left, right, top, bottom) > 1.001;
  let size: string;
  let position: string;
  if (isRepeating) {
    const tileWidth = box.w / Math.abs(width || 1);
    const tileHeight = box.h / Math.abs(height || 1);
    size = `${tileWidth}px ${tileHeight}px`;
    position = `${-Math.min(left, right) * tileWidth}px ${-Math.min(top, bottom) * tileHeight}px`;
    isTiled = true;
  } else {
    size = isTiled ? "auto" : `${100 / Math.abs(width || 1)}% ${100 / Math.abs(height || 1)}%`;
    const x = Math.abs(width) >= 0.9999 ? 0 : (Math.min(left, right) / (1 - Math.abs(width))) * 100;
    const y = Math.abs(height) >= 0.9999 ? 0 : (Math.min(top, bottom) / (1 - Math.abs(height))) * 100;
    position = `${x}% ${y}%`;
  }
  const repeat = isTiled ? "repeat" : "no-repeat";
  style.backgroundImage = `url("${url}")`;
  style.backgroundSize = size;
  style.backgroundPosition = position;
  style.backgroundRepeat = repeat;
  if (tint && !isWhite(tint)) {
    // The vertex colour multiplies the art, as the game does; the art's own alpha cuts the shape
    style.backgroundColor = rgba(tint);
    style.backgroundBlendMode = "multiply";
    setMaskImage(style, `url("${url}")`);
    setMaskSize(style, size);
    setMaskPosition(style, position);
    setMaskRepeat(style, repeat);
  } else {
    style.backgroundColor = "";
    style.backgroundBlendMode = "";
    setMaskImage(style, "");
  }
  const flipX = width < 0 ? -1 : 1;
  const flipY = height < 0 ? -1 : 1;
  return flipX !== 1 || flipY !== 1 ? `scale(${flipX},${flipY})` : "";
};

/** Cut to the clipping frame (and to the corners' shape when they were moved); false when nothing is left */
const applyClip = (style: CSSStyleDeclaration, item: SceneItem & { x: number; y: number; w: number; h: number }) => {
  const poly = "poly" in item ? item.poly : undefined;
  // A texture with moved corners is cut to their shape; inside a clipping frame its corners stay within it too
  const shape = (corners: Corners, left: number, top: number, right: number, bottom: number): string => {
    const points: string[] = [];
    for (let index = 0; index < 8; index += 2) {
      const x = Math.min(Math.max((corners[index] ?? 0) * item.w, left), item.w - right);
      const y = Math.min(Math.max((corners[index + 1] ?? 0) * item.h, top), item.h - bottom);
      points.push(`${x}px ${y}px`);
    }
    return `polygon(${points.join(", ")})`;
  };
  if (!item.cl) {
    style.clipPath = poly ? shape(poly, 0, 0, 0, 0) : "";
    return true;
  }
  const [cx = 0, cy = 0, cw = 0, ch = 0] = item.cl;
  const top = Math.max(0, cy - item.y);
  const left = Math.max(0, cx - item.x);
  const right = Math.max(0, item.x + item.w - (cx + cw));
  const bottom = Math.max(0, item.y + item.h - (cy + ch));
  if (left + right >= item.w || top + bottom >= item.h) return false;
  style.clipPath = poly ? shape(poly, left, top, right, bottom) : `inset(${top}px ${right}px ${bottom}px ${left}px)`;
  return true;
};

// A texture whose coordinates turn it a quarter: u runs down the screen, v across. Drawn upright in a box of swapped
// size, then turned into place, flipped where the coordinates run backwards.
const drawTurned = (element: ItemElement, item: TextureItem | null): void => {
  let inner = element.turned;
  if (!item) {
    if (inner) inner.remove();
    element.turned = null;
    return;
  }
  if (!inner) {
    inner = document.createElement("div");
    inner.className = "turned";
    inner.style.position = "absolute";
    inner.style.pointerEvents = "none";
    element.appendChild(inner);
    element.turned = inner;
  }
  const [uTop = 0, uBottom = 1, vLeft = 0, vRight = 1] = item.tc ?? [];
  const style = inner.style;
  style.width = `${item.h}px`;
  style.height = `${item.w}px`;
  style.left = `${(item.w - item.h) / 2}px`;
  style.top = `${(item.h - item.w) / 2}px`;
  // Upright, x is u and y is v; a quarter turn clockwise puts u down the screen and v right to left
  const coords = [Math.min(uTop, uBottom), Math.max(uTop, uBottom), Math.min(vLeft, vRight), Math.max(vLeft, vRight)];
  setImage(style, textureUrl(item.tex), coords, item.vc, false, { w: item.h, h: item.w });
  const flipU = uBottom >= uTop ? 1 : -1;
  const flipV = vRight <= vLeft ? 1 : -1;
  style.transform = `rotate(90deg) scale(${flipU},${flipV})`;
};

// The nine pieces of a sliced atlas, as children of the texture's element; null removes them
const drawSlices = (
  element: ItemElement,
  atlas: NonNullable<ReturnType<typeof getAtlas>> | null,
  item?: TextureItem,
): void => {
  let pieces = element.slices;
  if (!atlas?.slice || !item) {
    if (pieces) pieces.remove();
    element.slices = null;
    return;
  }
  if (!pieces) {
    pieces = document.createElement("div");
    pieces.className = "slices";
    pieces.style.cssText = "position:absolute;inset:0;pointer-events:none";
    for (let index = 0; index < 9; index++) pieces.appendChild(document.createElement("div"));
    element.appendChild(pieces);
    element.slices = pieces;
  }
  const scale = item.sc || 1;
  const [marginLeft = 0, marginTop = 0, marginRight = 0, marginBottom = 0] = atlas.slice;
  const fileWidth = atlas.width / (atlas.right - atlas.left);
  const fileHeight = atlas.height / (atlas.bottom - atlas.top);
  const originX = atlas.left * fileWidth;
  const originY = atlas.top * fileHeight;
  // Corners shrink together when the texture is smaller than its margins
  const fit = Math.min(
    1,
    item.w / ((marginLeft + marginRight) * scale || 1),
    item.h / ((marginTop + marginBottom) * scale || 1),
  );
  // [where in the element's pixels, how many, where on the screen, how far]
  const columns = [
    [0, marginLeft, 0, marginLeft * scale * fit],
    [
      marginLeft,
      atlas.width - marginLeft - marginRight,
      marginLeft * scale * fit,
      item.w - (marginLeft + marginRight) * scale * fit,
    ],
    [atlas.width - marginRight, marginRight, item.w - marginRight * scale * fit, marginRight * scale * fit],
  ] as const;
  const rows = [
    [0, marginTop, 0, marginTop * scale * fit],
    [
      marginTop,
      atlas.height - marginTop - marginBottom,
      marginTop * scale * fit,
      item.h - (marginTop + marginBottom) * scale * fit,
    ],
    [atlas.height - marginBottom, marginBottom, item.h - marginBottom * scale * fit, marginBottom * scale * fit],
  ] as const;
  const url = `url("${artUrl(atlas.fdid)}")`;
  const tint = item.vc && !isWhite(item.vc) ? item.vc : null;
  for (let rowIndex = 0; rowIndex < 3; rowIndex++) {
    const [sourceY, sourceHeight, y, height] = rows[rowIndex] as (typeof rows)[number];
    for (let columnIndex = 0; columnIndex < 3; columnIndex++) {
      const [sourceX, sourceWidth, x, width] = columns[columnIndex] as (typeof columns)[number];
      const piece = (pieces.children[rowIndex * 3 + columnIndex] as HTMLElement).style;
      piece.position = "absolute";
      piece.left = `${x}px`;
      piece.top = `${y}px`;
      piece.width = `${Math.max(width, 0)}px`;
      piece.height = `${Math.max(height, 0)}px`;
      const scaleX = sourceWidth > 0 ? width / sourceWidth : 1;
      const scaleY = sourceHeight > 0 ? height / sourceHeight : 1;
      const size = `${fileWidth * scaleX}px ${fileHeight * scaleY}px`;
      const position = `${-(originX + sourceX) * scaleX}px ${-(originY + sourceY) * scaleY}px`;
      piece.backgroundImage = url;
      piece.backgroundSize = size;
      piece.backgroundPosition = position;
      piece.backgroundRepeat = "no-repeat";
      if (tint) {
        piece.backgroundColor = rgba(tint);
        piece.backgroundBlendMode = "multiply";
        setMaskImage(piece, url);
        setMaskSize(piece, size);
        setMaskPosition(piece, position);
        setMaskRepeat(piece, "no-repeat");
      } else {
        piece.backgroundColor = "";
        piece.backgroundBlendMode = "";
        setMaskImage(piece, "");
      }
    }
  }
};

// A picture's vertex colour: its alpha fades the whole picture, as the game does (rather than turning the colour
// towards white), so the colour itself is passed on opaque
const opaqueTint = (item: TextureItem, style: CSSStyleDeclaration): Color | null | undefined => {
  const alpha = item.vc ? (item.vc[3] ?? 1) : 1;
  if (alpha < 1) style.opacity = String((item.a ?? 1) * alpha);
  // Greyed and coloured: the game greys the picture first and colours the grey (greyTintFilter does both at once)
  if (item.ds && !isWhite(item.vc)) return null;
  return item.vc ? [item.vc[0], item.vc[1], item.vc[2], 1] : item.vc;
};

// A greyed picture coloured afterwards, as the game draws SetDesaturated with SetVertexColor: one SVG colour matrix
// (the grey's weights times the colour), made once per colour for the page
const SVG = "http://www.w3.org/2000/svg";
const greyTintFilters = new Map<string, string>();
const greyTintFilter = (color: Color): string => {
  const parts = [color[0] ?? 1, color[1] ?? 1, color[2] ?? 1];
  const key = parts.map((value) => Math.round(value * 255)).join("-");
  let filterUrl = greyTintFilters.get(key);
  if (filterUrl) return filterUrl;
  let svg: Element | null = document.getElementById("grey-tint-filters");
  if (!svg) {
    const made = document.createElementNS(SVG, "svg");
    made.id = "grey-tint-filters";
    made.setAttribute("width", "0");
    made.setAttribute("height", "0");
    made.style.position = "absolute";
    document.body.appendChild(made);
    svg = made;
  }
  const filter = document.createElementNS(SVG, "filter");
  filter.id = `grey-tint-${key}`;
  filter.setAttribute("color-interpolation-filters", "sRGB");
  const matrix = document.createElementNS(SVG, "feColorMatrix");
  const row = (channel: number): string => `${0.2126 * channel} ${0.7152 * channel} ${0.0722 * channel} 0 0`;
  matrix.setAttribute("type", "matrix");
  matrix.setAttribute("values", `${row(parts[0] ?? 1)} ${row(parts[1] ?? 1)} ${row(parts[2] ?? 1)} 0 0 0 1 0`);
  filter.appendChild(matrix);
  svg.appendChild(filter);
  filterUrl = `url(#${filter.id})`;
  greyTintFilters.set(key, filterUrl);
  return filterUrl;
};

/** A mask over the texture (a file, or an atlas's piece of its sheet), with the tint's own mask when it has one */
const applyMask = (item: TextureItem, style: CSSStyleDeclaration): boolean => {
  const maskAtlas = item.maskAtlas ? getAtlas(item.maskAtlas) : null;
  if (!item.mask && !maskAtlas) return false;
  // A mask texture cuts the shape (the game's round portrait mask makes circles of squares); with a tint's own
  // mask, both apply
  const maskUrl = maskAtlas ? `url("${artUrl(maskAtlas.fdid)}")` : `url("${textureUrl(item.mask)}")`;
  const hasOwnMask = style.maskImage && style.maskImage !== "none";
  // The mask sits where its own region is, which may be larger than or offset from this texture
  let [maskX = 0, maskY = 0, maskWidth = 0, maskHeight = 0] = item.maskBox ?? [item.x, item.y, item.w, item.h];
  if (maskAtlas) {
    const spanX = maskAtlas.right - maskAtlas.left || 1;
    const spanY = maskAtlas.bottom - maskAtlas.top || 1;
    const sheetWidth = maskWidth / spanX;
    const sheetHeight = maskHeight / spanY;
    maskX -= maskAtlas.left * sheetWidth;
    maskY -= maskAtlas.top * sheetHeight;
    maskWidth = sheetWidth;
    maskHeight = sheetHeight;
  }
  let offsetX = maskX - item.x;
  let offsetY = maskY - item.y;
  if (item.rot && item.maskBox) {
    // The texture is turned about its middle, and its mask with it: place the mask where it would land after turning
    // back, so on screen it stays where the mask region is (the minimap's circle). The texture is turned by -rot in
    // CSS; the mask needs the opposite
    const angle = item.rot;
    const fromCenterX = maskX + maskWidth / 2 - (item.x + item.w / 2);
    const fromCenterY = maskY + maskHeight / 2 - (item.y + item.h / 2);
    const localX = fromCenterX * Math.cos(angle) - fromCenterY * Math.sin(angle);
    const localY = fromCenterX * Math.sin(angle) + fromCenterY * Math.cos(angle);
    offsetX = item.w / 2 + localX - maskWidth / 2;
    offsetY = item.h / 2 + localY - maskHeight / 2;
  }
  const maskSize = `${maskWidth}px ${maskHeight}px`;
  const maskPosition = `${offsetX}px ${offsetY}px`;
  setMaskImage(style, hasOwnMask ? `${style.maskImage}, ${maskUrl}` : maskUrl);
  setMaskSize(style, hasOwnMask ? `${style.maskSize}, ${maskSize}` : maskSize);
  setMaskPosition(style, hasOwnMask ? `${style.maskPosition}, ${maskPosition}` : maskPosition);
  setMaskRepeat(style, hasOwnMask ? `${style.maskRepeat}, no-repeat` : "no-repeat");
  style.maskComposite = hasOwnMask ? "intersect" : "";
  style.webkitMaskComposite = hasOwnMask ? "source-in" : "";
  return true;
};

const drawTexture = (item: TextureItem, element: ItemElement): void => {
  const style = element.style;
  style.left = `${item.x}px`;
  style.top = `${item.y}px`;
  style.width = `${item.w}px`;
  style.height = `${item.h}px`;
  // Corners moved with SetVertexOffset: the texture is cut to the shape they make (applyClip sets it)
  style.opacity = String(item.a ?? 1);
  let transform = "";
  if (item.gr && (item.c || (item.tex === undefined && !item.atlas))) {
    // A gradient tints its texture's colour from one end to the other, as vertex colours do in the game
    drawSlices(element, null);
    drawTurned(element, null);
    const base = item.c ?? [1, 1, 1, 1];
    const tint = (color: Color): Color => [
      (base[0] ?? 1) * (color[0] ?? 1),
      (base[1] ?? 1) * (color[1] ?? 1),
      (base[2] ?? 1) * (color[2] ?? 1),
      (base[3] ?? 1) * (color[3] ?? 1),
    ];
    style.backgroundColor = "";
    setMaskImage(style, "");
    const direction = item.gr.orientation === "HORIZONTAL" ? "to right" : "to top";
    style.backgroundImage = `linear-gradient(${direction}, ${rgba(tint(item.gr.from))}, ${rgba(tint(item.gr.to))})`;
  } else if (item.c) {
    drawSlices(element, null);
    drawTurned(element, null);
    style.backgroundImage = "";
    setMaskImage(style, "");
    const c = item.c;
    const vc = item.vc;
    style.backgroundColor = vc
      ? rgba([
          (c[0] ?? 1) * (vc[0] ?? 1),
          (c[1] ?? 1) * (vc[1] ?? 1),
          (c[2] ?? 1) * (vc[2] ?? 1),
          (c[3] ?? 1) * (vc[3] ?? 1),
        ])
      : rgba(c, 1);
  } else if (item.atlas) {
    const atlas = getAtlas(item.atlas);
    drawTurned(element, null);
    if (!atlas) {
      style.backgroundImage = "";
      drawSlices(element, null);
      return;
    }
    if (atlas.slice) {
      // Nine-sliced, as the game draws it: corners at their own size, edges and middle stretched (or tiled)
      clearPaint(style);
      drawSlices(element, atlas, item);
    } else {
      drawSlices(element, null);
      // Coordinates set after the atlas are the atlas's own, 0 to 1 across it, as in the game (the game's top tabs
      // turn theirs over with 0, 1, 1, 0): a part of the atlas, or the atlas turned over
      const tc = item.tc && !item.tcTurned ? item.tc : [0, 1, 0, 1];
      const spanX = atlas.right - atlas.left;
      const spanY = atlas.bottom - atlas.top;
      const coords = [
        atlas.left + (tc[0] ?? 0) * spanX,
        atlas.left + (tc[1] ?? 1) * spanX,
        atlas.top + (tc[2] ?? 0) * spanY,
        atlas.top + (tc[3] ?? 1) * spanY,
      ];
      transform = setImage(style, artUrl(atlas.fdid), coords, opaqueTint(item, style), false);
    }
  } else if (item.tex !== undefined) {
    drawSlices(element, null);
    drawTurned(element, null);
    if (item.tcTurned) {
      // A quarter turn (the game's backdrop top and bottom edges): drawn upright in a box the other way round
      clearPaint(style);
      drawTurned(element, item);
    } else {
      const isTiled = Boolean(item.tile && (item.tile[0] || item.tile[1]));
      transform = setImage(style, textureUrl(item.tex), item.tc, opaqueTint(item, style), isTiled, item);
    }
  }
  if (!applyMask(item, style) && isWhite(item.vc) && !item.tex && !item.atlas) setMaskImage(style, "");
  if (item.seam) {
    // Map tiles overlap a hair, so no seams show
    style.width = `${item.w + 1}px`;
    style.height = `${item.h + 1}px`;
  }
  style.mixBlendMode = item.bl === "ADD" ? "plus-lighter" : item.bl === "MOD" ? "multiply" : "";
  style.filter = item.ds ? (isWhite(item.vc) ? "grayscale(1)" : greyTintFilter(item.vc ?? [])) : "";
  if (item.rot) transform += ` rotate(${-item.rot}rad)`;
  style.transform = transform;
};

/** The atlases a line's HTML marked (data-atlas), their art put in as known */
export const fillInlineAtlases = (element: HTMLElement): void => {
  for (const span of element.querySelectorAll<HTMLElement>("[data-atlas]")) {
    const atlas = getAtlas(span.dataset.atlas ?? "");
    if (atlas)
      setImage(span.style, artUrl(atlas.fdid), [atlas.left, atlas.right, atlas.top, atlas.bottom], null, false);
  }
};

const drawFontString = (item: FontStringItem, element: ItemElement): void => {
  const style = element.style;
  element.className = "fs";
  style.left = `${item.x}px`;
  style.top = `${item.y}px`;
  style.width = `${Math.max(item.w, 1)}px`;
  style.height = `${Math.max(item.h, 1)}px`;
  style.opacity = String(item.a ?? 1);
  style.fontFamily = fontFamily(item.f);
  style.fontSize = `${item.fs}px`;
  style.color = rgba(item.c);
  style.justifyContent = item.jv === "TOP" ? "flex-start" : item.jv === "BOTTOM" ? "flex-end" : "center";
  style.gap = `${item.sp || 0}px`;
  const shadows: string[] = [];
  if (item.sh) shadows.push(`${item.sh[0] ?? 0}px ${-(item.sh[1] ?? 0)}px 0 #000`);
  if (item.fl && /OUTLINE/.test(item.fl)) shadows.push("-1px 0 #000", "1px 0 #000", "0 -1px #000", "0 1px #000");
  style.textShadow = shadows.join(",");
  const align = item.jh === "LEFT" ? "left" : item.jh === "RIGHT" ? "right" : "center";
  const state = { colors: [] };
  let html = "";
  for (const line of item.lines) {
    html += `<div style="height:${item.lh}px;line-height:${item.lh}px;text-align:${align}">${lineToHtml(line, state, item.lh)}</div>`;
  }
  if (element.html !== html) {
    element.innerHTML = html;
    element.html = html;
    fillInlineAtlases(element);
  }
  element.classList.toggle("cursor", item.cursor === true);
};

// A backdrop: the background, tiled or stretched, and the classic eight-piece edge
const EDGE_PIECES = ["left", "right", "top", "bottom", "topLeft", "topRight", "bottomLeft", "bottomRight"] as const;
const EDGE_HTML = `<div class="bg"></div>${EDGE_PIECES.map((name) => `<div class="edge ${name}"><div></div></div>`).join("")}`;

const drawBackdrop = (item: BackdropItem, element: ItemElement): void => {
  const style = element.style;
  element.className = "bd";
  style.left = `${item.x}px`;
  style.top = `${item.y}px`;
  style.width = `${item.w}px`;
  style.height = `${item.h}px`;
  style.opacity = String(item.a ?? 1);
  if (!element.firstChild) element.innerHTML = EDGE_HTML;
  const insets = item.ins ?? {};
  const background = (element.firstChild as HTMLElement).style;
  background.left = `${insets.left || 0}px`;
  background.right = `${insets.right || 0}px`;
  background.top = `${insets.top || 0}px`;
  background.bottom = `${insets.bottom || 0}px`;
  if (item.bg) {
    const isTiled = Boolean(item.tile && item.ts);
    setImage(background, textureUrl(item.bg), null, item.c, isTiled);
    if (isTiled) {
      background.backgroundSize = `${item.ts}px ${item.ts}px`;
      setMaskSize(background, `${item.ts}px ${item.ts}px`);
    }
  } else {
    // No background file: the game draws no background, whatever its colour
    clearPaint(background);
  }
  const edgeSize = Math.min(item.es || 16, item.w / 2, item.h / 2);
  const children = element.children;
  for (let index = 0; index < EDGE_PIECES.length; index++) {
    const name = EDGE_PIECES[index] as (typeof EDGE_PIECES)[number];
    const piece = children[index + 1] as HTMLElement;
    const inner = (piece.firstChild as HTMLElement).style;
    piece.style.display = item.edge ? "" : "none";
    if (!item.edge) continue;
    const isCorner = index >= 4;
    const isHorizontal = name === "top" || name === "bottom";
    const length = isHorizontal ? item.w - 2 * edgeSize : item.h - 2 * edgeSize;
    const isRightSide = name === "right" || name === "topRight" || name === "bottomRight";
    piece.style.width = `${isCorner ? edgeSize : isHorizontal ? length : edgeSize}px`;
    piece.style.height = `${isCorner ? edgeSize : isHorizontal ? edgeSize : length}px`;
    piece.style.left = `${isRightSide ? item.w - edgeSize : isHorizontal ? edgeSize : 0}px`;
    piece.style.top = `${name.startsWith("bottom") ? item.h - edgeSize : name === "left" || name === "right" ? edgeSize : 0}px`;
    piece.style.overflow = "hidden";
    // Each piece is one eighth of the edge file; the top and bottom are stored turned on their side
    inner.position = "absolute";
    inner.width = `${edgeSize}px`;
    inner.height = `${isCorner ? edgeSize : length}px`;
    setImage(inner, textureUrl(item.edge), [index / 8, (index + 1) / 8, 0, 1], item.bc, false);
    if (!isCorner) {
      inner.backgroundSize = `800% ${edgeSize}px`;
      inner.backgroundRepeat = "repeat-y";
      setMaskSize(inner, `800% ${edgeSize}px`);
      setMaskRepeat(inner, "repeat-y");
    }
    if (isHorizontal) {
      inner.left = `${(length - edgeSize) / 2}px`;
      inner.top = `${(edgeSize - length) / 2}px`;
      // Both turned the same way, as Backdrop.lua's coordinates do: the strip's left side ends up at the top
      inner.transform = "rotate(90deg)";
    } else {
      inner.left = "0px";
      inner.top = "0px";
      inner.transform = "";
    }
  }
};

const drawLine = (item: LineItem, element: ItemElement): void => {
  const style = element.style;
  const length = Math.hypot(item.x2 - item.x1, item.y2 - item.y1);
  const angle = Math.atan2(item.y2 - item.y1, item.x2 - item.x1);
  style.left = `${item.x1}px`;
  style.top = `${item.y1 - item.th / 2}px`;
  style.width = `${length}px`;
  style.height = `${item.th}px`;
  style.transformOrigin = `0 ${item.th / 2}px`;
  style.transform = `rotate(${angle}rad)`;
  style.opacity = String(item.a ?? 1);
  if (item.tex) setImage(style, textureUrl(item.tex), null, item.vc, false);
  else {
    style.backgroundImage = "";
    style.backgroundColor = rgba(item.c ?? [1, 1, 1, 1]);
  }
};

const drawItem = (item: SceneItem, element: ItemElement): void => {
  switch (item.k) {
    case "t":
      drawTexture(item, element);
      break;
    case "s":
      drawFontString(item, element);
      break;
    case "b":
      drawBackdrop(item, element);
      break;
    case "ln":
      drawLine(item, element);
      return; // (a line is placed by its ends; no box to clip)
  }
  element.style.display = applyClip(element.style, item) ? "" : "none";
};

/** A renderer drawing into a layer (the live screen's, or one of a picture page's) */
export const createDomRenderer = (layer: HTMLElement): DomRenderer => {
  const pool = new Map<string, ItemElement>();
  let epoch = 0;
  let renderCount = 0;
  const stopAtlases = onAtlasArrived(() => {
    epoch += 1; // (drawn again with it)
  });

  const elementFor = (key: string, kind: string): ItemElement => {
    let element = pool.get(key);
    if (!element || element.kind !== kind) {
      if (element) element.remove();
      element = document.createElement("div") as ItemElement;
      element.kind = kind;
      element.dataset.kind = kind;
      pool.set(key, element);
    }
    return element;
  };

  const render = (items: SceneItems): void => {
    renderCount += 1;
    for (let index = 0; index < items.length; index++) {
      const item = items[index];
      if (!item) continue;
      const element = elementFor(itemKey(item), item.k);
      element.seenAt = renderCount;
      // Drawn again only when it changed (or art it waits on arrived): every style set costs the browser, though the
      // value be the same, and most of the screen stays as it was from one frame to the next. The same object is
      // the same item (scene.ts); another with the same text is too.
      if (element.drawnItem !== item || element.drawnEpoch !== epoch) {
        const signature = JSON.stringify(item);
        if (element.drawnAs !== signature || element.drawnEpoch !== epoch) {
          drawItem(item, element);
          element.drawnAs = signature;
        }
        element.drawnItem = item;
        element.drawnEpoch = epoch;
      }
      if (element.drawnIndex !== index) {
        element.style.zIndex = String(index);
        element.drawnIndex = index;
      }
      if (element.parentNode !== layer) layer.appendChild(element);
    }
    for (const [key, element] of pool) {
      if (element.seenAt !== renderCount) {
        element.remove();
        pool.delete(key);
      }
    }
  };

  return {
    render,
    invalidate: () => {
      epoch += 1;
    },
    dispose: () => {
      stopAtlases();
      for (const element of pool.values()) element.remove();
      pool.clear();
    },
  };
};
