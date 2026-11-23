// One party member: who they are (portrait, class, addon), how far along their quests are, and a menu of what can be
// done to them. Their quests open in a window of their own (QuestsModal), not inline.
import { EllipsisVertical, ListCheck } from "@gravity-ui/icons";
import { Button, Chip, Dropdown, Label, ProgressBar } from "@heroui/react";
import type { CSSProperties } from "react";
import { Portrait } from "../../components/Portrait.tsx";
import { findClass, useFlavour } from "../../flavours/index.ts";
import { useGameAction } from "../../sim/hooks.ts";
import type { PartyMember } from "../../sim/types.ts";
import { findPartyAddon, usePartyAddons } from "./partyAddons.ts";

type Props = { member: PartyMember; onOpenQuests: () => void };

/** Objectives done out of all, over every quest: how far along they are, as one bar */
const sumProgress = (member: PartyMember): { done: number; total: number; ready: number } => {
  let done = 0;
  let total = 0;
  let ready = 0;
  for (const quest of member.quests) {
    if (quest.isComplete) ready += 1;
    for (const objective of quest.objectives) {
      done += Math.min(objective.fulfilled, objective.required);
      total += objective.required;
    }
  }
  return { done, total, ready };
};

export const MemberCard = ({ member, onOpenQuests }: Props) => {
  const action = useGameAction();
  const classInfo = findClass(useFlavour(), member.class);
  const progress = sumProgress(member);
  const addon = findPartyAddon(usePartyAddons(), member.addon);
  const questCount = member.quests.length;

  const handleMenu = (key: string | number): void => {
    const name = member.name;
    if (key === "near") void action.run({ action: "partyMove", name, isHere: true });
    else if (key === "copy") void action.run({ action: "partyCopyLog", name });
    else if (key === "online") void action.run({ action: "partyOnline", name, isOnline: !member.isOnline });
    else if (key === "remove") void action.run({ action: "partyRemove", name });
  };

  return (
    <article
      className="member-card flex flex-col gap-3 rounded-xl border p-3"
      style={{ "--class-color": classInfo.color } as CSSProperties}
    >
      <div className="flex items-center gap-3">
        <Portrait name={member.name} classFile={member.class} level={member.level} isOnline={member.isOnline} />
        <div className="min-w-0 grow">
          <div className="flex items-baseline gap-2">
            <span className="truncate text-[15px] font-semibold">{member.name}</span>
            <span className="text-xs text-muted">{member.unit}</span>
          </div>
          <div className="flex items-center gap-2 text-[13px]">
            <span style={{ color: classInfo.color }}>{classInfo.name}</span>
            {!member.isOnline && <span className="text-muted">offline</span>}
            <Chip size="sm" variant="soft" color={addon.color}>
              {addon.label}
            </Chip>
          </div>
        </div>
        <Dropdown>
          <Button
            isIconOnly
            size="sm"
            variant="ghost"
            aria-label={`More for ${member.name}`}
            isPending={action.isPending}
          >
            <EllipsisVertical />
          </Button>
          <Dropdown.Popover>
            <Dropdown.Menu onAction={handleMenu}>
              <Dropdown.Item id="near" textValue="Stand beside me">
                <Label>Stand beside me</Label>
              </Dropdown.Item>
              <Dropdown.Item id="copy" textValue="Give them my quests">
                <Label>Give them my quests</Label>
              </Dropdown.Item>
              <Dropdown.Item id="online" textValue={member.isOnline ? "Go offline" : "Come online"}>
                <Label>{member.isOnline ? "Go offline" : "Come online"}</Label>
              </Dropdown.Item>
              <Dropdown.Item id="remove" textValue="Remove from the party" variant="danger">
                <Label>Remove from the party</Label>
              </Dropdown.Item>
            </Dropdown.Menu>
          </Dropdown.Popover>
        </Dropdown>
      </div>

      <button
        type="button"
        onClick={onOpenQuests}
        className="flex w-full cursor-pointer flex-col gap-1.5 rounded-lg bg-surface-secondary px-3 py-2 text-left hover:bg-[#262b33]"
      >
        <span className="flex items-center gap-2 text-[13px]">
          <ListCheck className="size-4 text-muted" />
          <span className="grow">
            {questCount === 0 ? "No quests" : `${questCount} quest${questCount === 1 ? "" : "s"}`}
          </span>
          {progress.ready > 0 && (
            <Chip size="sm" color="success" variant="soft">
              {progress.ready} ready
            </Chip>
          )}
        </span>
        {progress.total > 0 && (
          <ProgressBar
            aria-label={`${member.name}'s quest progress`}
            size="sm"
            value={progress.done}
            maxValue={progress.total}
            color={progress.done >= progress.total ? "success" : "accent"}
          >
            <ProgressBar.Track>
              <ProgressBar.Fill />
            </ProgressBar.Track>
          </ProgressBar>
        )}
      </button>
      {action.problem && <p className="text-xs text-danger">{action.problem}</p>}
    </article>
  );
};
