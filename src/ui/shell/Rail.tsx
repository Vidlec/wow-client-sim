// The left rail: an icon for each panel, with its count; the panel shown lit. A press opens a panel, or folds the side
// away when it is the one shown (the game gets the room).
import { Badge, Button, Tooltip } from "@heroui/react";
import { Fragment } from "react";
import { usePref } from "../sim/prefs.ts";
import { togglePanel } from "./navigation.ts";
import { PANELS, type PanelCount, type PanelInfo } from "./panels.tsx";

const formatCount = (value: number): string => (value > 999 ? `${Math.floor(value / 1000)}k` : String(value));

const noCount = (): PanelCount | null => null;

const RailButton = ({ panel, isOn }: { panel: PanelInfo; isOn: boolean }) => {
  // (each button keeps its panel: the same hook at every render)
  const useCount = panel.useCount ?? noCount;
  const found = useCount();
  return (
    <Badge.Anchor>
      <Tooltip delay={250} closeDelay={0}>
        <Button
          isIconOnly
          variant="ghost"
          aria-label={found ? `${panel.title} (${found.value})` : panel.title}
          aria-pressed={isOn}
          onPress={() => togglePanel(panel.id)}
          className={`rail-button ${isOn ? "is-on" : ""}`}
        >
          {panel.icon}
        </Button>
        <Tooltip.Content placement="right" showArrow className="max-w-60">
          <span className="font-medium">{panel.title}</span>
          <span className="block text-xs text-muted">{panel.description}</span>
        </Tooltip.Content>
      </Tooltip>
      {found && (
        <Badge
          size="sm"
          color={found.tone}
          variant={found.tone === "default" ? "secondary" : "primary"}
          className="rail-badge"
        >
          {formatCount(found.value)}
        </Badge>
      )}
    </Badge.Anchor>
  );
};

const GROUPS: readonly PanelInfo["group"][] = ["game", "develop", "page"];

export const Rail = () => {
  const shown = usePref("panel");
  const isCollapsed = usePref("isSideCollapsed");
  const isFloating = usePref("isPanelFloating");
  return (
    <nav
      className="app-rail flex w-14 shrink-0 flex-col items-center gap-1.5 border-r border-separator py-2.5"
      aria-label="Panels"
    >
      {GROUPS.map((group, index) => (
        <Fragment key={group}>
          {index === 1 && <span className="rail-rule" aria-hidden="true" />}
          {index === 2 && <span className="grow" />}
          {PANELS.filter((panel) => panel.group === group).map((panel) => (
            <RailButton key={panel.id} panel={panel} isOn={panel.id === shown && (!isCollapsed || isFloating)} />
          ))}
        </Fragment>
      ))}
    </nav>
  );
};
