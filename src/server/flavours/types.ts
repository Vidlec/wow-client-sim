// What makes one WoW client different from another, for the simulator: the client's version and build, where its art
// and tables come from, how it reads addons' TOCs, how it names its atlases, where its interface source lives, where
// the game installs it. A new client (Classic, Retail) is one more file beside forever.ts, listed in index.ts.

export type Flavour = {
  /** Short and stable: settings keep it ("forever") */
  id: string;
  name: string;
  description: string;
  client: {
    /** GetBuildInfo's version ("1.60.1") */
    version: string;
    /** GetBuildInfo's build number ("71037") */
    buildNumber: string;
    /** GetBuildInfo's date */
    buildDate: string;
    /** GetBuildInfo's interface number, as addons' TOCs give it (16001) */
    interface: number;
    /** WOW_PROJECT_ID */
    projectId: number;
  };
  /** The build string wago.tools knows the client's files and tables by ("1.60.1.71037") */
  wagoBuild: string;
  /** Blizzard's product code for the client ("wowf"): its patch server's and wago.tools' name for its builds */
  product: string;
  /** The interface source's game types, family and game: which lines of the game's TOCs and Startup.lua load */
  gameTypes: string[];
  family: string;
  game: string;
  /** Which TOC an addon is read from, in order (the plain one last) */
  tocSuffixes: string[];
  /** The same for the game's own addons in the interface source */
  interfaceTocSuffixes: string[];
  /** wowless's product name for the client (its data about the client's API, fetched as the simulator first starts) */
  wowlessProduct: string;
  /** The wowless commit whose data the simulator is known to work with (bun run wowless fetches a newer one) */
  wowlessRef: string;
  /**
   * The atlas variant the client swaps in for a plain name where the variant exists ("-c60": Forever answers
   * "common-stat-bar-BG" with "common-stat-bar-BG-c60", and does not know "-c60" names themselves); null for none
   */
  atlasVariant: string | null;
  /** The game's interface code: a GitHub repository's branch (Gethe/wow-ui-source keeps one per client) */
  interfaceSource: { repository: string; branch: string };
  /** The folder the game installs this client in, inside "World of Warcraft" ("_forever_") */
  installFolder: string;
  /** Whether the client has the keyring (C_ActionBar.ShouldShowKeyring: its bag bar button, the keyring bag) */
  hasKeyring: boolean;
  /** The addons switched on in a fresh setup */
  defaultAddons: string[];
  /** The game's DB2 tables the simulator reads (wago.tools' CSV exports) */
  db2Tables: readonly string[];
};
