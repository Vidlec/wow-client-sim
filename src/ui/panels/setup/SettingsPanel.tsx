// The Settings panel: what the first setup chose (the flavour, the folders, LuaJIT), each in a fold, and how the
// simulator runs (the whole interface or the light one, the strict API, the language, Edit Mode's preset, the clock);
// the game's art and tables in the cache, with the last start part by part; where AddonSim keeps things; and every
// setting back to its default (asks first)
import { ArrowRotateLeft, ArrowUpFromLine, Cpu, FolderOpen, Gear, Picture, Tag } from "@gravity-ui/icons";
import {
  Accordion,
  AlertDialog,
  Button,
  Chip,
  Label,
  ListBox,
  NumberField,
  Select,
  Skeleton,
  ToggleButton,
  ToggleButtonGroup,
  toast,
} from "@heroui/react";
import { useEffect, useState } from "react";
import { Facts, PathText, SwitchRow } from "../../components/bits.tsx";
import { formatBytes } from "../../components/format.ts";
import { Section } from "../../components/Section.tsx";
import {
  type ArtInfo,
  type ClientBuilds,
  changeSettings,
  downloadInterface,
  type ResetChoice,
  readArtInfo,
  readClientBuilds,
  resetSetup,
  type Settings,
  type SetupState,
  useSetup,
} from "../../sim/setup.ts";
import { AddonsFolderStep, FlavourStep, InterfaceStep, LuajitStep } from "./SetupSteps.tsx";
import { StartSteps } from "./StartSteps.tsx";

const LOCALES = ["enUS", "deDE", "frFR", "esES", "esMX", "itIT", "ptBR", "ruRU", "koKR", "zhCN", "zhTW"] as const;
const LAYOUTS: readonly { id: Settings["editModeLayout"]; name: string }[] = [
  { id: "modern", name: "Modern" },
  { id: "classic", name: "Classic" },
  { id: "gamepad", name: "Gamepad" },
];

const save = async (change: Partial<Settings>): Promise<void> => {
  try {
    const answer = await changeSettings(change);
    for (const error of answer.errors) toast.danger(error.message);
    if (answer.needsAppRestart) toast.warning("Takes effect when AddonSim is started again");
    else if (answer.restarted) toast.success("Saved; the simulator started again");
    else if (answer.saved) toast.success("Saved");
  } catch (error) {
    toast.danger("Not saved", { description: String(error) });
  }
};

const SetupFolds = ({ setup }: { setup: SetupState }) => {
  const flavour = setup.flavours.find((entry) => entry.id === setup.settings.flavour);
  const parts = [
    {
      id: "flavour",
      title: "The game",
      summary: flavour?.name ?? setup.settings.flavour,
      body: <FlavourStep setup={setup} />,
    },
    {
      id: "addons",
      title: "Your addon folders",
      summary: ((count) => (count === 0 ? "none" : `${count} ${count === 1 ? "folder" : "folders"}`))(
        [setup.settings.addonsRoot, ...setup.settings.addonFolders].filter(Boolean).length,
      ),
      body: <AddonsFolderStep />,
    },
    {
      id: "interface",
      title: "The interface source",
      summary:
        setup.settings.interfaceRoot ||
        (setup.problems.some((problem) => problem.key === "interface") ? "not chosen" : "downloaded"),
      body: <InterfaceStep setup={setup} />,
    },
    {
      id: "luajit",
      title: "LuaJIT",
      summary: setup.detected.luajit.version ?? setup.detected.luajit.path ?? "not found",
      body: <LuajitStep setup={setup} />,
    },
  ];
  return (
    <Accordion variant="surface" className="settings-folds">
      {parts.map((part) => (
        <Accordion.Item key={part.id} id={part.id}>
          <Accordion.Heading>
            <Accordion.Trigger>
              <span className="flex min-w-0 grow flex-col text-left">
                <span className="text-[13px] font-medium">{part.title}</span>
                <span className="truncate font-mono text-[11px] text-muted">{part.summary}</span>
              </span>
              <Accordion.Indicator />
            </Accordion.Trigger>
          </Accordion.Heading>
          <Accordion.Panel>
            <Accordion.Body>{part.body}</Accordion.Body>
          </Accordion.Panel>
        </Accordion.Item>
      ))}
    </Accordion>
  );
};

