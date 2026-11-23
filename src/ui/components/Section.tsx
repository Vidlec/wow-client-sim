// A panel's card: a small heading with an icon, an optional line under it, actions on the right, then its content
import { Card } from "@heroui/react";
import type { ReactNode } from "react";

type Props = {
  title: ReactNode;
  icon?: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
  children?: ReactNode;
  className?: string;
};

export const Section = ({ title, icon, description, actions, children, className }: Props) => (
  <Card className={`section-card gap-3 p-3.5 ${className ?? ""}`}>
    <Card.Header className="flex flex-row items-center gap-2">
      {icon && (
        <span className="flex size-6 items-center justify-center rounded-md bg-accent-soft text-accent">{icon}</span>
      )}
      <Card.Title className="grow text-[13px] font-semibold tracking-wide">{title}</Card.Title>
      {actions}
    </Card.Header>
    {description && <Card.Description className="-mt-1 text-xs leading-relaxed">{description}</Card.Description>}
    {children !== undefined && <Card.Content className="flex flex-col gap-3">{children}</Card.Content>}
  </Card>
);
