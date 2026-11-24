// The Addons panel: your addons as the game's AddOns list files them, under their categories (## Category) with each
// group under its head (EllesmereUI's modules under EllesmereUI), one line each; a click opens what it requires, works
// with and is required by. Switches wait as changes (with what they bring: the addons they need come on, those that
// need one going off go off) until applied, one reload for all of them; the shown ones switched on or off at once;
// their saved variables read or reset in a drawer; the further folders above, the game's own below
import { ChevronDown, ChevronRight, EllipsisVertical, Layers } from "@gravity-ui/icons";
import {
  Button,
  Dropdown,
  Label,
  SearchField,
  Skeleton,
  ToggleButton,
  ToggleButtonGroup,
  Tooltip,
  toast,
} from "@heroui/react";
import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { planAddons } from "../../../shared/addonDeps.ts";
import { EmptyState } from "../../components/bits.tsx";
import { plainWowText, WowText } from "../../components/WowText.tsx";
import { requestWholeScene } from "../../shell/screen.ts";
import { api } from "../../sim/api.ts";
import { useSimState } from "../../sim/hooks.ts";
import { usePersistentState } from "../../sim/settings.ts";
import { refreshState } from "../../sim/store.ts";
import type { CatalogAddon, LoadedAddon } from "../../sim/types.ts";
import { AddonFolders } from "./AddonFolders.tsx";
import { AddonRow, type DependencyState, type Planned } from "./AddonRow.tsx";
import { GameAddons } from "./GameAddons.tsx";
import { SavedDrawer } from "./SavedDrawer.tsx";

const NO_ADDONS: LoadedAddon[] = [];
type View = "all" | "on" | "off" | "issues";

const lower = (name: string): string => name.toLowerCase();
const folderName = (path: string): string =>
  path
    .replace(/[\\/]+$/, "")
    .split(/[\\/]/)
    .at(-1) ?? path;
const isStringList = (value: unknown): value is string[] =>
  Array.isArray(value) && value.every((item) => typeof item === "string");

/** "A, B and 3 more" */
const listNames = (names: readonly string[], most = 4): string =>
  names.length <= most ? names.join(", ") : `${names.slice(0, most).join(", ")} and ${names.length - most} more`;

/** A group's head and the addons listed under it */
type Group = { head: CatalogAddon; children: CatalogAddon[] };
/** A category's heading (null: the addons after the headings, as the game lists those without one) */
type Category = { key: string; label: string | null; groups: Group[] };

/** The list as the game's AddOns list builds it: categories by name, then those without; heads by folder name */
const buildTree = (catalog: readonly CatalogAddon[], shown: readonly CatalogAddon[]): Category[] => {
  const byName = new Map(catalog.map((entry) => [lower(entry.name), entry]));
  const groups = new Map<string, Group>();
  const groupOf = (head: CatalogAddon): Group => {
    let group = groups.get(lower(head.name));
    if (!group) {
      group = { head, children: [] };
      groups.set(lower(head.name), group);
    }
    return group;
  };
  for (const entry of shown) {
    const head = byName.get(lower(entry.group));
    // (a child shown brings its head along, as what it is listed under)
    if (head && head !== entry) groupOf(head).children.push(entry);
    else groupOf(entry);
  }
  const categories = new Map<string, Category>();
  for (const group of groups.values()) {
    const label = group.head.category || null;
    const key = label ? lower(plainWowText(label)) : "";
    let category = categories.get(key);
    if (!category) {
      category = { key, label, groups: [] };
      categories.set(key, category);
    }
    category.groups.push(group);
    group.children.sort((first, second) => lower(first.name).localeCompare(lower(second.name)));
  }
  for (const category of categories.values())
    category.groups.sort((first, second) => lower(first.head.name).localeCompare(lower(second.head.name)));
  return [...categories.values()].sort((first, second) =>
    first.label === null ? 1 : second.label === null ? -1 : first.key.localeCompare(second.key),
  );
};

