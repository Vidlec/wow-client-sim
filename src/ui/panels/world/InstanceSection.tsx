// Instances: inside one (its name, type and number) with a way out, or a window to enter one by the game's instance
// number, its type and name (the loading screen's events fire as in the game)
import { ArrowRightFromSquare, ArrowRightToSquare, FolderHouse } from "@gravity-ui/icons";
import { Button, Chip, Input, Label, ListBox, Modal, NumberField, Select, TextField } from "@heroui/react";
import { useState } from "react";
import { Problem } from "../../components/bits.tsx";
import { Section } from "../../components/Section.tsx";
import { useFlavour } from "../../flavours/index.ts";
import { useGameAction, useSimState } from "../../sim/hooks.ts";

const EnterModal = ({ isOpen, onClose }: { isOpen: boolean; onClose: () => void }) => {
  const flavour = useFlavour();
  const [instanceId, setInstanceId] = useState<number>(Number.NaN);
  const [instanceType, setInstanceType] = useState("party");
  const [name, setName] = useState("");
  const action = useGameAction();
  const enter = async (): Promise<void> => {
    if (!Number.isFinite(instanceId)) return;
    const answer = await action.run({
      action: "instance",
      instanceId,
      instanceType,
      ...(name.trim() ? { name: name.trim() } : {}),
    });
    if (answer && !answer.problem) onClose();
  };
  return (
    <Modal.Backdrop isOpen={isOpen} onOpenChange={(open) => !open && onClose()}>
      <Modal.Container size="sm">
        <Modal.Dialog>
          <Modal.CloseTrigger />
          <Modal.Header>
            <Modal.Icon className="bg-accent-soft text-accent">
              <ArrowRightToSquare className="size-5" />
            </Modal.Icon>
            <Modal.Heading>Enter an instance</Modal.Heading>
          </Modal.Header>
          <Modal.Body className="flex flex-col gap-4">
            <div className="grid grid-cols-2 gap-3">
              <NumberField minValue={1} value={instanceId} onChange={setInstanceId}>
                <Label>Instance ID</Label>
                <NumberField.Group>
                  <NumberField.Input placeholder="e.g. 2998" autoFocus />
                </NumberField.Group>
              </NumberField>
              <Select value={instanceType} onChange={(value) => setInstanceType(String(value ?? "party"))}>
                <Label>Type</Label>
                <Select.Trigger>
                  <Select.Value />
                  <Select.Indicator />
                </Select.Trigger>
                <Select.Popover>
                  <ListBox>
                    {flavour.instanceTypes.map((entry) => (
                      <ListBox.Item key={entry.id} id={entry.id} textValue={entry.name}>
                        {entry.name}
                        <ListBox.ItemIndicator />
                      </ListBox.Item>
                    ))}
                  </ListBox>
                </Select.Popover>
              </Select>
            </div>
            <TextField value={name} onChange={setName}>
              <Label>Name</Label>
              <Input placeholder="e.g. Alcaz Prison" onKeyDown={(event) => event.key === "Enter" && void enter()} />
            </TextField>
            <Problem>{action.problem}</Problem>
          </Modal.Body>
          <Modal.Footer>
            <Button variant="tertiary" slot="close">
              Cancel
            </Button>
            <Button isDisabled={!Number.isFinite(instanceId)} isPending={action.isPending} onPress={() => void enter()}>
              Enter
            </Button>
          </Modal.Footer>
        </Modal.Dialog>
      </Modal.Container>
    </Modal.Backdrop>
  );
};

export const InstanceSection = () => {
  const flavour = useFlavour();
  const inside = useSimState(
    (state) =>
      state.profile.isInInstance
        ? { id: state.profile.instanceId, type: state.profile.instanceType, name: state.profile.instanceName ?? null }
        : null,
    null,
  );
  const [isEntering, setEntering] = useState(false);
  const action = useGameAction();
  const typeName = inside ? (flavour.instanceTypes.find((entry) => entry.id === inside.type)?.name ?? inside.type) : "";
  return (
    <Section title="Instance" icon={<FolderHouse className="size-3.5" />}>
      {inside ? (
        <div className="flex items-center gap-3 rounded-lg bg-surface-secondary p-3">
          <div className="min-w-0 grow">
            <p className="truncate font-medium text-gold">{inside.name ?? `Instance ${inside.id}`}</p>
            <p className="text-xs text-muted">
              {typeName} · {inside.id}
            </p>
          </div>
          <Button
            size="sm"
            variant="danger-soft"
            isPending={action.isPending}
            onPress={() => void action.run({ action: "instance", instanceId: 0 })}
          >
            <ArrowRightFromSquare />
            Leave
          </Button>
        </div>
      ) : (
        <div className="flex items-center gap-3">
          <Chip size="sm" variant="soft">
            In the open world
          </Chip>
          <span className="grow" />
          <Button size="sm" variant="secondary" onPress={() => setEntering(true)}>
            <ArrowRightToSquare />
            Enter one…
          </Button>
        </div>
      )}
      <Problem>{action.problem}</Problem>
      {isEntering && <EnterModal isOpen onClose={() => setEntering(false)} />}
    </Section>
  );
};
