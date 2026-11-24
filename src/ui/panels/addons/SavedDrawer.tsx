// An addon's saved variables (saved/<Addon>.lua, written at each reload), in a drawer from the right: read again on
// demand, copied, or reset (the file deleted and the game reloaded, as if the addon had never run; asks first)
import { ArrowRotateRight, Database, TrashBin } from "@gravity-ui/icons";
import { AlertDialog, Button, Chip, Drawer, ScrollShadow, Skeleton, toast } from "@heroui/react";
import { useCallback, useEffect, useRef, useState } from "react";
import { CopyButton, EmptyState } from "../../components/bits.tsx";
import { formatBytes } from "../../components/format.ts";
import { requestWholeScene } from "../../shell/screen.ts";
import { api } from "../../sim/api.ts";
import { useTask } from "../../sim/hooks.ts";
import type { CatalogAddon, SavedFile } from "../../sim/types.ts";

type Props = { addon: CatalogAddon | null; onClose: () => void; onReset: () => void };

export const SavedDrawer = ({ addon, onClose, onReset }: Props) => {
  const [file, setFile] = useState<SavedFile | null>(null);
  const [isConfirming, setConfirming] = useState(false);
  const name = addon?.name ?? null;
  const nameRef = useRef(name);
  nameRef.current = name;

  // (an answer for an addon no longer shown is dropped: switching quickly must not show the one before)
  const read = useCallback(async (): Promise<void> => {
    if (!name) return;
    setFile(null);
    try {
      const answer = await api.saved(name);
      if (nameRef.current === name) setFile(answer);
    } catch (error) {
      if (nameRef.current !== name) return;
      setFile({ addon: name, text: null });
      toast.danger(`Could not read ${name}'s saved variables`, { description: String(error) });
    }
  }, [name]);
  useEffect(() => {
    void read();
  }, [read]);

  const reset = useTask(async () => {
    if (!name) return null;
    const answer = await api.savedReset(name);
    requestWholeScene();
    toast.success(`${name} starts afresh`, { description: "Its saved variables are gone; the game reloaded" });
    onReset();
    await read();
    return answer;
  });

  const lines = file?.text ? file.text.split("\n").length : 0;

  return (
    <>
      <Drawer.Backdrop isOpen={addon !== null} onOpenChange={(open) => !open && onClose()}>
        <Drawer.Content placement="right">
          <Drawer.Dialog className="flex h-full w-[min(640px,92vw)] max-w-none flex-col">
            <Drawer.CloseTrigger />
            <Drawer.Header className="flex flex-col gap-1">
              <Drawer.Heading className="flex items-center gap-2">
                <Database className="size-4 text-accent" />
                {addon?.title ?? name}: saved variables
              </Drawer.Heading>
              <div className="flex flex-wrap items-center gap-1.5">
                {addon?.savedVariables.map((variable) => (
                  <Chip key={variable} size="sm" variant="soft" className="font-mono">
                    {variable}
                  </Chip>
                ))}
                {file?.text !== null && file?.bytes !== undefined && (
                  <span className="text-xs text-muted">
                    {formatBytes(file.bytes)} · {lines.toLocaleString()} lines
                  </span>
                )}
              </div>
            </Drawer.Header>
            <Drawer.Body className="flex min-h-0 flex-1 flex-col gap-3">
              {!file ? (
                <div className="flex flex-col gap-2">
                  <Skeleton className="h-3 w-3/5 rounded" />
                  <Skeleton className="h-3 w-4/5 rounded" />
                  <Skeleton className="h-3 w-2/5 rounded" />
                </div>
              ) : file.text === null ? (
                <EmptyState icon={<Database />}>Nothing saved yet: the file is written at the next reload.</EmptyState>
              ) : (
                <ScrollShadow
                  className="min-h-0 flex-1 rounded-lg border border-border bg-[#0b0d10]"
                  hideScrollBar={false}
                >
                  <pre className="p-3 font-mono text-[12px] leading-relaxed whitespace-pre text-[#c9d1d9]">
                    {file.text}
                  </pre>
                </ScrollShadow>
              )}
            </Drawer.Body>
            <Drawer.Footer className="flex gap-2">
              <Button size="sm" variant="danger-soft" isPending={reset.isPending} onPress={() => setConfirming(true)}>
                <TrashBin />
                Reset
              </Button>
              <span className="grow" />
              {file?.text && <CopyButton text={file.text} label="Copy the file" />}
              <Button size="sm" variant="tertiary" onPress={() => void read()}>
                <ArrowRotateRight />
                Read again
              </Button>
            </Drawer.Footer>
          </Drawer.Dialog>
        </Drawer.Content>
      </Drawer.Backdrop>
      <AlertDialog.Backdrop isOpen={isConfirming} onOpenChange={setConfirming}>
        <AlertDialog.Container>
          <AlertDialog.Dialog className="sm:max-w-[420px]">
            <AlertDialog.Header>
              <AlertDialog.Icon status="danger" />
              <AlertDialog.Heading>Reset {name}'s saved variables?</AlertDialog.Heading>
            </AlertDialog.Header>
            <AlertDialog.Body>
              <p className="text-sm text-muted">
                The file is deleted and the game reloads: the addon starts as if it had never run. Its settings are gone
                for good.
              </p>
            </AlertDialog.Body>
            <AlertDialog.Footer>
              <Button slot="close" variant="tertiary">
                Keep them
              </Button>
              <Button slot="close" variant="danger" onPress={() => void reset.run()}>
                Reset
              </Button>
            </AlertDialog.Footer>
          </AlertDialog.Dialog>
        </AlertDialog.Container>
      </AlertDialog.Backdrop>
    </>
  );
};
