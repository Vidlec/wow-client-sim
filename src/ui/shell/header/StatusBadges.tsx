// The header's right end: the screen (a press opens its controls), the client the simulator matches, how strict its
// API is, and the errors so far (a press shows them)
import { Display, TriangleExclamation } from "@gravity-ui/icons";
import { Button, Chip, Popover, Tooltip } from "@heroui/react";
import { useFlavour } from "../../flavours/index.ts";
import { ScreenControls, useScreenSummary } from "../../panels/view/ScreenControls.tsx";
import { useSimState } from "../../sim/hooks.ts";
import type { ClientInfo } from "../../sim/types.ts";
import { showPanel } from "../navigation.ts";

export const ViewChip = () => {
  const summary = useScreenSummary();
  return (
    <Popover>
      <Button size="sm" variant="ghost" className="font-mono text-xs text-muted" aria-label={`Screen: ${summary}`}>
        <Display />
        {summary}
      </Button>
      <Popover.Content placement="bottom end" className="w-80">
        <Popover.Dialog className="p-4">
          <Popover.Heading className="mb-3 text-sm font-semibold">Screen</Popover.Heading>
          <ScreenControls />
        </Popover.Dialog>
      </Popover.Content>
    </Popover>
  );
};

const NO_CLIENT: ClientInfo | null = null;

export const ClientBadges = () => {
  const flavour = useFlavour();
  const client = useSimState((state): ClientInfo | null => state.client ?? null, NO_CLIENT);
  if (!client?.build) return null;
  const build = /^(\d+\.\d+\.\d+)\.(\d+)$/.exec(client.build);
  return (
    <div className="flex items-center gap-1.5">
      <Tooltip delay={300}>
        <Chip size="sm" variant="soft" className="client-chip font-mono">
          {flavour.shortName} {build ? `${build[1]} · ${build[2]}` : client.build}
        </Chip>
        <Tooltip.Content>
          The client whose API, events and art the simulator matches ({flavour.clientName})
        </Tooltip.Content>
      </Tooltip>
      <Tooltip delay={300}>
        <Chip size="sm" variant="soft" color={client.isStrictApi ? "success" : "warning"}>
          {client.isStrictApi ? "Strict API" : "Loose API"}
        </Chip>
        <Tooltip.Content className="max-w-xs">
          {client.isStrictApi
            ? `Addons see exactly this client's functions: ${client.simOnly ?? "?"} the simulator has but the client lacks are nil, as in the game. ${client.clientOnly ?? "?"} of the client's are not simulated yet (api-report.txt).`
            : "Addons may call functions this client does not have: switch Strict API on in the settings"}
        </Tooltip.Content>
      </Tooltip>
    </div>
  );
};

export const ErrorsButton = () => {
  const count = useSimState((state) => state.errors.length, 0);
  if (count === 0) return null;
  return (
    <Button size="sm" variant="danger-soft" onPress={() => showPanel("errors")} className="errors-button">
      <TriangleExclamation />
      {count === 1 ? "1 error" : `${count} errors`}
    </Button>
  );
};
