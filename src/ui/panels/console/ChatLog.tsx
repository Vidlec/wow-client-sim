// The game's chat, as its chat frame shows it: each line in its colour, with the game's colour codes and links, the
// newest at the bottom (kept in view while it is)
import { Comment } from "@gravity-ui/icons";
import { useEffect, useRef } from "react";
import { EmptyState } from "../../components/bits.tsx";
import { WowText } from "../../components/WowText.tsx";
import { useSimState } from "../../sim/hooks.ts";
import type { ChatLine } from "../../sim/types.ts";

const SHOWN = 200;
const NO_LINES: ChatLine[] = [];

const toColor = (line: ChatLine): string =>
  `rgb(${Math.round(line.r * 255)}, ${Math.round(line.g * 255)}, ${Math.round(line.b * 255)})`;

export const ChatLog = () => {
  const lines = useSimState((state) => state.chat, NO_LINES);
  const box = useRef<HTMLDivElement>(null);
  const isAtBottom = useRef(true);
  const shown = lines.slice(-SHOWN);

  // biome-ignore lint/correctness/useExhaustiveDependencies: a new line is the cue to follow it
  useEffect(() => {
    const element = box.current;
    if (element && isAtBottom.current) element.scrollTop = element.scrollHeight;
  }, [lines]);

  if (shown.length === 0) return <EmptyState icon={<Comment />}>Nothing in the chat yet.</EmptyState>;
  return (
    <div
      ref={box}
      className="chat-log flex flex-col gap-0.5 overflow-y-auto rounded-xl border border-separator bg-[#0b0d10] p-2.5"
      onScroll={(event) => {
        const element = event.currentTarget;
        isAtBottom.current = element.scrollHeight - element.scrollTop - element.clientHeight < 24;
      }}
    >
      {shown.map((line, index) => (
        // biome-ignore lint/suspicious/noArrayIndexKey: the chat only grows at its end; a line keeps its place
        <div key={lines.length - shown.length + index} className="chat-line text-[12.5px] leading-snug">
          <span className="mr-1.5 font-mono text-[10px] text-muted tabular-nums">{line.time.toFixed(0)}</span>
          <WowText text={line.text} color={toColor(line)} />
        </div>
      ))}
    </div>
  );
};
