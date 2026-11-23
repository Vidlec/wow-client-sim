// The game's clock: paused or running, and how fast it runs; reloading the addons (as /reload), by hand or whenever
// one of their files is saved
import { ArrowRotateRight, Pause, Play } from "@gravity-ui/icons";
import { Button, Label, ListBox, Select, Switch, Tooltip, toast } from "@heroui/react";
import { api } from "../../sim/api.ts";
import { useSimState, useTask } from "../../sim/hooks.ts";
import { focusGame, requestWholeScene } from "../screen.ts";

const SPEEDS = [
  { value: 0.25, label: "¼×" },
  { value: 0.5, label: "½×" },
  { value: 1, label: "1×" },
  { value: 2, label: "2×" },
  { value: 5, label: "5×" },
] as const;

export const ClockControls = () => {
  const paused = useSimState((state) => state.paused, false);
  const speed = useSimState((state) => state.speed, 1);
  const autoReload = useSimState((state) => state.autoReload, false);
  const settings = useTask(api.settings);
  const reload = useTask(async () => {
    const answer = await api.reload();
    requestWholeScene();
    if (answer.error) toast.danger("The reload failed", { description: answer.error });
    else
      toast.success("Reloaded", {
        description: `The addons started again in ${answer.bootSeconds?.toFixed(2) ?? "?"} s`,
      });
    return answer;
  });
  const speedKey = SPEEDS.find((entry) => entry.value === speed)?.value ?? 1;

  return (
    <div className="flex items-center gap-1.5">
      <Tooltip delay={400}>
        <Button
          isIconOnly
          size="sm"
          variant={paused ? "primary" : "tertiary"}
          aria-label={paused ? "Run the game's clock" : "Pause the game's clock"}
          aria-pressed={paused}
          onPress={() => void settings.run({ paused: !paused })}
          className={paused ? "pulse-ring" : ""}
        >
          {paused ? <Play /> : <Pause />}
        </Button>
        <Tooltip.Content>
          {paused ? "Paused: events, timers and movement wait. Press to run" : "Stop the game's clock"}
        </Tooltip.Content>
      </Tooltip>
      <Select
        aria-label="Speed of the game's clock"
        value={String(speedKey)}
        onChange={(value) => {
          void settings.run({ speed: Number(value) || 1 });
          focusGame();
        }}
        className="w-[4.5rem]"
        variant="secondary"
      >
        <Select.Trigger className="h-8 min-h-8">
          <Select.Value />
          <Select.Indicator />
        </Select.Trigger>
        <Select.Popover>
          <ListBox>
            {SPEEDS.map((entry) => (
              <ListBox.Item key={entry.value} id={String(entry.value)} textValue={entry.label}>
                {entry.label}
                <ListBox.ItemIndicator />
              </ListBox.Item>
            ))}
          </ListBox>
        </Select.Popover>
      </Select>
      <Tooltip delay={400}>
        <Button
          size="sm"
          variant="tertiary"
          className="ml-1"
          isPending={reload.isPending}
          onPress={() => void reload.run()}
        >
          <ArrowRotateRight />
          Reload
        </Button>
        <Tooltip.Content>Save the variables and reload, as /reload</Tooltip.Content>
      </Tooltip>
      <Tooltip delay={400}>
        <Switch size="sm" isSelected={autoReload} onChange={(isOn) => void settings.run({ autoReload: isOn })}>
          <Switch.Content>
            <Switch.Control>
              <Switch.Thumb />
            </Switch.Control>
            <Label className="text-xs whitespace-nowrap text-muted">on save</Label>
          </Switch.Content>
        </Switch>
        <Tooltip.Content>Reload the addons whenever one of their files is saved</Tooltip.Content>
      </Tooltip>
    </div>
  );
};
