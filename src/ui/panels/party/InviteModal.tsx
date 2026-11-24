// Inviting a simulated player: a name (or one suggested), their class picked by its colour, their level and the quest
// addon they run (it decides what they tell the party: what a project's plugin makes it say, or only what the game
// shares). The addons offered are the ones the simulator lists (partyAddons.ts).
import { PersonPlus } from "@gravity-ui/icons";
import { Button, Input, Label, ListBox, Modal, NumberField, Select, TextField, toast } from "@heroui/react";
import { useEffect, useState } from "react";
import { Problem } from "../../components/bits.tsx";
import { ClassPicker } from "../../components/ClassPicker.tsx";
import { useGameAction } from "../../sim/hooks.ts";
import { usePartyAddons } from "./partyAddons.ts";

const SUGGESTED_NAMES = ["Garra", "Brakka", "Mira", "Olen", "Thokk", "Zula", "Vesh", "Rhaeg", "Kezzik", "Ulma"];

type Props = { isOpen: boolean; onClose: () => void; takenNames: readonly string[]; playerLevel: number };

const suggestName = (taken: readonly string[]): string =>
  SUGGESTED_NAMES.find((name) => !taken.includes(name)) ?? `Member${taken.length + 1}`;

export const InviteModal = ({ isOpen, onClose, takenNames, playerLevel }: Props) => {
  const [name, setName] = useState("");
  const [classFile, setClassFile] = useState("WARRIOR");
  const [level, setLevel] = useState<number | undefined>(undefined);
  const addons = usePartyAddons();
  const defaultAddon = addons.find((entry) => entry.isDefault)?.id ?? "none";
  const [addon, setAddon] = useState<string | null>(null);
  // Until one is picked, the default the simulator names (it is known only once the state has come)
  useEffect(() => {
    if (addon !== null && !addons.some((entry) => entry.id === addon)) setAddon(null);
  }, [addon, addons]);
  const chosenAddon = addon ?? defaultAddon;
  const action = useGameAction();
  const finalName = name.trim() || suggestName(takenNames);

  const invite = async (): Promise<void> => {
    const answer = await action.run({
      action: "partyAdd",
      name: finalName,
      class: classFile,
      ...(level !== undefined ? { level } : {}),
      addon: chosenAddon,
    });
    if (answer && !answer.problem) {
      setName("");
      toast.success(`${finalName} joined the party`);
      onClose();
    }
  };

  return (
    <Modal.Backdrop isOpen={isOpen} onOpenChange={(open) => !open && onClose()}>
      <Modal.Container size="sm">
        <Modal.Dialog>
          <Modal.CloseTrigger />
          <Modal.Header>
            <Modal.Icon className="bg-accent-soft text-accent">
              <PersonPlus className="size-5" />
            </Modal.Icon>
            <Modal.Heading>Invite to the party</Modal.Heading>
          </Modal.Header>
          <Modal.Body className="flex flex-col gap-4">
            <TextField value={name} onChange={setName}>
              <Label>Name</Label>
              <Input placeholder={suggestName(takenNames)} autoFocus />
            </TextField>
            <ClassPicker value={classFile} onChange={setClassFile} />
            <div className="grid grid-cols-2 gap-3">
              <NumberField minValue={1} maxValue={60} value={level ?? playerLevel} onChange={setLevel}>
                <Label>Level</Label>
                <NumberField.Group>
                  <NumberField.DecrementButton />
                  <NumberField.Input />
                  <NumberField.IncrementButton />
                </NumberField.Group>
              </NumberField>
              <Select value={chosenAddon} onChange={(value) => setAddon(String(value ?? "none"))}>
                <Label>Their addon</Label>
                <Select.Trigger>
                  <Select.Value>{({ selectedText }) => selectedText}</Select.Value>
                  <Select.Indicator />
                </Select.Trigger>
                <Select.Popover>
                  <ListBox>
                    {addons.map((entry) => (
                      <ListBox.Item key={entry.id} id={entry.id} textValue={entry.label}>
                        <div className="flex flex-col">
                          <span>{entry.label}</span>
                          <span className="text-xs text-muted">{entry.note}</span>
                        </div>
                        <ListBox.ItemIndicator />
                      </ListBox.Item>
                    ))}
                  </ListBox>
                </Select.Popover>
              </Select>
            </div>
            <Problem>{action.problem}</Problem>
          </Modal.Body>
          <Modal.Footer>
            <Button variant="tertiary" slot="close">
              Cancel
            </Button>
            <Button isPending={action.isPending} onPress={() => void invite()}>
              Invite {finalName}
            </Button>
          </Modal.Footer>
        </Modal.Dialog>
      </Modal.Container>
    </Modal.Backdrop>
  );
};
