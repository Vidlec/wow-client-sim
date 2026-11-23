// The View panel: the game's screen and UI scale, the page's zoom and renderer, the input (mouse and keyboard or the
// gamepad interface, the virtual pad) and the window (the panel floating over the game, fullscreen)
import { ArrowsExpand, Display, Gpu, LayoutSideContentLeft } from "@gravity-ui/icons";
import { Button, ToggleButton, ToggleButtonGroup, toast } from "@heroui/react";
import { GamepadIcon, SwitchRow } from "../../components/bits.tsx";
import { Section } from "../../components/Section.tsx";
import type { Renderer } from "../../engine/types.ts";
import { toggleFullscreen, useIsFullscreen } from "../../shell/fullscreen.ts";
import { InputSwitch } from "../../shell/header/InputSwitch.tsx";
import { focusGame, useDrawStats } from "../../shell/screen.ts";
import { setPref, usePref } from "../../sim/prefs.ts";
import { ScreenControls } from "./ScreenControls.tsx";

const RENDERERS: readonly { id: Renderer; label: string; note: string }[] = [
  { id: "gl", label: "GPU (WebGL2)", note: "Every item a few quads in one buffer: fast, the default" },
  {
    id: "dom",
    label: "Page elements",
    note: "As the picture pages draw: slower, easy to look into with the browser's tools",
  },
];

export const ViewPanel = () => {
  const renderer = usePref("renderer");
  const isFloating = usePref("isPanelFloating");
  const isFullscreen = useIsFullscreen();
  const stats = useDrawStats();

  return (
    <div className="flex flex-col gap-3">
      <Section title="Screen" icon={<Display className="size-3.5" />}>
        <ScreenControls />
      </Section>

      <Section
        title="Input"
        icon={<GamepadIcon className="size-3.5" />}
        description="Mouse and keyboard, or the game's gamepad interface. A controller plugged in plays the game while the page has the focus (press a button once if the browser has not shown it yet)."
      >
        <InputSwitch />
      </Section>

      <Section
        title="Renderer"
        icon={<Gpu className="size-3.5" />}
        description={
          stats
            ? `Now: ${stats.renderer === "gl" ? "GPU" : "page elements"}, ${stats.drawMs.toFixed(1)} ms a draw`
            : undefined
        }
      >
        <ToggleButtonGroup
          aria-label="Renderer"
          selectionMode="single"
          disallowEmptySelection
          size="sm"
          fullWidth
          selectedKeys={[renderer]}
          onSelectionChange={(keys) => {
            const chosen = RENDERERS.find((entry) => keys.has(entry.id));
            if (chosen) setPref("renderer", chosen.id);
            focusGame();
          }}
        >
          {RENDERERS.map((entry, index) => (
            <ToggleButton key={entry.id} id={entry.id}>
              {index > 0 && <ToggleButtonGroup.Separator />}
              {entry.label}
            </ToggleButton>
          ))}
        </ToggleButtonGroup>
        <p className="text-xs text-muted">{RENDERERS.find((entry) => entry.id === renderer)?.note}</p>
      </Section>

      <Section title="Window" icon={<LayoutSideContentLeft className="size-3.5" />}>
        <SwitchRow
          label="Float this panel over the game"
          description="A window you drag by its title and size by its corner; the game takes the whole width"
          isSelected={isFloating}
          onChange={(isOn) => setPref("isPanelFloating", isOn)}
        />
        <Button
          size="sm"
          variant="secondary"
          onPress={async () => {
            if (!(await toggleFullscreen())) toast.warning("The browser refused fullscreen");
          }}
        >
          <ArrowsExpand />
          {isFullscreen ? "Leave fullscreen" : "Fullscreen"}
        </Button>
      </Section>
    </div>
  );
};
