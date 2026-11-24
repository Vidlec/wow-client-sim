// The server's routes (src/server/http/routes.ts) as typed calls. Nothing here keeps state: the store (store.ts)
// polls the state, and calls that change the game ask it to read again (hooks.ts).
import type { CombatAction } from "../../shared/combat.ts";
import type {
  AddonPlan,
  CatalogAddon,
  ExecAnswer,
  FoundNpc,
  FoundQuest,
  GameAnswer,
  InspectedFrameInfo,
  QuestSources,
  SavedFile,
  ServerSettings,
  SimState,
  StateProblem,
  UiMap,
} from "./types.ts";

/** The changes lua/boot.lua's game handler knows, each with what it takes */
export type GameAction =
  | { action: "accept" | "complete" | "turnIn" | "abandon" | "markDone"; questId: number }
  | { action: "progress"; questId: number; objective: number; amount: number }
  | { action: "profile"; profile: { name?: string; level?: number; race?: string; class?: string; money?: number } }
  | { action: "position"; uiMapId: number; x: number; y: number }
  | { action: "kill"; npcId: number; loot?: boolean }
  | { action: "loot"; itemId: number; count: number }
  | { action: "talk"; npcId: number }
  | { action: "closeDialog" }
  | { action: "instance"; instanceId: number; instanceType?: string; name?: string }
  | { action: "partyAdd"; name: string; class: string; level?: number; addon: string }
  | { action: "partyRemove" | "partyCopyLog"; name: string }
  | { action: "partyAccept" | "partyComplete" | "partyAbandon"; name: string; questId: number }
  | { action: "partyProgress"; name: string; questId: number; objective: number; amount: number }
  | { action: "partyMove"; name: string; isHere: true }
  | { action: "partyOnline"; name: string; isOnline: boolean }
  | { action: "walk"; forward: number; right?: number }
  | { action: "turn"; degrees: number }
  | { action: "walkTo"; uiMapId?: number; x: number; y: number }
  | { action: "autoRun" | "stopMoving" }
  | { action: "walkMode"; isWalking: boolean }
  | { action: "clickToWalk" | "editMode"; isOn: boolean }
  | { action: "zoom"; delta: number }
  | { action: "placeMinimap"; point: string; x: number; y: number }
  | { action: "screen"; width: number; height: number; uiScale?: number }
  | { action: "interfaceStyle"; style: 0 | 1 }
  | { action: "cvar"; name: string; value: string }
  | { action: "restrict"; identity: boolean; threat: boolean }
  | { action: "combat"; inCombat: boolean }
  // The battle simulator's (src/shared/combat.ts)
  | CombatAction;

const readJson = async <T>(response: Response): Promise<T> => {
  const text = await response.text();
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new Error(response.ok ? "the server's answer was not JSON" : `the server answered ${response.status}`);
  }
};

export const getJson = async <T>(path: string): Promise<T> => readJson<T>(await fetch(path));

export const postJson = async <T>(path: string, body: unknown = {}): Promise<T> =>
  readJson<T>(
    await fetch(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }),
  );

export type BootAnswer = { ready?: boolean; bootSeconds?: number; errors?: number; error?: string };

export const api = {
  state: (): Promise<SimState | StateProblem> => getJson("/api/state"),
  game: (action: GameAction): Promise<GameAnswer> => postJson("/api/game", action),
  findQuests: async (text: string, limit = 25): Promise<FoundQuest[]> =>
    (await postJson<{ results?: FoundQuest[] }>("/api/findQuests", { text, limit })).results ?? [],
  findNpcs: async (text: string, limit = 15): Promise<FoundNpc[]> =>
    (await postJson<{ results?: FoundNpc[] }>("/api/findNpcs", { text, limit })).results ?? [],
  sources: async (): Promise<QuestSources[]> =>
    (await postJson<{ quests?: QuestSources[] }>("/api/sources", {})).quests ?? [],
  addonCatalog: (): Promise<CatalogAddon[]> => getJson("/api/addonCatalog"),
  /** Several addons switched on and off at once, with what they need and what needs them; one reload */
  changeAddons: (
    on: readonly string[],
    off: readonly string[],
  ): Promise<{ catalog?: CatalogAddon[]; plan?: AddonPlan; boot?: BootAnswer; error?: string }> =>
    postJson("/api/addons/change", { on, off }),
  saved: (addon: string): Promise<SavedFile> => getJson(`/api/saved?addon=${encodeURIComponent(addon)}`),
  savedReset: (addon: string): Promise<{ boot?: BootAnswer }> => postJson("/api/savedReset", { addon }),
  maps: (): Promise<UiMap[]> => getJson("/api/maps"),
  exec: (code: string): Promise<ExecAnswer> => postJson("/api/exec", { code }),
  slash: (text: string): Promise<unknown> => postJson("/api/slash", { text }),
  fireEvent: (name: string, args: unknown[]): Promise<unknown> => postJson("/api/event", { name, args }),
  frameInfo: (id: number): Promise<InspectedFrameInfo> => postJson("/api/frameInfo", { id }),
  clearErrors: (): Promise<unknown> => postJson("/api/clearErrors"),
  reload: (): Promise<BootAnswer> => postJson("/api/reload"),
  settings: (changes: Partial<ServerSettings>): Promise<ServerSettings> => postJson("/api/settings", changes),
} as const;
