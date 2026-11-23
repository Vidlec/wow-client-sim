// The Inspect panel, as the game's /fstack: every frame under the mouse, top first, each with its box on the game. A
// row pointed at shows its frame's box alone; a row pressed opens its details, whose parents and children open theirs.
import { CurlyBrackets, HandPointUp } from "@gravity-ui/icons";
import { Chip, Kbd, toast } from "@heroui/react";
import { useState } from "react";
import { EmptyState, SwitchRow } from "../../components/bits.tsx";
import { Section } from "../../components/Section.tsx";
import { getGameScreen, useInspectedFrames } from "../../shell/screen.ts";
import { api } from "../../sim/api.ts";
import { setPref, usePref } from "../../sim/prefs.ts";
import type { InspectedFrameInfo } from "../../sim/types.ts";
import { FrameDetails } from "./FrameDetails.tsx";

export const InspectPanel = () => {
  const isOn = usePref("inspectOn");
  const isHeld = usePref("inspectHeld");
  const isDrawnOnly = usePref("inspectDrawnOnly");
  const frames = useInspectedFrames() ?? [];
  const [details, setDetails] = useState<InspectedFrameInfo | null>(null);

  const open = async (id: number): Promise<void> => {
    try {
      const info = await api.frameInfo(id);
      if (info.error) toast.danger(info.error);
      else setDetails(info);
    } catch (error) {
      toast.danger("The frame's details did not come", { description: String(error) });
    }
  };

  return (
    <>
      <Section title="Frames under the mouse" icon={<CurlyBrackets className="size-3.5" />}>
        <SwitchRow
          label="Show them, as /fstack"
          description="Each with its box over the game; the top one first"
          isSelected={isOn}
          onChange={(value) => setPref("inspectOn", value)}
        />
        <SwitchRow
          label="Hold the list"
          description={
            <>
              It stays as it is while the mouse moves on (holding{" "}
              <Kbd className="text-[10px]">
                <Kbd.Content>Alt</Kbd.Content>
              </Kbd>{" "}
              over the game does the same)
            </>
          }
          isSelected={isHeld}
          onChange={(value) => setPref("inspectHeld", value)}
        />
        <SwitchRow
          label="Only frames that draw something or take the mouse"
          description="Off: every frame under the mouse, the full-screen containers and model scenes too, as /fstack lists them"
          isSelected={isDrawnOnly}
          onChange={(value) => setPref("inspectDrawnOnly", value)}
        />
      </Section>

      {!isOn ? (
        <EmptyState icon={<HandPointUp />}>Switch it on, then point at the game.</EmptyState>
      ) : frames.length === 0 ? (
        <EmptyState icon={<HandPointUp />}>Point at the game: the frames under the mouse are listed here.</EmptyState>
      ) : (
        <ul
          className="flex flex-col overflow-hidden rounded-xl border border-separator"
          onMouseLeave={() => getGameScreen()?.highlightFrame(null)}
        >
          {frames.map((frame, index) => (
            <li key={frame.id} className="border-separator border-b last:border-b-0">
              <button
                type="button"
                className={`inspect-row flex w-full cursor-pointer flex-col gap-0.5 px-3 py-2 text-left hover:bg-surface-secondary ${details?.frameId === frame.id ? "is-open" : ""}`}
                onMouseEnter={() => getGameScreen()?.highlightFrame(frame.id)}
                onFocus={() => getGameScreen()?.highlightFrame(frame.id)}
                onClick={() => void open(frame.id)}
              >
                <span className={`truncate font-mono text-[12px] ${index === 0 ? "text-[#ff8ae6]" : ""}`}>
                  {frame.name}
                </span>
                <span className="flex flex-wrap items-center gap-1.5 text-[11px] text-muted">
                  <Chip size="sm" variant="soft" className="h-4 px-1 text-[10px]">
                    {frame.type}
                  </Chip>
                  {frame.strata}:{frame.level}
                  {frame.mouse && <span className="text-accent">· mouse</span>}· {Math.round(frame.w)}×
                  {Math.round(frame.h)}
                  {frame.creator ? ` · made by ${frame.creator}` : ""}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}

      {details && (
        <Section title="Frame" icon={<CurlyBrackets className="size-3.5" />}>
          <FrameDetails info={details} onOpen={(id) => void open(id)} onClose={() => setDetails(null)} />
        </Section>
      )}
    </>
  );
};
