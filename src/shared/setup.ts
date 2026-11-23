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
//   POST /api/setup/pickFolder         FolderPickRequest -> FolderPick: the system's own folder dialog (this computer)
//
// While the setup is not done the server still serves the page and these routes; no simulator runs, and
// GET /api/state answers SetupNeeded instead of the game's state.

export const SETUP_ROUTES = {
  setup: "/api/setup",
  downloadInterface: "/api/setup/downloadInterface",
  checkFolder: "/api/setup/checkFolder",
  pickFolder: "/api/setup/pickFolder",
} as const;

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
  /** The app's version, and whether it runs from a source checkout (bun run start) or as the bundled executable */
  version: string;
  isSourceCheckout: boolean;
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

export type FolderPickRequest = { kind: FolderKind; startPath?: string };

/** path null: the dialog was closed without choosing (or there is no dialog on this system: error says so) */
export type FolderPick = { path: string | null; error?: string };

/** GET /api/state while the setup is not done (error says so too, for a page that knows only the game's state) */
export type SetupNeeded = { setupNeeded: true; problems: SetupProblem[]; error: string };
