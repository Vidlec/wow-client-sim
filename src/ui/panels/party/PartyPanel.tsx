// The Party panel: the simulated players in the group, as cards; inviting one and driving their quests happen in
// windows over the page, so the panel itself stays a short list
import { PersonPlus, Persons } from "@gravity-ui/icons";
import { Button } from "@heroui/react";
import { useState } from "react";
import { useSimState } from "../../sim/hooks.ts";
import type { PartyMember } from "../../sim/types.ts";
import { InviteModal } from "./InviteModal.tsx";
import { MemberCard } from "./MemberCard.tsx";
import { QuestsModal } from "./QuestsModal.tsx";

const PARTY_SIZE = 4; // members besides the player

const NO_MEMBERS: PartyMember[] = [];

export const PartyPanel = () => {
  const members = useSimState((state) => state.party ?? NO_MEMBERS, NO_MEMBERS);
  const playerLevel = useSimState((state) => state.profile?.level ?? 1, 1);
  const [isInviting, setInviting] = useState(false);
  const [openName, setOpenName] = useState<string | null>(null);
  const openMember = members.find((member) => member.name === openName) ?? null;
  const isFull = members.length >= PARTY_SIZE;

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-2">
        <span className="grow text-[13px] text-muted">
          {members.length} of {PARTY_SIZE} {members.length === 1 ? "member" : "members"}
        </span>
        <Button size="sm" isDisabled={isFull} onPress={() => setInviting(true)}>
          <PersonPlus />
          Invite
        </Button>
      </div>

      {members.length === 0 ? (
        <div className="flex flex-col items-center gap-3 rounded-xl border border-border border-dashed px-6 py-10 text-center">
          <Persons className="size-8 text-muted" />
          <p className="text-muted">You are on your own. Invite simulated players to try your addon in a group.</p>
          <Button size="sm" variant="secondary" onPress={() => setInviting(true)}>
            Invite someone
          </Button>
        </div>
      ) : (
        members.map((member) => (
          <MemberCard key={member.name} member={member} onOpenQuests={() => setOpenName(member.name)} />
        ))
      )}

      <p className="text-xs leading-relaxed text-muted">
        A member's addon may send its counts on its own channel, inside dungeons too (Questie's, or one a project's
        plugin adds); the game itself shows everyone's progress outside dungeons only.
      </p>

      <InviteModal
        isOpen={isInviting}
        onClose={() => setInviting(false)}
        takenNames={members.map((member) => member.name)}
        playerLevel={playerLevel}
      />
      <QuestsModal member={openMember} onClose={() => setOpenName(null)} />
    </div>
  );
};
