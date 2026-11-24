// The Settings panel: what the first setup chose (the flavour, the folders, LuaJIT), each in a fold, and how the
// simulator runs (the whole interface or the light one, the strict API, the language, Edit Mode's preset, the clock);
// where AddonSim keeps things; and every setting back to its default (asks first)
import { ArrowRotateLeft, Cpu, FolderOpen, Gear } from "@gravity-ui/icons";
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
import { useState } from "react";
import { Facts, SwitchRow } from "../../components/bits.tsx";
import { Section } from "../../components/Section.tsx";
import { changeSettings, type Settings, type SetupState, useSetup } from "../../sim/setup.ts";
import { AddonsFolderStep, FlavourStep, InterfaceStep, LuajitStep } from "./SetupSteps.tsx";

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
      title: "Your AddOns folder",
      summary: setup.settings.addonsRoot || "not chosen",
      body: <AddonsFolderStep setup={setup} />,
    },
    {
      id: "interface",
      title: "The interface source",
      summary:
        setup.settings.interfaceRoot || (setup.interfaceDownload?.state === "done" ? "downloaded" : "not chosen"),
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

const AppOptions = ({ setup }: { setup: SetupState }) => {
  const [isResetting, setResetting] = useState(false);
  const { settings, defaults, paths } = setup;
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
          [
            "Settings",
            <span key="settings" className="font-mono text-[11px] break-all">
              {paths.settingsFile}
            </span>,
          ],
          [
            "Saved variables",
            <span key="saved" className="font-mono text-[11px] break-all">
              {paths.savedDir}
            </span>,
          ],
          [
            "Cache",
            <span key="cache" className="font-mono text-[11px] break-all">
              {paths.cacheDir}
            </span>,
          ],
        ]}
      />
      <Button size="sm" variant="danger-soft" onPress={() => setResetting(true)}>
        <ArrowRotateLeft />
        Every setting back to its default
      </Button>
      <AlertDialog.Backdrop isOpen={isResetting} onOpenChange={setResetting}>
        <AlertDialog.Container>
          <AlertDialog.Dialog className="sm:max-w-[420px]">
            <AlertDialog.Header>
              <AlertDialog.Icon status="danger" />
              <AlertDialog.Heading>Back to the defaults?</AlertDialog.Heading>
            </AlertDialog.Header>
            <AlertDialog.Body>
              <p className="text-sm text-muted">
                Every setting as a fresh setup has it: the folders are forgotten and the first-run setup comes back.
                Your addons and their saved variables are not touched.
              </p>
            </AlertDialog.Body>
            <AlertDialog.Footer>
              <Button slot="close" variant="tertiary">
                Keep them
              </Button>
              <Button slot="close" variant="danger" onPress={() => void save(defaults)}>
                Reset
              </Button>
            </AlertDialog.Footer>
          </AlertDialog.Dialog>
        </AlertDialog.Container>
      </AlertDialog.Backdrop>
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
      <AppOptions setup={setup} />
    </>
  );
};
