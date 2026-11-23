// One addon of your folder: switched on or off (a reload, as the game's AddOns list needs one), what its TOC says,
// how long it took to load, its time a game tick (as the AddOn profiler measures it) and its saved variables
import { Database } from "@gravity-ui/icons";
import { Button, Chip, Label, Spinner, Switch, Tooltip } from "@heroui/react";
import { memo } from "react";
import { formatBytes } from "../../components/format.ts";
import { plainWowText } from "../../components/WowText.tsx";
import type { CatalogAddon, LoadedAddon } from "../../sim/types.ts";

type Props = {
  entry: CatalogAddon;
  running: LoadedAddon | undefined;
  isSwitching: boolean;
  onSwitch: (isOn: boolean) => void;
  onSaved: () => void;
};

const describeState = (
  entry: CatalogAddon,
  running: LoadedAddon | undefined,
): { label: string; color: "success" | "default" | "warning" | "accent" } => {
  if (!entry.enabled) return { label: "off", color: "default" };
  if (running?.loaded)
    return { label: running.seconds !== undefined ? `loaded in ${running.seconds} s` : "loaded", color: "success" };
  if (entry.loadOnDemand) return { label: "on demand", color: "accent" };
  return { label: "not loaded", color: "warning" };
};

export const AddonCard = memo(({ entry, running, isSwitching, onSwitch, onSaved }: Props) => {
  const state = describeState(entry, running);
  const cpu = running?.cpu;
  const title = plainWowText(entry.title) || entry.name;
  return (
    <article className={`addon-card flex gap-3 rounded-xl border p-3 ${entry.enabled ? "is-on" : ""}`}>
      <div className="pt-0.5">
        {isSwitching ? (
          <Spinner size="sm" />
        ) : (
          <Switch size="sm" isSelected={entry.enabled} onChange={onSwitch}>
            <Switch.Content>
              <Switch.Control>
                <Switch.Thumb />
              </Switch.Control>
              <Label className="sr-only">Load {title}</Label>
            </Switch.Content>
          </Switch>
        )}
      </div>
      <div className="flex min-w-0 grow flex-col gap-1">
        <div className="flex items-baseline gap-2">
          <span className="truncate text-[13px] font-semibold">{title}</span>
          {entry.version && <span className="font-mono text-[11px] text-muted">{entry.version}</span>}
        </div>
        {entry.notes && <p className="line-clamp-2 text-xs leading-relaxed text-muted">{plainWowText(entry.notes)}</p>}
        <div className="flex flex-wrap items-center gap-1.5">
          <Chip size="sm" variant="soft" color={state.color}>
            {state.label}
          </Chip>
          {entry.isProject && (
            <Chip size="sm" variant="soft" color="accent">
              project
            </Chip>
          )}
          {cpu && (
            <Tooltip delay={300}>
              <Chip size="sm" variant="soft" className="font-mono">
                {cpu.recent} ms/tick
              </Chip>
              <Tooltip.Content>
                {cpu.average} ms a tick since login, worst {cpu.peak} ms, {cpu.total} ms in all
              </Tooltip.Content>
            </Tooltip>
          )}
          {entry.dependencies.length > 0 && (
            <span className="text-[11px] text-muted">needs {entry.dependencies.join(", ")}</span>
          )}
        </div>
      </div>
      {entry.savedVariables.length > 0 && (
        <Tooltip delay={300}>
          <Button
            size="sm"
            variant="ghost"
            className="shrink-0 self-start"
            onPress={onSaved}
            aria-label={`${title}'s saved variables`}
          >
            <Database />
            {entry.savedBytes ? formatBytes(entry.savedBytes) : "Saved"}
          </Button>
          <Tooltip.Content>{entry.savedVariables.join(", ")}</Tooltip.Content>
        </Tooltip>
      )}
    </article>
  );
});
