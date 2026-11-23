// Finding a creature by name or id: talking to it (its quests, in the gossip window) or killing it (what it drops for
// your quests, when kills drop loot)
import { Comments, Skull } from "@gravity-ui/icons";
import { Button, Chip, SearchField, Spinner, toast } from "@heroui/react";
import { useState } from "react";
import { EmptyState } from "../../components/bits.tsx";
import { api } from "../../sim/api.ts";
import { useGameAction } from "../../sim/hooks.ts";
import { getPrefs } from "../../sim/prefs.ts";
import type { FoundNpc } from "../../sim/types.ts";
import { useSearch } from "../../sim/useSearch.ts";
import { TalkDialog } from "./TalkDialog.tsx";

const findNpcs = (query: string): Promise<FoundNpc[]> => api.findNpcs(query, 15);

const NpcRow = ({ npc, onTalk }: { npc: FoundNpc; onTalk: () => void }) => {
  const action = useGameAction();
  const kill = async (): Promise<void> => {
    const answer = await action.run({ action: "kill", npcId: npc.id, loot: getPrefs().lootOnKill });
    if (answer?.ok) toast(`${npc.name} slain`, { indicator: <Skull /> });
    else if (answer?.problem) toast.danger(`${npc.name}: ${answer.problem}`);
  };
  return (
    <li className="flex items-center gap-2 rounded-lg px-2.5 py-2 hover:bg-surface-secondary">
      <div className="min-w-0 grow">
        <p className="truncate text-[13px] font-medium">{npc.name}</p>
        <p className="truncate text-[11px] text-muted">
          {npc.id}
          {npc.level ? ` · level ${npc.level}` : ""}
        </p>
      </div>
      {npc.questCount ? (
        <Chip size="sm" variant="soft" color="warning">
          {npc.questCount} {npc.questCount === 1 ? "quest" : "quests"}
        </Chip>
      ) : null}
      <Button size="sm" variant="secondary" onPress={onTalk}>
        <Comments />
        Talk
      </Button>
      <Button size="sm" variant="danger-soft" isPending={action.isPending} onPress={() => void kill()}>
        <Skull />
        Kill
      </Button>
    </li>
  );
};

export const GiverFinder = () => {
  const [text, setText] = useState("");
  const [talkingTo, setTalkingTo] = useState<number | null>(null);
  const search = useSearch(text, findNpcs);
  const talk = useGameAction();
  const startTalking = async (npc: FoundNpc): Promise<void> => {
    setTalkingTo(npc.id);
    const answer = await talk.run({ action: "talk", npcId: npc.id });
    if (answer?.problem) {
      toast.danger(`${npc.name}: ${answer.problem}`);
      setTalkingTo(null);
    }
  };
  return (
    <div className="flex flex-col gap-3">
      <SearchField aria-label="Find a creature" value={text} onChange={setText} fullWidth>
        <SearchField.Group>
          <SearchField.SearchIcon />
          <SearchField.Input placeholder="A creature's name or id, e.g. Faranell" />
          {search.isSearching ? <Spinner size="sm" className="mr-2" /> : <SearchField.ClearButton />}
        </SearchField.Group>
      </SearchField>
      {!search.query ? (
        <EmptyState icon={<Comments />}>
          Quest givers and the creatures your quests need: talk to one for its quests, or kill it.
        </EmptyState>
      ) : search.results.length === 0 && !search.isSearching ? (
        <EmptyState>No creature by that name or id.</EmptyState>
      ) : (
        <ul className="flex flex-col">
          {search.results.map((npc) => (
            <NpcRow key={npc.id} npc={npc} onTalk={() => void startTalking(npc)} />
          ))}
        </ul>
      )}
      <TalkDialog npcId={talkingTo} onClose={() => setTalkingTo(null)} />
    </div>
  );
};
