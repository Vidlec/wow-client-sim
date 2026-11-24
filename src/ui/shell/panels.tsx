// Every panel of the side: its id (the rail's, ?tab='s and the remembered one), title, icon, what it is for, and the
// count its icon carries
import {
  Code,
  CurlyBrackets,
  Gear,
  Globe,
  Layers,
  ListCheck,
  Person,
  Persons,
  Sliders,
  TargetDart,
  Thunderbolt,
  TriangleExclamation,
} from "@gravity-ui/icons";
import type { ComponentType, ReactNode } from "react";
import { AddonsPanel } from "../panels/addons/AddonsPanel.tsx";
import { CharacterPanel } from "../panels/character/CharacterPanel.tsx";
import { CombatPanel } from "../panels/combat/CombatPanel.tsx";
import { ConsolePanel } from "../panels/console/ConsolePanel.tsx";
import { ErrorsPanel } from "../panels/errors/ErrorsPanel.tsx";
import { EventsPanel } from "../panels/events/EventsPanel.tsx";
import { InspectPanel } from "../panels/inspect/InspectPanel.tsx";
import { PartyPanel } from "../panels/party/PartyPanel.tsx";
import { QuestsPanel } from "../panels/quests/QuestsPanel.tsx";
import { SettingsPanel } from "../panels/setup/SettingsPanel.tsx";
import { ViewPanel } from "../panels/view/ViewPanel.tsx";
import { WorldPanel } from "../panels/world/WorldPanel.tsx";
import { useEventHistory, useSimState } from "../sim/hooks.ts";

export type PanelCount = { value: number; tone: "accent" | "danger" | "default" };

export type PanelInfo = {
  id: string;
  title: string;
  /** A line under the title: what the panel is for */
  description: string;
  icon: ReactNode;
  group: "game" | "develop" | "page";
  Component: ComponentType;
  useCount?: () => PanelCount | null;
};

const count = (value: number, tone: PanelCount["tone"] = "default"): PanelCount | null =>
  value > 0 ? { value, tone } : null;

export const PANELS: readonly PanelInfo[] = [
  {
    id: "character",
    title: "Character",
    description: "Who you play, and what the game tells addons about them",
    icon: <Person />,
    group: "game",
    Component: CharacterPanel,
  },
  {
    id: "world",
    title: "World",
    description: "Where you stand, walking, the minimap and instances",
    icon: <Globe />,
    group: "game",
    Component: WorldPanel,
  },
  {
    id: "quests",
    title: "Quests",
    description: "Find quests and givers, and move your log along",
    icon: <ListCheck />,
    group: "game",
    Component: QuestsPanel,
    useCount: () =>
      count(
        useSimState((state) => state.questLog.length, 0),
        "accent",
      ),
  },
  {
    id: "party",
    title: "Party",
    description: "Simulated players in your group, and their addons",
    icon: <Persons />,
    group: "game",
    Component: PartyPanel,
    useCount: () => count(useSimState((state) => state.party.length, 0)),
  },
  {
    id: "combat",
    title: "Combat",
    description: "Enemies to fight: their plates, health, threat and the combat log",
    icon: <TargetDart />,
    group: "game",
    Component: CombatPanel,
    useCount: () =>
      count(
        useSimState((state) => state.combat?.enemies.filter((enemy) => !enemy.isDead).length ?? 0, 0),
        "danger",
      ),
  },
  {
    id: "addons",
    title: "Addons",
    description: "Your addons on and off, their saved variables, the game's own",
    icon: <Layers />,
    group: "develop",
    Component: AddonsPanel,
    useCount: () =>
      count(
        useSimState(
          (state) => state.addons.filter((addon) => addon.loaded && !addon.name.startsWith("Blizzard_")).length,
          0,
        ),
      ),
  },
  {
    id: "inspect",
    title: "Inspect",
    description: "The frames under the mouse, as /fstack, and each one's details",
    icon: <CurlyBrackets />,
    group: "develop",
    Component: InspectPanel,
  },
  {
    id: "events",
    title: "Events",
    description: "Every event the game fired, and firing one by hand",
    icon: <Thunderbolt />,
    group: "develop",
    Component: EventsPanel,
    useCount: () => count(useEventHistory().length),
  },
  {
    id: "errors",
    title: "Errors",
    description: "Lua errors with where they came from, and what the simulator only pretends",
    icon: <TriangleExclamation />,
    group: "develop",
    Component: ErrorsPanel,
    useCount: () =>
      count(
        useSimState((state) => state.errors.length, 0),
        "danger",
      ),
  },
  {
    id: "console",
    title: "Console",
    description: "Lua in the game's global scope, and the chat",
    icon: <Code />,
    group: "develop",
    Component: ConsolePanel,
  },
  {
    id: "view",
    title: "View",
    description: "Screen, UI scale, zoom and input",
    icon: <Sliders />,
    group: "page",
    Component: ViewPanel,
  },
  {
    id: "settings",
    title: "Settings",
    description: "The game flavour, your AddOns folder, the interface source and LuaJIT",
    icon: <Gear />,
    group: "page",
    Component: SettingsPanel,
  },
];

export const PANEL_IDS: readonly string[] = PANELS.map((panel) => panel.id);

export const findPanel = (id: string): PanelInfo => PANELS.find((panel) => panel.id === id) ?? (PANELS[0] as PanelInfo);
