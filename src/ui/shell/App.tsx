// The page: the first setup when the server needs one, else the header, the rail, the side panel, the game and the
// strip under it; the virtual pad and the toasts over everything
import { Toast } from "@heroui/react";
import { useEffect, useState } from "react";
import { SetupFlow } from "../panels/setup/SetupFlow.tsx";
import { useStoreStatus } from "../sim/hooks.ts";
import { usePref } from "../sim/prefs.ts";
import { useSetupWanted } from "../sim/setup.ts";
import { startPolling } from "../sim/store.ts";
import { useIsFullscreen } from "./fullscreen.ts";
import { GameView } from "./GameView.tsx";
import { Header } from "./header/Header.tsx";
import { readDeepLink } from "./navigation.ts";
import { PANEL_IDS } from "./panels.tsx";
import { Rail } from "./Rail.tsx";
import { DockedPanel, FloatingPanel } from "./SidePanel.tsx";
import { StatusStrip } from "./StatusStrip.tsx";
import { VirtualPad } from "./VirtualPad.tsx";

const Shell = () => {
  const isCollapsed = usePref("isSideCollapsed");
  const isFloatingChosen = usePref("isPanelFloating");
  const isFullscreen = useIsFullscreen();
  const isFloating = isFloatingChosen || isFullscreen;
  return (
    <div className="app-shell flex h-screen flex-col overflow-hidden">
      <Header />
      <div className="flex min-h-0 flex-1">
        <Rail />
        {!isFloating && !isCollapsed && <DockedPanel />}
        <main className="stage relative flex min-w-0 flex-1 flex-col">
          <GameView />
          <StatusStrip />
          {isFloating && !isCollapsed && <FloatingPanel />}
        </main>
      </div>
      <VirtualPad />
    </div>
  );
};

export const App = () => {
  const { problem } = useStoreStatus();
  // (once shown, the setup stays until the user steps into the game: it does not vanish under them as it completes)
  const [isInSetup, setInSetup] = useState(false);
  useEffect(() => {
    readDeepLink(PANEL_IDS);
    startPolling();
  }, []);
  useEffect(() => {
    if (problem?.setupNeeded) setInSetup(true);
  }, [problem?.setupNeeded]);
  // (asked for by a reset in the settings: a fresh setup, walked through again)
  const setupWanted = useSetupWanted();
  useEffect(() => {
    if (!setupWanted.isWanted) return;
    setInSetup(true);
    setupWanted.take();
  }, [setupWanted]);
  return (
    <>
      {isInSetup || problem?.setupNeeded ? <SetupFlow onEnter={() => setInSetup(false)} /> : <Shell />}
      <Toast.Provider placement="bottom end" />
    </>
  );
};
