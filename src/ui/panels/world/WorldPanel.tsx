// The World panel: where the character stands, walking about, the minimap, instances; and the keys the game takes
import { Kbd } from "@heroui/react";
import { InstanceSection } from "./InstanceSection.tsx";
import { MinimapSection } from "./MinimapSection.tsx";
import { MovingSection } from "./MovingSection.tsx";
import { WhereSection } from "./WhereSection.tsx";

const KEYS: readonly [string, string][] = [
  ["M", "map"],
  ["L", "quest log"],
  ["Esc", "closes windows, the game menu"],
];

export const WorldPanel = () => (
  <>
    <WhereSection />
    <MovingSection />
    <MinimapSection />
    <InstanceSection />
    <p className="flex flex-wrap items-center gap-x-3 gap-y-1 px-1 text-xs text-muted">
      Keys go to the game screen while it has the focus:
      {KEYS.map(([key, what]) => (
        <span key={key} className="inline-flex items-center gap-1">
          <Kbd className="text-[10px]">
            <Kbd.Content>{key}</Kbd.Content>
          </Kbd>
          {what}
        </span>
      ))}
    </p>
  </>
);
