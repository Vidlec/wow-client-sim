// The Errors panel: the Lua errors so far (each with where it came from and its stack), cleared at will; and what the
// simulator only pretends exists that your addons reached (templates, strings, functions: candidates to add)
import { CircleCheck, TrashBin, TriangleExclamation } from "@gravity-ui/icons";
import { Accordion, Button, Chip } from "@heroui/react";
import { CopyButton, EmptyState } from "../../components/bits.tsx";
import { Section } from "../../components/Section.tsx";
import { api } from "../../sim/api.ts";
import { useSimState, useTask } from "../../sim/hooks.ts";
import type { SimError, Stub } from "../../sim/types.ts";
import { ErrorCard } from "./ErrorCard.tsx";

const NO_ERRORS: SimError[] = [];
const NO_STUBS: Stub[] = [];

const Stubs = () => {
  const stubs = useSimState((state) => state.stubs, NO_STUBS);
  const reached = stubs.filter((stub) => stub.addons && stub.addons.length > 0);
  const internal = stubs.length - reached.length;
  return (
    <Section
      title="Pretended to exist"
      icon={<TriangleExclamation className="size-3.5" />}
      description="Templates, strings and functions the simulator only stands in for, reached by your addons: candidates to add"
    >
      {reached.length === 0 ? (
        <p className="text-xs text-muted">None reached by your addons.</p>
      ) : (
        <ul className="flex flex-col divide-y divide-separator">
          {reached.map((stub) => {
            const [name, note] = stub.name.split(" (");
            return (
              <li key={stub.name} className="flex items-start gap-2 py-2 text-[12px] first:pt-0">
                <span className="w-9 shrink-0 pt-0.5 text-right font-mono text-[11px] text-muted">{stub.count}×</span>
                <div className="flex min-w-0 flex-col gap-1">
                  <span className="font-mono break-words text-foreground">{name}</span>
                  {note && <span className="text-[11px] text-muted">({note}</span>}
                  <div className="flex flex-wrap gap-1">
                    {stub.addons?.map((addon) => (
                      <Chip key={addon} size="sm" variant="soft" color="accent">
                        {addon}
                      </Chip>
                    ))}
                  </div>
                </div>
              </li>
            );
          })}
        </ul>
      )}
      {internal > 0 && (
        <Accordion variant="surface">
          <Accordion.Item id="internal">
            <Accordion.Heading>
              <Accordion.Trigger className="text-xs text-muted">
                …and {internal.toLocaleString()} reached only inside the game's own interface code
                <Accordion.Indicator />
              </Accordion.Trigger>
            </Accordion.Heading>
            <Accordion.Panel>
              <Accordion.Body className="max-h-64 overflow-y-auto font-mono text-[11px] text-muted">
                {stubs
                  .filter((stub) => !stub.addons?.length)
                  .sort((first, second) => second.count - first.count)
                  .slice(0, 200)
                  .map((stub) => (
                    <div key={stub.name}>
                      {stub.count}× {stub.name}
                    </div>
                  ))}
              </Accordion.Body>
            </Accordion.Panel>
          </Accordion.Item>
        </Accordion>
      )}
    </Section>
  );
};

export const ErrorsPanel = () => {
  const errors = useSimState((state) => state.errors, NO_ERRORS);
  const clear = useTask(api.clearErrors);
  const allText = errors.map((error) => `${error.message}\n${error.stack ?? ""}`).join("\n\n");
  return (
    <>
      <div className="flex items-center gap-2">
        <span className="grow text-xs text-muted">
          {errors.length === 0 ? "No errors" : errors.length === 1 ? "1 error" : `${errors.length} errors`}
        </span>
        {errors.length > 0 && <CopyButton text={allText} label="Copy every error" />}
        <Button
          size="sm"
          variant="tertiary"
          isDisabled={errors.length === 0}
          isPending={clear.isPending}
          onPress={() => void clear.run()}
        >
          <TrashBin />
          Clear
        </Button>
      </div>
      {errors.length === 0 ? (
        <EmptyState icon={<CircleCheck className="text-success" />}>No Lua errors. Your addons run clean.</EmptyState>
      ) : (
        errors.map((error, index) => (
          <ErrorCard key={`${error.message}${error.time ?? ""}`} error={error} isOpenAtFirst={index === 0} />
        ))
      )}
      <Stubs />
    </>
  );
};
