// One addon as a line of the list, as the game's AddOns list shows it: its switch, its icon and title (in the TOC's
// colours), and only what needs a look (a change waiting, not loaded, a missing dependency, a costly tick). A click
// opens the rest: its notes, what it requires, works with and is required by (each a link to that addon), its load
// time and tick, its folder and its saved variables.
import { ChevronDown, ChevronRight, Database } from "@gravity-ui/icons";
import { Button, Label, Switch, Tooltip } from "@heroui/react";
import { memo, useState } from "react";
import { isGameAddon } from "../../../shared/addonDeps.ts";
import { formatBytes } from "../../components/format.ts";
import { plainWowText, WowText } from "../../components/WowText.tsx";
import { textureUrl } from "../../engine/textures.ts";
import type { CatalogAddon, LoadedAddon } from "../../sim/types.ts";

/** How an addon stands after the changes waiting: on or off, and why it changes */
export type Planned = { isOn: boolean; change: "asked" | "brought" | "takenOut" | null };

/** How one of an addon's dependencies stands */
export type DependencyState = "on" | "coming" | "off" | "missing" | "game";

/** A group's head: how many it holds, how many of those are on, and whether they are shown */
export type GroupInfo = { count: number; on: number; isOpen: boolean; onToggle: () => void };

type Props = {
  entry: CatalogAddon;
  running: LoadedAddon | undefined;
  planned: Planned;
  dependencyStates: ReadonlyMap<string, DependencyState>;
  /** The addons on (after the changes) that need this one */
  neededBy: readonly string[];
  /** Folder labels: shown when addons come from more than one folder */
  folderLabel: string | null;
  isBusy: boolean;
  /** Listed under its group's head */
  isChild: boolean;
  group: GroupInfo | null;
  isOpen: boolean;
  isHighlighted: boolean;
  onOpen: () => void;
  onToggle: (isOn: boolean) => void;
  onSaved: () => void;
  /** Show another addon of the list (a dependency's link) */
  onReveal: (name: string) => void;
};

const DOTS: Record<DependencyState, { className: string; note: string }> = {
  on: { className: "bg-success", note: "on" },
  coming: { className: "bg-accent", note: "comes on with it" },
  off: { className: "bg-default", note: "off: switching this on brings it" },
  missing: { className: "bg-danger", note: "not installed: this addon will not load" },
  game: { className: "bg-default", note: "the game's own" },
};

const QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark";

/** What the line says at its right: only what needs a look */
const noteOf = (
  entry: CatalogAddon,
  running: LoadedAddon | undefined,
  planned: Planned,
  missing: readonly string[],
): { text: string; tone: string; tip: string } | null => {
  if (planned.change === "asked")
    return { text: planned.isOn ? "turns on" : "turns off", tone: "text-accent", tip: "Waits to be applied" };
  if (planned.change === "brought")
    return { text: "comes on", tone: "text-accent", tip: "Needed by one switched on: comes on with it" };
  if (planned.change === "takenOut")
    return { text: "goes off", tone: "text-warning", tip: "Needs one switched off: goes off with it" };
  if (!entry.isForThisGame)
    return {
      text: "other game",
      tone: "text-danger",
      tip: `Its TOC is for other game versions only (Interface ${entry.interfaceVersion}): the client does not list it`,
    };
  if (planned.isOn && missing.length > 0)
    return { text: `needs ${missing[0]}`, tone: "text-danger", tip: `Not installed: ${missing.join(", ")}` };
  if (!entry.enabled) return null;
  if (running?.loaded) return null;
  if (entry.loadOnDemand) return { text: "on demand", tone: "text-muted", tip: "Loads when code asks for it" };
  return { text: "not loaded", tone: "text-warning", tip: "On, but it did not load: see the errors" };
};

/** A row of addon names, each a link to it, with how it stands */
const NameList = ({
  label,
  names,
  stateOf,
  onReveal,
}: {
  label: string;
  names: readonly string[];
  stateOf: (name: string) => DependencyState;
  onReveal: (name: string) => void;
}) =>
  names.length === 0 ? null : (
    <div className="flex gap-2">
      <span className="w-[86px] shrink-0 text-muted">{label}</span>
      <span className="flex min-w-0 flex-wrap gap-x-2.5 gap-y-0.5">
        {names.map((name) => {
          const state = stateOf(name);
          const dot = DOTS[state];
          const canReveal = state !== "missing" && state !== "game";
          return (
            <button
              key={name}
              type="button"
              disabled={!canReveal}
              title={`${name}: ${dot.note}`}
              onClick={() => onReveal(name)}
              className={`inline-flex items-center gap-1 ${canReveal ? "hover:underline" : "cursor-default"} ${state === "missing" ? "text-danger" : ""}`}
            >
              <span className={`size-1.5 shrink-0 rounded-full ${dot.className}`} />
              {name}
            </button>
          );
        })}
      </span>
    </div>
  );

