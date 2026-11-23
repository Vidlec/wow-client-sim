// A slash command, as typed in the game's chat box: Enter runs it, Up and Down go through the ones typed before (kept
// for the session, as the game's chat box keeps them). Only slash commands run; chat is not sent anywhere.
import { Terminal } from "@gravity-ui/icons";
import { InputGroup, TextField, toast } from "@heroui/react";
import { type KeyboardEvent, useRef, useState } from "react";
import { api } from "../../sim/api.ts";
import { refreshState } from "../../sim/store.ts";

const history: string[] = [];

export const SlashCommand = () => {
  const [text, setText] = useState("");
  const position = useRef(history.length);

  const run = async (): Promise<void> => {
    const command = text.trim();
    if (!command) return;
    setText("");
    if (history[history.length - 1] !== command) history.push(command);
    position.current = history.length;
    if (!command.startsWith("/")) {
      toast.warning("Only slash commands run here", { description: "Chat is not sent anywhere: start with /" });
      return;
    }
    try {
      await api.slash(command);
    } catch (error) {
      toast.danger("The command did not reach the game", { description: String(error) });
    }
    void refreshState();
  };

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>): void => {
    if (event.key === "Enter") {
      event.preventDefault();
      void run();
      return;
    }
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    event.preventDefault();
    position.current = Math.max(0, Math.min(history.length, position.current + (event.key === "ArrowUp" ? -1 : 1)));
    setText(history[position.current] ?? "");
  };

  return (
    <TextField aria-label="Slash command" value={text} onChange={setText} className="w-80 min-w-44 shrink">
      <InputGroup className="h-8">
        <InputGroup.Prefix className="text-accent">
          <Terminal />
        </InputGroup.Prefix>
        <InputGroup.Input
          placeholder="/command  (↑ ↓ for earlier ones)"
          autoComplete="off"
          spellCheck={false}
          onKeyDown={onKeyDown}
          className="font-mono text-[13px]"
          onFocus={() => {
            if (!text) setText("/");
          }}
          onBlur={() => {
            if (text === "/") setText("");
          }}
        />
      </InputGroup>
    </TextField>
  );
};
