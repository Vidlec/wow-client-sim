// One of a member's quests: each objective's count with a bar and a "+1", the quest made ready or dropped
import { CircleCheck, Plus, TrashBin } from "@gravity-ui/icons";
import { Button, Chip, ProgressBar } from "@heroui/react";
import { useGameAction } from "../../sim/hooks.ts";
import type { PartyQuest } from "../../sim/types.ts";

type Props = { memberName: string; quest: PartyQuest };

export const QuestRow = ({ memberName, quest }: Props) => {
  const action = useGameAction();
  const target = { name: memberName, questId: quest.questId };
  return (
    <li className="flex flex-col gap-2 rounded-lg border border-border bg-surface-secondary p-3">
      <div className="flex items-center gap-2">
        <span className="grow font-medium text-[#ffd100]">{quest.title}</span>
        <span className="font-mono text-xs text-muted">{quest.questId}</span>
        {quest.isComplete && (
          <Chip size="sm" color="success" variant="soft">
            ready
          </Chip>
        )}
      </div>
      <ul className="flex flex-col gap-2">
        {quest.objectives.map((objective, index) => {
          const isDone = objective.fulfilled >= objective.required;
          return (
            <li key={objective.text} className="grid grid-cols-[1fr_auto] items-center gap-x-2 gap-y-1">
              <span className={`truncate text-[13px] ${isDone ? "text-muted" : ""}`}>{objective.text}</span>
              <Button
                isIconOnly
                size="sm"
                variant="tertiary"
                aria-label={`One more for ${objective.text}`}
                isDisabled={isDone}
                onPress={() => void action.run({ action: "partyProgress", ...target, objective: index + 1, amount: 1 })}
              >
                <Plus />
              </Button>
              <ProgressBar
                aria-label={objective.text}
                size="sm"
                value={Math.min(objective.fulfilled, objective.required)}
                maxValue={Math.max(1, objective.required)}
                color={isDone ? "success" : "accent"}
                className="col-span-2"
              >
                <ProgressBar.Track>
                  <ProgressBar.Fill />
                </ProgressBar.Track>
              </ProgressBar>
            </li>
          );
        })}
      </ul>
      <div className="flex gap-2">
        <Button
          size="sm"
          variant="secondary"
          isDisabled={quest.isComplete}
          isPending={action.isPending}
          onPress={() => void action.run({ action: "partyComplete", ...target })}
        >
          <CircleCheck />
          Make ready
        </Button>
        <span className="grow" />
        <Button size="sm" variant="danger-soft" onPress={() => void action.run({ action: "partyAbandon", ...target })}>
          <TrashBin />
          Drop
        </Button>
      </div>
      {action.problem && <p className="text-xs text-danger">{action.problem}</p>}
    </li>
  );
};
