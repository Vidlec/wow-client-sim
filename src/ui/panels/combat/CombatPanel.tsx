// The Combat panel: the player in the fight (bars, action buttons, attack and target), the enemies as nameplates
// (health, casts, threat, where they stand), bringing more in a window, the loot window, and the combat log; the fight
// reset with a seed, so the same seed plays the same fight
import { ArrowRotateLeft, Plus, Skull, TargetDart } from "@gravity-ui/icons";
import { Button, Chip, Label, NumberField, Popover } from "@heroui/react";
import { useState } from "react";
import type { CombatState } from "../../../shared/combat.ts";
import { EmptyState } from "../../components/bits.tsx";
import { Section } from "../../components/Section.tsx";
import { useGameAction, useSimState } from "../../sim/hooks.ts";
import { CombatLog } from "./CombatLog.tsx";
import { EnemyCard } from "./EnemyCard.tsx";
import { LootModal } from "./LootModal.tsx";
import { PlayerCard } from "./PlayerCard.tsx";
import { SpawnModal } from "./SpawnModal.tsx";

const NO_COMBAT: CombatState | null = null;

const ResetButton = ({ seed }: { seed: number }) => {
  const [chosen, setChosen] = useState(seed);
  const action = useGameAction();
  return (
    <Popover>
      <Button size="sm" variant="ghost">
        <ArrowRotateLeft />
        Reset
      </Button>
      <Popover.Content placement="bottom end" className="w-64">
        <Popover.Dialog className="flex flex-col gap-3 p-4">
          <Popover.Heading className="text-sm font-semibold">A fresh fight</Popover.Heading>
          <p className="text-xs text-muted">Every enemy gone, you alive and whole, out of combat.</p>
          <NumberField
            value={chosen}
            onChange={(value) => setChosen(Number.isFinite(value) ? value : 0)}
            formatOptions={{ useGrouping: false }}
          >
            <Label>Seed (the same plays the same fight)</Label>
            <NumberField.Group>
              <NumberField.Input />
            </NumberField.Group>
          </NumberField>
          <Button
            size="sm"
            variant="danger-soft"
            isPending={action.isPending}
            onPress={() => void action.run({ action: "combatReset", seed: chosen })}
          >
            Reset the fight
          </Button>
        </Popover.Dialog>
      </Popover.Content>
    </Popover>
  );
};

export const CombatPanel = () => {
  const combat = useSimState((state): CombatState | null => state.combat ?? null, NO_COMBAT);
  const now = useSimState((state) => state.now, 0);
  const [isSpawning, setSpawning] = useState(false);

  if (!combat)
    return (
      <EmptyState icon={<TargetDart />}>
        The battle simulator does not run in this simulator yet (lua/combat.lua): its state has no fight.
      </EmptyState>
    );

  const alive = combat.enemies.filter((enemy) => !enemy.isDead);
  return (
    <>
      <PlayerCard player={combat.player} now={now} />

      <Section
        title="Enemies"
        icon={<Skull className="size-3.5" />}
        actions={
          <div className="flex items-center gap-1">
            {combat.enemies.length > 0 && (
              <Chip size="sm" variant="soft" color={alive.length ? "danger" : "default"}>
                {alive.length} alive
              </Chip>
            )}
            <ResetButton seed={combat.seed} />
            <Button size="sm" variant="danger" onPress={() => setSpawning(true)}>
              <Plus />
              Bring
            </Button>
          </div>
        }
      >
        {combat.enemies.length === 0 ? (
          <EmptyState
            icon={<Skull />}
            action={
              <Button size="sm" variant="secondary" onPress={() => setSpawning(true)}>
                Bring an enemy
              </Button>
            }
          >
            No enemies about. Bring some to try your nameplates, unit frames and threat meters.
          </EmptyState>
        ) : (
          <div className="flex flex-col gap-2">
            {combat.enemies.map((enemy) => (
              <EnemyCard key={enemy.id} enemy={enemy} now={now} />
            ))}
          </div>
        )}
        <p className="text-[11px] text-muted">Nameplates show within {combat.nameplateRange} yards.</p>
      </Section>

      <Section
        title="Combat log"
        icon={<TargetDart className="size-3.5" />}
        description={
          combat.isCombatLogRestricted
            ? "The page's own: this client keeps COMBAT_LOG_EVENT_UNFILTERED from addons"
            : undefined
        }
      >
        <CombatLog lines={combat.log} />
      </Section>

      <SpawnModal isOpen={isSpawning} onClose={() => setSpawning(false)} />
      <LootModal loot={combat.loot} />
    </>
  );
};
