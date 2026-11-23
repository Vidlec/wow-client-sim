// The Addons panel: the addons of your AddOns folder, each switched on or off (with what it needs) and its saved
// variables read or reset in a drawer; and the game's own, folded away
import { Layers } from "@gravity-ui/icons";
import { SearchField, Skeleton, toast } from "@heroui/react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { EmptyState } from "../../components/bits.tsx";
import { plainWowText } from "../../components/WowText.tsx";
import { requestWholeScene } from "../../shell/screen.ts";
import { api } from "../../sim/api.ts";
import { useSimState } from "../../sim/hooks.ts";
import { refreshState } from "../../sim/store.ts";
import type { CatalogAddon, LoadedAddon } from "../../sim/types.ts";
import { AddonCard } from "./AddonCard.tsx";
import { GameAddons } from "./GameAddons.tsx";
import { SavedDrawer } from "./SavedDrawer.tsx";

const NO_ADDONS: LoadedAddon[] = [];

export const AddonsPanel = () => {
  const [catalog, setCatalog] = useState<CatalogAddon[] | null>(null);
  const [filter, setFilter] = useState("");
  const [switching, setSwitching] = useState<string | null>(null);
  const [savedOf, setSavedOf] = useState<string | null>(null);
  const loaded = useSimState((state) => state.addons, NO_ADDONS);
  const generation = useSimState((state) => state.generation, 0);
  const running = useMemo(() => new Map(loaded.map((addon) => [addon.name.toLowerCase(), addon])), [loaded]);

  const loadCatalog = useCallback(async (): Promise<void> => {
    try {
      setCatalog(await api.addonCatalog());
    } catch {
      setCatalog([]);
    }
  }, []);
  // (read again at each reload: the saved files' sizes change)
  // biome-ignore lint/correctness/useExhaustiveDependencies: generation only says when to read again
  useEffect(() => {
    void loadCatalog();
  }, [loadCatalog, generation]);

  const switchAddon = async (entry: CatalogAddon, isOn: boolean): Promise<void> => {
    setSwitching(entry.name);
    try {
      const answer = await api.switchAddon(entry.name, isOn);
      if (answer.error) toast.danger(answer.error);
      else {
        if (answer.catalog) setCatalog(answer.catalog);
        requestWholeScene();
        toast.success(`${plainWowText(entry.title) || entry.name} ${isOn ? "on" : "off"}`, {
          description: answer.boot?.error
            ? `The reload failed: ${answer.boot.error}`
            : `Reloaded in ${answer.boot?.bootSeconds?.toFixed(2) ?? "?"} s`,
        });
      }
    } catch (error) {
      toast.danger(`Could not switch ${entry.name}`, { description: String(error) });
    } finally {
      setSwitching(null);
      void refreshState();
    }
  };

  const words = filter.toLowerCase().split(/\s+/).filter(Boolean);
  const shown = (catalog ?? [])
    .filter((entry) =>
      words.every((word) => `${entry.name} ${entry.title} ${entry.notes}`.toLowerCase().includes(word)),
    )
    .sort(
      (first, second) =>
        Number(second.enabled) - Number(first.enabled) ||
        plainWowText(first.title).localeCompare(plainWowText(second.title)),
    );
  const enabledCount = catalog?.filter((entry) => entry.enabled).length ?? 0;

  return (
    <>
      <div className="flex items-center gap-2">
        <SearchField aria-label="Filter your addons" value={filter} onChange={setFilter} className="grow">
          <SearchField.Group>
            <SearchField.SearchIcon />
            <SearchField.Input placeholder="Filter: name or notes" />
            <SearchField.ClearButton />
          </SearchField.Group>
        </SearchField>
        {catalog && (
          <span className="shrink-0 text-xs text-muted">
            {enabledCount} on of {catalog.length}
          </span>
        )}
      </div>
      <p className="px-1 text-xs leading-relaxed text-muted">
        From your AddOns folder. Switching one on or off reloads, as the game's AddOns list does; one switched on brings
        the addons it needs.
      </p>
      {!catalog ? (
        <div className="flex flex-col gap-2">
          {[1, 2, 3].map((key) => (
            <Skeleton key={key} className="h-16 rounded-xl" />
          ))}
        </div>
      ) : shown.length === 0 ? (
        <EmptyState icon={<Layers />}>
          {catalog.length ? "No addon matches." : "No addons found in the AddOns folder (Settings)."}
        </EmptyState>
      ) : (
        <div className="flex flex-col gap-2">
          {shown.map((entry) => (
            <AddonCard
              key={entry.name}
              entry={entry}
              running={running.get(entry.name.toLowerCase())}
              isSwitching={switching === entry.name}
              onSwitch={(isOn) => void switchAddon(entry, isOn)}
              onSaved={() => setSavedOf(entry.name)}
            />
          ))}
        </div>
      )}
      <GameAddons />
      <SavedDrawer
        addon={catalog?.find((entry) => entry.name === savedOf) ?? null}
        onClose={() => setSavedOf(null)}
        onReset={() => void loadCatalog()}
      />
    </>
  );
};
