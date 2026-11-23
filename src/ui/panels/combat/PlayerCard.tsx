// The player in the fight, as the player frame and the action bar show it: health and power, combo points, the cast
// and the global cooldown, auto-attack, the cooldowns; and what can be done: attack, stop, run away, change target,
// press an action button, and after death release or come back
import { ArrowRight, ArrowRightFromSquare, Heart, Skull, StopFill, TargetDart } from "@gravity-ui/icons";
import { Button, ButtonGroup, Chip, Tooltip, toast } from "@heroui/react";
import type { CombatPlayer } from "../../../shared/combat.ts";
import { Portrait } from "../../components/Portrait.tsx";
import { useGameAction, useSimState } from "../../sim/hooks.ts";
import { Auras, Bar, CastBar, POWER_COLORS } from "./bars.tsx";

const SLOTS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] as const;
const SLOT_KEYS = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="] as const;
/** lua/combat.lua's LEASH: how far from its pull a creature chases */
const LEASH_YARDS = 60;

export const PlayerCard = ({ player, now }: { player: CombatPlayer; now: number }) => {
  const who = useSimState((state) => ({ name: state.profile.name, classFile: state.profile.class }), null);
  const action = useGameAction();
  const gcdLeft = player.gcdEnd !== undefined ? Math.max(0, player.gcdEnd - now) : 0;
  return (
    <div className={`player-card flex flex-col gap-3 rounded-xl border p-3 ${player.inCombat ? "is-fighting" : ""}`}>
      <div className="flex items-center gap-3">
        {who && <Portrait name={who.name} classFile={who.classFile} level={player.level} isOnline={!player.isDead} />}
        <div className="flex min-w-0 grow flex-col gap-1">
          <div className="flex items-center gap-1.5">
            <span className="grow truncate text-[13px] font-semibold">{who?.name ?? "You"}</span>
            {player.inCombat && (
              <Chip size="sm" color="danger" variant="soft">
                in combat
              </Chip>
            )}
            {player.isAutoAttacking && (
              <Chip size="sm" color="warning" variant="soft">
                attacking
              </Chip>
            )}
          </div>
          <Bar
            label="Health"
            value={player.health}
            max={player.healthMax}
            color="#1ec81e"
            height={14}
            text={`${player.health.toLocaleString()} / ${player.healthMax.toLocaleString()}`}
          />
          <Bar
            label={player.powerType.toLowerCase()}
            value={player.power}
            max={player.powerMax}
            color={POWER_COLORS[player.powerType]}
            height={10}
            text={`${player.power} / ${player.powerMax}`}
          />
          {player.comboPoints > 0 && (
            <div className="flex gap-1" role="img" aria-label={`${player.comboPoints} combo points`}>
              {[1, 2, 3, 4, 5].map((point) => (
                <span key={point} className={`combo-point ${point <= player.comboPoints ? "is-lit" : ""}`} />
              ))}
            </div>
          )}
        </div>
      </div>
      {player.casting && <CastBar cast={player.casting} now={now} />}
      <Auras auras={player.auras} now={now} />

      {player.isDead || player.isGhost ? (
        <div className="flex items-center gap-2 rounded-lg bg-danger-soft px-3 py-2">
          <Skull className="size-4 text-danger" />
          <span className="grow text-[13px]">{player.isGhost ? "A ghost" : "Dead"}</span>
          {!player.isGhost && (
            <Button size="sm" variant="tertiary" onPress={() => void action.run({ action: "combatRelease" })}>
              Release
            </Button>
          )}
          <Button size="sm" onPress={() => void action.run({ action: "combatResurrect" })}>
            <Heart />
            Come back
          </Button>
        </div>
      ) : (
        <>
          <div className="flex flex-wrap items-center gap-1.5">
            <Button
              size="sm"
              variant={player.isAutoAttacking ? "danger" : "primary"}
              onPress={() =>
                void action.run(player.isAutoAttacking ? { action: "combatStopAttack" } : { action: "combatAttack" })
              }
            >
              <TargetDart />
              {player.isAutoAttacking ? "Stop attacking" : "Attack"}
            </Button>
            <Button size="sm" variant="tertiary" onPress={() => void action.run({ action: "combatStop" })}>
              <StopFill />
              Stop
            </Button>
            {(player.inCombat || player.isFleeing) && (
              <Tooltip delay={300}>
                <Button
                  size="sm"
                  variant={player.isFleeing ? "danger-soft" : "secondary"}
                  onPress={() =>
                    void action
                      .run(player.isFleeing ? { action: "combatStop" } : { action: "combatFlee" })
                      .then((answer) => {
                        if (answer?.problem) toast.danger(answer.problem);
                      })
                  }
                >
                  <ArrowRightFromSquare />
                  {player.isFleeing ? "Running… (stop)" : "Run away"}
                </Button>
                <Tooltip.Content>
                  Turn your back and run. They chase you until each gives up, {LEASH_YARDS} yards from where you pulled
                  it.
                </Tooltip.Content>
              </Tooltip>
            )}
            <ButtonGroup size="sm" variant="tertiary">
              <Tooltip delay={300}>
                <Button variant="tertiary" onPress={() => void action.run({ action: "combatTarget", next: true })}>
                  Tab
                  <ArrowRight />
                </Button>
                <Tooltip.Content>The next enemy (Tab); the game's own targeting order</Tooltip.Content>
              </Tooltip>
              <Button variant="tertiary" onPress={() => void action.run({ action: "combatTarget", clear: true })}>
                <ButtonGroup.Separator />
                Clear
              </Button>
            </ButtonGroup>
          </div>
          {/* biome-ignore lint/a11y/useSemanticElements: a fieldset would change the bar's grid; a group of buttons */}
          <div className="action-slots grid grid-cols-12 gap-1" role="group" aria-label="The first action bar">
            {SLOTS.map((slot, index) => (
              <Tooltip key={slot} delay={300}>
                <button
                  type="button"
                  className="action-slot"
                  aria-label={`Action button ${slot}`}
                  onClick={() => void action.run({ action: "combatUseAction", slot })}
                >
                  {SLOT_KEYS[index]}
                  {gcdLeft > 0 && <span className="action-slot-gcd" />}
                </button>
                <Tooltip.Content>Action button {slot}, as its key presses it</Tooltip.Content>
              </Tooltip>
            ))}
          </div>
        </>
      )}
      {player.cooldowns.length > 0 && (
        <div className="flex flex-wrap gap-1">
          {player.cooldowns.map((cooldown) => (
            <Chip key={cooldown.spellId} size="sm" variant="soft" className="font-mono">
              {cooldown.name} {Math.max(0, cooldown.endTime - now).toFixed(1)}s
            </Chip>
          ))}
        </div>
      )}
      {action.problem && <p className="text-xs text-danger">{action.problem}</p>}
    </div>
  );
};
