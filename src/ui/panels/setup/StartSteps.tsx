// The simulator's start, part by part (src/server/startProgress.ts): the native core, the game's file list, wowless's
// data, the game's tables, the atlases, the map's highlights, the game booting. Each with how it stands, what it is at,
// how far it got and how long it took. The setup shows it while the simulator starts; the settings show the last one.
import { CircleCheckFill, CircleExclamationFill } from "@gravity-ui/icons";
import { ProgressBar, Spinner } from "@heroui/react";
import type { StartProgress, StartStep } from "../../sim/setup.ts";

const StepMark = ({ state }: { state: StartStep["state"] }) => {
  if (state === "done") return <CircleCheckFill className="size-4 text-success" />;
  if (state === "failed") return <CircleExclamationFill className="size-4 text-danger" />;
  if (state === "running") return <Spinner size="sm" />;
  return <span className="m-1 size-2 rounded-full bg-default" aria-hidden="true" />;
};

const STATE_NAMES: Record<StartStep["state"], string> = {
  waiting: "waiting",
  running: "under way",
  done: "done",
  failed: "failed",
};

const formatSeconds = (seconds: number): string =>
  seconds >= 60 ? `${Math.floor(seconds / 60)} min ${Math.round(seconds % 60)} s` : `${seconds.toFixed(1)} s`;

export const StartSteps = ({ start }: { start: StartProgress }) => (
  <ol className="flex w-full flex-col gap-2" aria-label="The simulator's start">
    {start.steps.map((step) => {
      const hasCount = step.state === "running" && step.total !== undefined && step.total > 0;
      return (
        <li key={step.id} className="grid grid-cols-[1.25rem_1fr_auto] items-start gap-x-2.5">
          <span className="flex h-5 items-center justify-center" title={STATE_NAMES[step.state]}>
            <StepMark state={step.state} />
          </span>
          <span className="flex min-w-0 flex-col gap-1">
            <span className={`text-[13px] ${step.state === "waiting" ? "text-muted" : ""}`}>
              {step.label}
              {hasCount && (
                <span className="text-muted">
                  {" "}
                  · {step.done} of {step.total}
                </span>
              )}
            </span>
            {step.detail && (
              <span
                className={`text-xs break-words ${step.state === "failed" ? "text-danger" : "text-muted"} ${step.id === "tables" && step.state === "running" ? "font-mono" : ""}`}
              >
                {step.detail}
              </span>
            )}
            {hasCount && (
              <ProgressBar
                aria-label={step.label}
                value={step.done ?? 0}
                maxValue={step.total ?? 1}
                size="sm"
                className="w-full"
              >
                <ProgressBar.Track>
                  <ProgressBar.Fill />
                </ProgressBar.Track>
              </ProgressBar>
            )}
          </span>
          <span className="pt-0.5 text-[11px] tabular-nums text-muted">
            {step.seconds !== undefined && step.state !== "waiting" ? formatSeconds(step.seconds) : ""}
          </span>
        </li>
      );
    })}
  </ol>
);
