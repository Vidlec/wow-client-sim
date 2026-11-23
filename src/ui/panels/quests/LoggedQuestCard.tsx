// One quest of the log: its title in the game's gold, each objective's count with a bar and a "+1", who to kill or
// what to open for it (a creature's menu brings it to fight, or kills it at once as the game would report it), and
// the quest completed, turned in or abandoned (abandoning asks first)
import { CircleCheck, Eye, Persons, Plus, Skull, Thunderbolt, TrashBin, Tray } from "@gravity-ui/icons";
import {
  AlertDialog,
  Button,
  Chip,
  Description,
  Dropdown,
  Header,
  Label,
  ProgressBar,
  Tooltip,
  toast,
} from "@heroui/react";
import { memo, useState } from "react";
import { Problem } from "../../components/bits.tsx";
import type { GameAction } from "../../sim/api.ts";
import { useGameAction } from "../../sim/hooks.ts";
import { getPrefs } from "../../sim/prefs.ts";
import type { LoggedQuest, ObjectiveSource, QuestSources } from "../../sim/types.ts";
import { announceBrought, bringAction, QUEST_SPAWN_DISTANCE } from "../combat/bringEnemy.ts";

const SOURCES_SHOWN = 3;

/** An objective without its count ("3/8 Raptor Head" is "Raptor Head"): what stays the same as it counts up */
export const objectiveName = (text: string): string => text.replace(/^\d+\/\d+\s+/, "");

type Props = { quest: LoggedQuest; sources: QuestSources["objectives"] | undefined };

/** What a source's menu can do: a creature brought to fight (one, or a pack), or killed at once; an object looted */
type SourceChoice = "fight" | "pack" | "kill" | "loot";
const PACK_SIZE = 3;

type Run = (change: GameAction, label: string, onDone?: () => void) => void;

const runChoice = (choice: SourceChoice, source: ObjectiveSource, itemId: number | undefined, run: Run): void => {
  if (choice === "fight" || choice === "pack") {
    const count = choice === "pack" ? PACK_SIZE : 1;
    run(bringAction(source.id, count), `Bring ${source.name}`, () => announceBrought(source.name, count));
  } else if (choice === "kill") {
    run({ action: "kill", npcId: source.id, loot: getPrefs().lootOnKill }, `Kill ${source.name}`);
  } else {
    run({ action: "loot", itemId: itemId ?? 0, count: 1 }, `Loot ${source.name}`);
  }
};

/** A creature's menu: fighting it is the first choice, the instant kill (only the count) the last */
const CreatureItems = ({ idPrefix }: { idPrefix: string }) => (
  <>
    <Dropdown.Item id={`fight:${idPrefix}`} textValue="Bring one to fight">
      <Skull className="size-4 shrink-0 text-danger" />
      <div className="flex flex-col">
        <Label>Bring one to fight</Label>
        <Description>{QUEST_SPAWN_DISTANCE} yards ahead, ready to fight</Description>
      </div>
    </Dropdown.Item>
    <Dropdown.Item id={`pack:${idPrefix}`} textValue={`Bring ${PACK_SIZE}`}>
      <Persons className="size-4 shrink-0 text-danger" />
      <div className="flex flex-col">
        <Label>Bring {PACK_SIZE}</Label>
        <Description>A pull of several, for threat and nameplates</Description>
      </div>
    </Dropdown.Item>
    <Dropdown.Item id={`kill:${idPrefix}`} textValue="Kill at once">
      <Thunderbolt className="size-4 shrink-0 text-muted" />
      <div className="flex flex-col">
        <Label>Kill at once</Label>
        <Description>No fight: the kill and its credit only</Description>
      </div>
    </Dropdown.Item>
  </>
);

const Sources = ({ sources, itemId, run }: { sources: ObjectiveSource[]; itemId: number | undefined; run: Run }) => {
  const shown = sources.slice(0, SOURCES_SHOWN);
  const more = sources.slice(SOURCES_SHOWN);
  const keyOf = (source: ObjectiveSource): string => `${source.kind}${source.id}`;
  const choose = (key: string | number): void => {
    const [choice, sourceKey] = String(key).split(":") as [SourceChoice, string];
    const source = sources.find((entry) => keyOf(entry) === sourceKey);
    if (source) runChoice(choice, source, itemId, run);
  };
  return (
    <div className="flex flex-wrap gap-1 pl-1">
      {shown.map((source) =>
        source.kind === "npc" ? (
          <Dropdown key={keyOf(source)}>
            <Button size="sm" variant="ghost" className="h-6 px-2 text-xs" aria-label={`${source.name}: fight or kill`}>
              <Skull className="size-3 text-danger" />
              {source.name}
            </Button>
            <Dropdown.Popover className="min-w-[240px]">
              <Dropdown.Menu onAction={choose}>
                <Dropdown.Section>
                  <Header>
                    {source.name} <span className="font-mono text-muted">{source.id}</span>
                  </Header>
                  <CreatureItems idPrefix={keyOf(source)} />
                </Dropdown.Section>
              </Dropdown.Menu>
            </Dropdown.Popover>
          </Dropdown>
        ) : (
          <Tooltip key={keyOf(source)} delay={400}>
            <Button
              size="sm"
              variant="ghost"
              className="h-6 px-2 text-xs"
              onPress={() => runChoice("loot", source, itemId, run)}
            >
              <Tray className="size-3 text-warning" />
              {source.name}
            </Button>
            <Tooltip.Content>
              Loot {source.name} (object {source.id})
            </Tooltip.Content>
          </Tooltip>
        ),
      )}
      {more.length > 0 && (
        <Dropdown>
          <Button size="sm" variant="ghost" className="h-6 px-2 text-xs text-muted">
            +{more.length} more
          </Button>
          <Dropdown.Popover className="max-h-72 min-w-[240px]">
            <Dropdown.Menu onAction={choose}>
              {more.map((source) => (
                <Dropdown.Section key={keyOf(source)}>
                  <Header>{source.name}</Header>
                  {source.kind === "npc" ? (
                    <CreatureItems idPrefix={keyOf(source)} />
                  ) : (
                    <Dropdown.Item id={`loot:${keyOf(source)}`} textValue={`Loot ${source.name}`}>
                      <Tray className="size-4 shrink-0 text-warning" />
                      <Label>Loot it</Label>
                    </Dropdown.Item>
                  )}
                </Dropdown.Section>
              ))}
            </Dropdown.Menu>
          </Dropdown.Popover>
        </Dropdown>
      )}
    </div>
  );
};