const SimulatorOptions = ({ settings }: { settings: Settings }) => (
  <Section title="The simulator" icon={<Cpu className="size-3.5" />}>
    <div className="flex flex-col gap-1.5">
      <span className="text-sm font-medium">The game's interface</span>
      <ToggleButtonGroup
        aria-label="The game's interface"
        selectionMode="single"
        disallowEmptySelection
        size="sm"
        fullWidth
        selectedKeys={[settings.blizzardAddons]}
        onSelectionChange={(keys) => void save({ blizzardAddons: keys.has("light") ? "light" : "all" })}
      >
        <ToggleButton id="all">The whole of it</ToggleButton>
        <ToggleButton id="light">
          <ToggleButtonGroup.Separator />A light stand-in
        </ToggleButton>
      </ToggleButtonGroup>
      <span className="text-xs text-muted">
        The whole: Blizzard's addons load as the client loads them. The light one starts faster, less faithful.
      </span>
    </div>
    <SwitchRow
      label="Strict API"
      description="Only the client's own functions exist, as in the game"
      isSelected={settings.strictApi}
      onChange={(isOn) => void save({ strictApi: isOn })}
    />
    <SwitchRow
      label="Reload on save"
      description="The addons reload whenever one of their files is saved"
      isSelected={settings.autoReload}
      onChange={(isOn) => void save({ autoReload: isOn })}
    />
    <div className="grid grid-cols-2 gap-3">
      <Select value={settings.locale} onChange={(value) => void save({ locale: String(value) })}>
        <Label>Language</Label>
        <Select.Trigger>
          <Select.Value />
          <Select.Indicator />
        </Select.Trigger>
        <Select.Popover>
          <ListBox>
            {LOCALES.map((locale) => (
              <ListBox.Item key={locale} id={locale} textValue={locale}>
                {locale}
                <ListBox.ItemIndicator />
              </ListBox.Item>
            ))}
          </ListBox>
        </Select.Popover>
      </Select>
      <Select
        value={settings.editModeLayout}
        onChange={(value) => void save({ editModeLayout: String(value) as Settings["editModeLayout"] })}
      >
        <Label>Edit Mode preset</Label>
        <Select.Trigger>
          <Select.Value />
          <Select.Indicator />
        </Select.Trigger>
        <Select.Popover>
          <ListBox>
            {LAYOUTS.map((layout) => (
              <ListBox.Item key={layout.id} id={layout.id} textValue={layout.name}>
                {layout.name}
                <ListBox.ItemIndicator />
              </ListBox.Item>
            ))}
          </ListBox>
        </Select.Popover>
      </Select>
      <NumberField
        minValue={10}
        maxValue={240}
        value={settings.fps}
        onChange={(value) => Number.isFinite(value) && value !== settings.fps && void save({ fps: value })}
      >
        <Label>Game clock (fps)</Label>
        <NumberField.Group>
          <NumberField.DecrementButton />
          <NumberField.Input />
          <NumberField.IncrementButton />
        </NumberField.Group>
      </NumberField>
      <div className="flex flex-col gap-1.5">
        <span className="text-sm font-medium">Achievement set</span>
        <ToggleButtonGroup
          aria-label="Achievement set"
          selectionMode="single"
          disallowEmptySelection
          size="sm"
          fullWidth
          selectedKeys={[settings.achievementSet]}
          onSelectionChange={(keys) => void save({ achievementSet: keys.has("b") ? "b" : "a" })}
        >
          <ToggleButton id="a">A</ToggleButton>
          <ToggleButton id="b">
            <ToggleButtonGroup.Separator />B
          </ToggleButton>
        </ToggleButtonGroup>
      </div>
    </div>
  </Section>
);

const describeFiles = ({ count, bytes }: { count: number; bytes: number }, noun: string): string =>
  count === 0 ? "none yet" : `${count.toLocaleString("en-US")} ${noun} · ${formatBytes(bytes)}`;

