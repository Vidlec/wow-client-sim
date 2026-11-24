// Where the addons come from: one list of folders, as many as you like and from anywhere on the disk, each a folder
// of addons (an AddOns folder) or one addon's own folder; the game's AddOns folders found on this computer are offered
// to add. The setup's addons step shows it open; the Addons tab folds it, with each folder's count of addons and the
// served project's own. A folder added or taken away restarts the simulator.
//
// Saved as the settings have it: the first folder as addonsRoot (where the game's WTF folder is looked for, beside
// it), the others as addonFolders. A game's AddOns folder goes first, so an addon in a folder of your own wins over
// the game's copy of it (a later folder over an earlier one).
import { Folder, FolderOpen, Plus, TrashBin } from "@gravity-ui/icons";
import { Button, Disclosure, FieldError, Input, TextField, Tooltip, toast } from "@heroui/react";
import { useState } from "react";
import type { FolderCheck } from "../../../shared/setup.ts";
import { PathText } from "../../components/bits.tsx";
import { FolderBrowser } from "../../components/FolderBrowser.tsx";
import { changeSettings, checkFolder, useSetup } from "../../sim/setup.ts";
import type { CatalogAddon } from "../../sim/types.ts";
import { getExamplePath } from "../setup/examplePaths.ts";

type Props = {
  /** The addons found, for each folder's count; null for none (the setup, before the simulator runs) */
  catalog: readonly CatalogAddon[] | null;
  /** Folded under a heading (the Addons tab); else shown as it is (the setup) */
  isCollapsible?: boolean;
};

const normal = (path: string): string =>
  path
    .replace(/[\\/]+$/, "")
    .replaceAll("\\", "/")
    .toLowerCase();

const isSamePath = (first: string, second: string): boolean => normal(first) === normal(second);

/** A game's AddOns folder (…/Interface/AddOns) */
const isGameAddOns = (path: string): boolean => normal(path).endsWith("/interface/addons");

/** The folders in the order they are read: the game's AddOns folders first, then the others as added */
const composeFolderOrder = (folders: readonly string[]): string[] => [
  ...folders.filter(isGameAddOns),
  ...folders.filter((folder) => !isGameAddOns(folder)),
];

const countIn = (catalog: readonly CatalogAddon[], root: string): number =>
  catalog.filter((entry) => isSamePath(entry.root, root)).length;

const FolderRow = ({ path, note, onRemove }: { path: string; note: string; onRemove: () => void }) => (
  <li className="flex items-start gap-2 py-1.5">
    <Folder className="mt-0.5 size-3.5 shrink-0 text-muted" />
    <span className="flex min-w-0 grow flex-col gap-0.5">
      <PathText path={path} className="text-[12px]" />
      {note && <span className="text-xs text-muted">{note}</span>}
    </span>
    <Tooltip delay={300}>
      <Button size="sm" variant="ghost" isIconOnly aria-label={`Remove ${path}`} onPress={onRemove}>
        <TrashBin />
      </Button>
      <Tooltip.Content>Stop reading addons from this folder (nothing on disk is touched)</Tooltip.Content>
    </Tooltip>
  </li>
);

