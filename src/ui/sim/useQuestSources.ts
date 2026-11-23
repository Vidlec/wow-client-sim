// Who drops or holds what each logged quest's objectives need (the game's data, /api/sources): asked again whenever
// the log changes, and the creatures among them that the quests still want killed
import { useEffect, useMemo, useState } from "react";
import { api } from "./api.ts";
import { useSimState } from "./hooks.ts";
import type { LoggedQuest, QuestSources } from "./types.ts";

const NO_QUESTS: LoggedQuest[] = [];

export type QuestSourcesByQuest = ReadonlyMap<number, QuestSources["objectives"]>;

/** The log and each quest's sources by quest id */
export const useQuestSources = (): { log: LoggedQuest[]; sources: QuestSourcesByQuest } => {
  const log = useSimState((state) => state.questLog, NO_QUESTS);
  const [sources, setSources] = useState<QuestSourcesByQuest>(new Map());

  // (the log keeps its object while it does not change: asked again only then)
  useEffect(() => {
    if (log.length === 0) return;
    let isCurrent = true;
    void api
      .sources()
      .then((quests) => {
        if (isCurrent) setSources(new Map(quests.map((quest) => [quest.questId, quest.objectives])));
      })
      .catch(() => {});
    return () => {
      isCurrent = false;
    };
  }, [log]);

  return { log, sources };
};

export type QuestCreature = { id: number; name: string; questTitle: string; objective: string };

/** Every creature an unfinished objective needs (to kill, or to kill for its drop), each once, by quest order */
export const listQuestCreatures = (log: readonly LoggedQuest[], sources: QuestSourcesByQuest): QuestCreature[] => {
  const seen = new Set<number>();
  const creatures: QuestCreature[] = [];
  for (const quest of log) {
    const found = sources.get(quest.questId);
    quest.objectives.forEach((objective, index) => {
      if (objective.fulfilled >= objective.required) return;
      for (const source of found?.[index]?.sources ?? []) {
        if (source.kind !== "npc" || seen.has(source.id)) continue;
        seen.add(source.id);
        creatures.push({ id: source.id, name: source.name, questTitle: quest.title, objective: objective.text });
      }
    });
  }
  return creatures;
};

/** The same list, kept while the log and its sources stay the same */
export const useQuestCreatures = (): QuestCreature[] => {
  const { log, sources } = useQuestSources();
  return useMemo(() => listQuestCreatures(log, sources), [log, sources]);
};
