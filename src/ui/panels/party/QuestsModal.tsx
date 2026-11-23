// A member's quests in a window over the page: give one, move each along, make it ready, drop it
import { Modal } from "@heroui/react";
import { Portrait } from "../../components/Portrait.tsx";
import { findClass, useFlavour } from "../../flavours/index.ts";
import type { PartyMember } from "../../sim/types.ts";
import { GiveQuest } from "./GiveQuest.tsx";
import { QuestRow } from "./QuestRow.tsx";

type Props = { member: PartyMember | null; onClose: () => void };

export const QuestsModal = ({ member, onClose }: Props) => {
  const flavour = useFlavour();
  const classInfo = member ? findClass(flavour, member.class) : null;
  return (
    <Modal.Backdrop isOpen={member !== null} onOpenChange={(isOpen) => !isOpen && onClose()}>
      <Modal.Container size="lg">
        <Modal.Dialog className="max-h-[85vh]">
          <Modal.CloseTrigger />
          {member && (
            <>
              <Modal.Header className="flex-row items-center gap-3">
                <Portrait name={member.name} classFile={member.class} level={member.level} isOnline={member.isOnline} />
                <div>
                  <Modal.Heading>{member.name}'s quests</Modal.Heading>
                  <p className="text-[13px]" style={{ color: classInfo?.color }}>
                    {classInfo?.name} {member.level}
                  </p>
                </div>
              </Modal.Header>
              <Modal.Body className="flex flex-col gap-4 overflow-y-auto">
                <GiveQuest memberName={member.name} givenIds={new Set(member.quests.map((quest) => quest.questId))} />
                {member.quests.length === 0 ? (
                  <p className="py-6 text-center text-muted">No quests yet: give one above.</p>
                ) : (
                  <ul className="flex flex-col gap-3">
                    {member.quests.map((quest) => (
                      <QuestRow key={quest.questId} memberName={member.name} quest={quest} />
                    ))}
                  </ul>
                )}
              </Modal.Body>
            </>
          )}
        </Modal.Dialog>
      </Modal.Container>
    </Modal.Backdrop>
  );
};
