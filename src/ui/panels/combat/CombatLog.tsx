// The combat log, as the game's window words it: each line coloured by what happened (damage red, heals green, misses
// grey, deaths gold), the newest at the bottom and kept in view
import { useEffect, useRef } from "react";
import type { CombatLogLine } from "../../../shared/combat.ts";

const lineColor = (line: CombatLogLine): string => {
  if (line.event === "UNIT_DIED" || line.event === "PARTY_KILL") return "#ffd100";
  if (line.event.endsWith("_HEAL") || line.event === "SPELL_ENERGIZE") return "#5fe07a";
  if (line.event.endsWith("_MISSED") || line.event === "SPELL_CAST_FAILED") return "#9aa3ae";
  if (line.event.startsWith("SPELL_AURA")) return "#c9a8ff";
  if (line.event.startsWith("SPELL_CAST") || line.event === "SPELL_INTERRUPT") return "#7fd4ff";
  if (line.event.endsWith("_DAMAGE")) return line.outcome === "CRITICAL" ? "#ff7a5c" : "#ffb3a3";
  return "#d6dbe1";
};

export const CombatLog = ({ lines }: { lines: readonly CombatLogLine[] }) => {
  const box = useRef<HTMLDivElement>(null);
  // biome-ignore lint/correctness/useExhaustiveDependencies: a new line is the cue to follow it
  useEffect(() => {
    const element = box.current;
    if (element) element.scrollTop = element.scrollHeight;
  }, [lines]);
  return (
    <div ref={box} className="combat-log max-h-64 overflow-y-auto rounded-xl border border-separator bg-[#0b0d10] p-2">
      {lines.length === 0 ? (
        <p className="p-2 text-xs text-muted">Nothing has happened yet.</p>
      ) : (
        lines.map((line, index) => (
          // biome-ignore lint/suspicious/noArrayIndexKey: the log only grows at its end, sixty lines kept
          <div key={`${line.time}-${index}`} className="flex gap-2 font-mono text-[11.5px] leading-relaxed">
            <span className="shrink-0 text-muted tabular-nums">{line.time.toFixed(1)}</span>
            <span style={{ color: lineColor(line) }} className={line.outcome === "CRITICAL" ? "font-bold" : ""}>
              {line.text}
            </span>
          </div>
        ))
      )}
    </div>
  );
};
