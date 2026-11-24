// Where the addons come from: the game's AddOns folder (set in Settings), further folders added here (each holding
// addon folders, or being one), and the served project's own. A folder added or taken away restarts the simulator.
import { Folder, FolderOpen, Plus, TrashBin } from "@gravity-ui/icons";
import { Button, Disclosure, Input, TextField, Tooltip, toast } from "@heroui/react";
import { useState } from "react";
import { FolderBrowser } from "../../components/FolderBrowser.tsx";
import { changeSettings, useSetup } from "../../sim/setup.ts";
import type { CatalogAddon } from "../../sim/types.ts";

type Props = { catalog: readonly CatalogAddon[] | null };

const normal = (path: string): string =>
  path
    .replace(/[\\/]+$/, "")
    .replaceAll("\\", "/")
    .toLowerCase();

const countIn = (catalog: readonly CatalogAddon[] | null, root: string): number =>
  catalog?.filter((entry) => normal(entry.root) === normal(root)).length ?? 0;

const FolderRow = ({
  path,
  count,
  note,
  onRemove,
}: {
  path: string;
  count: number;
  note?: string;
  onRemove?: () => void;
}) => (
  <li className="flex items-center gap-2 py-1 text-[12px]">
    <Folder className="size-3.5 shrink-0 text-muted" />
    <span className="min-w-0 grow truncate font-mono" title={path}>
      {path}
    </span>
    <span className="shrink-0 text-muted">
      {count} {count === 1 ? "addon" : "addons"}
      {note ? ` · ${note}` : ""}
    </span>
    {onRemove && (
      <Tooltip delay={300}>
        <Button size="sm" variant="ghost" isIconOnly aria-label={`Remove ${path}`} onPress={onRemove}>
          <TrashBin />
        </Button>
        <Tooltip.Content>Stop reading addons from this folder (nothing on disk is touched)</Tooltip.Content>
      </Tooltip>
    )}
  </li>
);

export const AddonFolders = ({ catalog }: Props) => {
  const { setup } = useSetup();
  const [typed, setTyped] = useState("");
  const [isBrowsing, setBrowsing] = useState(false);
  const [isBusy, setBusy] = useState(false);
  const settings = setup?.settings;
  const folders = settings?.addonFolders ?? [];
  const projectCount = catalog?.filter((entry) => entry.origin === "project").length ?? 0;

  const saveFolders = async (next: string[], message: string): Promise<void> => {
    setBusy(true);
    try {
      const answer = await changeSettings({ addonFolders: next });
      for (const error of answer.errors) toast.danger(error.message);
      if (answer.errors.length === 0) toast.success(message, { description: "The simulator starts again with them" });
    } catch (error) {
      toast.danger("Not saved", { description: String(error) });
    } finally {
      setBusy(false);
    }
  };
  const add = async (path: string): Promise<void> => {
    const trimmed = path.trim();
    if (!trimmed) return;
    if (
      folders.some((folder) => normal(folder) === normal(trimmed)) ||
      normal(trimmed) === normal(settings?.addonsRoot ?? "")
    ) {
      toast.warning("That folder is read already");
      return;
    }
    await saveFolders([...folders, trimmed], "Folder added");
    setTyped("");
  };

  return (
    <Disclosure className="rounded-xl border border-separator bg-surface">
      <Disclosure.Heading>
        <Disclosure.Trigger className="flex w-full items-center gap-2 px-3.5 py-3 text-left">
          <FolderOpen className="size-4 shrink-0 text-muted" />
          <span className="grow text-[13px] font-semibold">Addon folders</span>
          <span className="text-xs text-muted">
            {1 + folders.length + (projectCount > 0 ? 1 : 0)}{" "}
            {folders.length === 0 && projectCount === 0 ? "folder" : "folders"}
          </span>
          <Disclosure.Indicator />
        </Disclosure.Trigger>
      </Disclosure.Heading>
      <Disclosure.Content>
        <div className="flex flex-col gap-2 px-3.5 pb-3">
          <ul className="flex flex-col">
            <FolderRow
              path={settings?.addonsRoot || "(no AddOns folder chosen)"}
              count={countIn(catalog, settings?.addonsRoot ?? "")}
              note="the game's, in Settings"
            />
            {folders.map((folder) => (
              <FolderRow
                key={folder}
                path={folder}
                count={countIn(catalog, folder)}
                onRemove={() =>
                  void saveFolders(
                    folders.filter((known) => known !== folder),
                    "Folder removed",
                  )
                }
              />
            ))}
            {projectCount > 0 && (
              <li className="flex items-center gap-2 py-1 text-[12px] text-muted">
                <Folder className="size-3.5 shrink-0" />
                <span className="grow">The project's own</span>
                <span>
                  {projectCount} {projectCount === 1 ? "addon" : "addons"}
                </span>
              </li>
            )}
          </ul>
          <div className="flex items-end gap-2">
            <TextField aria-label="A folder with addons" value={typed} onChange={setTyped} className="grow">
              <Input
                placeholder="C:\Addons, or one addon's folder"
                className="font-mono text-[12px]"
                onKeyDown={(event) => {
                  if (event.key === "Enter") void add(typed);
                }}
              />
            </TextField>
            <Button size="sm" variant="secondary" isDisabled={isBusy} onPress={() => setBrowsing(true)}>
              <FolderOpen />
              Browse
            </Button>
            <Button size="sm" isDisabled={isBusy || !typed.trim()} isPending={isBusy} onPress={() => void add(typed)}>
              <Plus />
              Add
            </Button>
          </div>
          <p className="text-xs leading-relaxed text-muted">
            Addons in a folder added here are listed beside your AddOns folder's, and win over one of the same name
            there (a later folder over an earlier). Nothing is copied into the game.
          </p>
        </div>
        <FolderBrowser
          kind="addons"
          isOpen={isBrowsing}
          title="A folder of addons"
          startPath={typed || settings?.addonsRoot || undefined}
          onClose={() => setBrowsing(false)}
          onChoose={(path) => void add(path)}
        />
      </Disclosure.Content>
    </Disclosure>
  );
};
