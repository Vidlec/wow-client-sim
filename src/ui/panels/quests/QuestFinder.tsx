// Finding a quest by its name or id (QuestieDB's), and taking it: accepted into the log, or marked done without doing
// it (for a quest that needs another before it)
import { BookOpen, Check, CircleCheck, Plus } from "@gravity-ui/icons";
import { Button, Chip, SearchField, Spinner, Tooltip, toast } from "@heroui/react";
import { useState } from "react";
import { EmptyState } from "../../components/bits.tsx";
import { api } from "../../sim/api.ts";
import { useGameAction, useSimState } from "../../sim/hooks.ts";
import type { FoundQuest } from "../../sim/types.ts";
import { useSearch } from "../../sim/useSearch.ts";

const findQuests = (query: string): Promise<FoundQuest[]> => api.findQuests(query, 25);

const FoundRow = ({ quest }: { quest: FoundQuest }) => {
  const action = useGameAction();
  const take = async (kind: "accept" | "markDone"): Promise<void> => {
    const answer = await action.run({ action: kind, questId: quest.id });
    if (answer?.ok)
      toast.success(kind === "accept" ? `Accepted: ${quest.name}` : `Marked done: ${quest.name}`, {
        indicator: kind === "accept" ? <BookOpen /> : <CircleCheck />,
      });
    else if (answer?.problem) toast.danger(`${quest.name}: ${answer.problem}`);
  };
  return (
    <li className="flex items-center gap-2 rounded-lg px-2.5 py-2 hover:bg-surface-secondary">
      <span className="w-7 shrink-0 text-center font-mono text-xs text-muted">{quest.level ?? ""}</span>
      <div className="min-w-0 grow">
        <p className="quest-title truncate text-[13px] font-medium">{quest.name}</p>
        <p className="truncate text-[11px] text-muted">
          {quest.id}
          {quest.zone ? ` · ${quest.zone}` : ""}
          {quest.requiredLevel ? ` · from level ${quest.requiredLevel}` : ""}
        </p>
      </div>
      {quest.isInLog ? (
        <Chip size="sm" variant="soft" color="accent">
          in your log
        </Chip>
      ) : quest.isDone ? (
        <Chip size="sm" variant="soft" color="success">
          <Check className="size-3" />
          done
        </Chip>
      ) : (
        <div className="flex shrink-0 gap-1">
          <Button size="sm" isPending={action.isPending} onPress={() => void take("accept")}>
            <Plus />
            Accept
          </Button>
          <Tooltip delay={300}>
            <Button size="sm" variant="tertiary" aria-label="Mark it done" onPress={() => void take("markDone")}>
              Done
            </Button>
            <Tooltip.Content>Mark it done without doing it</Tooltip.Content>
          </Tooltip>
        </div>
      )}
    </li>
  );
};

export const QuestFinder = () => {
  const [text, setText] = useState("");
  const changes = useSimState((state) => `${state.questLog.length}:${state.completedCount}`, "");
  const search = useSearch(text, findQuests, changes);
  return (
    <div className="flex flex-col gap-3">
      <SearchField aria-label="Find a quest" value={text} onChange={setText} fullWidth autoFocus>
        <SearchField.Group>
          <SearchField.SearchIcon />
          <SearchField.Input placeholder="A quest's name or id, e.g. guano" />
          {search.isSearching ? <Spinner size="sm" className="mr-2" /> : <SearchField.ClearButton />}
        </SearchField.Group>
      </SearchField>
      {!search.query ? (
        <EmptyState icon={<BookOpen />}>
          Every quest of the game, by name or id: accept one into your log, or mark it done to open the ones after it.
        </EmptyState>
      ) : search.results.length === 0 && !search.isSearching ? (
        <EmptyState>No quest by that name or id.</EmptyState>
      ) : (
        <ul className="flex flex-col">
          {search.results.map((quest) => (
            <FoundRow key={quest.id} quest={quest} />
          ))}
        </ul>
      )}
    </div>
  );
};
