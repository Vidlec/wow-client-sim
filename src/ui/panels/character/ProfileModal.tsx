// Changing who the character is: name, level, race (by faction), class (by colour), money (in gold, silver and
// copper) and rested experience, applied at once as the game would see a new character's
import { PersonPencil } from "@gravity-ui/icons";
import {
  Button,
  Description,
  Header,
  Input,
  Label,
  ListBox,
  Modal,
  NumberField,
  Select,
  TextField,
  toast,
} from "@heroui/react";
import { useState } from "react";
import { Problem } from "../../components/bits.tsx";
import { ClassPicker } from "../../components/ClassPicker.tsx";
import { splitMoney } from "../../components/Money.tsx";
import { findFaction, useFlavour } from "../../flavours/index.ts";
import { useGameAction } from "../../sim/hooks.ts";
import type { Profile } from "../../sim/types.ts";

type Props = { profile: Profile; isOpen: boolean; onClose: () => void };

const CoinField = ({
  label,
  value,
  onChange,
  max,
  color,
}: {
  label: string;
  value: number;
  onChange: (value: number) => void;
  max?: number;
  color: string;
}) => (
  <NumberField
    minValue={0}
    {...(max !== undefined ? { maxValue: max } : {})}
    value={value}
    onChange={(next) => onChange(Number.isFinite(next) ? next : 0)}
  >
    <Label style={{ color }}>{label}</Label>
    <NumberField.Group>
      <NumberField.Input />
    </NumberField.Group>
  </NumberField>
);

export const ProfileModal = ({ profile, isOpen, onClose }: Props) => {
  const flavour = useFlavour();
  const action = useGameAction();
  const money = splitMoney(profile.money);
  const [name, setName] = useState(profile.name);
  const [level, setLevel] = useState(profile.level);
  const [race, setRace] = useState(profile.race);
  const [classFile, setClassFile] = useState(profile.class);
  const [gold, setGold] = useState(money.gold);
  const [silver, setSilver] = useState(money.silver);
  const [copper, setCopper] = useState(money.copper);
  const [restedXp, setRestedXp] = useState(profile.restedXp ?? 0);

  const apply = async (): Promise<void> => {
    const answer = await action.run({
      action: "profile",
      profile: {
        name: name.trim() || profile.name,
        level,
        race,
        class: classFile,
        money: gold * 10000 + silver * 100 + copper,
        restedXp,
      },
    });
    if (answer && !answer.problem) {
      toast.success(`${name.trim() || profile.name} is ready`, { description: "The game sees the character anew" });
      onClose();
    }
  };

  const factions = (["Alliance", "Horde"] as const).map((id) => ({
    id,
    info: findFaction(flavour, id),
    races: flavour.races.filter((entry) => entry.faction === id),
  }));

  return (
    <Modal.Backdrop isOpen={isOpen} onOpenChange={(open) => !open && onClose()}>
      <Modal.Container size="md">
        <Modal.Dialog>
          <Modal.CloseTrigger />
          <Modal.Header>
            <Modal.Icon className="bg-accent-soft text-accent">
              <PersonPencil className="size-5" />
            </Modal.Icon>
            <Modal.Heading>The character</Modal.Heading>
          </Modal.Header>
          <Modal.Body className="flex flex-col gap-4">
            <div className="grid grid-cols-[1fr_9rem] gap-3">
              <TextField value={name} onChange={setName}>
                <Label>Name</Label>
                <Input autoFocus />
              </TextField>
              <NumberField
                minValue={1}
                maxValue={flavour.maxLevel}
                value={level}
                onChange={(next) => setLevel(Number.isFinite(next) ? next : 1)}
              >
                <Label>Level</Label>
                <NumberField.Group>
                  <NumberField.DecrementButton />
                  <NumberField.Input className="min-w-0 text-center tabular-nums" />
                  <NumberField.IncrementButton />
                </NumberField.Group>
              </NumberField>
            </div>
            <Select value={race} onChange={(value) => setRace(String(value ?? profile.race))}>
              <Label>Race</Label>
              <Select.Trigger>
                <Select.Value />
                <Select.Indicator />
              </Select.Trigger>
              <Select.Popover>
                <ListBox>
                  {factions.map((faction) => (
                    <ListBox.Section key={faction.id}>
                      <Header style={{ color: faction.info.color }}>{faction.info.name}</Header>
                      {faction.races.map((entry) => (
                        <ListBox.Item key={entry.file} id={entry.file} textValue={entry.name}>
                          {entry.name}
                          <ListBox.ItemIndicator />
                        </ListBox.Item>
                      ))}
                    </ListBox.Section>
                  ))}
                </ListBox>
              </Select.Popover>
            </Select>
            <ClassPicker value={classFile} onChange={setClassFile} />
            <div className="grid grid-cols-3 gap-3">
              <CoinField label="Gold" value={gold} onChange={setGold} color={flavour.colors.money.gold} />
              <CoinField
                label="Silver"
                value={silver}
                onChange={setSilver}
                max={99}
                color={flavour.colors.money.silver}
              />
              <CoinField
                label="Copper"
                value={copper}
                onChange={setCopper}
                max={99}
                color={flavour.colors.money.copper}
              />
            </div>
            <NumberField
              minValue={0}
              value={restedXp}
              onChange={(next) => setRestedXp(Number.isFinite(next) ? Math.max(0, Math.floor(next)) : 0)}
            >
              <Label>Rested experience</Label>
              <NumberField.Group>
                <NumberField.Input />
              </NumberField.Group>
              <Description>
                Kills give twice the experience until it is used up; addons read it (GetXPExhaustion)
              </Description>
            </NumberField>
            <Problem>{action.problem}</Problem>
          </Modal.Body>
          <Modal.Footer>
            <Button variant="tertiary" slot="close">
              Cancel
            </Button>
            <Button isPending={action.isPending} onPress={() => void apply()}>
              Apply
            </Button>
          </Modal.Footer>
        </Modal.Dialog>
      </Modal.Container>
    </Modal.Backdrop>
  );
};
