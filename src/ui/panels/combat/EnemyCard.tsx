// An enemy, as its nameplate and the target frame show it: its name in its reaction's colour, level and rank (an
// elite's gold edge), health, its cast, the player's threat on it in the game's colours, where it stands from the
// player; and what can be done to it: target, focus, attack, hurt or heal, loot, take away
import { ArrowUp, Box, EllipsisVertical, Eye, TargetDart } from "@gravity-ui/icons";
import { Button, Chip, Dropdown, Label, Tooltip } from "@heroui/react";
import { memo } from "react";
import type { CombatEnemy } from "../../../shared/combat.ts";
import { useGameAction } from "../../sim/hooks.ts";
import { Auras, Bar, CastBar, reactionColor, THREAT_COLORS } from "./bars.tsx";

const RANKS: Partial<Record<CombatEnemy["classification"], string>> = {
  elite: "Elite",
  rareelite: "Rare elite",
  rare: "Rare",
  worldboss: "Boss",
};

const DAMAGES = [
  { id: "hurt-10", label: "Hurt 10%", share: 0.1 },
  { id: "hurt-50", label: "Hurt half", share: 0.5 },
  { id: "heal", label: "Heal fully", share: -1 },
] as const;

export const EnemyCard = memo(({ enemy, now }: { enemy: CombatEnemy; now: number }) => {
  const action = useGameAction();
  const enemyId = enemy.id;
  const rank = RANKS[enemy.classification];
  const isElite =
    enemy.classification === "elite" || enemy.classification === "rareelite" || enemy.classification === "worldboss";
  const healthShare = enemy.healthMax > 0 ? Math.round((enemy.health / enemy.healthMax) * 100) : 0;

  const onMenu = (key: string | number): void => {
    if (key === "focus") void action.run({ action: "combatFocus", enemyId });
    else if (key === "despawn") void action.run({ action: "combatDespawn", enemyId });
    else {
      const damage = DAMAGES.find((entry) => entry.id === key);
      if (damage) {
        const amount = damage.share < 0 ? -enemy.healthMax : Math.max(1, Math.round(enemy.healthMax * damage.share));
        void action.run({ action: "combatDamage", enemyId, amount });
      }
    }
  };

  return (
    <article
      className={`enemy-card flex flex-col gap-1.5 rounded-xl border p-2.5 ${enemy.isTarget ? "is-target" : ""} ${isElite ? "is-elite" : ""} ${enemy.isDead ? "is-dead" : ""}`}
      onMouseEnter={() => void action.run({ action: "combatHover", enemyId })}
      onMouseLeave={() => void action.run({ action: "combatHover" })}
    >
      <div className="flex items-center gap-1.5">
        <span className="font-mono text-[11px] text-muted">{enemy.level}</span>
        {rank && <span className="text-[10px] font-semibold text-gold uppercase">{rank}</span>}
        <span
          className="min-w-0 grow truncate text-[13px] font-semibold"
          style={{ color: enemy.isDead ? "#8b8f96" : reactionColor(enemy.reaction) }}
        >
          {enemy.name}
        </span>
        {enemy.isFocus && (
          <Chip size="sm" variant="soft" color="accent">
            focus
          </Chip>
        )}
        {enemy.isEvading && (
          <Chip size="sm" variant="soft" color="warning">
            evading
          </Chip>
        )}
        {enemy.isTappedByOthers && (
          <Chip size="sm" variant="soft">
            tapped
          </Chip>
        )}
        <Tooltip delay={300}>
          <span className="inline-flex items-center gap-0.5 font-mono text-[11px] text-muted">
            <ArrowUp className="size-3" style={{ transform: `rotate(${enemy.bearing}deg)` }} />
            {Math.round(enemy.distance)} yd
          </span>
          <Tooltip.Content>
            {Math.round(enemy.distance)} yards, {Math.round(enemy.bearing)}° from your facing
            {enemy.unit ? ` · ${enemy.unit}` : " · beyond nameplate range"}
          </Tooltip.Content>
        </Tooltip>
      </div>
      <Bar
        label={`${enemy.name}'s health`}
        value={enemy.health}
        max={enemy.healthMax}
        color={enemy.isTappedByOthers ? "#7f7f7f" : enemy.reaction <= 2 ? "#d42b20" : "#e8c000"}
        height={12}
        text={enemy.isDead ? "dead" : `${enemy.health.toLocaleString()} (${healthShare}%)`}
      />
      {enemy.casting && <CastBar cast={enemy.casting} now={now} />}
      {enemy.threat !== undefined && (
        <div className="flex items-center gap-2">
          <span className="text-[10px] text-muted uppercase">threat</span>
          <div className="grow">
            <Bar
              label="Your threat"
              value={enemy.threatPercent}
              max={100}
              color={THREAT_COLORS[enemy.threat] ?? THREAT_COLORS[0]}
              height={5}
            />
          </div>
          <span className="w-9 text-right font-mono text-[11px]" style={{ color: THREAT_COLORS[enemy.threat] }}>
            {Math.round(enemy.threatPercent)}%
          </span>
        </div>
      )}
      <Auras auras={enemy.auras} now={now} />
      <div className="flex items-center gap-1">
        {enemy.isDead ? (
          enemy.isLootable ? (
            <Button size="sm" variant="secondary" onPress={() => void action.run({ action: "combatLoot", enemyId })}>
              <Box />
              Loot
            </Button>
          ) : (
            <span className="text-xs text-muted">dead{enemy.targetUnit ? "" : ", nothing on it"}</span>
          )
        ) : (
          <>
            <Button
              size="sm"
              variant={enemy.isTarget ? "secondary" : "tertiary"}
              onPress={() => void action.run({ action: "combatTarget", enemyId })}
            >
              <Eye />
              {enemy.isTarget ? "Targeted" : "Target"}
            </Button>
            <Button
              size="sm"
              variant="danger-soft"
              onPress={() => void action.run({ action: "combatAttack", enemyId })}
            >
              <TargetDart />
              Attack
            </Button>
          </>
        )}
        <span className="grow" />
        {enemy.targetUnit === "player" && !enemy.isDead && (
          <span className="text-[11px] font-medium text-danger">on you</span>
        )}
        <Dropdown>
          <Button isIconOnly size="sm" variant="ghost" aria-label={`More for ${enemy.name}`}>
            <EllipsisVertical />
          </Button>
          <Dropdown.Popover placement="bottom end">
            <Dropdown.Menu onAction={onMenu}>
              <Dropdown.Item id="focus" textValue="Focus">
                <Label>Focus</Label>
              </Dropdown.Item>
              {DAMAGES.map((damage) => (
                <Dropdown.Item key={damage.id} id={damage.id} textValue={damage.label}>
                  <Label>{damage.label}</Label>
                </Dropdown.Item>
              ))}
              <Dropdown.Item id="despawn" textValue="Take it away" variant="danger">
                <Label>Take it away</Label>
              </Dropdown.Item>
            </Dropdown.Menu>
          </Dropdown.Popover>
        </Dropdown>
      </div>
      {action.problem && <p className="text-xs text-danger">{action.problem}</p>}
    </article>
  );
});
