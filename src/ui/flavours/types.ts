// What the page needs to know about a flavour of the game to look like it: its classes and their colours, its races
// and factions, item qualities, the gold of its money and quest titles, the loading screens that stand behind the
// interface. Another flavour (Classic, Retail) is one more file like forever.ts.

export type FactionId = "Alliance" | "Horde" | "Neutral";

export type ClassInfo = { file: string; name: string; color: string };
export type RaceInfo = { file: string; name: string; faction: FactionId };
export type FactionInfo = { name: string; color: string };
export type QualityInfo = { name: string; color: string };

/** A picture behind the interface where the game draws its world: the first whose word is in the continent's name */
export type LoadingScreen = { continentMatch: string; fileId: number };

export type Flavour = {
  id: string;
  /** As the game calls itself: "WoW: Forever" */
  clientName: string;
  /** A word for the header's badge: "Forever" */
  shortName: string;
  maxLevel: number;
  classes: readonly ClassInfo[];
  races: readonly RaceInfo[];
  factions: Readonly<Record<FactionId, FactionInfo>>;
  /** By the game's quality index: 0 poor, 1 common, 2 uncommon, 3 rare, 4 epic, 5 legendary… */
  qualities: readonly QualityInfo[];
  colors: {
    /** The game's gold: headings, quest titles (NORMAL_FONT_COLOR) */
    gold: string;
    /** Highlight text (HIGHLIGHT_FONT_COLOR) */
    highlight: string;
    money: { gold: string; silver: string; copper: string };
    /** The page's accent, where it takes the flavour's tint */
    accent: string;
  };
  loadingScreens: readonly LoadingScreen[];
  /** The kinds of instance the game knows, as GetInstanceInfo names them */
  instanceTypes: readonly { id: string; name: string }[];
};