export const AddonsPanel = () => {
  const [catalog, setCatalog] = useState<CatalogAddon[] | null>(null);
  const [filter, setFilter] = useState("");
  const [view, setView] = useState<View>("all");
  // The switches waiting: an addon's name (lower case) and what it is to be
  const [pending, setPending] = useState<ReadonlyMap<string, boolean>>(new Map());
  const [isApplying, setApplying] = useState(false);
  const [savedOf, setSavedOf] = useState<string | null>(null);
  // What is folded and open, remembered: categories folded, groups shown, addons opened (lower-case keys)
  const [foldedCategories, setFoldedCategories] = usePersistentState<string[]>(
    "addons.foldedCategories",
    [],
    isStringList,
  );
  const [openGroups, setOpenGroups] = usePersistentState<string[]>("addons.openGroups", [], isStringList);
  const [openAddons, setOpenAddons] = useState<ReadonlySet<string>>(new Set());
  const [highlighted, setHighlighted] = useState<string | null>(null);
  const highlightTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const loaded = useSimState((state) => state.addons, NO_ADDONS);
  const generation = useSimState((state) => state.generation, 0);
  const running = useMemo(() => new Map(loaded.map((addon) => [lower(addon.name), addon])), [loaded]);

  const loadCatalog = useCallback(async (): Promise<void> => {
    try {
      setCatalog(await api.addonCatalog());
    } catch {
      setCatalog([]);
    }
  }, []);
  // (read again at each reload: the saved files' sizes change, a folder may have been added)
  // biome-ignore lint/correctness/useExhaustiveDependencies: generation only says when to read again
  useEffect(() => {
    void loadCatalog();
  }, [loadCatalog, generation]);

  // What the waiting switches come to, worked out as the server will
  const plan = useMemo(() => {
    const loadable = (catalog ?? []).filter((entry) => entry.isForThisGame);
    const current = loadable.filter((entry) => entry.enabled).map((entry) => entry.name);
    const turnOn: string[] = [];
    const turnOff: string[] = [];
    for (const entry of loadable) {
      const wanted = pending.get(lower(entry.name));
      if (wanted === true && !entry.enabled) turnOn.push(entry.name);
      if (wanted === false && entry.enabled) turnOff.push(entry.name);
    }
    return { ...planAddons(loadable, current, turnOn, turnOff), turnOn, turnOff };
  }, [catalog, pending]);
  const onAfter = useMemo(() => new Set(plan.addons.map(lower)), [plan]);
  const brought = useMemo(() => new Set(plan.broughtIn.map(lower)), [plan]);
  const takenOut = useMemo(() => new Set(plan.takenOut.map(lower)), [plan]);
  const hasChanges = plan.turnOn.length + plan.turnOff.length > 0;

  const plannedOf = (entry: CatalogAddon): Planned => {
    const key = lower(entry.name);
    const isOn = onAfter.has(key);
    if (isOn === entry.enabled) return { isOn, change: null };
    if (brought.has(key)) return { isOn, change: "brought" };
    if (takenOut.has(key)) return { isOn, change: "takenOut" };
    return { isOn, change: "asked" };
  };

  const dependencyStates = useMemo(() => {
    const states = new Map<string, DependencyState>();
    for (const entry of catalog ?? []) {
      const key = lower(entry.name);
      states.set(key, onAfter.has(key) ? (entry.enabled ? "on" : "coming") : "off");
    }
    return states;
  }, [catalog, onAfter]);

  const neededByOf = useMemo(() => {
    const needed = new Map<string, string[]>();
    for (const entry of catalog ?? []) {
      if (!onAfter.has(lower(entry.name))) continue;
      for (const dependency of entry.dependencies) {
        const list = needed.get(lower(dependency)) ?? [];
        list.push(entry.name);
        needed.set(lower(dependency), list);
      }
    }
    return needed;
  }, [catalog, onAfter]);

  const missingOf = useMemo(() => new Set(plan.missing.map((item) => lower(item.addon))), [plan]);
  const hasIssue = (entry: CatalogAddon): boolean => {
    if (!entry.isForThisGame) return true;
    if (missingOf.has(lower(entry.name))) return true;
    const live = running.get(lower(entry.name));
    return entry.enabled && !entry.loadOnDemand && live !== undefined && !live.loaded;
  };

  const toggle = (entry: CatalogAddon, isOn: boolean): void => {
    setPending((before) => {
      const next = new Map(before);
      if (isOn === entry.enabled) next.delete(lower(entry.name));
      else next.set(lower(entry.name), isOn);
      // (an addon brought in or taken out by another's switch, switched back by hand: its own wish wins)
      return next;
    });
  };

  const apply = async (): Promise<void> => {
    setApplying(true);
    try {
      const answer = await api.changeAddons(plan.turnOn, plan.turnOff);
      if (answer.error) {
        toast.danger(answer.error);
        return;
      }
      if (answer.catalog) setCatalog(answer.catalog);
      setPending(new Map());
      requestWholeScene();
      const done = answer.plan;
      const parts = [
        done && done.addons.length > 0 ? `${done.addons.length} on` : null,
        done && done.broughtIn.length > 0 ? `brought ${listNames(done.broughtIn)}` : null,
        done && done.takenOut.length > 0 ? `took off ${listNames(done.takenOut)}` : null,
      ].filter(Boolean);
      toast.success(`Addons changed${parts.length ? `: ${parts.join(", ")}` : ""}`, {
        description: answer.boot?.error
          ? `The reload failed: ${answer.boot.error}`
          : `Reloaded in ${answer.boot?.bootSeconds?.toFixed(2) ?? "?"} s`,
      });
    } catch (error) {
      toast.danger("Could not change the addons", { description: String(error) });
    } finally {
      setApplying(false);
      void refreshState();
    }
  };

  const words = filter.toLowerCase().split(/\s+/).filter(Boolean);
  const isFiltered = words.length > 0 || view !== "all";
  const shown = (catalog ?? [])
    .filter((entry) =>
      words.every((word) =>
        `${entry.name} ${entry.title} ${entry.notes} ${plainWowText(entry.category)} ${folderName(entry.root)}`
          .toLowerCase()
          .includes(word),
      ),
    )
    .filter((entry) => {
      const isOn = onAfter.has(lower(entry.name));
      if (view === "issues") return hasIssue(entry);
      // (one for other game versions only: not listed, as the game's list leaves it out; Issues shows it)
      if (!entry.isForThisGame) return false;
      if (view === "on") return isOn;
      if (view === "off") return !isOn;
      return true;
    });
  const tree = buildTree(catalog ?? [], shown); // (shown is new at every render: a memo would never keep it)
  const switchShown = (isOn: boolean): void => {
    setPending((before) => {
      const next = new Map(before);
      for (const entry of shown) {
        if (!entry.isForThisGame) continue;
        if (isOn === entry.enabled) next.delete(lower(entry.name));
        else next.set(lower(entry.name), isOn);
      }
      return next;
    });
  };
  const enabledCount = catalog?.filter((entry) => entry.enabled).length ?? 0;
  const listedCount = catalog?.filter((entry) => entry.isForThisGame).length ?? 0;
  const issueCount = catalog?.filter(hasIssue).length ?? 0;
  // Folder labels only when the addons come from more than one place
  const roots = new Set(
    (catalog ?? []).filter((entry) => entry.origin !== "project").map((entry) => lower(entry.root)),
  );
  const labelOf = (entry: CatalogAddon): string | null =>
    roots.size > 1 ? (entry.origin === "game" ? "AddOns" : folderName(entry.root)) : null;

  // (while filtering, everything found is shown unfolded)
  const isCategoryOpen = (key: string): boolean => isFiltered || !foldedCategories.includes(key);
  const isGroupOpen = (name: string): boolean => isFiltered || openGroups.includes(lower(name));
  const flip = (list: string[], key: string): string[] =>
    list.includes(key) ? list.filter((item) => item !== key) : [...list, key];

  /** Another addon of the list, from a dependency's link: unfolded, opened, scrolled to and lit for a moment */
  const reveal = (name: string): void => {
    const entry = catalog?.find((item) => lower(item.name) === lower(name));
    if (!entry) return;
    if (!shown.includes(entry)) {
      setFilter("");
      setView("all");
    }
    const head = catalog?.find((item) => lower(item.name) === lower(entry.group));
    const categoryKey = lower(plainWowText((head ?? entry).category));
    setFoldedCategories(foldedCategories.filter((key) => key !== categoryKey));
    if (head && head !== entry && !openGroups.includes(lower(head.name)))
      setOpenGroups([...openGroups, lower(head.name)]);
    setOpenAddons((before) => new Set(before).add(lower(entry.name)));
    setHighlighted(lower(entry.name));
    setTimeout(() => {
      document.getElementById(`addon-${lower(entry.name)}`)?.scrollIntoView({ block: "center", behavior: "smooth" });
    }, 50);
    clearTimeout(highlightTimer.current); // (a reveal before the last one's light went out keeps its own)
    highlightTimer.current = setTimeout(() => setHighlighted(null), 1600);
  };

  const rowOf = (entry: CatalogAddon, isChild: boolean, group: Group | null): ReactNode => {
    const key = lower(entry.name);
    return (
      <AddonRow
        key={`${entry.root}|${entry.name}`}
        entry={entry}
        running={running.get(key)}
        planned={plannedOf(entry)}
        dependencyStates={dependencyStates}
        neededBy={neededByOf.get(key) ?? []}
        folderLabel={labelOf(entry)}
        isBusy={isApplying}
        isChild={isChild}
        group={
          group && group.children.length > 0
            ? {
                count: group.children.length,
                on: group.children.filter((child) => onAfter.has(lower(child.name))).length,
                isOpen: isGroupOpen(entry.name),
                onToggle: () => setOpenGroups(flip(openGroups, key)),
              }
            : null
        }
        isOpen={openAddons.has(key)}
        isHighlighted={highlighted === key}
        onOpen={() =>
          setOpenAddons((before) => {
            const next = new Set(before);
            if (!next.delete(key)) next.add(key);
            return next;
          })
        }
        onToggle={(isOn) => toggle(entry, isOn)}
        onSaved={() => setSavedOf(entry.name)}
        onReveal={reveal}
      />
    );
  };

  return (
    <>
      <AddonFolders catalog={catalog} isCollapsible />
      <div className="flex items-center gap-1.5">
        <SearchField aria-label="Filter your addons" value={filter} onChange={setFilter} className="grow">
          <SearchField.Group>
            <SearchField.SearchIcon />
            <SearchField.Input placeholder="Filter: name, notes, category" />
            <SearchField.ClearButton />
          </SearchField.Group>
        </SearchField>
        <Dropdown>
          <Button isIconOnly size="sm" variant="ghost" aria-label="Switch the shown addons" isDisabled={isApplying}>
            <EllipsisVertical />
          </Button>
          <Dropdown.Popover>
            <Dropdown.Menu onAction={(key) => switchShown(key === "on")}>
              <Dropdown.Item id="on" textValue="Switch on the shown">
                <Label>Switch on the {shown.length} shown</Label>
              </Dropdown.Item>
              <Dropdown.Item id="off" textValue="Switch off the shown">
                <Label>Switch off the {shown.length} shown</Label>
              </Dropdown.Item>
            </Dropdown.Menu>
          </Dropdown.Popover>
        </Dropdown>
      </div>
      <div className="flex items-center gap-2">
        <ToggleButtonGroup
          aria-label="Which addons"
          selectionMode="single"
          disallowEmptySelection
          size="sm"
          selectedKeys={[view]}
          onSelectionChange={(keys) => setView(([...keys][0] as View | undefined) ?? "all")}
        >
          <ToggleButton id="all">All</ToggleButton>
          <ToggleButton id="on">
            <ToggleButtonGroup.Separator />
            On
          </ToggleButton>
          <ToggleButton id="off">
            <ToggleButtonGroup.Separator />
            Off
          </ToggleButton>
          <ToggleButton id="issues">
            <ToggleButtonGroup.Separator />
            Issues{issueCount ? ` (${issueCount})` : ""}
          </ToggleButton>
        </ToggleButtonGroup>
        <span className="grow" />
        {catalog && (
          <Tooltip delay={300}>
            <span className="shrink-0 cursor-default text-xs text-muted">
              {enabledCount} on of {listedCount}
            </span>
            <Tooltip.Content>
              Switches wait until applied: one reload for all of them, as the game's AddOns list needs. One switched on
              brings the addons it needs; one switched off takes those that need it.
            </Tooltip.Content>
          </Tooltip>
        )}
      </div>
      {hasChanges && (
        <div className="addon-changes sticky top-0 z-10 flex flex-col gap-1 rounded-xl border px-3 py-2">
          <div className="flex items-center gap-2">
            <span className="grow text-[12.5px] font-semibold">
              {[
                plan.turnOn.length ? `${plan.turnOn.length} to switch on` : null,
                plan.turnOff.length ? `${plan.turnOff.length} to switch off` : null,
              ]
                .filter(Boolean)
                .join(", ")}
            </span>
            <Button size="sm" variant="ghost" isDisabled={isApplying} onPress={() => setPending(new Map())}>
              Discard
            </Button>
            <Button size="sm" isPending={isApplying} onPress={() => void apply()}>
              Apply and reload
            </Button>
          </div>
          {plan.broughtIn.length > 0 && (
            <p className="text-xs text-muted">Comes on with them, needed: {listNames(plan.broughtIn, 8)}</p>
          )}
          {plan.takenOut.length > 0 && (
            <p className="text-xs text-warning">Goes off too, needing one going off: {listNames(plan.takenOut, 8)}</p>
          )}
          {plan.missing.length > 0 && (
            <p className="text-xs text-danger">
              Will not load, needing what is not installed:{" "}
              {listNames(
                plan.missing.map((item) => `${item.addon} (needs ${item.needs})`),
                6,
              )}
            </p>
          )}
        </div>
      )}
      {!catalog ? (
        <div className="flex flex-col gap-1">
          {[1, 2, 3, 4, 5].map((key) => (
            <Skeleton key={key} className="h-7 rounded-md" />
          ))}
        </div>
      ) : shown.length === 0 ? (
        <EmptyState icon={<Layers />}>
          {catalog.length ? "No addon matches." : "No addons found: add a folder of addons in Addon folders above."}
        </EmptyState>
      ) : (
        <div className="flex flex-col gap-2">
          {tree.map((category) => {
            const isOpen = isCategoryOpen(category.key);
            const members = category.groups.flatMap((group) => [group.head, ...group.children]);
            const onCount = members.filter((entry) => onAfter.has(lower(entry.name))).length;
            return (
              <section
                key={category.key || "-"}
                className={`addon-category flex flex-col overflow-hidden rounded-xl border ${isOpen ? "is-open" : ""}`}
              >
                {/* (a heading as the game's list has: its name in gold, unless the TOC colours it; those without one
                under "Uncategorized", the game's word) */}
                <button
                  type="button"
                  className="addon-category-heading flex h-9 items-center gap-2 px-2.5 text-left"
                  aria-expanded={isOpen}
                  onClick={() => setFoldedCategories(flip(foldedCategories, category.key))}
                >
                  <span className="flex size-4 shrink-0 items-center justify-center">
                    {isOpen ? <ChevronDown /> : <ChevronRight />}
                  </span>
                  <WowText
                    text={category.label ?? "Uncategorized"}
                    className={`grow truncate text-[13.5px] font-bold tracking-wide ${category.label === null ? "is-plain" : ""}`}
                  />
                  <span
                    className={`addon-category-count shrink-0 rounded-full px-2 py-px text-[11px] font-semibold ${onCount > 0 ? "has-on" : ""}`}
                    title={`${onCount} of ${members.length} on`}
                  >
                    {onCount}/{members.length}
                  </span>
                </button>
                {isOpen && (
                  <div className="flex flex-col px-1 pt-0.5 pb-1">
                    {category.groups.map((group) => (
                      <div key={group.head.name} className="flex flex-col">
                        {rowOf(group.head, false, group)}
                        {group.children.length > 0 &&
                          isGroupOpen(group.head.name) &&
                          group.children.map((child) => rowOf(child, true, null))}
                      </div>
                    ))}
                  </div>
                )}
              </section>
            );
          })}
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
