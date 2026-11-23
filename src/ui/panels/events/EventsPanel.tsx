// The Events panel: every event the game fired since the page opened (the store gathers them), newest first, filtered
// by name or argument; an event's name pressed filters by it. Firing one by hand happens in a window.
import { ArrowDownToLine, Thunderbolt, TrashBin } from "@gravity-ui/icons";
import { Button, Chip, SearchField, Tooltip } from "@heroui/react";
import { useDeferredValue, useMemo, useState } from "react";
import { EmptyState } from "../../components/bits.tsx";
import { VirtualList } from "../../components/VirtualList.tsx";
import { useEventHistory } from "../../sim/hooks.ts";
import { clearHistory } from "../../sim/store.ts";
import type { SimEvent } from "../../sim/types.ts";
import { FireEventModal } from "./FireEventModal.tsx";

const ROW_HEIGHT = 26;

// Addon messages carry bytes that are no letters (serialized tables): shown as dots, not as broken characters
// biome-ignore lint/suspicious/noControlCharactersInRegex: those are the characters it replaces
const UNPRINTABLE = /[\u0000-\u001f\u007f-\u009f�]/g;
const printable = (text: string): string => text.replace(UNPRINTABLE, "·");

const eventTone = (name: string): string =>
  name.startsWith("BAG_") || name.startsWith("ITEM_")
    ? "text-success"
    : name.startsWith("CHAT_MSG")
      ? "text-[#c9a8ff]"
      : name.startsWith("QUEST")
        ? "text-gold"
        : name.startsWith("UNIT_") || name.startsWith("PLAYER_")
          ? "text-[#7fd4ff]"
          : "text-accent";

export const EventsPanel = () => {
  const history = useEventHistory();
  const [filter, setFilter] = useState("");
  const [isFiring, setFiring] = useState(false);
  const deferredFilter = useDeferredValue(filter.trim().toUpperCase());

  const shown = useMemo(() => {
    const newestFirst = history.slice().reverse();
    if (!deferredFilter) return newestFirst;
    return newestFirst.filter(
      (event) => event.event.includes(deferredFilter) || event.args.join(", ").toUpperCase().includes(deferredFilter),
    );
  }, [history, deferredFilter]);
  const knownEvents = useMemo(() => [...new Set(history.map((event) => event.event))].sort(), [history]);

  const renderRow = (event: SimEvent) => (
    <div className="event-row flex h-full items-center gap-2 px-2 font-mono text-[11.5px]">
      <span className="w-14 shrink-0 text-right text-muted tabular-nums">{event.time.toFixed(2)}</span>
      <button
        type="button"
        className={`shrink-0 cursor-pointer truncate hover:underline ${eventTone(event.event)}`}
        title={`Show only ${event.event}`}
        onClick={() => setFilter(event.event)}
      >
        {event.event}
      </button>
      <span className="min-w-0 truncate text-muted" title={printable(event.args.join(", "))}>
        {printable(event.args.join(", "))}
      </span>
    </div>
  );

  return (
    <>
      <div className="flex items-center gap-2">
        <SearchField aria-label="Filter the events" value={filter} onChange={setFilter} className="grow">
          <SearchField.Group>
            <SearchField.SearchIcon />
            <SearchField.Input placeholder="Filter: QUEST_, BAG_, an argument…" className="font-mono text-[12px]" />
            <SearchField.ClearButton />
          </SearchField.Group>
        </SearchField>
        <Button size="sm" onPress={() => setFiring(true)}>
          <Thunderbolt />
          Fire…
        </Button>
        <Tooltip delay={300}>
          <Button isIconOnly size="sm" variant="ghost" aria-label="Forget the events so far" onPress={clearHistory}>
            <TrashBin />
          </Button>
          <Tooltip.Content>Forget the events so far (the page's list only)</Tooltip.Content>
        </Tooltip>
      </div>
      <div className="flex items-center gap-2 px-1 text-xs text-muted">
        <ArrowDownToLine className="size-3.5" />
        Newest first
        <span className="grow" />
        <Chip size="sm" variant="soft">
          {deferredFilter
            ? `${shown.length.toLocaleString()} of ${history.length.toLocaleString()}`
            : history.length.toLocaleString()}
        </Chip>
      </div>
      {shown.length === 0 ? (
        <EmptyState icon={<Thunderbolt />}>{history.length ? "No events match." : "No events yet."}</EmptyState>
      ) : (
        <VirtualList
          label="Events"
          items={shown}
          rowHeight={ROW_HEIGHT}
          getKey={(event, index) => `${shown.length - index}:${event.time}:${event.event}`}
          renderRow={renderRow}
          className="events-list rounded-xl border border-separator bg-[#0b0d10]"
        />
      )}
      <FireEventModal isOpen={isFiring} onClose={() => setFiring(false)} knownEvents={knownEvents} />
    </>
  );
};
