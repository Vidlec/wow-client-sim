// The quest log: every quest the character has, each a card (LoggedQuestCard), with who drops or holds what each
// objective needs (read again whenever the log changes); and whether kills drop the quest items they can
import { ListCheck } from "@gravity-ui/icons";
import { Button } from "@heroui/react";
import { EmptyState, SwitchRow } from "../../components/bits.tsx";
import { setPref, usePref } from "../../sim/prefs.ts";
import { useQuestSources } from "../../sim/useQuestSources.ts";
import { LoggedQuestCard } from "./LoggedQuestCard.tsx";

export const QuestLog = ({ onFind }: { onFind: () => void }) => {
  const { log, sources } = useQuestSources();
  const lootOnKill = usePref("lootOnKill");

  return (
    <div className="flex flex-col gap-3">
      <SwitchRow
        label="Kills drop the quest items they can"
        description="A creature killed at once (from its menu under an objective) drops what your quests need of it"
        isSelected={lootOnKill}
        onChange={(isOn) => setPref("lootOnKill", isOn)}
      />
      {log.length === 0 ? (
        <EmptyState
          icon={<ListCheck />}
          action={
            <Button size="sm" variant="secondary" onPress={onFind}>
              Find a quest
            </Button>
          }
        >
          The quest log is empty.
        </EmptyState>
      ) : (
        log.map((quest) => <LoggedQuestCard key={quest.questId} quest={quest} sources={sources.get(quest.questId)} />)
      )}
    </div>
  );
};
