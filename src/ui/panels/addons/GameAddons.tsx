// The game's own addons (Blizzard_*), folded away: which loaded and how long each took, filtered by name
import { Disclosure, SearchField } from "@heroui/react";
import { useState } from "react";
import { plainWowText } from "../../components/WowText.tsx";
import { useSimState } from "../../sim/hooks.ts";
import type { LoadedAddon } from "../../sim/types.ts";

const NO_ADDONS: LoadedAddon[] = [];

export const GameAddons = () => {
  const addons = useSimState((state) => state.addons, NO_ADDONS);
  const [filter, setFilter] = useState("");
  const own = addons.filter((addon) => addon.name.startsWith("Blizzard_"));
  const loaded = own.filter((addon) => addon.loaded).length;
  const words = filter.toLowerCase().split(/\s+/).filter(Boolean);
  const shown = own.filter((addon) =>
    words.every((word) => `${addon.name} ${addon.title}`.toLowerCase().includes(word)),
  );
  return (
    <Disclosure className="rounded-xl border border-separator bg-surface">
      <Disclosure.Heading>
        <Disclosure.Trigger className="flex w-full items-center gap-2 px-3.5 py-3 text-left">
          <span className="grow text-[13px] font-semibold">The game's own</span>
          <span className="text-xs text-muted">
            {loaded} loaded of {own.length}
          </span>
          <Disclosure.Indicator />
        </Disclosure.Trigger>
      </Disclosure.Heading>
      <Disclosure.Content>
        <div className="flex flex-col gap-2 px-3.5 pb-3">
          <SearchField aria-label="Filter the game's addons" value={filter} onChange={setFilter} variant="secondary">
            <SearchField.Group>
              <SearchField.SearchIcon />
              <SearchField.Input placeholder="Filter: QuestLog, Map…" />
              <SearchField.ClearButton />
            </SearchField.Group>
          </SearchField>
          <ul className="flex flex-col">
            {shown.map((addon) => (
              <li key={addon.name} className="flex items-center gap-2 py-1 text-[12px]">
                <span
                  className={`size-1.5 shrink-0 rounded-full ${addon.loaded ? "bg-success" : "bg-default"}`}
                  aria-label={addon.loaded ? "loaded" : "not loaded"}
                  role="img"
                />
                <span className={`min-w-0 grow truncate ${addon.loaded ? "" : "text-muted"}`} title={addon.name}>
                  {plainWowText(addon.title) || addon.name}
                </span>
                <span className="font-mono text-[11px] text-muted">
                  {addon.loaded ? (addon.seconds !== undefined ? `${addon.seconds} s` : "loaded") : "off"}
                </span>
              </li>
            ))}
          </ul>
        </div>
      </Disclosure.Content>
    </Disclosure>
  );
};
