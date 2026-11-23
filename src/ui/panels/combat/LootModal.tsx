// The loot window, open while the game's is (LOOT_OPENED .. LOOT_CLOSED): each slot in its quality's colour, money in
// gold, quest items marked; taken one by one or all, closed as the game closes it
import { Box } from "@gravity-ui/icons";
import { Button, Chip, Modal } from "@heroui/react";
import type { CombatLoot } from "../../../shared/combat.ts";
import { useFlavour } from "../../flavours/index.ts";
import { useGameAction } from "../../sim/hooks.ts";
import { SpellIcon } from "./bars.tsx";

export const LootModal = ({ loot }: { loot: CombatLoot | undefined }) => {
  const flavour = useFlavour();
  const action = useGameAction();
  const close = (): void => void action.run({ action: "combatCloseLoot" });
  const takeAll = async (): Promise<void> => {
    for (const slot of loot?.slots ?? []) await action.run({ action: "combatLootSlot", slot: slot.slot });
  };
  return (
    <Modal.Backdrop isOpen={loot !== undefined} onOpenChange={(open) => !open && close()}>
      <Modal.Container size="xs">
        <Modal.Dialog className="loot-dialog">
          <Modal.CloseTrigger />
          {loot && (
            <>
              <Modal.Header>
                <Modal.Icon className="bg-warning-soft text-warning">
                  <Box className="size-5" />
                </Modal.Icon>
                <Modal.Heading>{loot.name}</Modal.Heading>
              </Modal.Header>
              <Modal.Body className="flex flex-col gap-1">
                {loot.slots.length === 0 && <p className="text-sm text-muted">Nothing left.</p>}
                {loot.slots.map((slot) => (
                  <button
                    key={slot.slot}
                    type="button"
                    className="flex cursor-pointer items-center gap-2.5 rounded-lg px-2 py-1.5 text-left hover:bg-white/5"
                    onClick={() => void action.run({ action: "combatLootSlot", slot: slot.slot })}
                  >
                    <SpellIcon icon={slot.icon} name={slot.name} size={30} />
                    <span
                      className="grow text-[13px] font-medium"
                      style={{
                        color: slot.isMoney
                          ? flavour.colors.money.gold
                          : (flavour.qualities[slot.quality]?.color ?? "#fff"),
                      }}
                    >
                      {slot.name}
                      {slot.quantity > 1 && !slot.isMoney ? ` ×${slot.quantity}` : ""}
                    </span>
                    {slot.isQuestItem && (
                      <Chip size="sm" color="warning" variant="soft">
                        quest
                      </Chip>
                    )}
                  </button>
                ))}
              </Modal.Body>
              <Modal.Footer>
                <Button variant="tertiary" onPress={close}>
                  Close
                </Button>
                <Button
                  isDisabled={loot.slots.length === 0}
                  isPending={action.isPending}
                  onPress={() => void takeAll()}
                >
                  Take all
                </Button>
              </Modal.Footer>
            </>
          )}
        </Modal.Dialog>
      </Modal.Container>
    </Modal.Backdrop>
  );
};
