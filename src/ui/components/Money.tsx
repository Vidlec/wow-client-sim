// Money as the game shows it: gold, silver and copper, each in its coin's colour (copper 100 to a silver, 100 silver to
// a gold), the parts that are zero left out
import { useFlavour } from "../flavours/index.ts";

type Props = { copper: number; className?: string };

export const splitMoney = (copper: number): { gold: number; silver: number; copper: number } => {
  const whole = Math.max(0, Math.floor(copper));
  return { gold: Math.floor(whole / 10000), silver: Math.floor(whole / 100) % 100, copper: whole % 100 };
};

const Coin = ({ color }: { color: string }) => (
  <span
    aria-hidden="true"
    className="inline-block size-2.5 rounded-full"
    style={{ background: `radial-gradient(circle at 35% 30%, #fff8, ${color} 45%, #0006 120%)` }}
  />
);

export const Money = ({ copper, className }: Props) => {
  const { colors } = useFlavour();
  const parts = splitMoney(copper);
  const shown = [
    { value: parts.gold, color: colors.money.gold, name: "gold" },
    { value: parts.silver, color: colors.money.silver, name: "silver" },
    { value: parts.copper, color: colors.money.copper, name: "copper" },
  ].filter((part, index, all) => part.value > 0 || (index === all.length - 1 && copper <= 0));
  return (
    <span
      role="img"
      className={`inline-flex items-center gap-2 font-mono tabular-nums ${className ?? ""}`}
      aria-label={shown.map((part) => `${part.value} ${part.name}`).join(" ")}
    >
      {shown.map((part) => (
        <span key={part.name} className="inline-flex items-center gap-1" style={{ color: part.color }}>
          {part.value}
          <Coin color={part.color} />
        </span>
      ))}
    </span>
  );
};
