// The first-run setup and the settings, as the server and the page share them: the routes, what each takes and what
// it answers. The server keeps the settings itself (in the user's data folder); the page reads and changes them
// through these routes only, so nobody writes a config file by hand.
//
//   GET  /api/setup                    SetupState: the settings, what is missing, what was found on this computer
//                                      (found folders are kept 30 s; ?refresh=1 looks again now: a Check button)
//   POST /api/setup                    SettingsChange -> SetupAnswer: checks, saves, (re)starts the simulator
//   POST /api/setup/downloadInterface  {} -> SetupState: starts fetching the flavour's interface source; its progress
//                                      is in GET /api/setup's interfaceDownload (poll it about once a second)
//   POST /api/setup/checkFolder        FolderCheckRequest -> FolderCheck: what a typed path holds, before saving it
//   POST /api/setup/listFolder         FolderListRequest -> FolderListing: a folder's folders, for the page's browser
//
// While the setup is not done the server still serves the page and these routes; no simulator runs, and
// GET /api/state answers SetupNeeded instead of the game's state.

export const SETUP_ROUTES = {
  setup: "/api/setup",
  downloadInterface: "/api/setup/downloadInterface",
  checkFolder: "/api/setup/checkFolder",
  listFolder: "/api/setup/listFolder",
  art: "/api/setup/art",
  reset: "/api/setup/reset",
  builds: "/api/setup/builds",
} as const;

/** The client's builds (GET /api/setup/builds): the one in use, the newest anywhere, and which can be used */
export type ClientBuilds = {
  /** The build the simulator runs ("1.60.1.71037") */
  current: string;
  /** The flavour's own build (settings.build "" means this one) */
  flavourBuild: string;
  /** What Blizzard's patch server says each region runs */
  blizzard: { region: string; build: string }[];
  /** The builds wago.tools has, newest first: only these can be used (the game's tables come from it) */
  wago: string[];
  /** The build the interface source in use is at (its version.txt), and the newest on its branch */
  interfaceInUse: string | null;
  interfaceLatest: string | null;
  /** What could not be asked (no network, a server down) */
  problems: string[];
};

/** POST /api/setup/reset's body: what is deleted besides the settings (which always go back to their defaults) */
export type ResetChoice = {
  /** The game's interface source the setup downloaded (not a checkout of your own) */
  interface: boolean;
  /** The game's files from Blizzard's CDN and tables from wago.tools, wowless's data, the boot cache */
  cache: boolean;
  /** The simulator's saved variables and its own state (never the game's WTF folder) */
  saved: boolean;
};

/** One WoW client the simulator can be (WoW: Forever today; Classic and Retail later) */
export type FlavourInfo = {
  id: string;
  /** "WoW: Forever" */
  name: string;
  description: string;
  /** The client's version and build, as GetBuildInfo gives them ("1.60.1", "71037") */
  clientVersion: string;
  clientBuild: string;
  /** Where its interface source comes from (a GitHub repository's branch), for the download button's label */
  interfaceSource: { repository: string; branch: string; url: string };
};

export type EditModeLayout = "modern" | "classic" | "gamepad";

/** Every setting, as the server keeps it. The page may change any of them with POST /api/setup */
export type Settings = {
  /** A FlavourInfo id */
  flavour: string;
  /** The game's Interface/AddOns folder with the addons to run */
  addonsRoot: string;
  /** More folders with addons, beside the AddOns folder: each holds addon folders (or is one); an addon in one of
   * these wins over one of the same name in the AddOns folder, a later folder over an earlier */
  addonFolders: string[];
  /** The game's interface source (wow-ui-source's Interface folder); "" for the one downloaded by the setup */
  interfaceRoot: string;
  /** The addons switched on, by folder name (the Addons tab changes these) */
  addons: string[];
  /** "all": the game's whole interface, as the client loads it; "light": the simulator's lighter stand-in */
  blizzardAddons: "all" | "light";
  /** Only the client's own functions exist, as in the game */
  strictApi: boolean;
  /** The client's language: enUS, deDE, frFR... */
  locale: string;
  screenWidth: number;
  screenHeight: number;
  editModeLayout: EditModeLayout;
  /** Which of Forever's two achievement sets the client lists: "a" (the default) or "b" */
  achievementSet: "a" | "b";
  /** Reload the addons whenever one of their files is saved */
  autoReload: boolean;
  /** The game's clock, frames a second (10 to 240) */
  fps: number;
  /** The page's port (taken at the next start of the app) */
  port: number;
  /** Open the page in the browser as the app starts */
  openBrowser: boolean;
  /** LuaJIT's executable; "" to find it on the PATH and in the usual places */
  luajitPath: string;
  /** The client build whose art, tables and API the simulator matches; "" for the flavour's own */
  build: string;
  /** Which TOC an addon is read from, in order; empty for the flavour's own */
  tocSuffixes: string[];
};

/** What a reset did: the setup as it is now, what was deleted, and what could not be (a file in use) */
export type ResetAnswer = SetupState & { deleted: string[]; failures: string[] };

/** POST /api/setup's body: only the settings to change */
export type SettingsChange = Partial<Settings>;

/** What a setting (or a part of the setup) lacks: key names the setting the page should point at */
export type SetupProblem = { key: keyof Settings | "luajit" | "interface" | "settings"; message: string };

/** A folder found on this computer that a setting could point at */
export type DetectedFolder = {
  path: string;
  /** Where it was found or what it holds: "WoW: Forever, from the registry", "12 addons" */
  note: string;
  /** The flavour it belongs to, when the folder says (_forever_, _classic_...) */
  flavour?: string;
};