export const AddonRow = memo(
  ({
    entry,
    running,
    planned,
    dependencyStates,
    neededBy,
    folderLabel,
    isBusy,
    isChild,
    group,
    isOpen,
    isHighlighted,
    onOpen,
    onToggle,
    onSaved,
    onReveal,
  }: Props) => {
    const [hasIcon, setHasIcon] = useState(true);
    const title = plainWowText(entry.title) || entry.name;
    const stateOf = (name: string): DependencyState =>
      dependencyStates.get(name.toLowerCase()) ?? (isGameAddon(name) ? "game" : "missing");
    const missing = entry.dependencies.filter((name) => stateOf(name) === "missing");
    const note = noteOf(entry, running, planned, missing);
    const cpu = running?.cpu;
    const isCostly = cpu !== undefined && Number(cpu.recent) >= 0.5;
    const icon = textureUrl(entry.iconTexture || QUESTION_MARK);
    // (a child's dependency on its group's head goes without saying: the list shows it under it)
    const requires = isChild
      ? entry.dependencies.filter((name) => name.toLowerCase() !== entry.group.toLowerCase())
      : entry.dependencies;
    return (
      <div
        id={`addon-${entry.name.toLowerCase()}`}
        className={`addon-row rounded-md ${isOpen ? "is-open" : ""} ${planned.change ? "is-changing" : ""} ${isHighlighted ? "is-highlighted" : ""}`}
      >
        <div className={`flex h-8 items-center gap-1.5 pr-1 ${isChild ? "pl-6" : "pl-1"}`}>
          {group ? (
            <button
              type="button"
              className="flex size-4 shrink-0 items-center justify-center text-muted hover:text-foreground"
              aria-label={group.isOpen ? `Fold ${title}'s group` : `Show ${title}'s group`}
              aria-expanded={group.isOpen}
              onClick={group.onToggle}
            >
              {group.isOpen ? <ChevronDown /> : <ChevronRight />}
            </button>
          ) : (
            !isChild && <span className="size-4 shrink-0" />
          )}
          <Switch
            size="sm"
            isSelected={planned.isOn}
            isDisabled={isBusy || !entry.isForThisGame}
            onChange={onToggle}
            className="shrink-0"
          >
            <Switch.Content>
              <Switch.Control>
                <Switch.Thumb />
              </Switch.Control>
              <Label className="sr-only">Load {title}</Label>
            </Switch.Content>
          </Switch>
          <button
            type="button"
            onClick={onOpen}
            aria-expanded={isOpen}
            className={`flex min-w-0 grow items-center gap-1.5 text-left ${planned.isOn ? "" : "opacity-55"}`}
          >
            {icon && hasIcon ? (
              <img src={icon} alt="" className="size-4 shrink-0 rounded-[3px]" onError={() => setHasIcon(false)} />
            ) : (
              <span className="size-4 shrink-0" />
            )}
            <WowText text={entry.richTitle || title} className="truncate text-[12.5px]" />
            {group && !group.isOpen && (
              <span
                className="shrink-0 rounded bg-default px-1 text-[10.5px] text-muted"
                title={`${group.on} of ${group.count} on`}
              >
                +{group.count}
              </span>
            )}
          </button>
          {note && (
            <span className={`shrink-0 text-[11px] ${note.tone}`} title={note.tip}>
              {note.text}
            </span>
          )}
          {isCostly && cpu && (
            <span
              className="shrink-0 font-mono text-[10.5px] text-warning"
              title={`${cpu.recent} ms a game tick lately`}
            >
              {cpu.recent} ms
            </span>
          )}
        </div>
        {isOpen && (
          <div
            className={`flex flex-col gap-1.5 pt-0.5 pb-2.5 pr-2 text-[11.5px] ${isChild ? "pl-[70px]" : "pl-[52px]"}`}
          >
            {entry.notes && <p className="leading-relaxed text-muted">{plainWowText(entry.notes)}</p>}
            <p className="flex flex-wrap gap-x-2 text-muted">
              <span className="text-foreground" title={entry.name}>
                {entry.name}
              </span>
              {entry.version && <span className="font-mono">{entry.version}</span>}
              {entry.author && <span>by {plainWowText(entry.author)}</span>}
              {running?.loaded && running.seconds !== undefined && <span>loaded in {running.seconds} s</span>}
              {entry.loadOnDemand && <span>on demand</span>}
              {cpu && (
                <span className="font-mono" title={`worst ${cpu.peak} ms, ${cpu.total} ms in all`}>
                  {cpu.recent} ms/tick (avg {cpu.average})
                </span>
              )}
              {entry.origin === "project" && <span className="text-accent">project</span>}
              {folderLabel && entry.origin !== "project" && <span title={entry.root}>in {folderLabel}</span>}
            </p>
            <NameList label="Requires" names={requires} stateOf={stateOf} onReveal={onReveal} />
            <NameList
              label="Works with"
              names={entry.optionalDependencies}
              stateOf={(name) => (stateOf(name) === "missing" ? "off" : stateOf(name))}
              onReveal={onReveal}
            />
            <NameList label="Required by" names={neededBy} stateOf={() => "on"} onReveal={onReveal} />
            {entry.savedVariables.length > 0 && (
              <div className="flex items-center gap-2">
                <span className="w-[86px] shrink-0 text-muted">Saved</span>
                <Tooltip delay={300}>
                  <Button size="sm" variant="ghost" className="h-6 min-h-0 px-1.5 text-[11.5px]" onPress={onSaved}>
                    <Database />
                    {entry.savedBytes ? formatBytes(entry.savedBytes) : "none yet"}
                  </Button>
                  <Tooltip.Content>{entry.savedVariables.join(", ")}: read or reset</Tooltip.Content>
                </Tooltip>
              </div>
            )}
          </div>
        )}
      </div>
    );
  },
);
