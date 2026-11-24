// A folder chosen in the page itself, browsing the folders the server sees (src/server/setup/browse.ts): the same on
// any system, and in a container, where the host's folders are those mounted into it. The folder looked into is
// checked for what is looked for (its addons, its interface source), and chosen with one press.
import { ArrowUp, CircleCheckFill, File, Folder, HardDrive } from "@gravity-ui/icons";
import { Button, Chip, Modal, ScrollShadow, Spinner } from "@heroui/react";
import { useCallback, useEffect, useRef, useState } from "react";
import type { FolderKind, FolderListing } from "../../shared/setup.ts";
import { listFolder } from "../sim/setup.ts";

type Props = {
  kind: FolderKind;
  isOpen: boolean;
  title: string;
  /** Where to start: the path typed or saved; none (or empty) for where browsing starts */
  startPath?: string | undefined;
  onClose: () => void;
  onChoose: (path: string) => void;
};

export const FolderBrowser = ({ kind, isOpen, title, startPath, onClose, onChoose }: Props) => {
  const [listing, setListing] = useState<FolderListing | null>(null);
  const [isLoading, setLoading] = useState(false);
  const asked = useRef(0);

  // (only the last folder asked for is shown: a quick double click must not show the one before)
  const open = useCallback(
    async (path?: string): Promise<void> => {
      asked.current += 1;
      const ticket = asked.current;
      setLoading(true);
      try {
        const answer = await listFolder(kind, path);
        if (ticket === asked.current) setListing(answer);
      } catch (error) {
        if (ticket === asked.current) setListing((before) => (before ? { ...before, error: String(error) } : null));
      } finally {
        if (ticket === asked.current) setLoading(false);
      }
    },
    [kind],
  );

  useEffect(() => {
    if (isOpen) void open(startPath || undefined);
  }, [isOpen, startPath, open]);

  const choose = (path: string): void => {
    onChoose(path);
    onClose();
  };
  const check = listing?.check;

  return (
    <Modal.Backdrop isOpen={isOpen} onOpenChange={(isNowOpen) => !isNowOpen && onClose()}>
      <Modal.Container size="lg">
        <Modal.Dialog>
          <Modal.CloseTrigger />
          <Modal.Header>
            <Modal.Heading>{title}</Modal.Heading>
          </Modal.Header>
          <Modal.Body className="flex flex-col gap-3">
            {listing && listing.roots.length > 0 && (
              <div className="flex flex-wrap gap-1.5">
                {listing.roots.map((root) => (
                  <Button key={root.path} size="sm" variant="tertiary" onPress={() => void open(root.path)}>
                    <HardDrive />
                    {root.name}
                  </Button>
                ))}
              </div>
            )}
            <div className="flex items-center gap-2">
              <Button
                size="sm"
                variant="secondary"
                isIconOnly
                aria-label="The folder above"
                isDisabled={!listing?.parent || isLoading}
                onPress={() => listing?.parent && void open(listing.parent)}
              >
                <ArrowUp />
              </Button>
              <span className="grow truncate font-mono text-[12px]" title={listing?.path}>
                {listing?.path ?? ""}
              </span>
              {isLoading && <Spinner size="sm" />}
            </div>
            {listing?.error && <span className="text-xs text-warning">{listing.error}</span>}
            <ScrollShadow className="folder-browser-list h-80 rounded-lg border border-separator">
              <ul className="flex flex-col py-1">
                {listing?.entries.length === 0 && <li className="px-3 py-2 text-xs text-muted">No folders here</li>}
                {listing?.entries.map((entry) => (
                  <li key={entry.path}>
                    <button
                      type="button"
                      className="flex w-full cursor-pointer items-center gap-2 px-3 py-1.5 text-left text-[13px] hover:bg-default"
                      onClick={() => (entry.isFolder ? void open(entry.path) : choose(entry.path))}
                    >
                      {entry.isFolder ? (
                        <Folder className="size-4 shrink-0 text-muted" />
                      ) : (
                        <File className="size-4 shrink-0 text-muted" />
                      )}
                      <span className="grow truncate">{entry.name}</span>
                      {entry.hint && (
                        <Chip size="sm" color="accent" variant="soft">
                          {entry.hint}
                        </Chip>
                      )}
                    </button>
                  </li>
                ))}
              </ul>
            </ScrollShadow>
            {check && (
              <span className={`text-xs ${check.isValid ? "text-success" : "text-muted"}`}>
                {check.isValid && <CircleCheckFill className="mr-1 inline size-3.5" />}
                This folder: {check.message}
              </span>
            )}
          </Modal.Body>
          <Modal.Footer>
            <Button variant="tertiary" onPress={onClose}>
              Cancel
            </Button>
            {kind !== "luajit" && (
              <Button isDisabled={!listing || isLoading} onPress={() => listing && choose(listing.path)}>
                Choose this folder
              </Button>
            )}
          </Modal.Footer>
        </Modal.Dialog>
      </Modal.Container>
    </Modal.Backdrop>
  );
};