export const LoggedQuestCard = memo(({ quest, sources }: Props) => {
  const action = useGameAction();
  const [isAbandoning, setAbandoning] = useState(false);
  const run = (change: GameAction, label?: string, onDone?: () => void): void => {
    void action.run(change).then((answer) => {
      if (answer?.problem) toast.danger(`${label ?? quest.title}: ${answer.problem}`);
      else if (answer?.ok) onDone?.();
    });
  };
  const turnIn = async (): Promise<void> => {
    const answer = await action.run({ action: "turnIn", questId: quest.questId });
    if (answer?.ok) toast.success(`Turned in: ${quest.title}`);
  };

  return (
    <article
      className={`quest-card flex flex-col gap-2.5 rounded-xl border p-3 ${quest.isComplete ? "is-complete" : ""}`}
    >
      <header className="flex items-start gap-2">
        <span className="mt-0.5 font-mono text-[11px] text-muted">[{quest.level}]</span>
        <h4 className="quest-title min-w-0 grow text-[13px] font-semibold">{quest.title}</h4>
        {quest.watched && (
          <Tooltip delay={300}>
            <Eye className="mt-0.5 size-3.5 text-muted" aria-label="Tracked" />
            <Tooltip.Content>Tracked on the screen</Tooltip.Content>
          </Tooltip>
        )}
        {quest.isComplete && (
          <Chip size="sm" variant="soft" color="success">
            ready
          </Chip>
        )}
        <span className="font-mono text-[11px] text-muted">{quest.questId}</span>
      </header>
      <ul className="flex flex-col gap-2">
        {quest.objectives.map((objective, index) => {
          const isDone = objective.fulfilled >= objective.required;
          const found = sources?.[index];
          return (
            <li key={objectiveName(objective.text)} className="flex flex-col gap-1">
              <div className="flex items-center gap-2">
                <span
                  className={`min-w-0 grow truncate text-[13px] ${isDone ? "text-muted line-through decoration-1" : ""}`}
                >
                  {objective.text}
                </span>
                <Button
                  isIconOnly
                  size="sm"
                  variant="tertiary"
                  className="size-6 min-w-6"
                  aria-label={`One more for ${objective.text}`}
                  isDisabled={isDone}
                  onPress={() => run({ action: "progress", questId: quest.questId, objective: index + 1, amount: 1 })}
                >
                  <Plus />
                </Button>
              </div>
              <ProgressBar
                aria-label={objective.text}
                size="sm"
                value={Math.min(objective.fulfilled, objective.required)}
                maxValue={Math.max(1, objective.required)}
                color={isDone ? "success" : "accent"}
              >
                <ProgressBar.Track>
                  <ProgressBar.Fill />
                </ProgressBar.Track>
              </ProgressBar>
              {!isDone && found?.sources && found.sources.length > 0 && (
                <Sources sources={found.sources} itemId={found.itemId} run={run} />
              )}
            </li>
          );
        })}
      </ul>
      <footer className="flex gap-1.5">
        <Button
          size="sm"
          variant="secondary"
          isDisabled={quest.isComplete}
          onPress={() => run({ action: "complete", questId: quest.questId })}
        >
          <CircleCheck />
          Complete
        </Button>
        <Button size="sm" variant={quest.isComplete ? "primary" : "tertiary"} onPress={() => void turnIn()}>
          Turn in
        </Button>
        <span className="grow" />
        <Button size="sm" variant="ghost" aria-label={`Abandon ${quest.title}`} onPress={() => setAbandoning(true)}>
          <TrashBin />
        </Button>
      </footer>
      <Problem>{action.problem}</Problem>
      <AlertDialog.Backdrop isOpen={isAbandoning} onOpenChange={setAbandoning}>
        <AlertDialog.Container>
          <AlertDialog.Dialog className="sm:max-w-[400px]">
            <AlertDialog.Header>
              <AlertDialog.Icon status="danger" />
              <AlertDialog.Heading>Abandon “{quest.title}”?</AlertDialog.Heading>
            </AlertDialog.Header>
            <AlertDialog.Body>
              <p className="text-sm text-muted">It leaves the log with its progress, as the game's Abandon does.</p>
            </AlertDialog.Body>
            <AlertDialog.Footer>
              <Button slot="close" variant="tertiary">
                Keep it
              </Button>
              <Button slot="close" variant="danger" onPress={() => run({ action: "abandon", questId: quest.questId })}>
                Abandon
              </Button>
            </AlertDialog.Footer>
          </AlertDialog.Dialog>
        </AlertDialog.Container>
      </AlertDialog.Backdrop>
    </article>
  );
});
