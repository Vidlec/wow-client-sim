// The game's sounds on the page, on or off (kept per browser): a quest's narration, the interface's clicks, music
import { VolumeFill, VolumeSlashFill } from "@gravity-ui/icons";
import { Button, Tooltip } from "@heroui/react";
import { useEffect, useState } from "react";
import { isSoundOn, onSoundSwitched, setSoundOn } from "../engine.ts";
import { focusGame } from "../screen.ts";

export const SoundSwitch = () => {
  const [isOn, setIsOn] = useState(isSoundOn);
  useEffect(() => onSoundSwitched(setIsOn), []);
  return (
    <Tooltip delay={400}>
      <Button
        isIconOnly
        size="sm"
        variant="tertiary"
        aria-label={isOn ? "Switch the game's sound off" : "Switch the game's sound on"}
        aria-pressed={isOn}
        onPress={() => {
          setSoundOn(!isOn);
          focusGame();
        }}
      >
        {isOn ? <VolumeFill /> : <VolumeSlashFill />}
      </Button>
      <Tooltip.Content>
        {isOn
          ? "The game's sounds play here, at its own volume settings. Press to mute"
          : "The game's sounds are off. Press to hear them"}
      </Tooltip.Content>
    </Tooltip>
  );
};
