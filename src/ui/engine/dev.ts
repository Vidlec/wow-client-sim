// The engine alone in the window (dev.html): a picture page when the address asks for one, else the live game screen,
// left on window.gameScreen for the console
import { createGameScreen, type GameScreen } from "./index.ts";
import { runPicturePage } from "./picture.ts";

declare global {
  interface Window {
    gameScreen?: GameScreen;
  }
}

const root = document.getElementById("root");
if (root && !runPicturePage(root)) {
  const screen = createGameScreen(root);
  window.gameScreen = screen;
  screen.onStatus((status) => {
    if (status.error) console.warn("AddonSim:", status.error);
  });
  // The world behind, as the page shows it by default
  void fetch("/api/state")
    .then((response) => response.json() as Promise<{ profile?: { uiMapId?: number } }>)
    .then((state) => screen.setWorldBackdrop(state.profile?.uiMapId ?? null));
}
