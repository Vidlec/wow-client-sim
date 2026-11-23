// The page's header: the clock and reload, the slash command, who is playing, the input switch, the screen, the
// client and the errors
import { Separator } from "@heroui/react";
import { CharacterSummary } from "./CharacterSummary.tsx";
import { ClockControls } from "./ClockControls.tsx";
import { InputSwitch } from "./InputSwitch.tsx";
import { SlashCommand } from "./SlashCommand.tsx";
import { ClientBadges, ErrorsButton, ViewChip } from "./StatusBadges.tsx";

const Brand = () => (
  <div className="brand flex shrink-0 items-center gap-2 pr-1">
    <span className="brand-mark flex size-7 items-center justify-center rounded-lg" aria-hidden="true">
      <svg
        viewBox="0 0 24 24"
        width="16"
        height="16"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        aria-hidden="true"
      >
        <rect x="3" y="4" width="18" height="13" rx="2" />
        <path d="M8 21h8M12 17v4M8.5 10.5l2 2 4-4" />
      </svg>
    </span>
    <span className="text-sm font-semibold tracking-tight">AddonSim</span>
  </div>
);

export const Header = () => (
  <header className="app-header flex h-12 shrink-0 items-center gap-3 border-b border-separator px-3">
    <Brand />
    <Separator orientation="vertical" className="h-6" />
    <ClockControls />
    <Separator orientation="vertical" className="h-6" />
    <SlashCommand />
    <CharacterSummary />
    <span className="grow" />
    <InputSwitch />
    <Separator orientation="vertical" className="h-6" />
    <ViewChip />
    <ClientBadges />
    <ErrorsButton />
  </header>
);
