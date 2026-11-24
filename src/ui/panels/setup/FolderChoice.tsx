// A folder a setting points at (your AddOns folder, the interface source, LuaJIT): the ones found on this computer to
// pick from, or a path typed (checked before it is saved, with a better one nearby offered) or chosen in the page's
// folder browser
import { CircleCheckFill, Folder, FolderOpen, MagnifierPlus } from "@gravity-ui/icons";
import { Button, Description, FieldError, Input, Label, Spinner, TextField, toast } from "@heroui/react";
import { useEffect, useState } from "react";
import type { FolderKind } from "../../../shared/setup.ts";
import { FolderBrowser } from "../../components/FolderBrowser.tsx";
import type { DetectedFolder } from "../../sim/setup.ts";
import { checkFolder } from "../../sim/setup.ts";

type Props = {
  kind: FolderKind;
  label: string;
  /** The path saved now ("" for none) */
  value: string;
  detected: readonly DetectedFolder[];
  placeholder: string;
  onSave: (path: string) => Promise<void>;
};

const samePath = (first: string, second: string): boolean =>
  first.replace(/[\\/]+$/, "").toLowerCase() === second.replace(/[\\/]+$/, "").toLowerCase();

export const FolderChoice = ({ kind, label, value, detected, placeholder, onSave }: Props) => {
  const [typed, setTyped] = useState(value);
  const [check, setCheck] = useState<{ isValid: boolean; message: string; suggestion?: string } | null>(null);
  const [isBusy, setBusy] = useState(false);
  const [isBrowsing, setBrowsing] = useState(false);
  useEffect(() => setTyped(value), [value]);

  const save = async (path: string): Promise<void> => {
    setBusy(true);
    try {
      await onSave(path);
    } catch (error) {
      toast.danger("Not saved", { description: String(error) });
    } finally {
      setBusy(false);
    }
  };
  const runCheck = async (path: string): Promise<void> => {
    if (!path.trim()) return;
    setBusy(true);
    try {
      const result = await checkFolder(kind, path.trim());
      setCheck(result);
      if (result.isValid) await onSave(result.path);
    } catch (error) {
      setCheck({ isValid: false, message: String(error) });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex flex-col gap-3">
      <FolderBrowser
        kind={kind}
        isOpen={isBrowsing}
        title={label}
        startPath={typed || value || undefined}
        onClose={() => setBrowsing(false)}
        onChoose={(path) => {
          setTyped(path);
          void runCheck(path);
        }}
      />
      {detected.length > 0 && (
        <div className="flex flex-col gap-1.5">
          <span className="text-xs font-medium text-muted">Found on this computer</span>
          {detected.map((folder) => {
            const isChosen = samePath(folder.path, value);
            return (
              <button
                key={folder.path}
                type="button"
                aria-pressed={isChosen}
                disabled={isBusy}
                onClick={() => void save(folder.path)}
                className={`setup-choice flex cursor-pointer items-center gap-3 rounded-xl border px-3 py-2.5 text-left ${isChosen ? "is-chosen" : ""}`}
              >
                {isChosen ? (
                  <CircleCheckFill className="size-5 shrink-0 text-success" />
                ) : (
                  <Folder className="size-5 shrink-0 text-muted" />
                )}
                <span className="flex min-w-0 flex-col">
                  <span className="truncate font-mono text-[12px]">{folder.path}</span>
                  <span className="text-xs text-muted">{folder.note}</span>
                </span>
              </button>
            );
          })}
        </div>
      )}
      <TextField
        value={typed}
        onChange={(text) => {
          setTyped(text);
          setCheck(null);
        }}
        isInvalid={check !== null && !check.isValid}
      >
        <Label>{label}</Label>
        <div className="flex gap-2">
          <Input
            placeholder={placeholder}
            className="grow font-mono text-[12px]"
            onKeyDown={(event) => event.key === "Enter" && void runCheck(typed)}
          />
          <Button variant="secondary" isDisabled={!typed.trim() || isBusy} onPress={() => void runCheck(typed)}>
            {isBusy ? <Spinner size="sm" /> : <MagnifierPlus />}
            Check
          </Button>
          <Button variant="tertiary" isDisabled={isBusy} onPress={() => setBrowsing(true)}>
            <FolderOpen />
            Browse…
          </Button>
        </div>
        {check?.isValid && <Description className="text-success">{check.message}</Description>}
        <FieldError>{check?.message}</FieldError>
      </TextField>
      {check?.suggestion && (
        <div className="flex items-center gap-2 rounded-lg bg-accent-soft px-3 py-2 text-xs">
          <span className="grow">
            Did you mean <span className="font-mono">{check.suggestion}</span>?
          </span>
          <Button
            size="sm"
            onPress={() => {
              const suggestion = check.suggestion ?? "";
              setTyped(suggestion);
              void runCheck(suggestion);
            }}
          >
            Use it
          </Button>
        </div>
      )}
    </div>
  );
};
