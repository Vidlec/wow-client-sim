// The Character panel: who the character is (a card in their class's colours: level, race, faction, money,
// experience), changed in a window; and what the game tells addons: in combat, identities and threat hidden
import { PersonPencil, Shield } from "@gravity-ui/icons";
import { Button, Chip, Label, Meter } from "@heroui/react";
import { useState } from "react";
import { Facts, SwitchRow } from "../../components/bits.tsx";
import { Money } from "../../components/Money.tsx";
import { Portrait } from "../../components/Portrait.tsx";
import { Section } from "../../components/Section.tsx";
import { findClass, findFaction, findRace, useFlavour } from "../../flavours/index.ts";
import { useGameAction, useSimState } from "../../sim/hooks.ts";
import type { Profile } from "../../sim/types.ts";
import { ProfileModal } from "./ProfileModal.tsx";

const CharacterCard = ({ profile, onEdit }: { profile: Profile; onEdit: () => void }) => {
  const flavour = useFlavour();
  const classInfo = findClass(flavour, profile.class);
  const race = findRace(flavour, profile.race);
  const faction = findFaction(flavour, profile.faction ?? race.faction);
  const itemKinds = Object.keys(profile.items ?? {}).length;
  const achievements = Object.keys(profile.achievements ?? {}).length;
  return (
    <div
      className="character-card relative overflow-hidden rounded-xl border p-4"
      style={{
        borderColor: `${classInfo.color}55`,
        background: `radial-gradient(120% 90% at 0% 0%, ${classInfo.color}2a, transparent 60%), linear-gradient(160deg, #1a1e24, #121519)`,
      }}
    >
      <div className="flex items-center gap-4">
        <Portrait name={profile.name} classFile={profile.class} level={profile.level} size="lg" />
        <div className="min-w-0 grow">
          <h3 className="truncate text-xl font-semibold" style={{ color: classInfo.color }}>
            {profile.name}
          </h3>
          <p className="text-[13px] text-muted">
            Level {profile.level} {profile.raceName ?? race.name} {classInfo.name}
          </p>
          <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
            <Chip size="sm" variant="soft" style={{ color: faction.color, background: `${faction.color}22` }}>
              {faction.name}
            </Chip>
            {profile.realm && (
              <Chip size="sm" variant="soft">
                {profile.realm}
              </Chip>
            )}
          </div>
        </div>
        <Button isIconOnly size="sm" variant="secondary" aria-label="Change the character" onPress={onEdit}>
          <PersonPencil />
        </Button>
      </div>
      {profile.xpMax ? (
        <Meter aria-label="Experience" value={profile.xp ?? 0} maxValue={profile.xpMax} size="sm" className="mt-4">
          <Label className="text-[11px] text-muted">Experience</Label>
          <Meter.Output className="text-[11px] text-muted">
            {(profile.xp ?? 0).toLocaleString()} / {profile.xpMax.toLocaleString()}
          </Meter.Output>
          <Meter.Track>
            <Meter.Fill />
          </Meter.Track>
        </Meter>
      ) : null}
      <div className="mt-4">
        <Facts
          rows={[
            ["Money", <Money key="money" copper={profile.money} />],
            ["Carrying", itemKinds ? `${itemKinds} kinds of item` : "nothing"],
            ["Achievements", achievements ? `${achievements} earned` : "none yet"],
          ]}
        />
      </div>
    </div>
  );
};

const GameState = () => {
  const restrictions = useSimState((state) => state.restrictions, { identity: false, threat: false });
  const serverCombat = useSimState((state) => state.inCombat ?? null, null);
  // (the state does not say whether the character is in combat: the switch keeps what it last sent)
  const [combat, setCombat] = useState(false);
  const inCombat = serverCombat ?? combat;
  const action = useGameAction();
  return (
    <Section
      title="What the game tells addons"
      icon={<Shield className="size-3.5" />}
      description="States an addon has to cope with, switched by hand"
    >
      <SwitchRow
        label="In combat"
        description="PLAYER_REGEN_DISABLED now, PLAYER_REGEN_ENABLED when it ends; InCombatLockdown() answers true"
        isSelected={inCombat}
        onChange={(isOn) => {
          setCombat(isOn);
          void action.run({ action: "combat", inCombat: isOn });
        }}
      />
      <SwitchRow
        label="Unit identities hidden"
        description="As in PvP and some instances: names and GUIDs of others are secret to addons"
        isSelected={restrictions.identity}
        onChange={(isOn) => void action.run({ action: "restrict", identity: isOn, threat: restrictions.threat })}
      />
      <SwitchRow
        label="Threat hidden"
        description="UnitDetailedThreatSituation and the like answer nothing"
        isSelected={restrictions.threat}
        onChange={(isOn) => void action.run({ action: "restrict", identity: restrictions.identity, threat: isOn })}
      />
    </Section>
  );
};

export const CharacterPanel = () => {
  const profile = useSimState((state): Profile | null => state.profile, null);
  const [isEditing, setEditing] = useState(false);
  if (!profile) return null;
  return (
    <>
      <CharacterCard profile={profile} onEdit={() => setEditing(true)} />
      <GameState />
      {isEditing && <ProfileModal profile={profile} isOpen onClose={() => setEditing(false)} />}
    </>
  );
};
