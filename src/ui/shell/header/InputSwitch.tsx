// The game's interface for mouse and keyboard or for a gamepad (its action bars, radial menu, cursor in windows), kept
// between runs; beside it the virtual pad, a controller drawn on the page. Opening the pad brings the gamepad interface:
// with mouse and keyboard the game binds no pad buttons.
import { Keyboard } from "@gravity-ui/icons";
import { ToggleButton, ToggleButtonGroup, Tooltip } from "@heroui/react";
import { GamepadIcon } from "../../components/bits.tsx";
import { useGameAction, useSimState } from "../../sim/hooks.ts";
import { setPref, usePref } from "../../sim/prefs.ts";
import { focusGame, useConnectedPad } from "../screen.ts";

export const useInputStyle = (): { style: 0 | 1; setStyle: (style: 0 | 1) => Promise<void>; isPending: boolean } => {
  const style = useSimState((state) => (state.gamepad?.style === 1 ? 1 : 0), 0);
  const action = useGameAction();
  const setStyle = async (next: 0 | 1): Promise<void> => {
    await action.run({ action: "interfaceStyle", style: next });
    focusGame();
  };
  return { style, setStyle, isPending: action.isPending };
};

export const InputSwitch = () => {
  const { style, setStyle, isPending } = useInputStyle();
  const isPadOpen = usePref("isVirtualPadOpen");
  const pad = useConnectedPad();

  return (
    <div className="flex items-center gap-1.5">
      <ToggleButtonGroup
        aria-label="The game's interface"
        selectionMode="single"
        disallowEmptySelection
        size="sm"
        isDisabled={isPending}
        selectedKeys={[style === 1 ? "gamepad" : "keyboard"]}
        onSelectionChange={(keys) => void setStyle(keys.has("gamepad") ? 1 : 0)}
        className="input-switch"
      >
        <Tooltip delay={300}>
          <ToggleButton id="keyboard" aria-label="Mouse and keyboard interface">
            <Keyboard />
            <span className="hidden 2xl:inline">Keyboard</span>
          </ToggleButton>
          <Tooltip.Content>The game's interface for mouse and keyboard</Tooltip.Content>
        </Tooltip>
        <Tooltip delay={300}>
          <ToggleButton id="gamepad" aria-label="Gamepad interface">
            <ToggleButtonGroup.Separator />
            <GamepadIcon />
            <span className="hidden 2xl:inline">Gamepad</span>
          </ToggleButton>
          <Tooltip.Content>
            The game's gamepad interface: its action bars, the radial menu (Start), the cursor in windows (d-pad, A, B).
            A controller plugged in plays the game either way.
          </Tooltip.Content>
        </Tooltip>
      </ToggleButtonGroup>
      <Tooltip delay={300}>
        <ToggleButton
          size="sm"
          isSelected={isPadOpen}
          onChange={(isOpen) => {
            setPref("isVirtualPadOpen", isOpen);
            if (isOpen && style !== 1) void setStyle(1);
          }}
          aria-label="Virtual gamepad"
        >
          <GamepadIcon />
          Pad
        </ToggleButton>
        <Tooltip.Content>
          A gamepad drawn on the page: click its buttons, drag its sticks (Shift-click or right-click holds a button)
        </Tooltip.Content>
      </Tooltip>
      {pad && (
        <Tooltip delay={300}>
          <span className="pad-connected flex size-7 items-center justify-center rounded-full bg-success-soft text-success">
            <GamepadIcon />
          </span>
          <Tooltip.Content>
            {pad.id}: its buttons and sticks play the game while this page has the focus
          </Tooltip.Content>
        </Tooltip>
      )}
    </div>
  );
};
