// A quest found by name or id and given to a member: the same finder as the Quests panel's, its results a short list
import { SearchField, Spinner } from "@heroui/react";
import { useState } from "react";
import { Problem } from "../../components/bits.tsx";
import { api } from "../../sim/api.ts";
import { useGameAction } from "../../sim/hooks.ts";
import type { FoundQuest } from "../../sim/types.ts";
import { useSearch } from "../../sim/useSearch.ts";

const RESULTS = 6;
const findQuests = (query: string): Promise<FoundQuest[]> => api.findQuests(query, RESULTS);

type Props = { memberName: string; givenIds: ReadonlySet<number> };

export const GiveQuest = ({ memberName, givenIds }: Props) => {
  const [text, setText] = useState("");
  const search = useSearch(text, findQuests);
  const action = useGameAction();

  return (
    <div className="flex flex-col gap-2">
      <SearchField aria-label="Find a quest to give" value={text} onChange={setText}>
        <SearchField.Group>
          <SearchField.SearchIcon />
          <SearchField.Input placeholder="Give a quest: its name or id" />
          {search.isSearching ? <Spinner size="sm" className="mr-2" /> : <SearchField.ClearButton />}
        </SearchField.Group>
      </SearchField>
      {search.results.length > 0 && (
        <ul className="flex flex-col overflow-hidden rounded-lg border border-border">
          {search.results.map((quest) => {
            const isGiven = givenIds.has(quest.id);
            return (
              <li key={quest.id} className="border-border border-b last:border-b-0">
                <button
                  type="button"
                  disabled={isGiven || action.isPending}
                  onClick={() => void action.run({ action: "partyAccept", name: memberName, questId: quest.id })}
                  className="flex w-full cursor-pointer items-center gap-2 px-3 py-2 text-left text-[13px] hover:bg-surface-secondary disabled:cursor-default disabled:opacity-50"
                >
                  <span className="w-8 font-mono text-xs text-muted">{quest.level ?? ""}</span>
                  <span className="quest-title grow truncate">{quest.name}</span>
                  <span className="text-xs text-muted">{isGiven ? "has it" : (quest.zone ?? quest.id)}</span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
      <Problem>{action.problem}</Problem>
    </div>
  );
};
