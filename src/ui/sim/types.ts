// The simulator's state as /api/state gives it (lua/boot.lua's handlers.state, the server's fields added), and the
// answers of the other routes. Only what the page reads is typed; the rest passes through.
import type { CombatState } from "../../shared/combat.ts";

export type Objective = { text: string; fulfilled: number; required: number };

export type LoggedQuest = {
  questId: number;
  title: string;
  level: number;
  isComplete: boolean;
  watched: boolean;
  objectives: Objective[];
};

export type Profile = {
  name: string;
  level: number;
  race: string;
  raceName?: string;
  class: string;
  className?: string;
  faction?: string;
  sex?: number;
  realm?: string;
  money: number;
  xp?: number;
  xpMax?: number;
  /** Rested experience (GetXPExhaustion): kills give twice the experience until it is used up */
  restedXp?: number;
  uiMapId: number;
  x: number;
  y: number;
  facing?: number;
  isInInstance: boolean;
  instanceId: number;
  instanceType: string;
  instanceName?: string;
  groupSize?: number;
  items?: Record<string, number>;
  achievements?: Record<string, number[]>;
};

export type PartyObjective = Objective;
export type PartyQuest = { questId: number; title: string; isComplete: boolean; objectives: PartyObjective[] };
export type PartyMember = {
  unit: string;
  name: string;
  class: string;
  level: number;
  addon: string;
  isOnline: boolean;
  uiMapId?: number;
  x?: number;
  y?: number;
  quests: PartyQuest[];
};

/** An addon a party member may run, as the simulator and the project's plugins registered it (lua/plugins.lua) */
export type PartyAddon = {
  id: string;
  label: string;
  note: string;
  color: "accent" | "success" | "warning" | "danger" | "default";
  /** What a member runs when none is named */
  isDefault: boolean;
};

export type LoadedAddon = {
  name: string;
  title: string;
  loaded: boolean;
  seconds?: number;
  cpu?: { average: number; recent: number; peak: number; total: number };
};

export type SimEvent = { event: string; time: number; args: string[] };
export type ChatLine = { text: string; r: number; g: number; b: number; time: number };
export type SimError = { message: string; stack?: string; count?: number; time?: number };
export type Stub = { name: string; count: number; addons?: string[] };

export type DialogOffer = { questID: number; title: string; questLevel: number };
export type DialogActive = { questID: number; title: string; questLevel?: number; isComplete: boolean };
export type NpcDialog = { id?: number; name: string; offers: DialogOffer[]; active: DialogActive[] };

export type Movement = {
  speed: number;
  isWalking: boolean;
  isAutoRunning: boolean;
  isMoving: boolean;
  distanceToTarget?: number | null;
};

export type ScreenState = { width: number; height: number; uiScale?: number | null };
export type GamepadState = { style: number; connected: boolean; name?: string };

export type ClientInfo = { build: string; isStrictApi: boolean; simOnly?: number | null; clientOnly?: number | null };

export type ClockPerf = {
  fps: number;
  frameMs: number;
  worstMs: number;
  sentPerSecond?: number;
  pages?: number;
  worstWaitMs?: number;
};
export type SimulatorPerf = {
  heapMb?: number;
  worst?: { total: number; tick: number; export: number; encode: number; collected: boolean };
  /** The frames' averages since last asked (ms), and the garbage collector's time between frames */
  average?: {
    frames: number;
    total: number;
    input: number;
    tick: number;
    export: number;
    encode: number;
    idleCollect: number;
    tickWorld?: number;
    tickTimers?: number;
    tickUpdates?: number;
    tickSizes?: number;
  };
};

