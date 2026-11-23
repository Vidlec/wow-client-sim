// The page: a picture page (?shot=, ?compare=: a saved scene drawn once, nothing live) or the simulator's shell, in
// React with HeroUI
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./shell/App.tsx";
import { runPicturePage } from "./shell/engine.ts";

const root = document.getElementById("root");
if (root && !runPicturePage(root)) {
  createRoot(root).render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
}
