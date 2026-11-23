// Bringing a creature into the fight from elsewhere (a quest's objective): the battle simulator's spawn, ahead of the
// player where the camera sees it, and a toast that leads to the Combat panel

import { Skull } from "@gravity-ui/icons";
import { toast } from "@heroui/react";
import { createElement } from "react";
import { showPanel } from "../../shell/navigation.ts";
import type { GameAction } from "../../sim/api.ts";

/** Close enough to be in nameplate range and to come at once, far enough for a pull */
export const QUEST_SPAWN_DISTANCE = 20;

export const bringAction = (npcId: number, count: number): GameAction => ({
  action: "combatSpawn",
  npcId,
  count,
  distance: QUEST_SPAWN_DISTANCE,
});

/** The toast once they are here */
export const announceBrought = (name: string, count: number): void => {
  const id = toast(`${count === 1 ? name : `${count} × ${name}`} ${count === 1 ? "is" : "are"} here`, {
    description: `${QUEST_SPAWN_DISTANCE} yards ahead. V on the game shows or hides enemy nameplates.`,
    indicator: createElement(Skull),
    actionProps: {
      children: "Open Combat",
      variant: "tertiary",
      onPress: () => {
        showPanel("combat");
        toast.close(id);
      },
    },
  });
};
