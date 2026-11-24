// The battle simulator's contract with the page (lua/combat.lua): the `combat` field of /api/state, and the
// /api/game actions that drive a fight. Every action is POSTed to /api/game as { action, ...fields } and answers
// CombatActionResult.
// Fields marked optional are absent from the JSON when they do not apply (the simulator's JSON writes no nulls).

/** How a unit stands to the player, as UnitReaction counts (2 hostile, 4 neutral, 5 friendly) */
export type CombatReaction = number;

/** UnitClassification's names */
export type CombatClassification = "normal" | "elite" | "rareelite" | "worldboss" | "rare" | "trivial" | "minus";

/** Enum.PowerType's names, as UnitPowerType gives the second value */
export type CombatPowerType = "MANA" | "RAGE" | "FOCUS" | "ENERGY";

/** A spell being cast or channelled (UnitCastingInfo / UnitChannelInfo), times in the game's seconds (GetTime) */
export type CombatCast = {
  spellId: number;
  name: string;
  icon: number;
  startTime: number;
  endTime: number;
  isChannel: boolean;
  notInterruptible: boolean;
};

/** An aura on a unit (C_UnitAuras' AuraData, reduced); expirationTime 0: lasts until cancelled */
export type CombatAura = {
  auraInstanceID: number;
  spellId: number;
  name: string;
  icon: number;
  isHelpful: boolean;
  duration: number;
  expirationTime: number;
  applications: number;
  /** "player" when the player put it there */
  sourceUnit?: string;
};

export type CombatEnemy = {
  /** The simulator's number for this creature, stable while it exists: what the actions take as enemyId */
  id: number;
  npcId: number;
  guid: string;
  name: string;
  level: number;
  classification: CombatClassification;
  reaction: CombatReaction;
  health: number;
  healthMax: number;
  power: number;
  powerMax: number;
  powerType: CombatPowerType;
  isDead: boolean;
  /** Dead, the player's kill, with loot still on it */
  isLootable: boolean;
  isTappedByOthers: boolean;
  inCombat: boolean;
  /** Running back to where it was pulled from, healing to full (it went too far) */
  isEvading: boolean;
  isTarget: boolean;
  isFocus: boolean;
  isMouseover: boolean;
  /** Its nameplate's unit token ("nameplate3") while it is in nameplate range; absent otherwise */
  unit?: string;
  /** The player's threat status on it (UnitThreatSituation: 0-3); absent when the player is not on its threat list */
  threat?: number;
  /** The player's share of its top threat, 0-100 */
  threatPercent: number;
  /** Whom it attacks: "player"; absent when nobody */
  targetUnit?: string;
  /** Yards from the player */
  distance: number;
  /** Degrees, clockwise from the player's facing (0 ahead, 90 right, -90 left, 180 behind) */
  bearing: number;
  casting?: CombatCast;
  auras: CombatAura[];
};

export type CombatPlayer = {
  level: number;
  health: number;
  healthMax: number;
  power: number;
  powerMax: number;
  powerType: CombatPowerType;
  comboPoints: number;
  /** PLAYER_REGEN_DISABLED .. PLAYER_REGEN_ENABLED (the fight's, not the manual "In combat" override) */
  inCombat: boolean;
  /** InCombatLockdown(): the fight's or the manual override's */
  isLockedDown: boolean;
  isDead: boolean;
  isGhost: boolean;
  /** Auto-attack (or Auto Shot / Shoot) is on */
  isAutoAttacking: boolean;
  /** Running away (combatFlee): auto-running from whoever fights, until they give up */
  isFleeing?: boolean;
  /** When the next swing lands (GetTime); absent when not swinging */
  nextSwing?: number;
  swingSpeed: number;
  casting?: CombatCast;
  /** When the global cooldown ends (GetTime); absent when none */
  gcdEnd?: number;
  /** Spells cooling down: their spell id and when they are ready (GetTime) */
  cooldowns: { spellId: number; name: string; endTime: number }[];
  /** A spell waiting for the next swing (Heroic Strike); absent when none */
  queuedSpellId?: number;
  xp: number;
  xpMax: number;
  auras: CombatAura[];
};

