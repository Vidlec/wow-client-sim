// The minimap: its zoom (and how far it sees), turning with the player, Edit Mode to drag it (the game's own where the
// whole interface runs), and back to its place
import { ArrowUturnCcwLeft, MagnifierMinus, MagnifierPlus, Target } from "@gravity-ui/icons";
import { Button, ButtonGroup } from "@heroui/react";
import { SwitchRow } from "../../components/bits.tsx";
import { Section } from "../../components/Section.tsx";
import { useGameAction, useSimState } from "../../sim/hooks.ts";

export const MinimapSection = () => {
  const zoom = useSimState((state) => state.minimapZoom, 0);
  const radius = useSimState((state) => state.viewRadius, 0);
  const rotate = useSimState((state) => state.rotateMinimap, false);
  const editMode = useSimState((state) => state.editMode, false);
  const action = useGameAction();
  return (
    <Section
      title="Minimap"
      icon={<Target className="size-3.5" />}
      actions={
        <span className="text-xs text-muted">
          zoom {zoom} · {Math.round(radius)} yd to the edge
        </span>
      }
    >
      <div className="flex items-center gap-2">
        <ButtonGroup size="sm" variant="tertiary">
          <Button
            aria-label="Zoom the minimap out: see farther"
            onPress={() => void action.run({ action: "zoom", delta: -1 })}
          >
            <MagnifierMinus />
          </Button>
          <Button
            aria-label="Zoom the minimap in: see closer"
            onPress={() => void action.run({ action: "zoom", delta: 1 })}
          >
            <MagnifierPlus />
          </Button>
        </ButtonGroup>
        <span className="grow" />
        <Button
          size="sm"
          variant="ghost"
          onPress={() => void action.run({ action: "placeMinimap", point: "TOPRIGHT", x: 0, y: 0 })}
        >
          <ArrowUturnCcwLeft />
          Back to its place
        </Button>
      </div>
      <SwitchRow
        label="Rotate with the player"
        description="The rotateMinimap console variable"
        isSelected={rotate}
        onChange={(isOn) => void action.run({ action: "cvar", name: "rotateMinimap", value: isOn ? "1" : "0" })}
      />
      <SwitchRow
        label="Edit Mode"
        description="The game's own: pick a frame and drag it, change its settings, save a layout"
        isSelected={editMode}
        onChange={(isOn) => void action.run({ action: "editMode", isOn })}
      />
      <p className="text-xs text-muted">The wheel over the minimap zooms it, as in the game.</p>
    </Section>
  );
};
