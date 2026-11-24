// The addons a party member may run, as the simulator lists them (/api/state partyAddons): whatever the served
// project's plugins register (lua/plugins.lua). Nothing is known of them here but what they say.
import { useSimState } from "../../sim/hooks.ts";
import type { PartyAddon } from "../../sim/types.ts";

export const NO_ADDON: PartyAddon = {
  id: "none",
  label: "No addon",
  note: "Only what the game itself shares",
  color: "default",
  isDefault: true,
};

const ONLY_NONE: PartyAddon[] = [NO_ADDON];

export const usePartyAddons = (): PartyAddon[] =>
  useSimState(
    (state) => (state.partyAddons && state.partyAddons.length > 0 ? state.partyAddons : ONLY_NONE),
    ONLY_NONE,
  );

/** A member's addon as listed; one no longer registered keeps its name */
export const findPartyAddon = (addons: readonly PartyAddon[], id: string): PartyAddon =>
  addons.find((addon) => addon.id === id) ?? (id === "none" ? NO_ADDON : { ...NO_ADDON, id, label: id, note: "" });
