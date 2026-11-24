// The View panel: the game's screen and UI scale, the page's zoom, the input (mouse and keyboard or the
// gamepad interface, the virtual pad) and the window (the panel floating over the game, fullscreen)
import { ArrowsExpand, Display, LayoutSideContentLeft } from "@gravity-ui/icons";
import { Button, toast } from "@heroui/react";
import { GamepadIcon, SwitchRow } from "../../components/bits.tsx";
import { Section } from "../../components/Section.tsx";
import { toggleFullscreen, useIsFullscreen } from "../../shell/fullscreen.ts";
import { InputSwitch } from "../../shell/header/InputSwitch.tsx";
import { setPref, usePref } from "../../sim/prefs.ts";
import { ScreenControls } from "./ScreenControls.tsx";

export const ViewPanel = () => {
  const isFloating = usePref("isPanelFloating");
  const isFullscreen = useIsFullscreen();

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
