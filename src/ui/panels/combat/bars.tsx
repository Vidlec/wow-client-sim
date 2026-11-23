// The game's bars and marks, drawn as its unit frames draw them: health green, each power in its own colour, a cast bar
// filling (or a channel emptying) on the game's clock, threat in the game's four colours, an aura's icon
import type { CSSProperties } from "react";
import type { CombatAura, CombatCast, CombatPowerType } from "../../../shared/combat.ts";

/** PowerBarColor's colours */
export const POWER_COLORS: Readonly<Record<CombatPowerType, string>> = {
  MANA: "#0080ff",
  RAGE: "#ff2020",
  FOCUS: "#ff8040",
  ENERGY: "#ffe000",
};

/** GetThreatStatusColor's: not tanking and low, higher, insecurely tanking, securely tanking */
export const THREAT_COLORS = ["#a8a8a8", "#ffff78", "#ff9900", "#ff2a2a"] as const;

/** UnitReaction's colours (FACTION_BAR_COLORS): hostile red, neutral yellow, friendly green */
export const reactionColor = (reaction: number): string =>
  reaction <= 2 ? "#ff3a2f" : reaction <= 4 ? "#ffd100" : "#3ee05a";

type BarProps = { value: number; max: number; color: string; label: string; height?: number; text?: string };

export const Bar = ({ value, max, color, label, height = 12, text }: BarProps) => {
  const share = max > 0 ? Math.max(0, Math.min(1, value / max)) : 0;
  return (
    // biome-ignore lint/a11y/useSemanticElements: <meter> cannot carry the game's glossy fill and its text over it
    <div
      role="meter"
      aria-label={label}
      aria-valuenow={value}
      aria-valuemin={0}
      aria-valuemax={max}
      className="game-bar relative overflow-hidden rounded-[3px]"
      style={{ height, "--bar-color": color } as CSSProperties}
    >
      <div className="game-bar-fill absolute inset-y-0 left-0" style={{ width: `${share * 100}%` }} />
      {text !== undefined && (
        <span className="absolute inset-0 flex items-center justify-center font-mono text-[10px] text-white [text-shadow:0_1px_1px_#000]">
          {text}
        </span>
      )}
    </div>
  );
};

/** A spell being cast, filled by the game's time now (`now`, GetTime) */
export const CastBar = ({ cast, now }: { cast: CombatCast; now: number }) => {
  const total = Math.max(0.01, cast.endTime - cast.startTime);
  const done = Math.max(0, Math.min(1, (now - cast.startTime) / total));
  const share = cast.isChannel ? 1 - done : done;
  return (
    <Bar
      label={`Casting ${cast.name}`}
      value={share * 100}
      max={100}
      height={10}
      color={cast.notInterruptible ? "#9aa3ae" : cast.isChannel ? "#33cc33" : "#ffb300"}
      text={`${cast.name} ${Math.max(0, cast.endTime - now).toFixed(1)}s`}
    />
  );
};

export const SpellIcon = ({ icon, name, size = 18 }: { icon: number; name: string; size?: number }) => (
  <img
    src={`/art?p=${icon}`}
    alt={name}
    title={name}
    width={size}
    height={size}
    className="spell-icon shrink-0 rounded-[3px]"
    loading="lazy"
  />
);

export const Auras = ({ auras, now }: { auras: readonly CombatAura[]; now: number }) =>
  auras.length === 0 ? null : (
    <div className="flex flex-wrap gap-1">
      {auras.map((aura) => {
        const left = aura.expirationTime > 0 ? Math.max(0, aura.expirationTime - now) : null;
        return (
          <span
            key={aura.auraInstanceID}
            className={`aura relative ${aura.isHelpful ? "is-helpful" : "is-harmful"}`}
            title={`${aura.name}${left !== null ? `, ${left.toFixed(0)} s left` : ""}${aura.sourceUnit === "player" ? " (yours)" : ""}`}
          >
            <SpellIcon icon={aura.icon} name={aura.name} />
            {aura.applications > 1 && (
              <span className="absolute -right-0.5 -bottom-0.5 font-mono text-[9px] font-bold text-white [text-shadow:0_0_2px_#000]">
                {aura.applications}
              </span>
            )}
          </span>
        );
      })}
    </div>
  );
