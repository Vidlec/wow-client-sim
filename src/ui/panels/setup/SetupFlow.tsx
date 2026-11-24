// The first run: a full-screen welcome that walks through what the simulator needs (the game's flavour, your AddOns
// folder, the interface source, LuaJIT), each step lit when it is done, then starts the game. Shown while the server
// says the setup is not done, and until the user steps into the game.
//
// Three columns on a wide screen: the steps, the step at hand, and the start (what is left, then each part of the
// simulator's start as it goes, and the way in). Narrower, the steps become one row above the other two; on a phone
// everything stacks. The screen scrolls as a whole and its content sits at the top, so nothing is cut off and the
// start panel growing never moves the rest.
import {
  ArrowLeft,
  ArrowRight,
  ArrowRotateRight,
  CircleCheckFill,
  CircleExclamationFill,
  Minus,
  Rocket,
} from "@gravity-ui/icons";
import { Button, Card, Disclosure, ProgressBar, Spinner } from "@heroui/react";
import { type ReactNode, useState } from "react";
import { PathText } from "../../components/bits.tsx";
import type { SetupProblem, SetupState } from "../../sim/setup.ts";
import { readSetup, useSetup } from "../../sim/setup.ts";
import { refreshState } from "../../sim/store.ts";
import { AddonsFolderStep, FlavourStep, InterfaceStep, LuajitStep } from "./SetupSteps.tsx";
import { StartSteps } from "./StartSteps.tsx";

