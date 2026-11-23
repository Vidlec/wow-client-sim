// Firing an event by hand: its name (any, or one seen already) and its arguments as JSON (a list, or one value), as
// the game would pass them to every frame registered for it
import { Thunderbolt } from "@gravity-ui/icons";
import {
  Button,
  ComboBox,
  Description,
  FieldError,
  Input,
  Label,
  ListBox,
  Modal,
  TextArea,
  TextField,
  toast,
} from "@heroui/react";
import { useMemo, useState } from "react";
import { api } from "../../sim/api.ts";
import { useTask } from "../../sim/hooks.ts";

type Props = { isOpen: boolean; onClose: () => void; knownEvents: readonly string[]; initialName?: string };

/** The arguments as the game takes them: a JSON list, or one value standing alone; null when not JSON */
const parseArgs = (text: string): unknown[] | null => {
  if (!text.trim()) return [];
  try {
    const value: unknown = JSON.parse(text);
    return Array.isArray(value) ? value : [value];
  } catch {
    return null;
  }
};

export const FireEventModal = ({ isOpen, onClose, knownEvents, initialName = "" }: Props) => {
  const [name, setName] = useState(initialName);
  const [argsText, setArgsText] = useState("");
  const args = parseArgs(argsText);
  const items = useMemo(() => knownEvents.map((event) => ({ id: event, name: event })), [knownEvents]);
  const fire = useTask(async () => {
    const event = name.trim().toUpperCase();
    if (!event || !args) return null;
    const answer = await api.fireEvent(event, args);
    toast.success(`${event} fired`, {
      indicator: <Thunderbolt />,
      description: args.length ? JSON.stringify(args) : "no arguments",
    });
    onClose();
    return answer;
  });

  return (
    <Modal.Backdrop isOpen={isOpen} onOpenChange={(open) => !open && onClose()}>
      <Modal.Container size="md">
        <Modal.Dialog>
          <Modal.CloseTrigger />
          <Modal.Header>
            <Modal.Icon className="bg-warning-soft text-warning">
              <Thunderbolt className="size-5" />
            </Modal.Icon>
            <Modal.Heading>Fire an event</Modal.Heading>
          </Modal.Header>
          <Modal.Body className="flex flex-col gap-4">
            <ComboBox
              allowsCustomValue
              inputValue={name}
              onInputChange={(value) => setName(value.toUpperCase())}
              items={items}
              menuTrigger="input"
              fullWidth
            >
              <Label>Event</Label>
              <ComboBox.InputGroup>
                <Input placeholder="QUEST_LOG_UPDATE" className="font-mono" autoFocus />
                <ComboBox.Trigger />
              </ComboBox.InputGroup>
              <Description>Any name; the ones the game fired so far are offered</Description>
              <ComboBox.Popover>
                <ListBox>
                  {(item: { id: string; name: string }) => (
                    <ListBox.Item id={item.id} textValue={item.name} className="font-mono text-[12px]">
                      {item.name}
                    </ListBox.Item>
                  )}
                </ListBox>
              </ComboBox.Popover>
            </ComboBox>
            <TextField value={argsText} onChange={setArgsText} isInvalid={args === null}>
              <Label>Arguments</Label>
              <TextArea placeholder='JSON: [123, "text", true]' className="font-mono text-[12px]" rows={3} />
              <Description>A JSON list, or one value</Description>
              <FieldError>Not JSON: a list like [123, "text"], or one value</FieldError>
            </TextField>
          </Modal.Body>
          <Modal.Footer>
            <Button variant="tertiary" slot="close">
              Cancel
            </Button>
            <Button
              isDisabled={!name.trim() || args === null}
              isPending={fire.isPending}
              onPress={() => void fire.run()}
            >
              <Thunderbolt />
              Fire
            </Button>
          </Modal.Footer>
        </Modal.Dialog>
      </Modal.Container>
    </Modal.Backdrop>
  );
};
