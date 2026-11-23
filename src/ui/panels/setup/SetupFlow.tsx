// The first run: a full-screen welcome that walks through what the simulator needs (the game's flavour, your AddOns
// folder, the interface source, LuaJIT), each step lit when it is done, then starts the game. Shown while the server
// says the setup is not done, and until the user steps into the game.
import { ArrowLeft, ArrowRight, CircleCheckFill, Gear, Rocket } from "@gravity-ui/icons";
import { Button, Card, Chip, ProgressBar, Spinner } from "@heroui/react";
import { type ReactNode, useState } from "react";
import type { SetupProblem, SetupState } from "../../sim/setup.ts";
import { readSetup, useSetup } from "../../sim/setup.ts";
import { refreshState } from "../../sim/store.ts";
import { AddonsFolderStep, FlavourStep, InterfaceStep, LuajitStep } from "./SetupSteps.tsx";

type Step = {
  id: string;
  title: string;
  lead: string;
  /** The problems' keys this step answers */
  keys: readonly SetupProblem["key"][];
  render: (setup: SetupState) => ReactNode;
};

const STEPS: readonly Step[] = [
  {
    id: "flavour",
    title: "The game",
    lead: "Which client your addons run against: its API, its art, its interface.",
    keys: ["flavour"],
    render: (setup) => <FlavourStep setup={setup} />,
  },
  {
    id: "addons",
    title: "Your addons",
    lead: "The game's Interface\\AddOns folder: the addons you work on live there.",
    keys: ["addonsRoot"],
    render: (setup) => <AddonsFolderStep setup={setup} />,
  },
  {
    id: "interface",
    title: "The game's interface",
    lead: "Blizzard's own interface code, so your addon sits among the real frames: a checkout, or downloaded here.",
    keys: ["interfaceRoot", "interface"],
    render: (setup) => <InterfaceStep setup={setup} />,
  },
  {
    id: "luajit",
    title: "LuaJIT",
    lead: "The game's Lua 5.1, which runs the simulator.",
    keys: ["luajit", "luajitPath"],
    render: (setup) => <LuajitStep setup={setup} />,
  },
];

const isStepDone = (step: Step, setup: SetupState): boolean =>
  !setup.problems.some((problem) => step.keys.includes(problem.key));

const SimulatorState = ({ setup }: { setup: SetupState }) => {
  const { state, error } = setup.simulator;
  if (state === "running")
    return (
      <Chip color="success" variant="soft">
        <CircleCheckFill className="size-3.5" />
        The simulator runs
      </Chip>
    );
  if (state === "starting")
    return (
      <Chip color="accent" variant="soft">
        <Spinner size="sm" />
        Starting (the first time fetches the game's art and tables)
      </Chip>
    );
  if (state === "failed") return <p className="text-sm text-danger">{error ?? "The simulator did not start"}</p>;
  return null;
};

export const SetupFlow = ({ onEnter }: { onEnter: () => void }) => {
  const { setup, error } = useSetup();
  const [index, setIndex] = useState(0);
  const step = STEPS[index] as Step;
  const doneCount = setup ? STEPS.filter((entry) => isStepDone(entry, setup)).length : 0;
  const isLast = index === STEPS.length - 1;

  return (
    <div className="setup-screen flex min-h-screen items-center justify-center overflow-y-auto p-6">
      <div className="flex w-full max-w-3xl flex-col gap-6">
        <header className="flex flex-col items-center gap-3 text-center">
          <span
            className="brand-mark setup-mark flex size-14 items-center justify-center rounded-2xl"
            aria-hidden="true"
          >
            <Rocket className="size-7" />
          </span>
          <h1 className="text-3xl font-semibold tracking-tight">
            Welcome to <span className="text-gold">AddonSim</span>
          </h1>
          <p className="max-w-lg text-sm text-muted">
            Your addons in the browser, among the game's own interface, with its real art. Four things and you are in.
          </p>
          <ProgressBar
            aria-label="The setup"
            value={doneCount}
            maxValue={STEPS.length}
            size="sm"
            className="w-64"
            color="success"
          >
            <ProgressBar.Track>
              <ProgressBar.Fill />
            </ProgressBar.Track>
          </ProgressBar>
        </header>

        {!setup ? (
          <div className="flex flex-col items-center gap-3 py-10 text-muted">
            {error ? (
              <>
                <p className="text-danger">The server did not answer: {error}</p>
                <Button variant="secondary" onPress={() => void readSetup()}>
                  Try again
                </Button>
              </>
            ) : (
              <Spinner />
            )}
          </div>
        ) : (
          <div className="grid gap-5 md:grid-cols-[13rem_1fr]">
            <nav aria-label="Setup steps" className="flex flex-col gap-1">
              {STEPS.map((entry, position) => {
                const isDone = isStepDone(entry, setup);
                return (
                  <button
                    key={entry.id}
                    type="button"
                    aria-current={position === index ? "step" : undefined}
                    onClick={() => setIndex(position)}
                    className={`setup-step flex cursor-pointer items-center gap-3 rounded-xl px-3 py-2.5 text-left ${position === index ? "is-current" : ""}`}
                  >
                    <span
                      className={`setup-step-dot flex size-7 shrink-0 items-center justify-center rounded-full text-xs font-bold ${isDone ? "is-done" : ""}`}
                    >
                      {isDone ? <CircleCheckFill className="size-4" /> : position + 1}
                    </span>
                    <span className="text-[13px] font-medium">{entry.title}</span>
                  </button>
                );
              })}
              <div className="mt-3 px-3 text-[11px] text-muted">
                Kept in <span className="font-mono break-all">{setup.paths.settingsFile}</span>
              </div>
            </nav>

            <Card className="setup-card gap-4 p-5">
              <Card.Header>
                <Card.Title className="text-lg">{step.title}</Card.Title>
                <Card.Description>{step.lead}</Card.Description>
              </Card.Header>
              <Card.Content>{step.render(setup)}</Card.Content>
              {setup.problems
                .filter((problem) => step.keys.includes(problem.key))
                .map((problem) => (
                  <p key={problem.message} className="text-xs text-warning">
                    {problem.message}
                  </p>
                ))}
              <Card.Footer className="flex flex-wrap items-center gap-2">
                <Button variant="tertiary" isDisabled={index === 0} onPress={() => setIndex(index - 1)}>
                  <ArrowLeft />
                  Back
                </Button>
                <Button variant="ghost" onPress={() => void readSetup(true)}>
                  <Gear />
                  Look again
                </Button>
                <span className="grow" />
                {!isLast && (
                  <Button
                    variant={isStepDone(step, setup) ? "primary" : "secondary"}
                    onPress={() => setIndex(index + 1)}
                  >
                    Next
                    <ArrowRight />
                  </Button>
                )}
              </Card.Footer>
            </Card>
          </div>
        )}

        {setup && (
          <footer className="flex flex-col items-center gap-3">
            <SimulatorState setup={setup} />
            <Button
              size="lg"
              isDisabled={!setup.isReady}
              className="enter-button"
              onPress={() => {
                void refreshState();
                onEnter();
              }}
            >
              <Rocket />
              {setup.isReady ? "Into the game" : `${STEPS.length - doneCount} to go`}
            </Button>
          </footer>
        )}
      </div>
    </div>
  );
};
