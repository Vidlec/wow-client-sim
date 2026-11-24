// Small pieces the panels share: an empty state, a problem line, a switch with its label and note, a copy button,
// the gamepad's icon (the icon set has none), a path that wraps between its folders
import { Check, Copy } from "@gravity-ui/icons";
import { Button, Description, Label, Switch, Tooltip } from "@heroui/react";
import { type ReactNode, useEffect, useState } from "react";

export const EmptyState = ({
  icon,
  children,
  action,
}: {
  icon?: ReactNode;
  children: ReactNode;
  action?: ReactNode;
}) => (
  <div className="flex flex-col items-center gap-2.5 rounded-xl border border-border border-dashed px-5 py-7 text-center">
    {icon && <span className="text-muted [&>svg]:size-7">{icon}</span>}
    <div className="text-[13px] leading-relaxed text-muted">{children}</div>
    {action}
  </div>
);

export const Problem = ({ children }: { children: ReactNode }) =>
  children ? (
    <p role="alert" className="text-xs text-danger">
      {children}
    </p>
  ) : null;

type SwitchRowProps = {
  label: ReactNode;
  description?: ReactNode;
  isSelected: boolean;
  onChange: (isSelected: boolean) => void;
  isDisabled?: boolean;
};

/** A switch with its label (and a note under it), the whole row pressable */
export const SwitchRow = ({ label, description, isSelected, onChange, isDisabled }: SwitchRowProps) => (
  <Switch size="sm" isSelected={isSelected} onChange={onChange} isDisabled={isDisabled ?? false}>
    <Switch.Content>
      <Switch.Control className="shrink-0">
        <Switch.Thumb />
      </Switch.Control>
      <Label className="text-[13px]">{label}</Label>
    </Switch.Content>
    {description && <Description className="pl-9 text-xs">{description}</Description>}
  </Switch>
);

const COPIED_MS = 1500;

/** Copies text; says so for a moment */
export const CopyButton = ({ text, label = "Copy" }: { text: string; label?: string }) => {
  const [state, setState] = useState<"idle" | "copied" | "failed">("idle");
  useEffect(() => {
    if (state === "idle") return;
    const timer = setTimeout(() => setState("idle"), COPIED_MS);
    return () => clearTimeout(timer);
  }, [state]);
  const copy = async (): Promise<void> => {
    try {
      await navigator.clipboard.writeText(text);
      setState("copied");
    } catch {
      setState("failed");
    }
  };
  return (
    <Tooltip delay={300}>
      <Button isIconOnly size="sm" variant="ghost" aria-label={label} onPress={() => void copy()}>
        {state === "copied" ? <Check className="text-success" /> : <Copy />}
      </Button>
      <Tooltip.Content>{state === "copied" ? "Copied" : state === "failed" ? "Could not copy" : label}</Tooltip.Content>
    </Tooltip>
  );
};

/** A controller, drawn as the icon set draws its icons (16 px, currentColor) */
export const GamepadIcon = ({ className }: { className?: string }) => (
  <svg
    viewBox="0 0 16 16"
    width="16"
    height="16"
    fill="none"
    stroke="currentColor"
    strokeWidth="1.4"
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
    className={className}
  >
    <path d="M4.6 4h6.8a3 3 0 0 1 2.9 2.3l.8 3.6a1.8 1.8 0 0 1-3.1 1.6L10.6 10H5.4L3.99 11.5A1.8 1.8 0 0 1 .9 9.9l.8-3.6A3 3 0 0 1 4.6 4Z" />
    <path d="M5 6.2v2M4 7.2h2" />
    <circle cx="10.6" cy="6.6" r=".2" fill="currentColor" />
    <circle cx="11.8" cy="7.8" r=".2" fill="currentColor" />
  </svg>
);

/** A title and its value in a two-column list */
/** A file or folder path in monospace that wraps only after a separator, never inside a folder's name */
export const PathText = ({ path, className }: { path: string; className?: string }) => (
  <span className={`font-mono text-[11px] ${className ?? ""}`}>
    {path.split(/(?<=[/\\])/).map((part, index) => (
      // biome-ignore lint/suspicious/noArrayIndexKey: the parts of one path, in their fixed order
      <span key={index}>
        {part}
        <wbr />
      </span>
    ))}
  </span>
);

export const Facts = ({ rows }: { rows: readonly (readonly [string, ReactNode])[] }) => (
  <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-[13px]">
    {rows.map(([key, value]) => (
      <div key={key} className="contents">
        <dt className="text-muted">{key}</dt>
        <dd className="min-w-0 break-words">{value}</dd>
      </div>
    ))}
  </dl>
);
