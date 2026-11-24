// The flavour of the game the simulator runs (the setup's choice; Forever until there are others), and lookups the
// panels share: a class's colour and name, a race's faction, the loading screen of a continent
import { useSimState } from "../sim/hooks.ts";
import { FOREVER } from "./forever.ts";
import type { ClassInfo, FactionInfo, Flavour, RaceInfo } from "./types.ts";

export type { ClassInfo, FactionId, Flavour, RaceInfo } from "./types.ts";

const FLAVOURS: Readonly<Record<string, Flavour>> = { [FOREVER.id]: FOREVER };

export const getFlavour = (id: string | undefined): Flavour => (id ? FLAVOURS[id] : undefined) ?? FOREVER;

export const useFlavour = (): Flavour => getFlavour(useSimState((state) => state.config?.flavour, undefined));

const UNKNOWN_CLASS_COLOR = "#9AA3AE";

export const findClass = (flavour: Flavour, file: string): ClassInfo =>
  flavour.classes.find((entry) => entry.file === file) ?? {
    file,
    name: file.charAt(0) + file.slice(1).toLowerCase(),
    color: UNKNOWN_CLASS_COLOR,
  };

export const findRace = (flavour: Flavour, file: string): RaceInfo =>
  flavour.races.find((entry) => entry.file === file) ?? { file, name: file, faction: "Neutral" };

export const findFaction = (flavour: Flavour, name: string | undefined): FactionInfo =>
  flavour.factions[name === "Alliance" || name === "Horde" ? name : "Neutral"];
