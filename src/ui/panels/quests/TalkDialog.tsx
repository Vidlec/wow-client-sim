// Talking to a quest giver, as the game's gossip window: the quests they offer (a gold "!") to accept, the ones they
// take back (a "?", gold when ready) to turn in. Its contents are the game's own (state.npc), so what is accepted
// leaves the list at once; closing it closes the game's window too.
import { Button, Modal, toast } from "@heroui/react";
import { EmptyState } from "../../components/bits.tsx";
import { useGameAction, useSimState } from "../../sim/hooks.ts";
import type { NpcDialog } from "../../sim/types.ts";

type Props = { npcId: number | null; onClose: () => void };

const Mark = ({ sign, isLit }: { sign: "!" | "?"; isLit: boolean }) => (
  <span
    aria-hidden="true"
    className="flex size-6 shrink-0 items-center justify-center rounded-full text-[15px] font-black"
    style={{
      color: isLit ? "#ffd100" : "#8b8f96",
      textShadow: isLit ? "0 0 8px #ffd10088, 0 1px 0 #000" : "none",
      background: isLit ? "radial-gradient(circle, #ffd10022, transparent 70%)" : "transparent",
    }}
  >
    {sign}
  </span>
);

const NO_DIALOG: NpcDialog | null = null;

export const TalkDialog = ({ npcId, onClose }: Props) => {
  const dialog = useSimState((state): NpcDialog | null => state.npc ?? null, NO_DIALOG);
  const action = useGameAction();
  const isOpen = npcId !== null && dialog !== null && (dialog.id === undefined || dialog.id === npcId);

  const close = (): void => {
    void action.run({ action: "closeDialog" });
    onClose();
  };
  const run = async (kind: "accept" | "turnIn", questId: number, title: string): Promise<void> => {
    const answer = await action.run({ action: kind, questId });
    if (answer?.ok) toast.success(kind === "accept" ? `Accepted: ${title}` : `Turned in: ${title}`);
    else if (answer?.problem) toast.danger(`${title}: ${answer.problem}`);
  };

  return (
    <Modal.Backdrop isOpen={isOpen} onOpenChange={(open) => !open && close()}>
      <Modal.Container size="sm">
        <Modal.Dialog className="gossip-dialog">
          <Modal.CloseTrigger />
          {dialog && (
            <>
              <Modal.Header>
                <Modal.Heading className="quest-title text-lg">{dialog.name}</Modal.Heading>
                <p className="text-xs text-muted">Greetings, traveller. What brings you here?</p>
              </Modal.Header>
              <Modal.Body className="flex flex-col gap-1">
                {dialog.offers.length === 0 && dialog.active.length === 0 && (
                  <EmptyState>Nothing to offer you.</EmptyState>
                )}
                {dialog.offers.map((offer) => (
                  <div key={offer.questID} className="flex items-center gap-2 rounded-lg px-2 py-1.5 hover:bg-white/5">
                    <Mark sign="!" isLit />
                    <span className="grow text-[13px]">
                      <span className="font-mono text-xs text-muted">[{offer.questLevel}]</span> {offer.title}
                    </span>
                    <Button
                      size="sm"
                      isPending={action.isPending}
                      onPress={() => void run("accept", offer.questID, offer.title)}
                    >
                      Accept
                    </Button>
                  </div>
                ))}
                {dialog.active.map((quest) => (
                  <div key={quest.questID} className="flex items-center gap-2 rounded-lg px-2 py-1.5 hover:bg-white/5">
                    <Mark sign="?" isLit={quest.isComplete} />
                    <span className={`grow text-[13px] ${quest.isComplete ? "" : "text-muted"}`}>{quest.title}</span>
                    {quest.isComplete ? (
                      <Button
                        size="sm"
                        variant="secondary"
                        isPending={action.isPending}
                        onPress={() => void run("turnIn", quest.questID, quest.title)}
                      >
                        Turn in
                      </Button>
                    ) : (
                      <span className="text-xs text-muted">not done</span>
                    )}
                  </div>
                ))}
              </Modal.Body>
              <Modal.Footer>
                <Button variant="tertiary" onPress={close}>
                  Goodbye
                </Button>
              </Modal.Footer>
            </>
          )}
        </Modal.Dialog>
      </Modal.Container>
    </Modal.Backdrop>
  );
};
