// Walking about without the keyboard: a step ahead or back, a turn either way, auto-run, stop, walking pace; and how
// the character moves now
import {
  ArrowRotateLeft,
  ArrowRotateRight,
  ArrowShapeDown,
  ArrowShapeUp,
  Compass,
  PersonWorker,
  StopFill,
} from "@gravity-ui/icons";
import { Button, ButtonGroup, Chip, Kbd, Tooltip } from "@heroui/react";
import type { ReactNode } from "react";
import { SwitchRow } from "../../components/bits.tsx";
import { Section } from "../../components/Section.tsx";
import type { GameAction } from "../../sim/api.ts";
import { useGameAction, useSimState } from "../../sim/hooks.ts";
import type { Movement } from "../../sim/types.ts";

const STANDING: Movement = { speed: 0, isWalking: false, isAutoRunning: false, isMoving: false };

const Key = ({ children }: { children: string }) => (
  <Kbd className="text-[10px]">
    <Kbd.Content>{children}</Kbd.Content>
  </Kbd>
);

const describe = (move: Movement): string =>
  !move.isMoving
    ? "standing"
    : `${move.isWalking ? "walking" : "running"} ${move.speed} yd/s${move.isAutoRunning ? " · auto-run" : ""}${
        move.distanceToTarget !== undefined && move.distanceToTarget !== null
          ? ` · ${move.distanceToTarget} yd to go`
          : ""
      }`;

export const MovingSection = () => {
  const movement = useSimState((state) => state.movement, STANDING);
  const facing = useSimState((state) => state.facing, 0);
  const action = useGameAction();
  const step = (label: string, icon: ReactNode, change: GameAction, tip: string) => (
    <Tooltip delay={300}>
      <Button size="sm" variant="tertiary" aria-label={label} onPress={() => void action.run(change)}>
        {icon}
        {label.length < 9 ? label : null}
      </Button>
      <Tooltip.Content>{tip}</Tooltip.Content>
    </Tooltip>
  );

  return (
    <Section
      title="Moving"
      icon={<PersonWorker className="size-3.5" />}
      actions={
        <Chip size="sm" variant="soft" color={movement.isMoving ? "success" : "default"}>
          {describe(movement)}
        </Chip>
      }
    >
      <p className="text-xs leading-relaxed text-muted">
        Click the game, then hold <Key>W</Key> <Key>A</Key> <Key>S</Key> <Key>D</Key> (<Key>Q</Key> <Key>E</Key> to
        strafe), as in the game; <Key>Num Lock</Key> runs on its own.
      </p>
      <div className="flex flex-wrap items-center gap-2">
        <ButtonGroup size="sm" variant="tertiary">
          {step("Turn left 15°", <ArrowRotateLeft />, { action: "turn", degrees: 15 }, "Turn left 15°")}
          {step("Forward", <ArrowShapeUp />, { action: "walk", forward: 8 }, "A step of 8 yards ahead")}
          {step("Back", <ArrowShapeDown />, { action: "walk", forward: -4 }, "A step of 4 yards back")}
          {step("Turn right 15°", <ArrowRotateRight />, { action: "turn", degrees: -15 }, "Turn right 15°")}
        </ButtonGroup>
        <span className="inline-flex items-center gap-1 text-xs text-muted">
          <Compass className="size-3.5" style={{ transform: `rotate(${-facing}deg)` }} />
          facing {facing}°
        </span>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <Button
          size="sm"
          variant={movement.isAutoRunning ? "primary" : "secondary"}
          onPress={() => void action.run({ action: "autoRun" })}
        >
          Auto-run
        </Button>
        <Button size="sm" variant="secondary" onPress={() => void action.run({ action: "stopMoving" })}>
          <StopFill />
          Stop
        </Button>
      </div>
      <SwitchRow
        label="Walk"
        description="2.5 yards a second instead of running at 7 (Numpad /)"
        isSelected={movement.isWalking}
        onChange={(isOn) => void action.run({ action: "walkMode", isWalking: isOn })}
      />
    </Section>
  );
};
