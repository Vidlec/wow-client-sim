// Bringing enemies in: a creature found by name or id (the game's data), or one the quests in the log still need; how
// many, how far and where from the player, its level, whether it attacks on its own, and whether someone else tapped it
import { Compass, ListCheck, Skull } from "@gravity-ui/icons";
import { Button, Label, Modal, NumberField, SearchField, Slider, Spinner, toast } from "@heroui/react";
import { useState } from "react";
import { Problem, SwitchRow } from "../../components/bits.tsx";
import { api } from "../../sim/api.ts";
import { useGameAction } from "../../sim/hooks.ts";
import type { FoundNpc } from "../../sim/types.ts";
import { useQuestCreatures } from "../../sim/useQuestSources.ts";
import { useSearch } from "../../sim/useSearch.ts";

const findNpcs = (query: string): Promise<FoundNpc[]> => api.findNpcs(query, 8);

const sliderValue = (value: number | number[]): number => (Array.isArray(value) ? (value[0] ?? 0) : value);

export const SpawnModal = ({ isOpen, onClose }: { isOpen: boolean; onClose: () => void }) => {
  const [text, setText] = useState("");
  const [chosen, setChosen] = useState<FoundNpc | null>(null);
  const [count, setCount] = useState(1);
  const [distance, setDistance] = useState(20);
  const [bearing, setBearing] = useState(0);
  const [level, setLevel] = useState<number>(Number.NaN);
  const [aggro, setAggro] = useState(true);
  const [isTapped, setTapped] = useState(false);
  const search = useSearch(chosen ? "" : text, findNpcs);
  const questCreatures = useQuestCreatures();
  const action = useGameAction();

  const spawn = async (): Promise<void> => {
    if (!chosen) return;
    const answer = await action.run({
      action: "combatSpawn",
      npcId: chosen.id,
      count,
      distance,
      bearing,
      aggro,
      isTappedByOthers: isTapped,
      ...(Number.isFinite(level) ? { level } : {}),
    });
    if (answer?.ok) {
      toast(`${count === 1 ? chosen.name : `${count} × ${chosen.name}`} ${count === 1 ? "is" : "are"} here`, {
        indicator: <Skull />,
      });
      onClose();
    }
  };

  return (
    <Modal.Backdrop isOpen={isOpen} onOpenChange={(open) => !open && onClose()}>
      <Modal.Container size="md">
        <Modal.Dialog>
          <Modal.CloseTrigger />
          <Modal.Header>
            <Modal.Icon className="bg-danger-soft text-danger">
              <Skull className="size-5" />
            </Modal.Icon>
            <Modal.Heading>Bring enemies</Modal.Heading>
          </Modal.Header>
          <Modal.Body className="flex flex-col gap-4">
            {chosen ? (
              <div className="flex items-center gap-2 rounded-lg bg-surface-secondary px-3 py-2">
                <span className="grow text-[13px] font-semibold text-danger">{chosen.name}</span>
                <span className="font-mono text-xs text-muted">
                  {chosen.id}
                  {chosen.level ? ` · level ${chosen.level}` : ""}
                </span>
                <Button size="sm" variant="ghost" onPress={() => setChosen(null)}>
                  Change
                </Button>
              </div>
            ) : (
              <div className="flex flex-col gap-2">
                <SearchField aria-label="Find a creature" value={text} onChange={setText} autoFocus>
                  <SearchField.Group>
                    <SearchField.SearchIcon />
                    <SearchField.Input placeholder="A creature's name or id, e.g. Plainstrider" />
                    {search.isSearching ? <Spinner size="sm" className="mr-2" /> : <SearchField.ClearButton />}
                  </SearchField.Group>
                </SearchField>
                {text.trim() === "" && questCreatures.length > 0 && (
                  <div className="flex flex-col gap-1">
                    <span className="flex items-center gap-1.5 px-1 text-xs font-medium text-muted">
                      <ListCheck className="size-3.5" />
                      Your quests need
                    </span>
                    <ul className="flex max-h-56 flex-col overflow-y-auto">
                      {questCreatures.map((creature) => (
                        <li key={creature.id}>
                          <button
                            type="button"
                            className="flex w-full cursor-pointer items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-[13px] hover:bg-surface-secondary"
                            onClick={() => setChosen({ id: creature.id, name: creature.name })}
                          >
                            <Skull className="size-3.5 shrink-0 text-danger" />
                            <span className="flex min-w-0 grow flex-col">
                              <span className="truncate">{creature.name}</span>
                              <span className="truncate text-xs text-muted">
                                {creature.objective} · {creature.questTitle}
                              </span>
                            </span>
                            <span className="font-mono text-xs text-muted">{creature.id}</span>
                          </button>
                        </li>
                      ))}
                    </ul>
                  </div>
                )}
                <ul className="flex flex-col">
                  {search.results.map((npc) => (
                    <li key={npc.id}>
                      <button
                        type="button"
                        className="flex w-full cursor-pointer items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-[13px] hover:bg-surface-secondary"
                        onClick={() => setChosen(npc)}
                      >
                        <span className="grow truncate">{npc.name}</span>
                        <span className="font-mono text-xs text-muted">
                          {npc.id}
                          {npc.level ? ` · ${npc.level}` : ""}
                        </span>
                      </button>
                    </li>
                  ))}
                </ul>
              </div>
            )}
            <div className="grid grid-cols-2 gap-3">
              <NumberField
                minValue={1}
                maxValue={20}
                value={count}
                onChange={(value) => setCount(Number.isFinite(value) ? value : 1)}
              >
                <Label>How many</Label>
                <NumberField.Group>
                  <NumberField.DecrementButton />
                  <NumberField.Input />
                  <NumberField.IncrementButton />
                </NumberField.Group>
              </NumberField>
              <NumberField minValue={1} maxValue={63} value={level} onChange={setLevel}>
                <Label>Level</Label>
                <NumberField.Group>
                  <NumberField.Input placeholder="its own" />
                </NumberField.Group>
              </NumberField>
            </div>
            <Slider minValue={2} maxValue={60} value={distance} onChange={(value) => setDistance(sliderValue(value))}>
              <Label>Distance</Label>
              <Slider.Output>{distance} yd</Slider.Output>
              <Slider.Track>
                <Slider.Fill />
                <Slider.Thumb />
              </Slider.Track>
            </Slider>
            <Slider
              minValue={-180}
              maxValue={180}
              step={15}
              value={bearing}
              onChange={(value) => setBearing(sliderValue(value))}
            >
              <Label className="inline-flex items-center gap-1">
                <Compass className="size-3.5" style={{ transform: `rotate(${bearing}deg)` }} />
                Where from your facing
              </Label>
              <Slider.Output>
                {bearing === 0
                  ? "ahead"
                  : Math.abs(bearing) === 180
                    ? "behind"
                    : `${Math.abs(bearing)}° ${bearing > 0 ? "right" : "left"}`}
              </Slider.Output>
              <Slider.Track>
                <Slider.Fill />
                <Slider.Thumb />
              </Slider.Track>
            </Slider>
            <SwitchRow
              label="It attacks on its own"
              description="Off: it waits, even when hostile"
              isSelected={aggro}
              onChange={setAggro}
            />
            <SwitchRow
              label="Tapped by someone else"
              description="No credit and no loot for you, as a grey creature"
              isSelected={isTapped}
              onChange={setTapped}
            />
            <Problem>{action.problem}</Problem>
          </Modal.Body>
          <Modal.Footer>
            <Button variant="tertiary" slot="close">
              Cancel
            </Button>
            <Button variant="danger" isDisabled={!chosen} isPending={action.isPending} onPress={() => void spawn()}>
              <Skull />
              Bring {count > 1 ? count : "it"}
            </Button>
          </Modal.Footer>
        </Modal.Dialog>
      </Modal.Container>
    </Modal.Backdrop>
  );
};
