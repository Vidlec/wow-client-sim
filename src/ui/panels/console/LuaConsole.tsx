// Lua in the game's global scope: typed (Ctrl+Enter runs it), its printed lines and its result or error kept as a
// short history, newest first; a few lines to start from in a menu
import { Play, TrashBin } from "@gravity-ui/icons";
import { Button, Dropdown, Kbd, Label, TextArea, Tooltip } from "@heroui/react";
import { type KeyboardEvent, useState } from "react";
import { CopyButton } from "../../components/bits.tsx";
import { api } from "../../sim/api.ts";
import { useTask } from "../../sim/hooks.ts";

const HISTORY = 20;

const EXAMPLES: readonly { label: string; code: string }[] = [
  { label: "The map shown", code: "return WorldMapFrame:GetMapID()" },
  {
    label: "Where the player is",
    code: "local map = C_Map.GetBestMapForUnit('player')\nreturn map, C_Map.GetPlayerMapPosition(map, 'player'):GetXY()",
  },
  { label: "Quests in the log", code: "return C_QuestLog.GetNumQuestLogEntries()" },
  { label: "An addon's state", code: "return C_AddOns.IsAddOnLoaded('Blizzard_WorldMap')" },
  {
    label: "The frame under the mouse",
    code: "local focus = GetMouseFoci()[1]\nreturn focus and focus:GetDebugName()",
  },
  { label: "Print to the chat", code: "print('Hello from the console')" },
];

type Run = { id: number; code: string; lines: string[]; result: string | null; error: string | null };

let nextRunId = 1;

export const LuaConsole = () => {
  const [code, setCode] = useState("");
  const [runs, setRuns] = useState<Run[]>([]);
  const exec = useTask(async (source: string) => {
    const answer = await api.exec(source);
    const run: Run = {
      id: nextRunId++,
      code: source,
      lines: answer.output ?? [],
      result: answer.error ? null : (answer.result ?? null),
      error: answer.error ?? null,
    };
    setRuns((before) => [run, ...before].slice(0, HISTORY));
    return answer;
  });
  const run = (): void => {
    if (code.trim()) void exec.run(code);
  };
  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>): void => {
    if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
      event.preventDefault();
      run();
    }
  };

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-col gap-1.5">
        <div className="flex items-center gap-2">
          <Label className="grow text-sm">Lua in the game's global scope</Label>
          <Dropdown>
            <Button size="sm" variant="ghost">
              Examples
            </Button>
            <Dropdown.Popover placement="bottom end">
              <Dropdown.Menu onAction={(key) => setCode(EXAMPLES.find((example) => example.label === key)?.code ?? "")}>
                {EXAMPLES.map((example) => (
                  <Dropdown.Item key={example.label} id={example.label} textValue={example.label}>
                    <Label>{example.label}</Label>
                  </Dropdown.Item>
                ))}
              </Dropdown.Menu>
            </Dropdown.Popover>
          </Dropdown>
        </div>
        <TextArea
          aria-label="Lua to run"
          value={code}
          onChange={(event) => setCode(event.target.value)}
          onKeyDown={onKeyDown}
          rows={6}
          spellCheck={false}
          placeholder="return WorldMapFrame:GetMapID()"
          className="lua-editor font-mono text-[12.5px]"
        />
        <div className="flex items-center gap-2">
          <Button size="sm" isPending={exec.isPending} isDisabled={!code.trim()} onPress={run}>
            <Play />
            Run
          </Button>
          <span className="text-xs text-muted">
            <Kbd className="text-[10px]">
              <Kbd.Abbr keyValue="ctrl" />
              <Kbd.Content>Enter</Kbd.Content>
            </Kbd>
          </span>
          <span className="grow" />
          {runs.length > 0 && (
            <Tooltip delay={300}>
              <Button isIconOnly size="sm" variant="ghost" aria-label="Forget the runs" onPress={() => setRuns([])}>
                <TrashBin />
              </Button>
              <Tooltip.Content>Forget the runs</Tooltip.Content>
            </Tooltip>
          )}
        </div>
      </div>
      {runs.map((entry) => {
        const output = [...entry.lines, entry.error ? `error: ${entry.error}` : (entry.result ?? "")]
          .filter(Boolean)
          .join("\n");
        return (
          <div key={entry.id} className="lua-run flex flex-col overflow-hidden rounded-lg border border-separator">
            <div className="flex items-start gap-2 bg-surface-secondary px-2.5 py-1.5">
              <pre className="min-w-0 grow truncate font-mono text-[11px] text-muted">{entry.code}</pre>
              <Button size="sm" variant="ghost" className="h-5 px-1.5 text-[11px]" onPress={() => setCode(entry.code)}>
                Again
              </Button>
              {output && <CopyButton text={output} label="Copy the output" />}
            </div>
            <pre
              className={`max-h-60 overflow-auto px-2.5 py-2 font-mono text-[12px] whitespace-pre-wrap ${entry.error ? "text-danger" : "text-[#c9e8c9]"}`}
            >
              {output || <span className="text-muted">(nothing returned)</span>}
            </pre>
          </div>
        );
      })}
    </div>
  );
};
