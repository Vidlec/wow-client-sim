// An error as the panel shows it: its message, how many times, where in an addon of yours it came from (the first
// stack line in an addon that is not the game's own), its stack with your addons' lines lit and the game's dimmed,
// and a button to copy it all
import { ChevronDown, FileCode } from "@gravity-ui/icons";
import { Chip, Disclosure } from "@heroui/react";
import { memo } from "react";
import { CopyButton } from "../../components/bits.tsx";
import type { SimError } from "../../sim/types.ts";

// (Lua shortens long paths from the front: "...AddOns/Blizzard_X/File.lua:12")
const ADDON_LINE = /AddOns[\\/]([^\\/]+)[\\/]([^:]+):(\d+)/;

type StackLine = { text: string; kind: "own" | "game" | "other" };

export const readStack = (stack: string | undefined): { lines: StackLine[]; origin: string | null } => {
  let origin: string | null = null;
  const lines = String(stack ?? "")
    .split("\n")
    .filter(Boolean)
    .map((text): StackLine => {
      const match = ADDON_LINE.exec(text);
      const isOwn = match !== null && !match[1]?.startsWith("Blizzard_");
      if (isOwn && match && !origin) origin = `${match[1]}/${match[2]}:${match[3]}`;
      return { text, kind: isOwn ? "own" : match ? "game" : "other" };
    });
  return { lines, origin };
};

const LINE_CLASS: Record<StackLine["kind"], string> = {
  own: "text-[#ffb4a8]",
  game: "text-muted",
  other: "text-[#8b939e]/70",
};

export const ErrorCard = memo(({ error, isOpenAtFirst }: { error: SimError; isOpenAtFirst: boolean }) => {
  const { lines, origin } = readStack(error.stack);
  return (
    <article className="error-card flex flex-col gap-2 rounded-xl border p-3">
      <div className="flex items-start gap-2">
        {(error.count ?? 1) > 1 && (
          <Chip size="sm" color="danger" variant="primary" className="shrink-0 font-mono">
            {error.count}×
          </Chip>
        )}
        <p className="min-w-0 grow font-mono text-[12px] leading-relaxed break-words text-[#ffcfc7]">{error.message}</p>
        <CopyButton text={`${error.message}\n${error.stack ?? ""}`} label="Copy the message and its stack" />
      </div>
      {origin && (
        <span className="inline-flex items-center gap-1.5 text-xs text-muted">
          <FileCode className="size-3.5 text-danger" />
          from <span className="font-mono text-foreground">{origin}</span>
        </span>
      )}
      {lines.length > 0 && (
        <Disclosure defaultExpanded={isOpenAtFirst}>
          <Disclosure.Heading>
            <Disclosure.Trigger className="flex items-center gap-1 text-xs text-muted hover:text-foreground">
              <ChevronDown className="size-3.5 transition-transform in-aria-expanded:rotate-180" />
              Stack ({lines.length} lines)
            </Disclosure.Trigger>
          </Disclosure.Heading>
          <Disclosure.Content>
            <pre className="mt-1 max-h-72 overflow-auto rounded-lg bg-[#0b0d10] p-2.5 font-mono text-[11px] leading-relaxed">
              {lines.map((line, index) => (
                // biome-ignore lint/suspicious/noArrayIndexKey: the lines of one stack, in order, never moved
                <div key={index} className={LINE_CLASS[line.kind]}>
                  {line.text}
                </div>
              ))}
            </pre>
          </Disclosure.Content>
        </Disclosure>
      )}
    </article>
  );
});