export const AddonFolders = ({ catalog, isCollapsible = false }: Props) => {
  const { setup } = useSetup();
  const [typed, setTyped] = useState("");
  const [check, setCheck] = useState<FolderCheck | null>(null);
  const [isBrowsing, setBrowsing] = useState(false);
  const [isBusy, setBusy] = useState(false);
  const settings = setup?.settings;
  const folders = [settings?.addonsRoot ?? "", ...(settings?.addonFolders ?? [])].filter(Boolean);
  const suggestions = (setup?.detected.addonsRoots ?? []).filter(
    (found) => !folders.some((folder) => isSamePath(folder, found.path)),
  );
  const projectCount = catalog?.filter((entry) => entry.origin === "project").length ?? 0;

  const saveFolders = async (next: string[], message: string): Promise<void> => {
    const ordered = composeFolderOrder(next);
    setBusy(true);
    try {
      const answer = await changeSettings({ addonsRoot: ordered[0] ?? "", addonFolders: ordered.slice(1) });
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
    if (folders.some((folder) => isSamePath(folder, trimmed))) {
      toast.warning("That folder is in the list already");
      return;
    }
    setBusy(true);
    let result: FolderCheck;
    try {
      result = await checkFolder("addons", trimmed);
    } catch (error) {
      setCheck({ path: trimmed, isValid: false, message: String(error) });
      return;
    } finally {
      setBusy(false);
    }
    setCheck(result.isValid ? null : result);
    if (!result.isValid) return;
    await saveFolders([...folders, result.path], "Folder added");
    setTyped("");
  };
  const remove = (path: string): void =>
    void saveFolders(
      folders.filter((folder) => folder !== path),
      "Folder removed",
    );

  const noteOf = (folder: string): string => {
    const found = catalog ? countIn(catalog, folder) : null;
    const count = found === null ? "" : `${found} ${found === 1 ? "addon" : "addons"}`;
    return [count, isGameAddOns(folder) ? "the game's" : ""].filter(Boolean).join(" · ");
  };

  const body = (
    <div className="flex flex-col gap-3">
      {folders.length > 0 ? (
        <ul className="flex flex-col">
          {folders.map((folder) => (
            <FolderRow key={folder} path={folder} note={noteOf(folder)} onRemove={() => remove(folder)} />
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
      ) : (
        <p className="text-[13px] text-muted">No addon folders yet: the sim runs the game's own interface alone.</p>
      )}
      {suggestions.length > 0 && (
        <div className="flex flex-col gap-1.5">
          <span className="text-xs font-medium text-muted">Found on this computer</span>
          {suggestions.map((found) => (
            <div key={found.path} className="flex items-center gap-3 rounded-xl border border-separator px-3 py-2">
              <Folder className="size-4 shrink-0 text-muted" />
              <span className="flex min-w-0 grow flex-col">
                <span className="truncate font-mono text-[12px]" title={found.path}>
                  {found.path}
                </span>
                <span className="text-xs text-muted">{found.note}</span>
              </span>
              <Button size="sm" variant="secondary" isDisabled={isBusy} onPress={() => void add(found.path)}>
                <Plus />
                Add
              </Button>
            </div>
          ))}
        </div>
      )}
      <TextField
        aria-label="Another folder with addons"
        value={typed}
        onChange={(text) => {
          setTyped(text);
          setCheck(null);
        }}
        isInvalid={check !== null}
      >
        <div className="flex flex-wrap items-center gap-2">
          <Input
            placeholder={getExamplePath(setup, "addonFolder")}
            className="min-w-48 grow basis-48 font-mono text-[12px]"
            onKeyDown={(event) => {
              if (event.key === "Enter") void add(typed);
            }}
          />
          <Button variant="secondary" className="shrink-0" isDisabled={isBusy} onPress={() => setBrowsing(true)}>
            <FolderOpen />
            Browse…
          </Button>
          <Button
            className="shrink-0"
            isDisabled={isBusy || !typed.trim()}
            isPending={isBusy}
            onPress={() => void add(typed)}
          >
            <Plus />
            Add
          </Button>
        </div>
        <FieldError>{check?.message}</FieldError>
      </TextField>
      {check?.suggestion && (
        <div className="flex items-center gap-2 rounded-lg bg-accent-soft px-3 py-2 text-xs">
          <span className="grow">
            Did you mean <span className="font-mono">{check.suggestion}</span>?
          </span>
          <Button size="sm" onPress={() => void add(check.suggestion ?? "")}>
            Add that
          </Button>
        </div>
      )}
      <p className="text-xs leading-relaxed text-muted">
        Add as many as you like, from anywhere: a folder of addons (an AddOns folder), or one addon's own folder. An
        addon in a folder of yours wins over the game's copy of it. Nothing is copied or changed on disk.
      </p>
      <FolderBrowser
        kind="addons"
        isOpen={isBrowsing}
        title="A folder with addons"
        startPath={typed || folders.at(-1) || undefined}
        onClose={() => setBrowsing(false)}
        onChoose={(path) => {
          setTyped(path);
          void add(path);
        }}
      />
    </div>
  );

  if (!isCollapsible) return body;
  return (
    <Disclosure className="rounded-xl border border-separator bg-surface">
      <Disclosure.Heading>
        <Disclosure.Trigger className="flex w-full items-center gap-2 px-3.5 py-3 text-left">
          <FolderOpen className="size-4 shrink-0 text-muted" />
          <span className="grow text-[13px] font-semibold">Addon folders</span>
          <span className="text-xs text-muted">
            {folders.length} {folders.length === 1 ? "folder" : "folders"}
          </span>
          <Disclosure.Indicator />
        </Disclosure.Trigger>
      </Disclosure.Heading>
      <Disclosure.Content>
        <div className="px-3.5 pb-3">{body}</div>
      </Disclosure.Content>
    </Disclosure>
  );
};
