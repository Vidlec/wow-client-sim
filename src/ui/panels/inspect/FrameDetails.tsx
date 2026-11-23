// One frame's details, as the inspector opens them: where it hangs (its parents, each a link), what it is and who
// made it, where it is on screen and what it takes; its anchors, scripts, attributes and children (each a link)
import { Xmark } from "@gravity-ui/icons";
import { Accordion, Breadcrumbs, Button, Chip } from "@heroui/react";
import { CopyButton, Facts } from "../../components/bits.tsx";
import type { InspectedFrameInfo } from "../../sim/types.ts";

type Props = { info: InspectedFrameInfo; onOpen: (id: number) => void; onClose: () => void };

const Link = ({ id, children, onOpen }: { id: number; children: string; onOpen: (id: number) => void }) => (
  <button
    type="button"
    className="cursor-pointer truncate text-left font-mono text-accent hover:underline"
    onClick={() => onOpen(id)}
  >
    {children}
  </button>
);

export const FrameDetails = ({ info, onOpen, onClose }: Props) => {
  const takes = [info.mouse && "mouse", info.wheel && "wheel", info.keyboard && "keyboard"].filter(Boolean).join(", ");
  const sections = [
    {
      id: "anchors",
      title: `Anchors (${info.points.length})`,
      body: info.points.map((point) => (
        <div key={`${point.point}${point.relative}${point.relativePoint}`} className="font-mono text-[12px]">
          {point.point} → {point.relative} {point.relativePoint} ({point.x}, {point.y})
        </div>
      )),
    },
    {
      id: "scripts",
      title: `Scripts (${info.scripts.length})`,
      body: (
        <div className="flex flex-wrap gap-1">
          {info.scripts.map((script) => (
            <Chip key={script} size="sm" variant="soft" className="font-mono">
              {script}
            </Chip>
          ))}
        </div>
      ),
    },
    {
      id: "attributes",
      title: `Attributes (${info.attributes.length})`,
      body: info.attributes.map((attribute) => (
        <div key={attribute.key} className="truncate font-mono text-[12px]">
          {attribute.key} = <span className="text-muted">{attribute.value}</span>
        </div>
      )),
    },
    {
      id: "children",
      title: `Children (${info.children.length})`,
      body: info.children.map((child) => (
        <div key={child.id} className="flex items-center gap-2 text-[12px]">
          <Link id={child.id} onOpen={onOpen}>
            {child.name}
          </Link>
          <span className="shrink-0 text-muted">
            {child.type}
            {child.shown ? "" : " · hidden"}
          </span>
        </div>
      )),
    },
  ].filter(
    (section) =>
      section.id === "children" || (Array.isArray(section.body) ? section.body.length > 0 : info.scripts.length > 0),
  );

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-2">
        <h3 className="min-w-0 grow truncate font-mono text-[13px] font-semibold text-gold">{info.name}</h3>
        <CopyButton text={info.name} label="Copy the name" />
        <Button isIconOnly size="sm" variant="ghost" aria-label="Close the details" onPress={onClose}>
          <Xmark />
        </Button>
      </div>
      {info.path.length > 0 && (
        <Breadcrumbs className="flex-wrap text-[12px]">
          {info.path.map((parent) => (
            <Breadcrumbs.Item key={parent.id}>
              <Link id={parent.id} onOpen={onOpen}>
                {parent.name}
              </Link>
            </Breadcrumbs.Item>
          ))}
          <Breadcrumbs.Item>{info.name.split(".").pop() ?? info.name}</Breadcrumbs.Item>
        </Breadcrumbs>
      )}
      <Facts
        rows={[
          ["type", info.type],
          ["made by", info.creator ?? "the game"],
          ["shown", `${info.shown}${info.visible === false ? " (a parent is hidden)" : ""}`],
          ["strata : level", info.strata ? `${info.strata} : ${info.level}` : "–"],
          ["alpha · scale", `${info.alpha ?? "–"} · ${info.scale ?? "–"}`],
          ["on screen", info.rect ? `${info.rect[0]}, ${info.rect[1]} · ${info.rect[2]}×${info.rect[3]}` : "no size"],
          ["takes", takes || "nothing"],
          ["regions", `${info.regions.textures} textures, ${info.regions.fontStrings} font strings`],
        ]}
      />
      <Accordion allowsMultipleExpanded defaultExpandedKeys={["children"]} variant="surface">
        {sections.map((section) => (
          <Accordion.Item key={section.id} id={section.id}>
            <Accordion.Heading>
              <Accordion.Trigger className="text-[13px]">
                {section.title}
                <Accordion.Indicator />
              </Accordion.Trigger>
            </Accordion.Heading>
            <Accordion.Panel>
              <Accordion.Body className="flex max-h-72 flex-col gap-1 overflow-y-auto">{section.body}</Accordion.Body>
            </Accordion.Panel>
          </Accordion.Item>
        ))}
      </Accordion>
    </div>
  );
};
