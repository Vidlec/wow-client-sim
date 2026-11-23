// A character's face as the game's unit frames show one: a round portrait ringed in their class's colour, their level
// on a small gold disc, a dot for online or offline. No art of the character: their initial on the class's tint.
import { findClass, useFlavour } from "../flavours/index.ts";

type Size = "sm" | "md" | "lg";

type Props = { name: string; classFile: string; level?: number; isOnline?: boolean; size?: Size };

const SIZES: Record<Size, { box: string; text: string; disc: string; ring: number }> = {
  sm: { box: "size-7", text: "text-xs", disc: "size-4 text-[8px] -right-1 -bottom-1", ring: 1.5 },
  md: { box: "size-12", text: "text-lg", disc: "size-5 text-[10px] -right-1 -bottom-1", ring: 2 },
  lg: { box: "size-16", text: "text-2xl", disc: "size-6 text-[11px] -right-0.5 -bottom-0.5", ring: 2.5 },
};

export const Portrait = ({ name, classFile, level, isOnline = true, size = "md" }: Props) => {
  const flavour = useFlavour();
  const color = findClass(flavour, classFile).color;
  const shape = SIZES[size];
  return (
    <div className={`relative shrink-0 ${shape.box}`}>
      <div
        className={`flex items-center justify-center rounded-full font-bold text-white/90 ${shape.box} ${shape.text}`}
        style={{
          background: `radial-gradient(circle at 35% 30%, ${color}77, #1d2127 72%)`,
          boxShadow: `0 0 0 ${shape.ring}px ${color}, 0 0 14px ${color}44`,
          opacity: isOnline ? 1 : 0.45,
        }}
      >
        {name.slice(0, 1).toUpperCase()}
      </div>
      {level !== undefined && (
        <span
          className={`absolute flex items-center justify-center rounded-full border-2 bg-[#13161a] font-bold ${shape.disc}`}
          style={{ borderColor: flavour.colors.money.gold, color: flavour.colors.money.gold }}
        >
          {level}
        </span>
      )}
      {size !== "sm" && (
        <span
          role="img"
          aria-label={isOnline ? "Online" : "Offline"}
          className={`absolute -top-0.5 -left-0.5 size-3 rounded-full border-2 border-[#13161a] ${isOnline ? "bg-success" : "bg-default"}`}
        />
      )}
    </div>
  );
};