/** One line of the combat log, worded as the game's combat log window words it */
export type CombatLogLine = {
  /** GetTime when it happened */
  time: number;
  /** The combat log's subevent: SWING_DAMAGE, SWING_MISSED, SPELL_DAMAGE, SPELL_MISSED, SPELL_HEAL, SPELL_CAST_START,
   *  SPELL_CAST_SUCCESS, SPELL_CAST_FAILED, SPELL_INTERRUPT, SPELL_AURA_APPLIED, SPELL_AURA_REMOVED,
   *  SPELL_PERIODIC_DAMAGE, SPELL_PERIODIC_HEAL, SPELL_ENERGIZE, UNIT_DIED, PARTY_KILL, ENVIRONMENTAL_DAMAGE */
  event: string;
  sourceName?: string;
  destName?: string;
  spellId?: number;
  spellName?: string;
  amount?: number;
  /** For a miss: MISS, DODGE, PARRY, BLOCK, RESIST, ABSORB, EVADE, IMMUNE; for a hit, CRITICAL / GLANCING / CRUSHING (absent for a plain hit) */
  outcome?: string;
  text: string;
};

export type CombatLootSlot = {
  slot: number;
  /** absent for money */
  itemId?: number;
  name: string;
  icon: number;
  quantity: number;
  quality: number;
  isQuestItem: boolean;
  isMoney: boolean;
};

/** The open loot window (LOOT_OPENED .. LOOT_CLOSED) */
export type CombatLoot = { enemyId: number; name: string; slots: CombatLootSlot[] };

export type CombatState = {
  enemies: CombatEnemy[];
  player: CombatPlayer;
  /** The newest last, at most 60 */
  log: CombatLogLine[];
  /** Absent when no loot window is open */
  loot?: CombatLoot;
  /** The seed the fight's rolls start from (combatReset sets it): the same seed plays the same fight */
  seed: number;
  /** The yards within which creatures have nameplates (the nameplateMaxDistance setting) */
  nameplateRange: number;
  /** The client keeps the combat log from addons (COMBAT_LOG_EVENT_UNFILTERED is restricted in this build): the log
   *  above is the page's, not something an addon sees */
  isCombatLogRestricted: boolean;
};

// The actions, by name, with what each takes

export type CombatSpawnRequest = {
  action: "combatSpawn";
  /** The creature, by its id or its name (QuestieDB's NPC data) */
  npcId?: number;
  name?: string;
  /** How many (each placed a few yards from the last); 1 by default */
  count?: number;
  /** Yards from the player (20 by default) */
  distance?: number;
  /** Degrees clockwise from the player's facing (0 ahead, the default) */
  bearing?: number;
  /** Its level, within its range in the data (the data's lowest by default) */
  level?: number;
  /** false: it does not attack on its own, even when hostile */
  aggro?: boolean;
  /** A spell it casts (else one guessed from its name, or none) */
  spellId?: number;
  /** Someone outside the group tapped it: no credit, no loot */
  isTappedByOthers?: boolean;
};

export type CombatAction =
  | CombatSpawnRequest
  /** Target: an enemy by id; next: the next enemy (Tab), reverse: Shift-Tab; clear: no target */
  | { action: "combatTarget"; enemyId?: number; next?: boolean; reverse?: boolean; clear?: boolean }
  | { action: "combatFocus"; enemyId?: number; clear?: boolean }
  /** The mouse over an enemy (UPDATE_MOUSEOVER_UNIT); none given: off it */
  | { action: "combatHover"; enemyId?: number }
  /** Auto-attack on (the target, or this enemy, targeted first) */
  | { action: "combatAttack"; enemyId?: number }
  | { action: "combatStopAttack" }
  /** An action button's slot pressed, as its key does (1-12 the first bar) */
  | { action: "combatUseAction"; slot: number }
  | { action: "combatCastSpell"; spellId: number }
  /** Run from whoever fights the player: back to them and auto-run, until each gives up at its leash */
  | { action: "combatFlee" }
  /** Stop casting, attacking and running away */
  | { action: "combatStop" }
  /** Open a dead enemy's loot (the nearest lootable one when none is given) */
  | { action: "combatLoot"; enemyId?: number }
  | { action: "combatLootSlot"; slot: number }
  | { action: "combatCloseLoot" }
  /** Release the spirit (dead -> ghost) */
  | { action: "combatRelease" }
  /** Come back to life (from dead or ghost), at half health and mana */
  | { action: "combatResurrect" }
  /** Hurt (or with a negative amount, heal) the player or an enemy directly, for testing health bars */
  | { action: "combatDamage"; enemyId?: number; amount: number }
  | { action: "combatDespawn"; enemyId?: number }
  /** Every enemy gone, the player alive and whole, out of combat; seed: the rolls' new seed */
  | { action: "combatReset"; seed?: number };

export type CombatActionResult = {
  ok: boolean;
  problem?: string;
  /** combatSpawn: the new enemies' ids */
  enemyIds?: number[];
};
