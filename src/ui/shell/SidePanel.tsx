// The side panel: the panel chosen in the rail, under its title, beside the game (its width dragged at its edge) or
// floating over it as a window (dragged by its title, sized by its corner). Panels once opened stay mounted, hidden,
// so what was typed in them is still there when they come back.
import { ChevronsLeft, LayoutSideContentLeft, Picture } from "@gravity-ui/icons";
import { Button, ScrollShadow, Tooltip } from "@heroui/react";
import { type PointerEvent as ReactPointerEvent, useEffect, useRef, useState } from "react";
import { getPrefs, type Place, setPref, usePref } from "../sim/prefs.ts";
import { useIsFullscreen } from "./fullscreen.ts";
import { findPanel, PANELS } from "./panels.tsx";

const MIN_WIDTH = 320;
const MAX_WIDTH = 720;

const PanelBodies = ({ shownId }: { shownId: string }) => {
  const [visited, setVisited] = useState<ReadonlySet<string>>(() => new Set([shownId]));
  useEffect(() => {
    setVisited((before) => (before.has(shownId) ? before : new Set([...before, shownId])));
  }, [shownId]);
  return (
    <>
      {PANELS.filter((panel) => visited.has(panel.id)).map((panel) => (
        <section
          key={panel.id}
          hidden={panel.id !== shownId}
          aria-label={panel.title}
          className="panel-body flex flex-col gap-3"
        >
          <panel.Component />
        </section>
      ))}
    </>
  );
};

const PanelHead = ({
  isFloating,
  onPointerDown,
}: {
  isFloating: boolean;
  onPointerDown?: (event: ReactPointerEvent) => void;
}) => {
  const shown = findPanel(usePref("panel"));
  const isFullscreen = useIsFullscreen();
  return (
    <div
      className={`panel-head flex items-start gap-2 px-4 pt-3 pb-2 ${isFloating ? "cursor-move" : ""}`}
      onPointerDown={onPointerDown}
    >
      <span className="panel-head-icon mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-lg">
        {shown.icon}
      </span>
      <div className="min-w-0 grow">
        <h2 className="text-[15px] font-semibold leading-tight">{shown.title}</h2>
        <p className="truncate text-xs text-muted">{shown.description}</p>
      </div>
      {!isFullscreen && (
        <Tooltip delay={300}>
          <Button
            isIconOnly
            size="sm"
            variant="ghost"
            aria-label={isFloating ? "Dock beside the game" : "Float over the game"}
            onPress={() => setPref("isPanelFloating", !isFloating)}
          >
            {isFloating ? <LayoutSideContentLeft /> : <Picture />}
          </Button>
          <Tooltip.Content>{isFloating ? "Dock beside the game" : "Float over the game, as a window"}</Tooltip.Content>
        </Tooltip>
      )}
      <Tooltip delay={300}>
        <Button
          isIconOnly
          size="sm"
          variant="ghost"
          aria-label="Fold the panel away"
          onPress={() => setPref("isSideCollapsed", true)}
        >
          <ChevronsLeft />
        </Button>
        <Tooltip.Content>Fold the panel away (or press its icon in the rail again)</Tooltip.Content>
      </Tooltip>
    </div>
  );
};

/** Docked beside the game */
export const DockedPanel = () => {
  const shownId = usePref("panel");
  const width = usePref("sideWidth");
  const startResize = (event: ReactPointerEvent<HTMLDivElement>): void => {
    const startX = event.clientX;
    const startWidth = getPrefs().sideWidth;
    const target = event.currentTarget;
    target.setPointerCapture(event.pointerId);
    const move = (moveEvent: PointerEvent): void => {
      setPref(
        "sideWidth",
        Math.round(Math.max(MIN_WIDTH, Math.min(MAX_WIDTH, startWidth + moveEvent.clientX - startX))),
      );
    };
    const stop = (): void => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", stop);
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", stop);
  };
  return (
    <aside className="side-panel relative flex shrink-0 flex-col border-r border-separator" style={{ width }}>
      <PanelHead isFloating={false} />
      <ScrollShadow className="min-h-0 flex-1 px-3 pb-4" hideScrollBar={false}>
        <PanelBodies shownId={shownId} />
      </ScrollShadow>
      <div className="side-resizer" onPointerDown={startResize} aria-hidden="true" />
    </aside>
  );
};

const DEFAULT_PLACE: Place = { left: 16, top: 16, width: 400, height: 560 };

const keepInside = (place: Place, area: DOMRect): Place => ({
  ...place,
  left: Math.max(0, Math.min(place.left, area.width - 120)),
  top: Math.max(0, Math.min(place.top, area.height - 48)),
});

/** Floating over the game, inside the stage */
export const FloatingPanel = () => {
  const shownId = usePref("panel");
  const saved = usePref("floatingPlace") ?? DEFAULT_PLACE;
  const box = useRef<HTMLDivElement>(null);
  const [place, setPlace] = useState<Place>(saved);

  // The size the user gave its corner is kept (CSS resize: both)
  useEffect(() => {
    const element = box.current;
    if (!element) return;
    const observer = new ResizeObserver(() => {
      const width = Math.round(element.offsetWidth);
      const height = Math.round(element.offsetHeight);
      const current = getPrefs().floatingPlace ?? DEFAULT_PLACE;
      if (current.width !== width || current.height !== height) setPref("floatingPlace", { ...current, width, height });
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  const startDrag = (event: ReactPointerEvent): void => {
    if ((event.target as HTMLElement).closest("button")) return;
    const element = box.current;
    const area = element?.parentElement?.getBoundingClientRect();
    if (!element || !area) return;
    const offsetX = event.clientX - element.offsetLeft;
    const offsetY = event.clientY - element.offsetTop;
    let latest = place;
    const move = (moveEvent: PointerEvent): void => {
      latest = keepInside({ ...latest, left: moveEvent.clientX - offsetX, top: moveEvent.clientY - offsetY }, area);
      setPlace(latest);
    };
    const stop = (): void => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", stop);
      setPref("floatingPlace", { ...(getPrefs().floatingPlace ?? DEFAULT_PLACE), left: latest.left, top: latest.top });
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", stop);
  };

  return (
    <div
      ref={box}
      className="floating-panel absolute z-30 flex flex-col overflow-hidden rounded-xl border border-border"
      style={{ left: place.left, top: place.top, width: saved.width ?? 400, height: saved.height ?? 560 }}
    >
      <PanelHead isFloating onPointerDown={startDrag} />
      <ScrollShadow className="min-h-0 flex-1 px-3 pb-4" hideScrollBar={false}>
        <PanelBodies shownId={shownId} />
      </ScrollShadow>
    </div>
  );
};
