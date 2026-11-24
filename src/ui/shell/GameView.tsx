// The game screen in the page: the engine mounted in a div, fitted again whenever its room changes, told the page's
// choices (zoom, the world's backdrop, the inspector), and its socket's news passed to the store (a new run,
// a new error or chat line: the state is read again at once)
import { useEffect, useRef } from "react";
import type { StreamStatus } from "../engine/types.ts";
import { useSimState } from "../sim/hooks.ts";
import { getPrefs, usePref } from "../sim/prefs.ts";
import { refreshState } from "../sim/store.ts";
import { createGameScreen } from "./engine.ts";
import { setGameScreen, setStreamHealth, useGameScreen } from "./screen.ts";

const isNews = (before: StreamStatus | null, now: StreamStatus): boolean =>
  !before ||
  before.generation !== now.generation ||
  before.errors !== now.errors ||
  before.chat !== now.chat ||
  before.isConnected !== now.isConnected;

export const GameView = () => {
  const container = useRef<HTMLDivElement>(null);
  const screen = useGameScreen();
  const magnify = usePref("magnify");
  const isBackdropOn = usePref("worldBackdrop");
  const inspectOn = usePref("inspectOn");
  const inspectHeld = usePref("inspectHeld");
  const inspectDrawnOnly = usePref("inspectDrawnOnly");
  const uiMapId = useSimState((state) => state.profile.uiMapId, null);

  useEffect(() => {
    const element = container.current;
    if (!element) return;
    const created = createGameScreen(element, { magnify: getPrefs().magnify });
    setGameScreen(created);
    let last: StreamStatus | null = null;
    const stopStatus = created.onStatus((status) => {
      if (isNews(last, status)) void refreshState();
      setStreamHealth({ isConnected: status.isConnected, error: status.error });
      last = status;
    });
    const observer = new ResizeObserver(() => created.fit());
    observer.observe(element);
    created.focus();
    return () => {
      observer.disconnect();
      stopStatus();
      setGameScreen(null);
      created.destroy();
    };
  }, []);

  useEffect(() => screen?.setMagnify(magnify), [screen, magnify]);
  useEffect(() => screen?.setWorldBackdrop(isBackdropOn ? uiMapId : null), [screen, isBackdropOn, uiMapId]);
  useEffect(
    () => screen?.setInspect({ isOn: inspectOn, isHeld: inspectHeld, isDrawnOnly: inspectDrawnOnly }),
    [screen, inspectOn, inspectHeld, inspectDrawnOnly],
  );

  return <div ref={container} className="game-view relative min-h-0 min-w-0 flex-1 overflow-hidden bg-[#07080a]" />;
};
