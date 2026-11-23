// The game's screen: its resolution (the interface lays out as on a screen of that size and shape) and its UI Scale
// setting (off: drawn pixel for pixel, as the game does by default); and how large the page draws it (zoom). Used by
// the View panel and the header's chip.
import { Description, Header, Label, ListBox, Select, Slider, ToggleButton, ToggleButtonGroup } from "@heroui/react";
import { useEffect, useState } from "react";
import { SwitchRow } from "../../components/bits.tsx";
import type { Magnify } from "../../engine/types.ts";
import { focusGame } from "../../shell/screen.ts";
import { useGameAction, useSimState } from "../../sim/hooks.ts";
import { setPref, usePref } from "../../sim/prefs.ts";
import type { ScreenState } from "../../sim/types.ts";
import { formatSize, SCREEN_GROUPS, UI_SCALE_MARKS, UI_SCALE_MAX, UI_SCALE_MIN } from "./screenSizes.ts";

const DEFAULT_SCREEN: ScreenState = { width: 1366, height: 768 };
const MAGNIFIES: readonly Magnify[] = [1, 2, 3, 4];

const roundScale = (value: number): number => Math.round(value * 100) / 100;

export const ScreenControls = () => {
  const screen = useSimState((state) => state.screen, DEFAULT_SCREEN);
  const magnify = usePref("magnify");
  const action = useGameAction();
  const size = `${screen.width}x${screen.height}`;
  const isListed = SCREEN_GROUPS.some((group) => group.sizes.includes(size));
  // (the slider moves freely; the game is told when it is let go)
  const [scale, setScale] = useState(screen.uiScale ?? 1);
  useEffect(() => setScale(screen.uiScale ?? 1), [screen.uiScale]);

  const apply = async (width: number, height: number, uiScale: number | null): Promise<void> => {
    await action.run({ action: "screen", width, height, ...(uiScale ? { uiScale: roundScale(uiScale) } : {}) });
    focusGame();
  };

  return (
    <div className="flex flex-col gap-4">
      <Select
        value={size}
        onChange={(value) => {
          const [width, height] = String(value).split("x").map(Number);
          if (width && height) void apply(width, height, screen.uiScale ?? null);
        }}
        isDisabled={action.isPending}
      >
        <Label>Resolution</Label>
        <Select.Trigger>
          <Select.Value />
          <Select.Indicator />
        </Select.Trigger>
        <Description className="text-xs">The interface lays out as on a screen of this size and shape</Description>
        <Select.Popover className="max-h-80">
          <ListBox>
            {!isListed && (
              <ListBox.Item id={size} textValue={formatSize(size)}>
                {formatSize(size)} (set by a scenario)
                <ListBox.ItemIndicator />
              </ListBox.Item>
            )}
            {SCREEN_GROUPS.map((group) => (
              <ListBox.Section key={group.shape}>
                <Header>{group.shape}</Header>
                {group.sizes.map((entry) => (
                  <ListBox.Item key={entry} id={entry} textValue={formatSize(entry)}>
                    {formatSize(entry)}
                    <ListBox.ItemIndicator />
                  </ListBox.Item>
                ))}
              </ListBox.Section>
            ))}
          </ListBox>
        </Select.Popover>
      </Select>

      <div className="flex flex-col gap-2">
        <SwitchRow
          label="UI scale"
          description="Off: drawn pixel for pixel (the game's default), so the interface is smaller on a larger screen"
          isSelected={Boolean(screen.uiScale)}
          onChange={(isOn) => void apply(screen.width, screen.height, isOn ? scale : null)}
          isDisabled={action.isPending}
        />
        {screen.uiScale ? (
          <Slider
            aria-label="UI scale"
            minValue={UI_SCALE_MIN}
            maxValue={UI_SCALE_MAX}
            step={0.01}
            value={scale}
            onChange={(value) => setScale(Array.isArray(value) ? (value[0] ?? 1) : value)}
            onChangeEnd={(value) =>
              void apply(screen.width, screen.height, Array.isArray(value) ? (value[0] ?? 1) : value)
            }
            className="px-1"
          >
            <Slider.Output className="text-xs text-muted">{scale.toFixed(2)}</Slider.Output>
            <Slider.Track>
              <Slider.Fill />
              <Slider.Thumb />
            </Slider.Track>
            <Slider.Marks>
              {UI_SCALE_MARKS.map((mark) => (
                <Slider.Mark key={mark} value={mark}>
                  {mark}
                </Slider.Mark>
              ))}
            </Slider.Marks>
          </Slider>
        ) : null}
      </div>

      <div className="flex flex-col gap-1.5">
        <span className="text-sm font-medium">Zoom</span>
        <ToggleButtonGroup
          aria-label="Zoom"
          selectionMode="single"
          disallowEmptySelection
          size="sm"
          fullWidth
          selectedKeys={[String(magnify)]}
          onSelectionChange={(keys) => {
            const chosen = MAGNIFIES.find((value) => keys.has(String(value)));
            if (chosen) setPref("magnify", chosen);
            focusGame();
          }}
        >
          {MAGNIFIES.map((value, index) => (
            <ToggleButton key={value} id={String(value)}>
              {index > 0 && <ToggleButtonGroup.Separator />}
              {value === 1 ? "Fit" : `${value}×`}
            </ToggleButton>
          ))}
        </ToggleButtonGroup>
        <span className="text-xs text-muted">
          Larger than the window, to look at small things: Alt + wheel or the scroll bars move around
        </span>
      </div>
    </div>
  );
};

/** The header's words for the screen: "1920×1080 · scale 0.8 · 2×" */
export const useScreenSummary = (): string => {
  const screen = useSimState((state) => state.screen, DEFAULT_SCREEN);
  const magnify = usePref("magnify");
  return [
    `${screen.width}×${screen.height}`,
    screen.uiScale ? `scale ${roundScale(screen.uiScale)}` : "",
    magnify > 1 ? `${magnify}×` : "",
  ]
    .filter(Boolean)
    .join(" · ");
};