/** "1.60.1.71091" after "1.60.1.71037": by each number in turn (src/server/clientBuilds.ts has the same) */
const compareBuilds = (first: string, second: string): number => {
  const a = first.split(".").map(Number);
  const b = second.split(".").map(Number);
  for (let index = 0; index < Math.max(a.length, b.length); index++) {
    const difference = (a[index] ?? 0) - (b[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
};

/**
 * The client's build: the one in use, the newest Blizzard's servers run, and those wago.tools has (the game's
 * tables come from it, so only those can be used); a newer one taken with one button, the downloaded interface source
 * fetched again with it so the two match
 */
const ClientBuild = ({ setup }: { setup: SetupState }) => {
  const [builds, setBuilds] = useState<ClientBuilds | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [isSwitching, setSwitching] = useState(false);
  const current = setup.settings.build || null;
  // biome-ignore lint/correctness/useExhaustiveDependencies: read again when the build in use changes
  useEffect(() => {
    let isCurrent = true;
    readClientBuilds()
      .then((answer) => isCurrent && setBuilds(answer))
      .catch((error: unknown) => isCurrent && setProblem(String(error)));
    return () => {
      isCurrent = false;
    };
  }, [current, setup.interfaceDownload?.state]);
  if (problem) return <p className="text-xs text-danger">The builds were not read: {problem}</p>;
  if (!builds) return <Skeleton className="h-24 rounded-lg" />;

  const newestUsable = builds.wago[0] ?? null;
  const newestAnywhere = [...builds.blizzard.map((entry) => entry.build), ...builds.wago].sort((a, b) =>
    compareBuilds(b, a),
  )[0];
  const regionsAt = (build: string): string =>
    builds.blizzard
      .filter((entry) => entry.build === build)
      .map((entry) => entry.region.toUpperCase())
      .join(", ");
  const isDownloadedInterface = setup.settings.interfaceRoot === "";
  const canUpdate = newestUsable !== null && compareBuilds(newestUsable, builds.current) > 0;
  const isInterfaceBehind =
    builds.interfaceInUse !== null && compareBuilds(builds.interfaceInUse, builds.current) !== 0;

  /** The build taken (the flavour's own as "": it follows the flavour), the downloaded interface source with it */
  const switchToBuild = async (build: string): Promise<void> => {
    setSwitching(true);
    try {
      await save({ build: build === builds.flavourBuild ? "" : build });
      if (isDownloadedInterface && builds.interfaceLatest && builds.interfaceInUse !== builds.interfaceLatest) {
        await downloadInterface();
        toast.success(`Using ${build}; the interface source is downloading again`);
      }
    } finally {
      setSwitching(false);
    }
  };

  return (
    <div className="flex flex-col gap-3">
      <Facts
        rows={[
          ["In use", `${builds.current}${builds.current === builds.flavourBuild ? " (the flavour's own)" : ""}`],
          [
            "Newest",
            newestAnywhere
              ? `${newestAnywhere}${regionsAt(newestAnywhere) ? ` · Blizzard ${regionsAt(newestAnywhere)}` : ""}${
                  builds.wago.includes(newestAnywhere) ? " · on wago.tools" : " · not on wago.tools yet"
                }`
              : "not known",
          ],
          [
            "Interface source",
            builds.interfaceInUse
              ? `${builds.interfaceInUse}${builds.interfaceLatest && builds.interfaceLatest !== builds.interfaceInUse ? ` · ${builds.interfaceLatest} on GitHub` : ""}`
              : "its build is not known",
          ],
        ]}
      />
      {isInterfaceBehind && (
        <p className="text-xs text-warning">
          The interface source is at {builds.interfaceInUse}, the client at {builds.current}:{" "}
          {isDownloadedInterface ? "download it again (The setup, The interface source)" : "update your checkout"}.
        </p>
      )}
      {builds.problems.map((text) => (
        <p key={text} className="text-xs text-muted">
          Not asked: {text}
        </p>
      ))}
      <div className="flex flex-wrap items-end gap-2">
        {canUpdate && newestUsable && (
          <Button size="sm" isPending={isSwitching} onPress={() => void switchToBuild(newestUsable)}>
            <ArrowUpFromLine />
            Update to {newestUsable}
          </Button>
        )}
        <Select
          className="min-w-48 grow"
          value={builds.current}
          isDisabled={isSwitching}
          onChange={(value) => value && String(value) !== builds.current && void switchToBuild(String(value))}
        >
          <Label>Build</Label>
          <Select.Trigger>
            <Select.Value />
            <Select.Indicator />
          </Select.Trigger>
          <Select.Popover>
            <ListBox>
              {[...new Set([builds.current, ...builds.wago])]
                .sort((a, b) => compareBuilds(b, a))
                .map((build) => (
                  <ListBox.Item key={build} id={build} textValue={build}>
                    {build}
                    {build === builds.flavourBuild ? " (the flavour's own)" : ""}
                    <ListBox.ItemIndicator />
                  </ListBox.Item>
                ))}
            </ListBox>
          </Select.Popover>
        </Select>
      </div>
      <p className="text-xs text-muted">
        A build's art and tables are fetched the first time it is used, and kept beside the others.
      </p>
    </div>
  );
};

/** The game's art and tables as the cache holds them, read when the panel opens and after each start */
const GameArt = ({ setup }: { setup: SetupState }) => {
  const [art, setArt] = useState<ArtInfo | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const startedAt = setup.start?.startedAt;
  const simulatorState = setup.simulator.state;
  // biome-ignore lint/correctness/useExhaustiveDependencies: read again when a start begins or ends
  useEffect(() => {
    let isCurrent = true;
    readArtInfo()
      .then((info) => isCurrent && setArt(info))
      .catch((error: unknown) => isCurrent && setProblem(String(error)));
    return () => {
      isCurrent = false;
    };
  }, [startedAt, simulatorState]);
  const listfile = art?.listfile;
  return (
    <Section
      title="The game's art"
      icon={<Picture className="size-3.5" />}
      actions={
        art && (
          <Chip size="sm" variant="soft">
            {formatBytes(art.totalBytes)}
          </Chip>
        )
      }
    >
      <p className="text-xs text-muted">
        The game's files (textures, fonts, sounds, maps) come straight from Blizzard's CDN: a build's indexes (about 250
        MB) are fetched once, then each file the first time it is needed. Its tables come from wago.tools, once a build.
      </p>
      {problem && <p className="text-xs text-danger">Not read: {problem}</p>}
      {!art && !problem && <Skeleton className="h-28 rounded-lg" />}
      {art && (
        <Facts
          rows={[
            ["Build", `${art.build} · ${art.locale}`],
            [
              "File list",
              listfile?.isReady
                ? `${(listfile.rows ?? 0).toLocaleString("en-US")} paths${listfile.builtAt ? ` · ${listfile.builtAt.replace("T", " ").slice(0, 16)}` : ""}`
                : (listfile?.error ?? "not built yet"),
            ],
            ["Tables (DB2)", describeFiles(art.tables, "tables")],
            ["Game files", describeFiles(art.files, "files")],
            ["Pictures made", describeFiles(art.pictures, "pictures")],
            [
              "API data",
              art.wowless.product
                ? `wowless ${art.wowless.product}: ${art.wowless.isFetched ? "fetched" : "not fetched"}`
                : "none for this game",
            ],
            ["Blizzard's indexes", art.blizzardIndexes.count === 0 ? "none" : formatBytes(art.blizzardIndexes.bytes)],
          ]}
        />
      )}
      {setup.start && (
        <div className="flex flex-col gap-2">
          <span className="text-[13px] font-medium">The last start</span>
          <StartSteps start={setup.start} />
        </div>
      )}
    </Section>
  );
};

/** Back to a fresh setup, deleting what the user chose; asks first, says what went and what could not */
const ResetDialog = ({ isOpen, onOpenChange }: { isOpen: boolean; onOpenChange: (isOpen: boolean) => void }) => {
  const [choice, setChoice] = useState<ResetChoice>({ interface: true, cache: false, saved: false });
  const [isBusy, setBusy] = useState(false);
  const reset = async (): Promise<void> => {
    setBusy(true);
    try {
      const answer = await resetSetup(choice);
      const what = ["the settings", ...answer.deleted].join(", ");
      if (answer.failures.length > 0) {
        toast.warning("Reset, but some files are in use", {
          description: `${answer.failures.slice(0, 3).join("; ")}${answer.failures.length > 3 ? "…" : ""}`,
        });
      } else toast.success(`Reset: ${what}`);
      onOpenChange(false);
    } catch (error) {
      toast.danger("Not reset", { description: String(error) });
    } finally {
      setBusy(false);
    }
  };
  return (
    <AlertDialog.Backdrop isOpen={isOpen} onOpenChange={onOpenChange}>
      <AlertDialog.Container>
        <AlertDialog.Dialog className="sm:max-w-[460px]">
          <AlertDialog.Header>
            <AlertDialog.Icon status="danger" />
            <AlertDialog.Heading>Start over?</AlertDialog.Heading>
          </AlertDialog.Header>
          <AlertDialog.Body className="flex flex-col gap-3">
            <p className="text-sm text-muted">
              Every setting goes back to its default and the first-run setup comes back. Also delete:
            </p>
            <SwitchRow
              label="The downloaded interface source"
              description="Downloaded again in the setup (a few hundred MB). A checkout of your own is never touched."
              isSelected={choice.interface}
              onChange={(isOn) => setChoice({ ...choice, interface: isOn })}
            />
            <SwitchRow
              label="The game's art and tables"
              description="The whole cache: fetched again at the next start (the files from Blizzard's CDN, the tables from wago.tools)."
              isSelected={choice.cache}
              onChange={(isOn) => setChoice({ ...choice, cache: isOn })}
            />
            <SwitchRow
              label="The simulator's saved variables"
              description="Your addons' saved variables in the simulator, and its own state. The game's WTF folder is never touched."
              isSelected={choice.saved}
              onChange={(isOn) => setChoice({ ...choice, saved: isOn })}
            />
            <p className="text-xs text-muted">
              Your addons' own files are never deleted. Deleted data cannot be brought back.
            </p>
          </AlertDialog.Body>
          <AlertDialog.Footer>
            <Button slot="close" variant="tertiary" isDisabled={isBusy}>
              Keep everything
            </Button>
            <Button variant="danger" isPending={isBusy} onPress={() => void reset()}>
              Start over
            </Button>
          </AlertDialog.Footer>
        </AlertDialog.Dialog>
      </AlertDialog.Container>
    </AlertDialog.Backdrop>
  );
};

const AppOptions = ({ setup }: { setup: SetupState }) => {
  const [isResetting, setResetting] = useState(false);
  const { settings, paths } = setup;
  return (
    <Section
      title="AddonSim"
      icon={<FolderOpen className="size-3.5" />}
      actions={
        <Chip size="sm" variant="soft">
          v{setup.version}
        </Chip>
      }
    >
      <div className="grid grid-cols-[8rem_1fr] items-end gap-3">
        <NumberField
          minValue={1024}
          maxValue={65535}
          value={settings.port}
          formatOptions={{ useGrouping: false }}
          onChange={(value) => Number.isFinite(value) && value !== settings.port && void save({ port: value })}
        >
          <Label>Port</Label>
          <NumberField.Group>
            <NumberField.Input />
          </NumberField.Group>
        </NumberField>
        <SwitchRow
          label="Open the browser at start"
          isSelected={settings.openBrowser}
          onChange={(isOn) => void save({ openBrowser: isOn })}
        />
      </div>
      <Facts
        rows={[
          ["Settings", <PathText key="settings" path={paths.settingsFile} />],
          ["Saved variables", <PathText key="saved" path={paths.savedDir} />],
          ["Cache", <PathText key="cache" path={paths.cacheDir} />],
        ]}
      />
      <Button size="sm" variant="danger-soft" onPress={() => setResetting(true)}>
        <ArrowRotateLeft />
        Start over…
      </Button>
      <ResetDialog isOpen={isResetting} onOpenChange={setResetting} />
    </Section>
  );
};

export const SettingsPanel = () => {
  const { setup, error } = useSetup();
  if (!setup)
    return error ? (
      <p className="text-sm text-danger">The settings did not come: {error}</p>
    ) : (
      <div className="flex flex-col gap-2">
        <Skeleton className="h-24 rounded-xl" />
        <Skeleton className="h-48 rounded-xl" />
      </div>
    );
  return (
    <>
      {setup.problems.length > 0 && (
        <div className="rounded-xl border border-warning/30 bg-warning-soft p-3 text-xs">
          {setup.problems.map((problem) => (
            <p key={problem.message}>{problem.message}</p>
          ))}
        </div>
      )}
      <Section title="The setup" icon={<Gear className="size-3.5" />}>
        <SetupFolds setup={setup} />
      </Section>
      <SimulatorOptions settings={setup.settings} />
      <Section title="The client build" icon={<Tag className="size-3.5" />}>
        <ClientBuild setup={setup} />
      </Section>
      <GameArt setup={setup} />
      <AppOptions setup={setup} />
    </>
  );
};