export type SimState = {
  errors: SimError[];
  chat: ChatLine[];
  profile: Profile;
  questLog: LoggedQuest[];
  completedCount: number;
  npc?: NpcDialog | null;
  addons: LoadedAddon[];
  events: SimEvent[];
  bootSeconds?: number;
  version: number;
  now: number;
  rotateMinimap: boolean;
  editMode: boolean;
  gamepad: GamepadState;
  screen: ScreenState;
  restrictions: { identity: boolean; threat: boolean };
  party: PartyMember[];
  /** The addons a party member may run ("none" first) */
  partyAddons?: PartyAddon[];
  minimapZoom: number;
  facing: number;
  viewRadius: number;
  movement: Movement;
  clickToWalk: boolean;
  inCombat?: boolean;
  /** The battle simulator's (src/shared/combat.ts); absent where it does not run */
  combat?: CombatState;
  client: ClientInfo;
  zoneName?: string | null;
  simulatorPerf?: SimulatorPerf;
  stubs: Stub[];
  // The server's own
  generation: number;
  boot?: { ready?: boolean; bootSeconds?: number; errors?: number; error?: string };
  paused: boolean;
  speed: number;
  autoReload: boolean;
  artReady: boolean;
  config?: { addons: string[]; addonsRoot: string; build: string; flavour?: string };
  /** The project the server serves (bun run start --project), null for the settings' addons */
  project?: { root: string; addons: string[]; scenariosDir: string } | null;
  perf?: ClockPerf;
  [key: string]: unknown;
};

/** The state route's answer when the simulator is not running, or the platform needs its first setup */
export type StateProblem = { error?: string; boot?: { error?: string }; setupNeeded?: boolean };

export type GameAnswer = { ok?: boolean; problem?: string; [key: string]: unknown };

export type FoundQuest = {
  id: number;
  name: string;
  level?: number;
  zone?: string;
  requiredLevel?: number;
  isInLog?: boolean;
  isDone?: boolean;
};

export type FoundNpc = { id: number; name: string; level?: number; questCount?: number };

export type ObjectiveSource = { kind: "npc" | "object"; id: number; name: string };
export type QuestSources = {
  questId: number;
  objectives: { text: string; itemId?: number; sources?: ObjectiveSource[] }[];
};

export type CatalogAddon = {
  name: string;
  title: string;
  notes: string;
  version: string;
  author: string;
  dependencies: string[];
  /** Loaded first when they are on, not needed */
  optionalDependencies: string[];
  loadOnDemand: boolean;
  savedVariables: string[];
  enabled: boolean;
  savedBytes: number;
  /** One of the served project's own addons */
  isProject?: boolean;
  /** Where it was found: the game's AddOns folder, a further folder (Settings' addon folders), the project */
  origin: "game" | "folder" | "project";
  /** The folder it was found in */
  root: string;
  /** Its TOC's ## Interface */
  interfaceVersion: string;
  /** Whether this client lists it (false: its TOC is only for other game lines) */
  isForThisGame: boolean;
  /** Its TOC's title as the game shows it, with its colour codes */
  richTitle: string;
  /** ## Category, with its colour codes: the game's AddOns list files it under this heading (none: after them) */
  category: string;
  /**
   * The addon it is listed under, as the game's AddOns list nests it: ## Group, else the one it needs whose name its
   * own starts with (EllesmereUIActionBars under EllesmereUI); its own name when it heads a group or stands alone
   */
  group: string;
  /** ## IconTexture: its icon in the game's list (empty: none) */
  iconTexture: string;
};

/** What a change of addons did (shared/addonDeps.ts) */
export type { AddonPlan } from "../../shared/addonDeps.ts";

export type SavedFile = { addon: string; text: string | null; bytes?: number };

export type UiMap = { id: number; name: string; type: number; parent: number };

export type InspectedFrameInfo = {
  frameId: number;
  name: string;
  type: string;
  creator?: string;
  path: { id: number; name: string }[];
  points: { point: string; relative: string; relativePoint: string; x: number; y: number }[];
  scripts: string[];
  attributes: { key: string; value: string }[];
  children: { id: number; name: string; type: string; shown: boolean }[];
  regions: { textures: number; fontStrings: number };
  shown: boolean;
  visible?: boolean;
  alpha?: number;
  scale?: number;
  strata?: string;
  level?: number;
  rect?: [number, number, number, number];
  mouse?: boolean;
  wheel?: boolean;
  keyboard?: boolean;
  error?: string;
};

export type ExecAnswer = { output?: string[]; result?: string; error?: string };
export type ServerSettings = { paused: boolean; speed: number; autoReload: boolean };
