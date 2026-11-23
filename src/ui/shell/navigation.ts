// Which panel the side shows, and whether it is folded away: the rail, the header's buttons and links inside the
// panels all go through here
import { getPrefs, setPref } from "../sim/prefs.ts";

export const showPanel = (id: string): void => {
  setPref("panel", id);
  setPref("isSideCollapsed", false);
};

/** The rail's click: another panel opens; the one shown folds the side away (the game gets the room) */
export const togglePanel = (id: string): void => {
  const { panel, isSideCollapsed, isPanelFloating } = getPrefs();
  if (panel === id && !isSideCollapsed && !isPanelFloating) setPref("isSideCollapsed", true);
  else showPanel(id);
};

/** ?tab=addons (or any panel's id): the page opens on that panel, for a link straight to it */
export const readDeepLink = (knownIds: readonly string[]): void => {
  const wanted = new URLSearchParams(location.search).get("tab");
  if (wanted && knownIds.includes(wanted)) showPanel(wanted);
};
