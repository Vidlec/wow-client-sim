// The setup's parts, used by the first-run flow and the Settings panel alike: the game's flavour, your addon folders,
// the game's interface source (found, chosen, or downloaded with its progress) and LuaJIT
import { ArrowDownToLine, CircleCheckFill, CircleExclamationFill, Terminal } from "@gravity-ui/icons";
import { Button, Chip, ProgressBar, toast } from "@heroui/react";
import { formatBytes } from "../../components/format.ts";
import { changeSettings, downloadInterface, type SetupState } from "../../sim/setup.ts";
import { AddonFolders } from "../addons/AddonFolders.tsx";
import { getExamplePath } from "./examplePaths.ts";
import { FolderChoice } from "./FolderChoice.tsx";

type StepProps = { setup: SetupState };

const reportAnswer = (answer: Awaited<ReturnType<typeof changeSettings>>): void => {
  for (const error of answer.errors) toast.danger(error.message);
  if (answer.needsAppRestart) toast.warning("Takes effect when AddonSim is started again");
  else if (answer.restarted) toast.success("Saved; the simulator started again");
};

const save = async (change: Parameters<typeof changeSettings>[0]): Promise<void> => {
  reportAnswer(await changeSettings(change));
};

export const FlavourStep = ({ setup }: StepProps) => (
  <div className="grid gap-3">
    {setup.flavours.map((flavour) => {
      const isChosen = flavour.id === setup.settings.flavour;
      return (
        <button
          key={flavour.id}
          type="button"
          aria-pressed={isChosen}
          onClick={() => void save({ flavour: flavour.id })}
          className={`setup-choice flavour-card flex cursor-pointer flex-col gap-1.5 rounded-xl border p-4 text-left ${isChosen ? "is-chosen" : ""}`}
        >
          <span className="flex items-center gap-2">
            <span className="text-gold grow text-lg font-semibold">{flavour.name}</span>
            {isChosen && <CircleCheckFill className="size-5 text-success" />}
          </span>
          <span className="text-[13px] text-muted">{flavour.description}</span>
          <span className="flex gap-1.5">
            <Chip size="sm" variant="soft" className="font-mono">
              client {flavour.clientVersion} · {flavour.clientBuild}
            </Chip>
          </span>
        </button>
      );
    })}
    <p className="text-xs text-muted">Classic and Retail come later; each is one more flavour.</p>
  </div>
);

// (the Addons tab has the same list, folded)
export const AddonsFolderStep = () => <AddonFolders catalog={null} />;

const DownloadBox = ({ setup }: StepProps) => {
  const download = setup.interfaceDownload;
  const flavour = setup.flavours.find((entry) => entry.id === setup.settings.flavour);
  const state = download?.state ?? "idle";
  const isRunning = state === "downloading" || state === "unpacking";
  const isUsingDownload = setup.settings.interfaceRoot === "" && state === "done";
  return (
    <div className="download-box flex flex-col gap-3 rounded-xl border p-4">
      <div className="flex items-start gap-3">
        <ArrowDownToLine className="mt-0.5 size-5 shrink-0 text-accent" />
        <div className="min-w-0 grow">
          <p className="text-[13px] font-medium">Download it</p>
          <p className="text-xs text-muted">
            {flavour ? (
              <>
                From <span className="font-mono">{flavour.interfaceSource.repository}</span>, branch{" "}
                <span className="font-mono">{flavour.interfaceSource.branch}</span> (a few hundred MB, once)
              </>
            ) : (
              "The flavour's interface source"
            )}
          </p>
        </div>
        {state === "done" ? (
          isUsingDownload ? (
            <Chip size="sm" color="success" variant="soft">
              in use
            </Chip>
          ) : (
            <Button size="sm" onPress={() => void save({ interfaceRoot: "" })}>
              Use it
            </Button>
          )
        ) : (
          <Button size="sm" isPending={isRunning} onPress={() => void downloadInterface()}>
            {state === "failed" ? "Try again" : "Download"}
          </Button>
        )}
      </div>
      {isRunning && (
        <ProgressBar
          aria-label="The download"
          size="sm"
          isIndeterminate={!download?.totalBytes || state === "unpacking"}
          value={download?.receivedBytes ?? 0}
          maxValue={download?.totalBytes ?? 1}
        >
          <span className="flex justify-between text-[11px] text-muted">
            <span>{state === "unpacking" ? "Unpacking…" : "Downloading…"}</span>
            <span>
              {formatBytes(download?.receivedBytes ?? 0)}
              {download?.totalBytes ? ` of ${formatBytes(download.totalBytes)}` : ""}
            </span>
          </span>
          <ProgressBar.Track>
            <ProgressBar.Fill />
          </ProgressBar.Track>
        </ProgressBar>
      )}
      {state === "failed" && <p className="text-xs text-danger">{download?.error ?? "The download failed"}</p>}
      {state === "done" && download?.path && <p className="font-mono text-[11px] text-muted">{download.path}</p>}
    </div>
  );
};

export const InterfaceStep = ({ setup }: StepProps) => (
  <div className="flex flex-col gap-4">
    <FolderChoice
      kind="interface"
      label="A checkout of wow-ui-source: its Interface folder"
      value={setup.settings.interfaceRoot}
      detected={setup.detected.interfaceRoots}
      placeholder={getExamplePath(setup, "interface")}
      onSave={(path) => save({ interfaceRoot: path })}
    />
    <div className="flex items-center gap-3 text-xs text-muted">
      <span className="h-px grow bg-separator" />
      or
      <span className="h-px grow bg-separator" />
    </div>
    <DownloadBox setup={setup} />
  </div>
);

export const LuajitStep = ({ setup }: StepProps) => {
  const luajit = setup.detected.luajit;
  return (
    <div className="flex flex-col gap-4">
      {luajit.path ? (
        <div className="flex items-center gap-3 rounded-xl border border-success/30 bg-success-soft px-3 py-2.5">
          <CircleCheckFill className="size-5 shrink-0 text-success" />
          <span className="flex min-w-0 flex-col">
            <span className="text-[13px] font-medium">{luajit.version ?? "LuaJIT"}</span>
            <span className="truncate font-mono text-[11px] text-muted">{luajit.path}</span>
          </span>
        </div>
      ) : (
        <div className="flex flex-col gap-2 rounded-xl border border-warning/30 bg-warning-soft p-3">
          <span className="flex items-center gap-2 text-[13px] font-medium">
            <CircleExclamationFill className="size-4 text-warning" />
            LuaJIT was not found
          </span>
          {luajit.instructions && (
            <pre className="flex gap-2 overflow-x-auto rounded-lg bg-[#0b0d10] p-2.5 font-mono text-[12px] whitespace-pre-wrap">
              <Terminal className="mt-0.5 size-3.5 shrink-0 text-muted" />
              {luajit.instructions}
            </pre>
          )}
        </div>
      )}
      <FolderChoice
        kind="luajit"
        label="Or its executable, if it is elsewhere"
        value={setup.settings.luajitPath}
        detected={[]}
        placeholder={getExamplePath(setup, "luajit")}
        onSave={(path) => save({ luajitPath: path })}
      />
    </div>
  );
};