export type LuajitInfo = {
  /** The executable found (or set), or null when there is none */
  path: string | null;
  /** "LuaJIT 2.1.1720049189" */
  version?: string;
  /** How to install it on this system, when it was not found */
  instructions?: string;
};

export type InterfaceDownload = {
  state: "idle" | "downloading" | "unpacking" | "done" | "failed";
  receivedBytes: number;
  /** Known only when the server sends a length (GitHub's archives usually do not) */
  totalBytes?: number;
  error?: string;
  /** The Interface folder once done (interfaceRoot "" uses it) */
  path?: string;
};

export type SimulatorStatus = {
  state: "stopped" | "starting" | "running" | "failed";
  /** Why it failed or stopped (a LuaJIT error, a missing folder) */
  error?: string;
};

/** One part of the simulator's start, as the setup shows it */
export type StartStep = {
  id: "native" | "blizzard" | "listfile" | "wowless" | "tables" | "atlases" | "highlights" | "boot";
  label: string;
  state: "waiting" | "running" | "done" | "failed";
  /** What it is at or came to: "UiTextureAtlas", "12.4 MB", "from the cache", an error */
  detail?: string | undefined;
  /** Its progress, when it counts something (tables fetched, of how many) */
  done?: number | undefined;
  total?: number | undefined;
  /** How long it took, or has taken so far */
  seconds?: number | undefined;
};

/** The last start of the simulator, part by part (the first one fetches the game's art and tables) */
export type StartProgress = { startedAt: string; steps: StartStep[] };

/** What the cache holds of the game's art and tables, for the settings (GET /api/setup/art) */
export type ArtInfo = {
  build: string;
  locale: string;
  cacheDir: string;
  /** The game's file list (wago.tools' listfile), indexed: paths to file ids */
  listfile: {
    isReady: boolean;
    rows?: number | undefined;
    downloadedBytes?: number | undefined;
    builtAt?: string | undefined;
    error?: string | null | undefined;
  };
  /** The game's tables (DB2) fetched, for this build and language */
  tables: { count: number; bytes: number };
  /** Game files fetched (textures, fonts, sounds, maps) and the pictures made of them */
  files: { count: number; bytes: number };
  pictures: { count: number; bytes: number };
  /** wowless's data about the client's API */
  wowless: { product: string; isFetched: boolean };
  /** Blizzard's CDN's indexes kept (every build's), which the game's files are found with */
  blizzardIndexes: { count: number; bytes: number };
  /** Everything in the cache folder */
  totalBytes: number;
};

export type SetupState = {
  /** Nothing is missing: the simulator can run (and runs, when simulator.state says so) */
  isReady: boolean;
  problems: SetupProblem[];
  settings: Settings;
  /** The settings a fresh setup starts from, for "reset" */
  defaults: Settings;
  flavours: FlavourInfo[];
  detected: {
    addonsRoots: DetectedFolder[];
    interfaceRoots: DetectedFolder[];
    luajit: LuajitInfo;
  };
  interfaceDownload?: InterfaceDownload;
  simulator: SimulatorStatus;
  /** Where the app keeps things, to show the user */
  paths: { settingsFile: string; dataDir: string; cacheDir: string; savedDir: string; downloadedInterface: string };
  /** The app's version */
  version: string;
  /** The system the server runs on ("win32", "darwin", "linux"...): the paths the setup shows as examples */
  platform: string;
  /** The simulator's last start, part by part; null before the first */
  start: StartProgress | null;
};

export type SetupAnswer = SetupState & {
  /** Whether the change was saved; false when every changed setting was refused */
  saved: boolean;
  /** Settings refused, each with why (a wrong type, out of range, an unknown flavour); the others are saved */
  errors: SetupProblem[];
  /** The simulator was started again for the change */
  restarted: boolean;
  /** A change (the port) that takes effect only when the app is started again */
  needsAppRestart: boolean;
};

export type FolderKind = "addons" | "interface" | "luajit";

export type FolderCheckRequest = { kind: FolderKind; path: string };

export type FolderCheck = {
  path: string;
  isValid: boolean;
  /** "18 addons", "the interface source (build 1.60.1)", or what is wrong with it */
  message: string;
  /** A better path nearby: the AddOns folder inside a game folder, the Interface folder inside a checkout */
  suggestion?: string;
};

/** A folder to look into (none: where browsing starts: the setting's own, else the host's folders, else the home) */
export type FolderListRequest = { kind: FolderKind; path?: string };

export type FolderEntry = {
  name: string;
  path: string;
  isFolder: boolean;
  /** What it seems to be, for the kind looked for ("an AddOns folder", "the game") */
  hint?: string;
};

/** A folder as the server sees it (in a container: the host's folders mounted into it, ADDONSIM_BROWSE) */
export type FolderListing = {
  path: string;
  /** The folder above, or null at a root */
  parent: string | null;
  /** Where browsing may start over: drives, the home, the host's folders */
  roots: { name: string; path: string }[];
  /** Its folders (and, for LuaJIT, its files that may be it), by name */
  entries: FolderEntry[];
  /** What this folder is, for the kind looked for (null for LuaJIT, which is a file) */
  check: FolderCheck | null;
  /** The folder could not be read (it was not there: path is where it went instead) */
  error?: string;
};

/** GET /api/state while the setup is not done (error says so too, for a page that knows only the game's state) */
export type SetupNeeded = { setupNeeded: true; problems: SetupProblem[]; error: string };
