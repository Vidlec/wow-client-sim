// The strip under the game: the latest events (a press shows them all), how the simulator is (addons, boot, the game's
// time), and how it keeps up: the game's frames a second and their cost, the page's draws (a press splits them)
import { Pulse, Thunderbolt } from "@gravity-ui/icons";
import { Button, Popover } from "@heroui/react";
import { Facts } from "../components/bits.tsx";
import { useEventHistory, useSimState, useStoreStatus } from "../sim/hooks.ts";
import type { ClockPerf, SimulatorPerf } from "../sim/types.ts";
import { showPanel } from "./navigation.ts";
import { useDrawStats, useStreamHealth } from "./screen.ts";

const TICKER_EVENTS = 3;

const Ticker = () => {
  const history = useEventHistory();
  const latest = history.slice(-TICKER_EVENTS).reverse();
  return (
    <button
      type="button"
      onClick={() => showPanel("events")}
      className="ticker flex min-w-0 cursor-pointer items-center gap-2 rounded-md px-2 py-0.5 hover:bg-surface-secondary"
      aria-label="The latest events: show all of them"
    >
      <Thunderbolt className="size-3.5 shrink-0 text-warning" />
      {latest.length === 0 && <span className="text-muted">no events yet</span>}
      {latest.map((event, index) => (
        <span
          key={`${event.time}-${event.event}-${event.args.join(",")}`}
          className={`ticker-event truncate ${index === 0 ? "is-newest" : ""}`}
        >
          <span className="text-muted tabular-nums">{event.time.toFixed(2)}</span>{" "}
          <span className={event.event.startsWith("BAG_") ? "text-success" : "text-accent"}>{event.event}</span>
        </span>
      ))}
    </button>
  );
};

const SimulatorStatus = () => {
  const { isOffline, problem } = useStoreStatus();
  const stream = useStreamHealth();
  const loaded = useSimState(
    (state) =>
      state.addons.filter((addon) => addon.loaded && !addon.name.startsWith("Blizzard_")).map((addon) => addon.name),
    [],
  );
  const boot = useSimState((state) => state.bootSeconds ?? null, null);
  const now = useSimState((state) => Math.floor(state.now), 0);
  const artReady = useSimState((state) => state.artReady, true);
  const paused = useSimState((state) => state.paused, false);
  if (isOffline || !stream.isConnected) return <span className="text-danger">server not answering</span>;
  if (stream.error) return <span className="truncate text-danger">{stream.error}</span>;
  if (problem?.error) return <span className="text-danger">{problem.error}</span>;
  return (
    <span className="truncate text-muted" title={loaded.join(", ")}>
      <span className={`status-dot ${paused ? "is-paused" : "is-live"}`} aria-hidden="true" />
      {loaded.length} {loaded.length === 1 ? "addon" : "addons"} · boot {boot?.toFixed(2) ?? "?"} s · game time {now} s
      {paused ? " · paused" : ""}
      {artReady ? "" : " · art index building…"}
    </span>
  );
};

const PerfReadout = () => {
  const perf = useSimState((state): ClockPerf | null => state.perf ?? null, null);
  const simulator = useSimState((state): SimulatorPerf | null => state.simulatorPerf ?? null, null);
  const draw = useDrawStats();
  const worst = simulator?.worst;
  const game = perf ? `${perf.fps} fps · ${perf.frameMs} ms` : "";
  const page = draw
    ? `drawn ${Math.round(draw.drawsPerSecond)}/s · ${draw.renderer === "gl" ? "GPU" : "DOM"} ${draw.drawMs.toFixed(1)} ms`
    : "";
  return (
    <Popover>
      <Button size="sm" variant="ghost" className="h-6 gap-1.5 px-2 font-mono text-[11px] text-muted">
        <Pulse className="size-3.5" />
        {[game, page].filter(Boolean).join("  ·  ") || "…"}
      </Button>
      <Popover.Content placement="top end" className="w-80">
        <Popover.Dialog className="flex flex-col gap-3 p-4">
          <Popover.Heading className="text-sm font-semibold">How it keeps up</Popover.Heading>
          <Facts
            rows={[
              ["Game clock", perf ? `${perf.fps} frames a second` : "…"],
              ["A frame", perf ? `${perf.frameMs} ms (worst ${perf.worstMs} ms)` : "…"],
              [
                "Worst, split",
                worst
                  ? `code ${worst.tick} + list ${worst.export} + send ${worst.encode} ms${worst.collected ? ", garbage collected" : ""}`
                  : "…",
              ],
              ["Lua heap", simulator?.heapMb !== undefined ? `${simulator.heapMb} MB` : "…"],
              ["Pages watching", perf?.pages !== undefined ? String(perf.pages) : "…"],
              ["Page draws", draw ? `${Math.round(draw.drawsPerSecond)} a second` : "…"],
              [
                "Renderer",
                draw
                  ? `${draw.renderer === "gl" ? "GPU (WebGL2)" : "page elements"}, ${draw.drawMs.toFixed(1)} ms a draw`
                  : "…",
              ],
            ]}
          />
          <p className="text-xs leading-relaxed text-muted">
            The worst frame of the last second is split into the game's code (input and tick), the drawing list (export)
            and its changes written (send).
          </p>
        </Popover.Dialog>
      </Popover.Content>
    </Popover>
  );
};

export const StatusStrip = () => (
  <footer className="status-strip flex h-8 shrink-0 items-center gap-3 border-t border-separator px-2 text-xs">
    <Ticker />
    <span className="grow" />
    <SimulatorStatus />
    <PerfReadout />
  </footer>
);