type Step = {
  id: string;
  title: string;
  lead: string;
  /** The problems' keys this step answers */
  keys: readonly SetupProblem["key"][];
  /** Not needed to start (the AddOns folder): done once chosen, else marked optional, never counted as left */
  isOptional?: true;
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
    lead: "The folders your addons are in, as many as you like: the game's AddOns folder, or any folder on the disk. Optional: the sim runs without them, and the Addons tab takes them later.",
    keys: ["addonsRoot"],
    isOptional: true,
    render: () => <AddonsFolderStep />,
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

const hasProblem = (step: Step, setup: SetupState): boolean =>
  setup.problems.some((problem) => step.keys.includes(problem.key));

/** Done: nothing wrong with it, and an optional step only once something is chosen */
const isStepDone = (step: Step, setup: SetupState): boolean =>
  !hasProblem(step, setup) &&
  (!step.isOptional || setup.settings.addonsRoot !== "" || setup.settings.addonFolders.length > 0);

const REQUIRED_STEPS = STEPS.filter((step) => !step.isOptional);

/** A step's mark in the list: done, skipped for now (optional), or its number */
const StepDot = ({ step, position, setup }: { step: Step; position: number; setup: SetupState }) => {
  const isDone = isStepDone(step, setup);
  const isSkipped = !isDone && step.isOptional && !hasProblem(step, setup);
  return (
    <span
      className={`setup-step-dot flex size-7 shrink-0 items-center justify-center rounded-full text-xs font-bold ${isDone ? "is-done" : ""}`}
    >
      {isDone ? <CircleCheckFill className="size-4" /> : isSkipped ? <Minus className="size-3.5" /> : position + 1}
    </span>
  );
};

/** The start once it ran: one line, its parts folded away */
const StartSummary = ({ setup }: { setup: SetupState }) => {
  const boot = setup.start?.steps.find((step) => step.id === "boot");
  if (!setup.start) return null;
  return (
    <Disclosure>
      <Disclosure.Heading>
        <Disclosure.Trigger className="flex w-full items-center gap-2 text-left text-xs text-muted">
          <span className="grow">
            Booted{boot?.seconds !== undefined ? ` in ${boot.seconds.toFixed(1)} s` : ""}
            {boot?.detail ? ` · ${boot.detail}` : ""}
          </span>
          <span>Details</span>
          <Disclosure.Indicator />
        </Disclosure.Trigger>
      </Disclosure.Heading>
      <Disclosure.Content>
        <div className="pt-3">
          <StartSteps start={setup.start} />
        </div>
      </Disclosure.Content>
    </Disclosure>
  );
};

/** The right-hand panel: what is left to set up, then the simulator's start part by part, and the way in */
const StartPanel = ({
  setup,
  onGoToStep,
  onEnter,
}: {
  setup: SetupState;
  onGoToStep: (index: number) => void;
  onEnter: () => void;
}) => {
  const { state, error } = setup.simulator;
  const leftSteps = STEPS.flatMap((entry, position) =>
    entry.isOptional || isStepDone(entry, setup) ? [] : [{ entry, position }],
  );
  const title = !setup.isReady
    ? "Before the sim starts"
    : state === "running"
      ? "The simulator runs"
      : state === "failed"
        ? "The simulator did not start"
        : "Starting the simulator";
  return (
    <Card className="setup-card gap-4 p-5">
      <Card.Header className="flex flex-row items-center gap-2">
        {setup.isReady && state === "starting" && <Spinner size="sm" />}
        {state === "running" && <CircleCheckFill className="size-4 text-success" />}
        {state === "failed" && <CircleExclamationFill className="size-4 text-danger" />}
        <Card.Title className="text-base">{title}</Card.Title>
      </Card.Header>
      <Card.Content className="flex flex-col gap-4">
        {!setup.isReady && (
          <ul className="flex flex-col gap-1.5">
            {leftSteps.map(({ entry, position }) => (
              <li key={entry.id}>
                <button
                  type="button"
                  onClick={() => onGoToStep(position)}
                  className="setup-step flex w-full cursor-pointer items-start gap-2.5 rounded-lg px-2.5 py-2 text-left"
                >
                  <span className="setup-step-dot mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full text-[11px] font-bold">
                    {position + 1}
                  </span>
                  <span className="flex flex-col gap-0.5">
                    <span className="text-[13px] font-medium">{entry.title}</span>
                    {setup.problems
                      .filter((problem) => entry.keys.includes(problem.key))
                      .map((problem) => (
                        <span key={problem.message} className="text-xs text-muted">
                          {problem.message}
                        </span>
                      ))}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
        {setup.isReady && state === "starting" && (
          <p className="text-xs text-muted">
            The first start fetches the game's art and tables from wago.tools (a few minutes); later starts read them
            from the cache.
          </p>
        )}
        {setup.isReady && setup.start && state !== "running" && <StartSteps start={setup.start} />}
        {setup.isReady && state === "running" && <StartSummary setup={setup} />}
        {state === "failed" && <p className="text-sm break-words text-danger">{error ?? "It stopped"}</p>}
      </Card.Content>
      <Card.Footer>
        <Button
          size="lg"
          fullWidth
          isDisabled={!setup.isReady || state === "starting" || state === "stopped"}
          className="enter-button"
          onPress={() => {
            void refreshState();
            onEnter();
          }}
        >
          <Rocket />
          {!setup.isReady ? `${leftSteps.length} to go` : state === "starting" ? "Starting…" : "Into the sim"}
        </Button>
      </Card.Footer>
    </Card>
  );
};

export const SetupFlow = ({ onEnter }: { onEnter: () => void }) => {
  const { setup, error } = useSetup();
  const [index, setIndex] = useState(0);
  const step = STEPS[index] as Step;
  const doneCount = setup ? REQUIRED_STEPS.filter((entry) => isStepDone(entry, setup)).length : 0;
  const isLast = index === STEPS.length - 1;

  return (
    <div className="setup-screen h-full overflow-y-auto">
      <div className="mx-auto flex w-full max-w-7xl flex-col gap-8 px-4 py-8 sm:px-8 lg:py-16">
        <header className="flex flex-wrap items-center gap-x-5 gap-y-4">
          <span
            className="brand-mark setup-mark flex size-14 shrink-0 items-center justify-center rounded-2xl"
            aria-hidden="true"
          >
            <Rocket className="size-7" />
          </span>
          <div className="flex min-w-0 grow flex-col gap-1">
            <h1 className="text-3xl font-semibold tracking-tight">
              Welcome to <span className="text-gold">AddonSim</span>
            </h1>
            <p className="max-w-2xl text-sm text-muted">
              Your addons in the browser, among the game's own interface, with its real art. Three things and you are
              in; your addons whenever you like.
            </p>
          </div>
          <ProgressBar
            aria-label="The setup"
            value={doneCount}
            maxValue={REQUIRED_STEPS.length}
            size="sm"
            className="w-full sm:w-56"
            color="success"
          >
            <span className="text-xs text-muted">
              {doneCount} of {REQUIRED_STEPS.length} done
            </span>
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
          <div className="grid items-start gap-6 md:grid-cols-[minmax(0,1fr)_20rem] lg:grid-cols-[14rem_minmax(0,1fr)_24rem]">
            {/* (a row above the other two until there is room for a column of its own) */}
            <nav
              aria-label="Setup steps"
              className="-mx-1 flex gap-1 overflow-x-auto px-1 md:col-span-2 lg:col-span-1 lg:mx-0 lg:flex-col lg:overflow-visible lg:px-0"
            >
              {STEPS.map((entry, position) => (
                <button
                  key={entry.id}
                  type="button"
                  aria-current={position === index ? "step" : undefined}
                  onClick={() => setIndex(position)}
                  className={`setup-step flex shrink-0 cursor-pointer items-center gap-3 rounded-xl px-3 py-2.5 text-left ${position === index ? "is-current" : ""}`}
                >
                  <StepDot step={entry} position={position} setup={setup} />
                  <span className="flex flex-col">
                    <span className="text-[13px] font-medium">{entry.title}</span>
                    {entry.isOptional && <span className="text-[11px] text-muted">Optional</span>}
                  </span>
                </button>
              ))}
              <p className="mt-3 hidden px-3 text-[11px] text-muted lg:block">
                Kept in <PathText path={setup.paths.settingsFile} />
              </p>
            </nav>

            <Card className="setup-card min-w-0 gap-4 p-6">
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
                  <ArrowRotateRight />
                  Look again
                </Button>
                <span className="grow" />
                {!isLast && (
                  <Button
                    variant={hasProblem(step, setup) ? "secondary" : "primary"}
                    onPress={() => setIndex(index + 1)}
                  >
                    {step.isOptional && !isStepDone(step, setup) ? "Skip for now" : "Next"}
                    <ArrowRight />
                  </Button>
                )}
              </Card.Footer>
            </Card>

            <div className="flex flex-col gap-3 lg:sticky lg:top-8">
              <StartPanel setup={setup} onGoToStep={setIndex} onEnter={onEnter} />
              <p className="px-1 text-[11px] text-muted lg:hidden">
                Kept in <PathText path={setup.paths.settingsFile} />
              </p>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};
